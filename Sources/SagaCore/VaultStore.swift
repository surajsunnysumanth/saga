import Foundation

public enum ChatKind: String, CaseIterable, Sendable { case all = "All", people = "People", groups = "Groups" }
public enum ChatSort: String, CaseIterable, Sendable { case recent = "Most recent", mostMessages = "Most messages", name = "Name (A–Z)", oldest = "Oldest first" }
public enum MessageFilter: String, CaseIterable, Sendable { case all = "All messages", mine = "Sent by me", theirs = "Received", media = "Media only" }
public enum SenderFilter: String, CaseIterable, Sendable { case any = "Anyone", me = "Me", them = "Others" }
public enum SearchSort: String, CaseIterable, Sendable { case newest = "Newest first", oldest = "Oldest first", relevance = "Best match" }

public struct ChatRow: Identifiable, Hashable, Sendable {
    public let id: Int64, name: String, isGroup: Bool, count: Int, first: Date, last: Date, preview: String
    public var jid: String = ""
}
public struct MessageRow: Identifiable, Hashable, Sendable {
    public let id: Int64, ts: Date, fromMe: Bool, sender: String, personKey: String, text: String, mediaKind: String?
    public var uid: String = ""
    public var media: ChatMedia? = nil
}
public struct SearchHit: Identifiable, Hashable, Sendable {
    public let id: Int64, chatID: Int64, chat: String, ts: Date, sender: String, fromMe: Bool, snippet: String
}
public struct PersonRow: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String, name: String, resolved: Bool, received: Int, inDMs: Int, inGroups: Int, first: Date, last: Date
}
public enum PersonSort: String, CaseIterable, Sendable { case mostMessages = "Most messages", recent = "Most recent", name = "Name (A–Z)", mostGroups = "Most group activity" }
public struct PersonDetail: Sendable {
    public let yearly: [(year: String, count: Int)]
    public let groups: [(chatID: Int64, name: String, count: Int)]
    public let dmChat: ChatRow?
    public let dmSentPct: Int
    /// Every original number/identity behind this person (several when their numbers are merged).
    public let numbers: [MergeMember]
}
public struct TopChat: Identifiable, Sendable { public let id: Int64, name: String, isGroup: Bool, count: Int, sent: Int }
public struct WrappedStats: Sendable {
    public let year: String, total: Int, sent: Int, words: Int
    public let years: [String]
    public let monthly: [(month: Int, count: Int)], hourly: [(hour: Int, count: Int)]
    public let dms: [TopChat], groups: [TopChat]
    public let people: [(key: String, name: String, count: Int)]
    public let busiest: [(day: String, count: Int)]
    public let longest: (text: String, chat: String, length: Int)?
    public let busiestHour: Int
    public let activeDays: Int
}
public struct VaultStats: Sendable {
    public let messages: Int, chats: Int, namedPeople: Int, sent: Int, first: Date, last: Date
    public let yearly: [(year: String, count: Int, sent: Int)]
    public let hourly: [(hour: Int, count: Int)]
    public let topChats: [ChatRow]
}

/// Read-only access to `vault_index.db` for the UI.
public final class VaultStore: @unchecked Sendable {   // read-only SQLite connection (serialized mode)
    public let db: SQLiteDB
    let hasChatStats: Bool
    public let hasContentCol: Bool
    public let hasLastRealCol: Bool
    /// Disposable identity table added by `VaultIndexer`; absent in older indices, which then behave as singletons.
    public let hasMergeMembers: Bool
    /// Reaction rows, added after the first indices shipped; an older index simply draws no chips.
    public let hasReactions: Bool
    public init(path: String) throws {
        db = try SQLiteDB(path: path, readOnly: true)
        hasChatStats = ((try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='chat_stats'")) ?? 0) > 0
        hasContentCol = ((try? db.scalarInt("SELECT count(*) FROM pragma_table_info('chat_stats') WHERE name='content'")) ?? 0) > 0
        hasLastRealCol = ((try? db.scalarInt("SELECT count(*) FROM pragma_table_info('chat_stats') WHERE name='last_real_ts'")) ?? 0) > 0
        hasMergeMembers = ((try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='merge_members'")) ?? 0) > 0
        hasReactions = ((try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='reactions'")) ?? 0) > 0
    }

    private var mentionCache: [String: String?] = [:]
    /// Replaces "@12345678901" style mentions with "@Name" when the number is a known contact.
    func resolveMentions(_ s: String) -> String {
        guard s.contains("@") else { return s }
        var out = s
        let ns = s as NSString
        guard let re = try? NSRegularExpression(pattern: "@(\\d{7,})") else { return s }
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tok = ns.substring(with: m.range(at: 1))
            var name: String?
            if let c = mentionCache[tok] { name = c } else {
                try? db.query("SELECT name FROM aliases WHERE alias='\(tok)' LIMIT 1") { name = $0.text(0) }
                mentionCache[tok] = name
            }
            if let name, let r = Range(m.range, in: out) { out.replaceSubrange(r, with: "@" + name) }
        }
        return out
    }

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    public struct ContextMessage: Sendable { public let id: Int64, chatID: Int64, chat: String, ts: Date, fromMe: Bool, sender: String, text: String, uid: String }

    static let stopwords: Set<String> = ["the","and","for","are","was","were","what","when","where","who","whom","why","how","did","does","do","have","has","had","with","that","this","from","about","which","there","their","them","they","you","your","our","can","could","would","should","will","any","all","some","get","got","say","said","tell","find","show","talk","talked","discuss","discussed","chat","chats","message","messages","last","first","time","year","years","ever","again","been","being","into","than","then","also","just","like","its","his","her","she","him","one","two","a","an","of","in","on","at","to","is","it","me","my","we","us","i"]

    /// Keyword retrieval for questions: FTS5 OR-search on the meaningful words, best matches first, each with a little context around it.
    public func retrieve(question: String, chat: Int64?, maxHits: Int = 30, context: Int = 2) throws -> [ContextMessage] {
        let words = question.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !Self.stopwords.contains($0) }
        var seen = Set<String>(); let terms = words.filter { seen.insert($0).inserted }.prefix(8)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        let st = try db.prepare("""
            SELECT m.id FROM msg_fts JOIN messages m ON m.id = msg_fts.rowid
            WHERE msg_fts MATCH ? \(chat.map { "AND m.chat_id=\($0)" } ?? "") ORDER BY bm25(msg_fts) LIMIT \(maxHits)
            """)
        sqlite3_bindText(st, match)
        var ids: [Int64] = []
        while try st.step() { ids.append(st.int(0)) }
        guard !ids.isEmpty else { return [] }
        var wanted = Set<Int64>(ids)
        for id in ids.prefix(12) {
            try db.query("""
                SELECT id FROM (SELECT m2.id FROM messages m1 JOIN messages m2 ON m2.chat_id=m1.chat_id AND (m2.ts<m1.ts OR (m2.ts=m1.ts AND m2.id<m1.id)) WHERE m1.id=\(id) ORDER BY m2.ts DESC, m2.id DESC LIMIT \(context))
                UNION SELECT id FROM (SELECT m2.id FROM messages m1 JOIN messages m2 ON m2.chat_id=m1.chat_id AND (m2.ts>m1.ts OR (m2.ts=m1.ts AND m2.id>m1.id)) WHERE m1.id=\(id) ORDER BY m2.ts, m2.id LIMIT \(context))
                """) { wanted.insert($0.int(0)) }
        }
        var out: [ContextMessage] = []
        try db.query("""
            SELECT m.id, m.chat_id, c.name, m.ts, m.from_me, m.sender, m.text, m.uid FROM messages m JOIN chats c USING(chat_id)
            WHERE m.id IN (\(wanted.map(String.init).joined(separator: ","))) AND COALESCE(m.text,'')<>'' ORDER BY m.chat_id, m.ts, m.id
            """) {
            out.append(ContextMessage(id: $0.int(0), chatID: $0.int(1), chat: $0.text(2) ?? "", ts: Self.date($0.int(3)), fromMe: $0.int(4) == 1, sender: $0.text(5) ?? "", text: resolveMentions($0.text(6) ?? ""), uid: $0.text(7) ?? ""))
        }
        return out
    }

    /// uid -> (row id, chat id) for messages that still exist in this library (row ids change when the library is rebuilt).
    public func resolve(uids: [String]) -> [String: (id: Int64, chatID: Int64)] {
        var out: [String: (Int64, Int64)] = [:]
        for batch in stride(from: 0, to: uids.count, by: 400).map({ Array(uids[$0..<min($0 + 400, uids.count)]) }) {
            let list = batch.map { "'" + Self.esc($0) + "'" }.joined(separator: ",")
            try? db.query("SELECT uid, id, chat_id FROM messages WHERE uid IN (\(list))") { out[$0.text(0) ?? ""] = ($0.int(1), $0.int(2)) }
        }
        return out
    }

    public func countMessages(chat: Int64, after ms: Int64) -> Int {
        Int(db.scalarIntOrZero("SELECT count(*) FROM messages WHERE chat_id=\(chat) AND ts>\(ms) AND COALESCE(text,'')<>''"))
    }

    public func messageDate(id: Int64) -> Date? {
        var ts: Int64 = 0
        try? db.query("SELECT ts FROM messages WHERE id=\(id)") { ts = $0.int(0) }
        return ts > 0 ? Self.date(ts) : nil
    }

    /// What a stored message identity still points at.
    ///
    /// Every "see it in the chat" control carries a row id captured when its story was built.
    /// Row ids are not durable: rebuilding the index renumbers them and a prune deletes rows,
    /// so a moment can outlive the message it quotes. The id is resolved before anything
    /// scrolls to it, and the answer says which of the three cases this is.
    public enum JumpTarget: Equatable, Sendable {
        /// The message is here, in the conversation that was asked for.
        case message(id: Int64, chatID: Int64, at: Date)
        /// The conversation is here but that message is not: open the chat, no highlight.
        case chat(chatID: Int64)
        /// Neither is here.
        case gone
    }

    public func jumpTarget(messageID: Int64, chatID: Int64) -> JumpTarget {
        let hasChat = chatID > 0 && chatExists(chatID)
        guard messageID > 0 else { return hasChat ? .chat(chatID: chatID) : .gone }
        var id: Int64 = 0, foundChat: Int64 = 0, ts: Int64 = 0
        try? db.query("SELECT id, chat_id, ts FROM messages WHERE id=\(messageID)") {
            id = $0.int(0); foundChat = $0.int(1); ts = $0.int(2)
        }
        if id > 0, ts > 0 {
            // The id resolves to a message in another conversation: the story's chat is the
            // truthful destination, and highlighting a stranger's message would be a lie.
            if foundChat == chatID { return .message(id: id, chatID: foundChat, at: Self.date(ts)) }
            return hasChat ? .chat(chatID: chatID) : .gone
        }
        return hasChat ? .chat(chatID: chatID) : .gone
    }

    public func chatExists(_ chatID: Int64) -> Bool {
        ((try? db.scalarInt("SELECT count(*) FROM chats WHERE chat_id=\(chatID)")) ?? 0) > 0
    }

    /// The page of a conversation that ends with one message, so a jump can never highlight
    /// a message the list did not load. `found` is false when the filter hides it (a
    /// placeholder row) or when it is not in this conversation at all.
    public func messages(chat: Int64, around id: Int64, filter: MessageFilter = .all,
                         limit: Int = 200) throws -> (rows: [MessageRow], found: Bool) {
        guard let when = messageDate(id: id) else { return ([], false) }
        let rows = try messages(chat: chat, before: when.addingTimeInterval(0.001), filter: filter, limit: limit)
        return (rows, rows.contains { $0.id == id })
    }

    public func stats() throws -> VaultStats {
        var yearly: [(String, Int, Int)] = [], hourly: [(Int, Int)] = []
        try db.query("SELECT strftime('%Y',ts/1000,'unixepoch','localtime') y, count(*), sum(from_me) FROM messages GROUP BY y ORDER BY y") {
            yearly.append(($0.text(0) ?? "", Int($0.int(1)), Int($0.int(2))))
        }
        try db.query("SELECT CAST(strftime('%H',ts/1000,'unixepoch','localtime') AS INT) h, count(*) FROM messages GROUP BY h ORDER BY h") {
            hourly.append((Int($0.int(0)), Int($0.int(1))))
        }
        var sent = 0, first = Date(), last = Date()
        try db.query("SELECT sum(from_me), min(ts), max(ts) FROM messages") { sent = Int($0.int(0)); first = Self.date($0.int(1)); last = Self.date($0.int(2)) }
        return VaultStats(messages: Int(try db.scalarInt("SELECT count(*) FROM messages")),
                          chats: Int(try db.scalarInt("SELECT count(DISTINCT chat_id) FROM messages")),
                          namedPeople: Int(try db.scalarInt("SELECT count(*) FROM people WHERE resolved=1")),
                          sent: sent, first: first, last: last,
                          yearly: yearly, hourly: hourly, topChats: try chats(sort: .mostMessages, limit: 6))
    }

    public func chats(matching q: String = "", kind: ChatKind = .all, sort: ChatSort = .recent, minMessages: Int = 1, includeEmpty: Bool = false, limit: Int = 3000) throws -> [ChatRow] {
        let like = "%" + Self.esc(q) + "%"
        let kindSQL = (kind == .people ? "AND c.is_group=0" : kind == .groups ? "AND c.is_group=1" : "") + (hasContentCol && hasChatStats && !includeEmpty ? " AND s.content > 0" : "")
        let order: String
        switch sort {
        case .recent: order = hasLastRealCol ? "ifnull(last_real_ts, first_ts) DESC" : "last_ts DESC"
        case .mostMessages: order = "n DESC"
        case .name: order = "c.name COLLATE NOCASE ASC"
        case .oldest: order = "first_ts ASC"
        }
        let from = hasChatStats
            ? "chat_stats s JOIN chats c ON c.chat_id = s.chat_id"
            : "(SELECT chat_id, count(*) n, min(ts) first_ts, max(ts) last_ts, NULL last_text FROM messages GROUP BY chat_id) s JOIN chats c ON c.chat_id = s.chat_id"
        var out: [ChatRow] = []
        try db.query("""
            SELECT c.chat_id, c.name, c.is_group, s.n, s.first_ts, \(hasLastRealCol ? "ifnull(s.last_real_ts, s.first_ts)" : "s.last_ts"), s.last_text, c.jid FROM \(from)
            WHERE c.name LIKE '\(like)' AND s.n >= \(minMessages) \(kindSQL) ORDER BY \(order) LIMIT \(limit)
            """) {
            var row = ChatRow(id: $0.int(0), name: $0.text(1) ?? "?", isGroup: $0.int(2) == 1, count: Int($0.int(3)),
                               first: Self.date($0.int(4)), last: Self.date($0.int(5)), preview: resolveMentions($0.text(6) ?? ""))
            row.jid = $0.text(7) ?? ""
            out.append(row)
        }
        return out
    }

    private static let msgSelect = """
        SELECT m.id, m.ts, m.from_me, m.sender, m.person, m.text, md.kind, m.uid,
               md.file_path, md.size, md.mime, md.file_hash, md.caption FROM messages m
        LEFT JOIN media md ON md.msg_id = m.id
        """
    private func rows(_ sql: String) throws -> [MessageRow] {
        var out: [MessageRow] = []
        try db.query(sql) {
            var r = MessageRow(id: $0.int(0), ts: Self.date($0.int(1)), fromMe: $0.int(2) != 0, sender: $0.text(3) ?? "",
                                  personKey: $0.text(4) ?? "", text: resolveMentions($0.text(5) ?? ""), mediaKind: $0.text(6))
            r.uid = $0.text(7) ?? ""
            if let kind = r.mediaKind {
                r.media = ChatMedia(uid: r.uid, kind: kind, filePath: $0.text(8), size: $0.int(9),
                                    mime: $0.text(10), fileHash: $0.text(11), caption: $0.text(12))
            }
            out.append(r)
        }
        return out
    }
    private func filterSQL(_ f: MessageFilter) -> String {
        let visible = "AND (COALESCE(m.text,'') <> '' OR md.kind IS NOT NULL)"   // hide empty system/placeholder rows
        switch f {
        case .all: return visible
        case .mine: return "AND m.from_me=1 " + visible
        case .theirs: return "AND m.from_me=0 " + visible
        case .media: return "AND md.kind IS NOT NULL"
        }
    }

    /// Newest-first page before `before`, returned oldest-first.
    public func messages(chat: Int64, before: Date? = nil, filter: MessageFilter = .all, limit: Int = 200) throws -> [MessageRow] {
        let b = before.map(Self.ms) ?? Int64.max
        return try rows("\(Self.msgSelect) WHERE m.chat_id=\(chat) AND m.ts<\(b) \(filterSQL(filter)) ORDER BY m.ts DESC LIMIT \(limit)").reversed()
    }
    /// Messages from `from` onwards (jump to a date or search hit).
    public func messages(chat: Int64, from: Date, filter: MessageFilter = .all, limit: Int = 200) throws -> [MessageRow] {
        try rows("\(Self.msgSelect) WHERE m.chat_id=\(chat) AND m.ts>=\(Self.ms(from)) \(filterSQL(filter)) ORDER BY m.ts LIMIT \(limit)")
    }

    /// What a find bar sends to FTS5 while the person is still typing.
    ///
    /// A find field cannot hand FTS5 its text raw: a stray `"`, `-`, `:` or a trailing
    /// operator is a syntax error, and the bar reads "no matches" on a query that is
    /// perfectly reasonable to type. Each word is quoted as literal text and the last
    /// one is a prefix, so `hel` finds "hello" and `goa trip` finds "Goa trip" as you type.
    /// Returns "" when there is nothing searchable in the text.
    public static func findQuery(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\"", with: " ")
        let words = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let last = words.last, last.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        let quoted = words.dropLast().map { "\"\($0)\"" }
        return (quoted + ["\"\(last)\"*"]).joined(separator: " ")
    }

    /// The find bar's own query: one conversation, oldest match first so a hit's number
    /// matches its position in the transcript, and a cap the caller can label as `n+`.
    /// A query with nothing searchable in it returns no rows rather than throwing.
    public func find(_ text: String, in chatID: Int64, limit: Int = 500) throws -> [SearchHit] {
        let q = Self.findQuery(text)
        guard !q.isEmpty else { return [] }
        return try search(q, chat: chatID, sort: .oldest, limit: limit)
    }

    /// FTS5 search (supports "a AND b", prefix*, "exact phrase") with filters.
    public func search(_ q: String, chat: Int64? = nil, sender: SenderFilter = .any, from: Date? = nil, to: Date? = nil,
                       sort: SearchSort = .newest, limit: Int = 200) throws -> [SearchHit] {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var cond = ""
        if let chat { cond += " AND m.chat_id=\(chat)" }
        if sender == .me { cond += " AND m.from_me=1" } else if sender == .them { cond += " AND m.from_me=0" }
        if let from { cond += " AND m.ts>=\(Self.ms(from))" }
        if let to { cond += " AND m.ts<\(Self.ms(to.addingTimeInterval(86400)))" }
        let order = sort == .newest ? "m.ts DESC" : sort == .oldest ? "m.ts ASC" : "rank"
        let st = try db.prepare("""
            SELECT m.id, m.chat_id, c.name, m.ts, m.sender, m.from_me, snippet(msg_fts,0,'[',']','…',18)
            FROM msg_fts JOIN messages m ON m.id=msg_fts.rowid JOIN chats c USING(chat_id)
            WHERE msg_fts MATCH ? \(cond) ORDER BY \(order) LIMIT \(limit)
            """)
        sqlite3_bindText(st, q)
        var out: [SearchHit] = []
        while try st.step() {
            out.append(SearchHit(id: st.int(0), chatID: st.int(1), chat: st.text(2) ?? "", ts: Self.date(st.int(3)),
                                 sender: st.text(4) ?? "", fromMe: st.int(5) != 0, snippet: resolveMentions(st.text(6) ?? "")))
        }
        return out
    }

    // MARK: People
    public func people(matching q: String = "", sort: PersonSort = .mostMessages, namedOnly: Bool = true, limit: Int = 1500) throws -> [PersonRow] {
        let like = "%" + Self.esc(q) + "%"
        let order = [PersonSort.mostMessages: "s.n DESC", .recent: "s.last_ts DESC", .name: "p.name COLLATE NOCASE ASC", .mostGroups: "s.grp DESC"][sort]!
        var out: [PersonRow] = []
        try db.query("""
            SELECT p.person, p.name, p.resolved, s.n, s.dm, s.grp, s.first_ts, s.last_ts FROM person_stats s JOIN people p ON p.person=s.person
            WHERE p.name LIKE '\(like)' \(namedOnly ? "AND p.resolved=1" : "") AND s.person NOT IN ('me','unknown') ORDER BY \(order) LIMIT \(limit)
            """) {
            out.append(PersonRow(key: $0.text(0) ?? "", name: $0.text(1) ?? "", resolved: $0.int(2) == 1, received: Int($0.int(3)),
                                 inDMs: Int($0.int(4)), inGroups: Int($0.int(5)), first: Self.date($0.int(6)), last: Self.date($0.int(7))))
        }
        return out
    }

    public func detail(for key: String) throws -> PersonDetail {
        let k = Self.esc(key)
        var yearly: [(String, Int)] = [], groups: [(Int64, String, Int)] = []
        try db.query("SELECT strftime('%Y',ts/1000,'unixepoch','localtime') y, count(*) FROM messages WHERE person='\(k)' GROUP BY y ORDER BY y") { yearly.append(($0.text(0) ?? "", Int($0.int(1)))) }
        try db.query("""
            SELECT c.chat_id, c.name, count(*) n FROM messages m JOIN chats c USING(chat_id) WHERE m.person='\(k)' AND c.is_group=1
            GROUP BY c.chat_id ORDER BY n DESC LIMIT 12
            """) { groups.append(($0.int(0), $0.text(1) ?? "", Int($0.int(2)))) }
        var dm: ChatRow? = nil
        try db.query("""
            SELECT c.chat_id, c.name, c.is_group, s.n, s.first_ts, s.last_ts, s.last_text, c.jid FROM chats c JOIN chat_stats s ON s.chat_id=c.chat_id
            WHERE c.person='\(k)' ORDER BY s.n DESC LIMIT 1
            """) {
            var row = ChatRow(id: $0.int(0), name: $0.text(1) ?? "", isGroup: false, count: Int($0.int(3)), first: Self.date($0.int(4)), last: Self.date($0.int(5)), preview: $0.text(6) ?? "")
            row.jid = $0.text(7) ?? ""                                  // without it, summaries/prune keys would start empty
            dm = row
        }
        var pct = 0
        if let dm { pct = Int(try db.scalarInt("SELECT 100*sum(from_me)/count(*) FROM messages WHERE chat_id=\(dm.id)")) }
        // Display one row per distinct number; a mapped LID collapses into the phone it points at.
        var seenDisplay = Set<String>()
        let numbers = mergeMembers(person: key).filter { seenDisplay.insert($0.display).inserted }
        return PersonDetail(yearly: yearly, groups: groups, dmChat: dm, dmSentPct: pct, numbers: numbers)
    }

    // MARK: Wrapped
    public func wrapped(year: String) throws -> WrappedStats {
        let y = Self.esc(year), W = "strftime('%Y',ts/1000,'unixepoch','localtime')='\(y)'"
        var total = 0, sent = 0, chars = 0
        try db.query("SELECT count(*), sum(from_me), sum(length(text)) FROM messages WHERE \(W)") { total = Int($0.int(0)); sent = Int($0.int(1)); chars = Int($0.int(2)) }
        var years: [String] = [], monthly: [(Int, Int)] = [], hourly: [(Int, Int)] = [], busiest: [(String, Int)] = [], people: [(String, String, Int)] = []
        try db.query("SELECT DISTINCT strftime('%Y',ts/1000,'unixepoch','localtime') y FROM messages ORDER BY y DESC") { years.append($0.text(0) ?? "") }
        try db.query("SELECT CAST(strftime('%m',ts/1000,'unixepoch','localtime') AS INT) m, count(*) FROM messages WHERE \(W) GROUP BY m ORDER BY m") { monthly.append((Int($0.int(0)), Int($0.int(1)))) }
        try db.query("SELECT CAST(strftime('%H',ts/1000,'unixepoch','localtime') AS INT) h, count(*) FROM messages WHERE \(W) GROUP BY h ORDER BY h") { hourly.append((Int($0.int(0)), Int($0.int(1)))) }
        try db.query("SELECT date(ts/1000,'unixepoch','localtime') d, count(*) n FROM messages WHERE \(W) GROUP BY d ORDER BY n DESC LIMIT 3") { busiest.append(($0.text(0) ?? "", Int($0.int(1)))) }
        try db.query("""
            SELECT m.person, m.sender, count(*) n FROM messages m WHERE \(W.replacingOccurrences(of: "ts/", with: "m.ts/")) AND m.from_me=0
            AND m.person NOT LIKE 'lid:%' AND m.person<>'unknown' GROUP BY m.person ORDER BY n DESC LIMIT 8
            """) { people.append(($0.text(0) ?? "", $0.text(1) ?? "", Int($0.int(2)))) }
        func top(_ group: Int) throws -> [TopChat] {
            var out: [TopChat] = []
            try db.query("""
                SELECT c.chat_id, c.name, count(*) n, sum(m.from_me) FROM messages m JOIN chats c USING(chat_id)
                WHERE \(W.replacingOccurrences(of: "ts/", with: "m.ts/")) AND c.is_group=\(group) GROUP BY c.chat_id ORDER BY n DESC LIMIT 5
                """) { out.append(TopChat(id: $0.int(0), name: $0.text(1) ?? "", isGroup: group == 1, count: Int($0.int(2)), sent: Int($0.int(3)))) }
            return out
        }
        var longest: (String, String, Int)? = nil
        try db.query("""
            SELECT substr(m.text,1,400), c.name, length(m.text) l FROM messages m JOIN chats c USING(chat_id)
            WHERE \(W.replacingOccurrences(of: "ts/", with: "m.ts/")) AND m.from_me=1 AND m.text IS NOT NULL ORDER BY l DESC LIMIT 1
            """) { longest = (resolveMentions($0.text(0) ?? ""), $0.text(1) ?? "", Int($0.int(2))) }
        let activeDays = Int(try db.scalarInt("SELECT count(DISTINCT date(ts/1000,'unixepoch','localtime')) FROM messages WHERE \(W)"))
        return WrappedStats(year: year, total: total, sent: sent, words: chars / 5, years: years, monthly: monthly, hourly: hourly,
                            dms: try top(0), groups: try top(1), people: people, busiest: busiest, longest: longest,
                            busiestHour: hourly.max(by: { $0.1 < $1.1 })?.0 ?? 0, activeDays: activeDays)
    }

    // MARK: Export paging
    public struct ExportPage { public let rows: [MessageRow]; public let lastTs: Int64; public let lastId: Int64; public var isEmpty: Bool { rows.isEmpty } }
    public func exportPage(chat: Int64, afterTs: Int64, afterId: Int64, limit: Int) throws -> ExportPage {
        let r = try rows("""
            \(Self.msgSelect) WHERE m.chat_id=\(chat) AND (m.ts>\(afterTs) OR (m.ts=\(afterTs) AND m.id>\(afterId)))
            AND (COALESCE(m.text,'') <> '' OR md.kind IS NOT NULL) ORDER BY m.ts, m.id LIMIT \(limit)
            """)
        guard let last = r.last else { return ExportPage(rows: [], lastTs: afterTs, lastId: afterId) }
        return ExportPage(rows: r, lastTs: Int64(last.ts.timeIntervalSince1970 * 1000), lastId: last.id)
    }
}

/// One row from the media index, for the Gallery.
public struct MediaItem: Sendable, Identifiable {
    public let id: Int64          // message id
    public let chatID: Int64
    public let ts: Date
    public let kind: String       // image / video / audio / doc
    public let path: String
    public let chatName: String
    public let size: Int64
}

/// A voice note, joined to the message and chat that carry it. A thumbnail cannot say who
/// spoke, so the Gallery needs the sender and conversation beside every row.
public struct VoiceNote: Sendable, Identifiable, Hashable {
    public let id: Int64          // message id
    public let chatID: Int64
    public let ts: Date
    public let path: String
    public let size: Int64
    public let mime: String
    public let caption: String
    public let fromMe: Bool
    /// Display-ready: a person's name, a number when that is all the archive knows, or "You".
    public let senderName: String
    public let chatName: String
    public let isGroup: Bool

    /// The conversation view prints `messages.sender` verbatim, and the importer already
    /// chooses a saved name or the full number. Old/LID rows can still say "Unknown", so
    /// fall back to the person key (a normalised number or a LID) and finally to a neutral
    /// label — never the word "Unknown" in a place where someone is being credited.
    public static func senderLabel(fromMe: Bool, sender: String, person: String) -> String {
        if fromMe { return "You" }
        let raw = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let looksUnknown = raw.isEmpty || lower == "unknown" || lower.hasPrefix("unknown (") || lower.hasPrefix("unknown ")
        if !looksUnknown { return raw }

        let key = person.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("lid:") {
            let digits = key.dropFirst(4).filter(\.isNumber)
            return digits.isEmpty ? "Unnamed sender" : "Number ending \(String(digits.suffix(4)))"
        }
        let digits = key.filter(\.isNumber)
        if !digits.isEmpty { return "+\(digits)" }
        let quoted = raw.filter(\.isNumber)
        if !quoted.isEmpty { return "Number ending \(String(quoted.suffix(4)))" }
        return "Unnamed sender"
    }

    /// A chat with no stored name still has a JID; print its number instead of an empty line.
    public static func chatLabel(name: String, jid: String, isGroup: Bool) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        if !isGroup {
            let user = jid.split(separator: "@").first.map(String.init) ?? ""
            let digits = user.filter(\.isNumber)
            if !digits.isEmpty { return "+\(digits)" }
            return "One conversation"
        }
        return "Unnamed group"
    }
}

public enum MediaSort: String, Sendable, CaseIterable {
    case newest = "Newest first", oldest = "Oldest first", about = "By conversation"
}

extension VaultStore {
    /// Counts per media kind, for the Gallery's tab labels. Scoped to one conversation when
    /// `chatID` is given, so a chat's Media tab counts what that chat actually holds instead
    /// of the whole archive.
    public func mediaCounts(chatID: Int64? = nil) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let whereSQL = chatID.map { "WHERE chat_id = \($0)" } ?? ""
        try db.query("SELECT kind, count(*) FROM media \(whereSQL) GROUP BY kind") { row in
            out[row.text(0) ?? "other"] = Int(row.int(1))
        }
        // The Gallery has an Images tab and no Stickers tab: a sticker is a picture and shows
        // there. The sticker count stays in the map, so a card can still name it separately.
        if let stickers = out["sticker"] { out["image", default: 0] += stickers }
        return out
    }

    /// A bounded slice of the media index, with the same filters the Gallery shows.
    public func media(kind: String?, chatID: Int64? = nil, year: Int? = nil,
                      sort: MediaSort = .newest, limit: Int = 400) throws -> [MediaItem] {
        var clauses: [String] = []
        if let kind {
            // Images includes stickers: a sticker is a picture, and hiding it from the Gallery
            // because the archive now files it separately would lose photos, not gain honesty.
            clauses.append(kind == "image" ? "m.kind IN ('image','sticker')" : "m.kind = '\(Self.esc(kind))'")
        }
        if let chatID { clauses.append("m.chat_id = \(chatID)") }
        if let year { clauses.append("strftime('%Y', m.ts/1000, 'unixepoch', 'localtime') = '\(year)'") }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let order: String = switch sort {
        case .newest: "m.ts DESC"
        case .oldest: "m.ts ASC"
        case .about: "c.name ASC, m.ts DESC"
        }
        var out: [MediaItem] = []
        out.reserveCapacity(limit)
        try db.query("""
            SELECT m.msg_id, m.chat_id, m.ts, m.kind, coalesce(m.file_path,''),
                   coalesce(nullif(c.name,''), nullif(c.person,''), ''), coalesce(m.size,0)
            FROM media m LEFT JOIN chats c ON c.chat_id = m.chat_id
            \(whereSQL) ORDER BY \(order) LIMIT \(max(1, limit))
            """) { row in
            out.append(MediaItem(id: row.int(0), chatID: row.int(1),
                                 ts: Self.date(row.int(2)),
                                 kind: row.text(3) ?? "other", path: row.text(4) ?? "",
                                 chatName: row.text(5) ?? "", size: row.int(6)))
        }
        return out
    }

    /// Every audio attachment, joined to the message that sent it and the chat it landed in.
    /// Sender and chat are resolved here so the Gallery never has to guess, and so a row can
    /// say "Meera · Flat 4B" without loading the conversation first.
    public func voiceNotes(chatID: Int64? = nil, year: Int? = nil,
                           sort: MediaSort = .newest, limit: Int = 400) throws -> [VoiceNote] {
        var clauses = ["md.kind = 'audio'"]
        if let chatID { clauses.append("md.chat_id = \(chatID)") }
        if let year { clauses.append("strftime('%Y', md.ts/1000, 'unixepoch', 'localtime') = '\(year)'") }
        let order: String = switch sort {
        case .newest: "md.ts DESC, md.msg_id DESC"
        case .oldest: "md.ts ASC, md.msg_id ASC"
        case .about: "coalesce(c.name,'') COLLATE NOCASE ASC, md.ts DESC"
        }
        var out: [VoiceNote] = []
        out.reserveCapacity(limit)
        try db.query("""
            SELECT md.msg_id, md.chat_id, md.ts, coalesce(md.file_path,''), coalesce(md.size,0),
                   coalesce(md.mime,''), coalesce(md.caption,''),
                   coalesce(m.from_me,0), coalesce(m.sender,''), coalesce(m.person,''),
                   coalesce(c.name,''), coalesce(c.is_group,0), coalesce(c.jid,'')
            FROM media md
            LEFT JOIN messages m ON m.id = md.msg_id
            LEFT JOIN chats c ON c.chat_id = md.chat_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(order) LIMIT \(max(1, limit))
            """) { row in
            let fromMe = row.int(7) != 0
            let isGroup = row.int(11) != 0
            out.append(VoiceNote(id: row.int(0), chatID: row.int(1), ts: Self.date(row.int(2)),
                                 path: row.text(3) ?? "", size: row.int(4),
                                 mime: row.text(5) ?? "", caption: row.text(6) ?? "",
                                 fromMe: fromMe,
                                 senderName: VoiceNote.senderLabel(fromMe: fromMe,
                                                                   sender: row.text(8) ?? "",
                                                                   person: row.text(9) ?? ""),
                                 chatName: VoiceNote.chatLabel(name: row.text(10) ?? "",
                                                               jid: row.text(12) ?? "",
                                                               isGroup: isGroup),
                                 isGroup: isGroup))
        }
        return out
    }

    /// Years that hold media, newest first, for the Gallery's year filter. `media.ts` is in
    /// milliseconds, like `messages.ts`. Scoped to one conversation when `chatID` is given.
    public func mediaYears(chatID: Int64? = nil) throws -> [Int] {
        var out: [Int] = []
        let whereSQL = chatID.map { "WHERE chat_id = \($0)" } ?? ""
        try db.query("SELECT DISTINCT strftime('%Y', ts/1000, 'unixepoch', 'localtime') y FROM media \(whereSQL) ORDER BY y DESC") { row in
            if let y = Int(row.text(0) ?? "") { out.append(y) }
        }
        return out
    }
}
