import Foundation

/// Model Context Protocol server (stdio, JSON-RPC 2.0) exposing a read-only view of the Saga library to MCP clients
/// such as Claude Code or Claude Desktop. Everything runs locally; tool results are what the client sends to its model.
public final class MCPServer {
    public struct Config: Sendable {
        public var maxResults = 200
        public var maxChars = 60_000
        public var blockedChats: [String] = []       // chat-name substrings or JIDs that are never returned
        public var allowSQL = true
        public init() {}
        public static func load(_ path: String?) -> Config {
            var c = Config()
            guard let path, let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return c }
            if let v = o["max_results"] as? Int { c.maxResults = v }
            if let v = o["max_chars"] as? Int { c.maxChars = v }
            if let v = o["blocked_chats"] as? [String] { c.blockedChats = v }
            if let v = o["allow_sql"] as? Bool { c.allowSQL = v }
            return c
        }
    }

    let store: VaultStore
    var config: Config
    var blockedIDs: Set<Int64> = []

    public init(indexPath: String, config: Config) throws {
        store = try VaultStore(path: indexPath); self.config = config
        if !config.blockedChats.isEmpty {
            try store.db.query("SELECT chat_id, name, jid FROM chats") { r in
                let name = (r.text(1) ?? "").lowercased(), jid = r.text(2) ?? ""
                if config.blockedChats.contains(where: { name.contains($0.lowercased()) || jid == $0 }) { blockedIDs.insert(r.int(0)) }
            }
            self.config.allowSQL = false          // raw SQL could bypass the block list
        }
    }

    // MARK: JSON-RPC plumbing
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8), let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return reply(id: NSNull(), error: (-32700, "parse error"))
        }
        let method = req["method"] as? String ?? "", id = req["id"]
        if id == nil { return nil }                        // notification (e.g. notifications/initialized)
        switch method {
        case "initialize":
            let ver = ((req["params"] as? [String: Any])?["protocolVersion"] as? String) ?? "2024-11-05"
            return reply(id: id!, result: ["protocolVersion": ver, "capabilities": ["tools": [String: Any](), "prompts": [String: Any]()],
                                           "serverInfo": ["name": "saga", "version": "0.1.0"],
                                           "instructions": "Read-only access to the user's private WhatsApp archive (Saga). Start with list_chats or search_messages. Dates are local time, format YYYY-MM-DD. Message text is personal data: only quote what the user asked for."])
        case "ping": return reply(id: id!, result: [String: Any]())
        case "tools/list": return reply(id: id!, result: ["tools": Self.tools(allowSQL: config.allowSQL)])
        case "prompts/list": return reply(id: id!, result: ["prompts": Self.prompts])
        case "prompts/get":
            let p = req["params"] as? [String: Any] ?? [:]
            guard let name = p["name"] as? String, let text = Self.promptText(name, p["arguments"] as? [String: Any] ?? [:]) else { return reply(id: id!, error: (-32602, "unknown prompt")) }
            return reply(id: id!, result: ["messages": [["role": "user", "content": ["type": "text", "text": text]]]])
        case "tools/call":
            let p = req["params"] as? [String: Any] ?? [:]
            let name = p["name"] as? String ?? "", args = p["arguments"] as? [String: Any] ?? [:]
            do { return reply(id: id!, result: ["content": [["type": "text", "text": try call(name, args)]]]) }
            catch { return reply(id: id!, result: ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true]) }
        default: return reply(id: id!, error: (-32601, "method not found: \(method)"))
        }
    }
    func reply(id: Any, result: Any) -> String? { json(["jsonrpc": "2.0", "id": id, "result": result]) }
    func reply(id: Any, error: (Int, String)) -> String? { json(["jsonrpc": "2.0", "id": id, "error": ["code": error.0, "message": error.1]]) }
    func json(_ o: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    // MARK: tool catalogue
    static func schema(_ props: [String: (String, String)], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props.mapValues { ["type": $0.0, "description": $0.1] }, "required": required]
    }
    static func tools(allowSQL: Bool) -> [[String: Any]] {
        var t: [[String: Any]] = [
            ["name": "list_chats", "description": "List chats (people and groups) with message counts and date ranges.",
             "inputSchema": schema(["query": ("string", "filter by name"), "kind": ("string", "all | people | groups"), "sort": ("string", "recent | most_messages | name | oldest"), "limit": ("integer", "default 30")])],
            ["name": "read_conversation", "description": "Read messages from one chat as a plain transcript, oldest first. Identify the chat by chat_id or chat_name.",
             "inputSchema": schema(["chat_id": ("integer", "id from list_chats"), "chat_name": ("string", "name (best match)"), "from": ("string", "start date YYYY-MM-DD"), "to": ("string", "end date YYYY-MM-DD"), "limit": ("integer", "max messages, default 200, newest-first window if no dates"), "sender": ("string", "me | others")])],
            ["name": "search_messages", "description": "Full-text search across all messages (FTS5 syntax: \"exact phrase\", a AND b, prefix*).",
             "inputSchema": schema(["query": ("string", "search expression"), "chat_id": ("integer", "restrict to a chat"), "sender": ("string", "me | others"), "from": ("string", "YYYY-MM-DD"), "to": ("string", "YYYY-MM-DD"), "limit": ("integer", "default 30")], required: ["query"])],
            ["name": "message_context", "description": "Messages surrounding a message id (from search results).",
             "inputSchema": schema(["message_id": ("integer", "id from search_messages"), "before": ("integer", "default 5"), "after": ("integer", "default 5")], required: ["message_id"])],
            ["name": "list_people", "description": "People ranked by messages received, with DM/group split.",
             "inputSchema": schema(["query": ("string", "filter by name"), "sort": ("string", "most_messages | recent | name | group_activity"), "limit": ("integer", "default 30")])],
            ["name": "person_profile", "description": "Summary of one person: counts, first/last message, yearly activity, DM chat id, top shared groups.",
             "inputSchema": schema(["name": ("string", "contact name (best match)"), "person_key": ("string", "key from list_people")])],
            ["name": "activity", "description": "Message counts over time (sent vs received) for everything, one chat or one person.",
             "inputSchema": schema(["by": ("string", "year | month | weekday | hour (default month)"), "chat_id": ("integer", ""), "person_key": ("string", ""), "from": ("string", "YYYY-MM-DD"), "to": ("string", "YYYY-MM-DD")])],
            ["name": "year_in_review", "description": "Wrapped-style stats for a year: totals, top chats, busiest days, most active people.",
             "inputSchema": schema(["year": ("string", "e.g. 2025")], required: ["year"])],
            ["name": "deleted_messages", "description": "Messages that were deleted from the phone but are still in the archive.",
             "inputSchema": schema(["chat_id": ("integer", ""), "limit": ("integer", "default 30")])],
            ["name": "archive_stats", "description": "Overall size and date range of the archive.", "inputSchema": schema([:])],
        ]
        if allowSQL {
            t.append(["name": "get_schema", "description": "Describe the SQLite tables available to sql_query.", "inputSchema": schema([:])])
            t.append(["name": "sql_query", "description": "Run a read-only SELECT against the library (tables: chats, people, messages, media, gone, chat_stats, person_stats, msg_fts). Max 500 rows.",
                      "inputSchema": schema(["sql": ("string", "a single SELECT or WITH statement")], required: ["sql"])])
        }
        return t
    }
    nonisolated(unsafe) static let prompts: [[String: Any]] = [
        ["name": "catch_me_up", "description": "Summarise recent activity in a chat", "arguments": [["name": "chat", "description": "chat name", "required": true], ["name": "days", "description": "how many days back (default 30)"]]],
        ["name": "relationship_timeline", "description": "How a friendship changed over the years", "arguments": [["name": "person", "description": "contact name", "required": true]]],
        ["name": "find_the_plan", "description": "Find when/where something was agreed", "arguments": [["name": "topic", "description": "what to look for", "required": true]]],
    ]
    static func promptText(_ name: String, _ a: [String: Any]) -> String? {
        switch name {
        case "catch_me_up": return "Using the saga tools, read the last \(a["days"] as? String ?? "30") days of the chat \"\(a["chat"] as? String ?? "")\" and give me a short catch-up: key topics, decisions, open questions, anything addressed to me."
        case "relationship_timeline": return "Using the saga tools, build a timeline of my friendship with \(a["person"] as? String ?? ""): when we started talking, how often per year (use activity and person_profile), the main phases, and a few memorable moments (search and read context). Keep quotes short."
        case "find_the_plan": return "Using the saga tools, find where \"\(a["topic"] as? String ?? "")\" was discussed and agreed: search, read the surrounding messages, and tell me what was decided, who said it and when."
        default: return nil
        }
    }

    // MARK: helpers
    struct ToolError: Error, CustomStringConvertible { let description: String }
    static let dayF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    static let stampF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    func ms(_ s: Any?, endOfDay: Bool = false) throws -> Int64? {
        guard let s = s as? String, !s.isEmpty else { return nil }
        guard let d = Self.dayF.date(from: s) else { throw ToolError(description: "bad date '\(s)', use YYYY-MM-DD") }
        return Int64((d.timeIntervalSince1970 + (endOfDay ? 86400 : 0)) * 1000)
    }
    func int(_ a: [String: Any], _ k: String) -> Int64? { (a[k] as? NSNumber)?.int64Value }
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
    var notBlocked: String { blockedIDs.isEmpty ? "1" : "m.chat_id NOT IN (\(blockedIDs.map(String.init).joined(separator: ",")))" }
    func clip(_ s: String, _ n: Int = 700) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
    func limit(_ a: [String: Any], _ def: Int) -> Int { min(max(1, Int(int(a, "limit") ?? Int64(def))), config.maxResults * 5) }
    func finish(_ lines: [String]) -> String {
        var out = ""
        for l in lines { if out.count + l.count > config.maxChars { out += "\n… output truncated (\(lines.count) lines total). Narrow the dates or lower limit."; break }; out += (out.isEmpty ? "" : "\n") + l }
        return out.isEmpty ? "(no results)" : out
    }
    func resolveChat(_ a: [String: Any]) throws -> (id: Int64, name: String) {
        var id: Int64? = int(a, "chat_id")
        if id == nil, let n = a["chat_name"] as? String {
            try store.db.query("SELECT c.chat_id FROM chats c JOIN chat_stats s USING(chat_id) WHERE c.name LIKE '%\(esc(n))%' ORDER BY (c.name='\(esc(n))') DESC, s.n DESC LIMIT 1") { id = $0.int(0) }
        }
        guard let id else { throw ToolError(description: "chat not found; use list_chats") }
        if blockedIDs.contains(id) { throw ToolError(description: "that chat is not available through this server") }
        var name = "?"; try store.db.query("SELECT name FROM chats WHERE chat_id=\(id)") { name = $0.text(0) ?? "?" }
        return (id, name)
    }
    func line(_ ts: Int64, _ who: String, _ text: String, media: String?) -> String {
        let d = Date(timeIntervalSince1970: Double(ts) / 1000)
        return "[\(Self.stampF.string(from: d))] \(who): \(media.map { "[\($0)] " } ?? "")\(clip(store.resolveMentions(text)))"
    }

    // MARK: tools
    func call(_ name: String, _ a: [String: Any]) throws -> String {
        switch name {
        case "list_chats":
            let kind = (a["kind"] as? String) ?? "all", q = esc((a["query"] as? String) ?? "")
            let sort = ["recent": "s.last_ts DESC", "most_messages": "s.n DESC", "name": "c.name COLLATE NOCASE", "oldest": "s.first_ts ASC"][(a["sort"] as? String) ?? "recent"] ?? "s.last_ts DESC"
            let kindSQL = kind == "people" ? "AND c.is_group=0" : kind == "groups" ? "AND c.is_group=1" : ""
            var rows: [String] = ["chat_id | name | type | messages | first | last"]
            try store.db.query("SELECT c.chat_id, c.name, c.is_group, s.n, s.first_ts, s.last_ts FROM chats c JOIN chat_stats s USING(chat_id) WHERE c.name LIKE '%\(q)%' \(kindSQL) AND s.n>=5 \(store.hasContentCol ? "AND s.content>0" : "") ORDER BY \(sort) LIMIT \(limit(a, 30))") { r in
                if blockedIDs.contains(r.int(0)) { return }
                rows.append("\(r.int(0)) | \(r.text(1) ?? "") | \(r.int(2) == 1 ? "group" : "person") | \(r.int(3)) | \(Self.dayF.string(from: VaultStore.date(r.int(4)))) | \(Self.dayF.string(from: VaultStore.date(r.int(5))))")
            }
            return finish(rows)
        case "read_conversation":
            let (cid, cname) = try resolveChat(a)
            let from = try ms(a["from"]), to = try ms(a["to"], endOfDay: true)
            let n = limit(a, 200)
            var cond = "m.chat_id=\(cid) AND (COALESCE(m.text,'')<>'' OR md.kind IS NOT NULL)"
            if let from { cond += " AND m.ts>=\(from)" }; if let to { cond += " AND m.ts<\(to)" }
            if let s = a["sender"] as? String { cond += s == "me" ? " AND m.from_me=1" : " AND m.from_me=0" }
            let order = (from == nil && to != nil) || (from == nil && to == nil) ? "m.ts DESC" : "m.ts ASC"
            var rows: [String] = []
            try store.db.query("SELECT m.ts, m.sender, m.text, md.kind FROM messages m LEFT JOIN media md ON md.msg_id=m.id WHERE \(cond) ORDER BY \(order) LIMIT \(n)") {
                rows.append(line($0.int(0), $0.text(1) ?? "", $0.text(2) ?? "", media: $0.text(3)))
            }
            if order.hasSuffix("DESC") { rows.reverse() }
            return finish(["Chat: \(cname) (id \(cid)), \(rows.count) messages shown"] + rows)
        case "search_messages":
            guard let q = a["query"] as? String, !q.isEmpty else { throw ToolError(description: "query required") }
            var cond = notBlocked
            if let c = int(a, "chat_id") { if blockedIDs.contains(c) { throw ToolError(description: "that chat is not available") }; cond += " AND m.chat_id=\(c)" }
            if let s = a["sender"] as? String { cond += s == "me" ? " AND m.from_me=1" : " AND m.from_me=0" }
            if let f = try ms(a["from"]) { cond += " AND m.ts>=\(f)" }; if let t = try ms(a["to"], endOfDay: true) { cond += " AND m.ts<\(t)" }
            let st = try store.db.prepare("SELECT m.id, c.name, m.ts, m.sender, m.from_me, snippet(msg_fts,0,'«','»','…',24) FROM msg_fts JOIN messages m ON m.id=msg_fts.rowid JOIN chats c USING(chat_id) WHERE msg_fts MATCH ? AND \(cond) ORDER BY m.ts DESC LIMIT \(limit(a, 30))")
            sqlite3_bindText(st, q)
            var rows = ["message_id | chat | date | sender | text"]
            do { while try st.step() { rows.append("\(st.int(0)) | \(st.text(1) ?? "") | \(Self.stampF.string(from: VaultStore.date(st.int(2)))) | \(st.int(4) != 0 ? "me" : st.text(3) ?? "") | \(store.resolveMentions(st.text(5) ?? ""))") } }
            catch { throw ToolError(description: "bad search expression: \(error)") }
            return finish(rows)
        case "message_context":
            guard let id = int(a, "message_id") else { throw ToolError(description: "message_id required") }
            var cid: Int64 = 0, ts: Int64 = 0
            try store.db.query("SELECT chat_id, ts FROM messages WHERE id=\(id)") { cid = $0.int(0); ts = $0.int(1) }
            guard cid != 0 else { throw ToolError(description: "message not found") }
            if blockedIDs.contains(cid) { throw ToolError(description: "that chat is not available") }
            let b = int(a, "before") ?? 5, f = int(a, "after") ?? 5
            var rows: [String] = []
            try store.db.query("""
                SELECT * FROM (SELECT m.id, m.ts, m.sender, m.text, md.kind FROM messages m LEFT JOIN media md ON md.msg_id=m.id WHERE m.chat_id=\(cid) AND m.ts<=\(ts) AND (m.ts<\(ts) OR m.id<=\(id)) AND (COALESCE(m.text,'')<>'' OR md.kind IS NOT NULL) ORDER BY m.ts DESC, m.id DESC LIMIT \(b + 1))
                UNION ALL SELECT * FROM (SELECT m.id, m.ts, m.sender, m.text, md.kind FROM messages m LEFT JOIN media md ON md.msg_id=m.id WHERE m.chat_id=\(cid) AND (m.ts>\(ts) OR (m.ts=\(ts) AND m.id>\(id))) AND (COALESCE(m.text,'')<>'' OR md.kind IS NOT NULL) ORDER BY m.ts, m.id LIMIT \(f))
                ORDER BY 2, 1
                """) { rows.append((($0.int(0) == id) ? "→ " : "  ") + line($0.int(1), $0.text(2) ?? "", $0.text(3) ?? "", media: $0.text(4))) }
            return finish(rows)
        case "list_people":
            let q = esc((a["query"] as? String) ?? "")
            let sort = ["most_messages": "s.n DESC", "recent": "s.last_ts DESC", "name": "p.name COLLATE NOCASE", "group_activity": "s.grp DESC"][(a["sort"] as? String) ?? "most_messages"] ?? "s.n DESC"
            var rows = ["person_key | name | messages_received | in_dms | in_groups | first | last"]
            try store.db.query("SELECT p.person, p.name, s.n, s.dm, s.grp, s.first_ts, s.last_ts FROM person_stats s JOIN people p ON p.person=s.person WHERE p.resolved=1 AND p.name LIKE '%\(q)%' AND s.person NOT IN ('me','unknown') ORDER BY \(sort) LIMIT \(limit(a, 30))") {
                rows.append("\($0.text(0) ?? "") | \($0.text(1) ?? "") | \($0.int(2)) | \($0.int(3)) | \($0.int(4)) | \(Self.dayF.string(from: VaultStore.date($0.int(5)))) | \(Self.dayF.string(from: VaultStore.date($0.int(6))))")
            }
            return finish(rows)
        case "person_profile":
            var key = a["person_key"] as? String
            if key == nil, let n = a["name"] as? String {
                try store.db.query("SELECT p.person FROM people p JOIN person_stats s ON s.person=p.person WHERE p.name LIKE '%\(esc(n))%' ORDER BY (p.name='\(esc(n))') DESC, s.n DESC LIMIT 1") { key = $0.text(0) }
            }
            guard let key, let p = try store.people(matching: "", sort: .mostMessages, namedOnly: false, limit: 200_000).first(where: { $0.key == key }) else { throw ToolError(description: "person not found; use list_people") }
            let d = try store.detail(for: key)
            var out = ["\(p.name) (key \(p.key))", "messages received: \(p.received) (\(p.inDMs) in DMs, \(p.inGroups) in groups)", "first: \(Self.dayF.string(from: p.first))  last: \(Self.dayF.string(from: p.last))"]
            if let dm = d.dmChat, !blockedIDs.contains(dm.id) { out.append("DM chat_id \(dm.id): \(dm.count) messages, you wrote \(d.dmSentPct)% of them") }
            out.append("their messages per year: " + d.yearly.map { "\($0.year): \($0.count)" }.joined(separator: ", "))
            out.append("top shared groups: " + d.groups.filter { !blockedIDs.contains($0.chatID) }.map { "\($0.name) (id \($0.chatID), \($0.count))" }.joined(separator: "; "))
            return out.joined(separator: "\n")
        case "activity":
            let by = (a["by"] as? String) ?? "month"
            let expr = ["year": "strftime('%Y',m.ts/1000,'unixepoch','localtime')", "month": "strftime('%Y-%m',m.ts/1000,'unixepoch','localtime')",
                        "weekday": "strftime('%w',m.ts/1000,'unixepoch','localtime')", "hour": "strftime('%H',m.ts/1000,'unixepoch','localtime')"][by] ?? ""
            guard !expr.isEmpty else { throw ToolError(description: "by must be year, month, weekday or hour") }
            var cond = notBlocked
            if let c = int(a, "chat_id") { cond += " AND m.chat_id=\(c)" }
            if let p = a["person_key"] as? String { cond += " AND (m.person='\(esc(p))' OR m.chat_id IN (SELECT chat_id FROM chats WHERE person='\(esc(p))'))" }
            if let f = try ms(a["from"]) { cond += " AND m.ts>=\(f)" }; if let t = try ms(a["to"], endOfDay: true) { cond += " AND m.ts<\(t)" }
            var rows = ["\(by) | total | sent_by_me"]
            try store.db.query("SELECT \(expr) k, count(*), sum(m.from_me) FROM messages m WHERE \(cond) GROUP BY k ORDER BY k") { rows.append("\($0.text(0) ?? "") | \($0.int(1)) | \($0.int(2))") }
            return finish(rows)
        case "year_in_review":
            guard let y = a["year"] as? String ?? (a["year"] as? NSNumber).map({ "\($0)" }) else { throw ToolError(description: "year required") }
            let w = try store.wrapped(year: y)
            var o = ["Year \(y): \(w.total) messages (\(w.sent) sent), ~\(w.words) words, active on \(w.activeDays) days, busiest hour \(w.busiestHour):00"]
            o.append("top people (DMs): " + w.dms.filter { !blockedIDs.contains($0.id) }.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
            o.append("top groups: " + w.groups.filter { !blockedIDs.contains($0.id) }.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
            o.append("busiest days: " + w.busiest.map { "\($0.day) (\($0.count))" }.joined(separator: ", "))
            o.append("most active people: " + w.people.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
            o.append("messages per month: " + w.monthly.map { "\($0.month):\($0.count)" }.joined(separator: " "))
            return o.joined(separator: "\n")
        case "deleted_messages":
            var cond = notBlocked
            if let c = int(a, "chat_id") { cond += " AND m.chat_id=\(c)" }
            var rows = ["Messages deleted from the phone but kept in the archive (newest first):"]
            try store.db.query("SELECT m.ts, c.name, m.sender, m.text FROM gone g JOIN messages m USING(uid) JOIN chats c USING(chat_id) WHERE \(cond) AND COALESCE(m.text,'')<>'' ORDER BY m.ts DESC LIMIT \(limit(a, 30))") {
                rows.append("[\(Self.stampF.string(from: VaultStore.date($0.int(0))))] \($0.text(1) ?? "") / \($0.text(2) ?? ""): \(clip(store.resolveMentions($0.text(3) ?? "")))")
            }
            return finish(rows)
        case "archive_stats":
            let s = try store.stats()
            return "messages: \(s.messages)\nchats: \(s.chats)\nnamed people: \(s.namedPeople)\nfirst message: \(Self.dayF.string(from: s.first))\nlast message: \(Self.dayF.string(from: s.last))\nsent by you: \(s.sent) (\(100 * s.sent / max(1, s.messages))%)"
        case "get_schema":
            guard config.allowSQL else { throw ToolError(description: "sql is disabled") }
            return """
            chats(chat_id, jid, is_group, name, resolved, person)
            people(person, name, resolved)               -- person key = last 10 digits of phone number, or lid:<id>
            messages(id, chat_id, from_me, sender, person, ts /*ms epoch*/, type, text, uid)
            media(msg_id, chat_id, ts, mime, kind /*image|video|audio|doc|other*/, file_path, size, file_hash, caption, rel)
            gone(uid, seen_gone)                        -- messages deleted on the phone, kept here
            chat_stats(chat_id, n, first_ts, last_ts, last_text)
            person_stats(person, n, dm, grp, first_ts, last_ts)
            msg_fts(text)                               -- FTS5 over messages.text; join: msg_fts.rowid = messages.id
            Dates: datetime(ts/1000,'unixepoch','localtime')
            """
        case "sql_query":
            guard config.allowSQL else { throw ToolError(description: "sql is disabled") }
            let sql = ((a["sql"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
            let low = sql.lowercased()
            guard low.hasPrefix("select") || low.hasPrefix("with"), !sql.contains(";") else { throw ToolError(description: "only a single SELECT/WITH statement is allowed") }
            let st = try store.db.prepare("SELECT * FROM (\(sql)) LIMIT 500")
            let cols = st.columnNames
            var rows = [cols.joined(separator: " | ")]
            while try st.step() { rows.append((0..<cols.count).map { i in clip(st.text(Int32(i)) ?? "NULL", 300) }.joined(separator: " | ")) }
            return finish(rows)
        default: throw ToolError(description: "unknown tool \(name)")
        }
    }
}
