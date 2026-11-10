import Foundation

/// What an unnamed chat actually is. A number with no name is usually a stranger, but it can just as
/// easily be a delivery driver, a shop, or WhatsApp's own newsletter feed — and those are not people
/// to go hunting for. The kind is derived from the JID server, which is the only identity evidence the
/// index holds for a chat the resolver could not name.
public enum UnnamedKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    case person = "Person"
    case business = "Business"
    case newsletter = "Newsletter"
    case group = "Group"

    public var id: String { rawValue }

    /// Stored in the index as a lowercase token; the display label stays capitalised.
    public var key: String { rawValue.lowercased() }

    public init?(key: String) {
        guard let match = UnnamedKind.allCases.first(where: { $0.key == key.lowercased() }) else { return nil }
        self = match
    }

    /// Classify one chat. Groups are decided by the chat row, everything else by the JID's server:
    /// `newsletter` is a channel, `bot`/`broadcast`/`temp` are service traffic, and a `s.whatsapp.net`
    /// or `lid` node is a person.
    public static func classify(isGroup: Bool, jid: String) -> UnnamedKind {
        if isGroup { return .group }
        let server = jid.split(separator: "@", maxSplits: 1).last.map(String.init) ?? ""
        switch server {
        case "g.us": return .group
        case "newsletter": return .newsletter
        case "bot", "broadcast", "temp", "status": return .business
        default: return .person
        }
    }

    public var symbol: String {
        switch self {
        case .person: "person"
        case .business: "briefcase"
        case .newsletter: "newspaper"
        case .group: "person.3"
        }
    }

    /// The filter chip's label. "Persons" and "Businesss" are what a naive `rawValue + "s"` produces.
    public var plural: String {
        switch self {
        case .person: "People"
        case .business: "Businesses"
        case .newsletter: "Newsletters"
        case .group: "Groups"
        }
    }
}

/// One chat the resolver could not put a name to, with just enough on it for a person to recognise
/// the conversation: the identifier the archive actually holds, how much was said, and when.
public struct UnnamedChat: Identifiable, Hashable, Sendable {
    /// `chats.chat_id`
    public let id: Int64
    /// The full chat JID. This is the key a manual override is written under.
    public let jid: String
    public let isGroup: Bool
    /// The index's display name for this chat. Often a number, and sometimes a masked one or a
    /// placeholder like `Unknown (7151)` — never a name, because that is why it is here.
    public let label: String
    public let kind: UnnamedKind
    public let count: Int
    public let last: Date

    public init(id: Int64, jid: String, isGroup: Bool, label: String, kind: UnnamedKind, count: Int, last: Date) {
        self.id = id; self.jid = jid; self.isGroup = isGroup; self.label = label
        self.kind = kind; self.count = count; self.last = last
    }

    /// What to show in the row: the number in international form, or the id the archive holds
    /// (`lid:…`, `newsletter:…`, `group:…`). This is the value the owner can compare against a phone,
    /// a door, or a memory — a masked label cannot be compared to anything.
    public var identifier: String { UnnamedChat.identifier(of: jid, kind: kind) }

    /// A label only when the index holds something a person could read. A masked number is not one.
    public var subtitle: String? {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty, !UnnamedChat.isPlaceholder(l), l != identifier else { return nil }
        return l
    }

    public static func identifier(of jid: String, kind: UnnamedKind) -> String {
        let parts = jid.split(separator: "@", maxSplits: 1)
        let user = parts.first.map(String.init) ?? ""
        let server = parts.count > 1 ? String(parts[1]) : ""
        switch kind {
        case .newsletter: return "newsletter:" + user
        case .group: return "group:" + user
        case .business: return server == "newsletter" ? "newsletter:" + user : (server.isEmpty ? user : "\(server):\(user)")
        case .person:
            if server == "lid" || server == "hosted.lid" { return "lid:" + user }
            let digits = user.filter { $0.isASCII && $0.isNumber }
            if digits.count == user.count, let formatted = formatPhone(digits) { return formatted }
            return jid
        }
    }

    /// Full international form for a phone node: `+91 98000 00101`, or `+` and the digits when the
    /// country is not one we format. Never invents a country code from a ten-digit key.
    public static func formatPhone(_ digits: String) -> String? {
        guard digits.count >= 10, digits.count <= 15 else { return nil }
        if digits.count == 12, digits.hasPrefix("91") {
            let rest = digits.dropFirst(2)
            return "+91 \(rest.prefix(5)) \(rest.dropFirst(5))"
        }
        return "+" + digits
    }

    /// True for a value that is an identifier rather than a name: empty, a number with or without a
    /// mask, "Unknown (7151)", "(unnamed group)".
    public static func isPlaceholder(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        let low = t.lowercased()
        if low.contains("unnamed") || low.contains("unknown") { return true }
        if t.contains("*") { return true }
        let digits = t.filter { $0.isNumber }
        let letters = t.filter(\.isLetter)
        return letters.isEmpty && digits.count >= 4
    }
}

extension VaultStore {
    /// `VaultStore.esc` is file-private to `VaultStore.swift`; this extension is not.
    private static func sqlQuote(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    /// Chats the resolver could not name, most active first. `resolved = 0` is the same test every other
    /// surface uses, so a chat that gained a name from the address book or an override is not listed here.
    ///
    /// - Parameters:
    ///   - q: matched against the display name, the person key and the full JID (so digits and `lid:` ids work).
    ///   - kind: narrow to people, businesses, newsletters or groups; `nil` is every unnamed chat.
    ///   - ignored: chat JIDs the owner marked "not a person"; they are dropped before paging.
    ///   - limit/offset: paging over the full list. Prefer a page of a hundred over all 8,700 rows.
    public func unnamedChats(matching q: String = "", kind: UnnamedKind? = nil,
                             excluding ignored: Set<String> = [],
                             limit: Int = 100, offset: Int = 0) throws -> [UnnamedChat] {
        let sql = """
            SELECT id, jid, grp, label, n, last_ts, k FROM (\(unnamedSelect(q: q, excluding: ignored)))
            \(kind.map { "WHERE k='\(Self.sqlQuote($0.key))'" } ?? "")
            ORDER BY n DESC, last_ts DESC, id ASC LIMIT \(max(0, limit)) OFFSET \(max(0, offset))
            """
        var out: [UnnamedChat] = []
        try db.query(sql) {
            out.append(UnnamedChat(id: $0.int(0), jid: $0.text(1) ?? "", isGroup: $0.int(2) == 1,
                                   label: $0.text(3) ?? "", kind: UnnamedKind(key: $0.text(6) ?? "") ?? .person,
                                   count: Int($0.int(4)), last: Self.date($0.int(5))))
        }
        return out
    }

    /// How many unnamed chats there are per kind, after the same ignored filter. One query, so the
    /// filter chips can show real counts instead of guessing from the page that is drawn.
    public func unnamedChatCounts(excluding ignored: Set<String> = []) throws -> [UnnamedKind: Int] {
        var out: [UnnamedKind: Int] = [:]
        try db.query("SELECT k, count(*) FROM (\(unnamedSelect(q: "", excluding: ignored))) GROUP BY k") { row in
            guard let kind = UnnamedKind(key: row.text(0) ?? "") else { return }
            out[kind] = Int(row.int(1))
        }
        return out
    }

    /// Total unnamed chats (all kinds), for the People sidebar's entry row.
    public func unnamedChatCount(excluding ignored: Set<String> = []) throws -> Int {
        Int(try db.scalarInt("SELECT count(*) FROM (\(unnamedSelect(q: "", excluding: ignored)))"))
    }

    /// The shared inner select. `status@broadcast` is the owner's own status feed, not a conversation
    /// with anybody, so it is left out rather than offered as a business to name.
    private func unnamedSelect(q: String, excluding ignored: Set<String>) -> String {
        let like = "%" + Self.sqlQuote(q) + "%"
        // LEFT JOIN on purpose: a chat with no messages is still an unnamed chat, and leaving it out made the
        // list quietly disagree with the archive (270 newsletters, 18 of them with a message).
        let from = hasChatStats
            ? "chats c LEFT JOIN chat_stats s ON s.chat_id = c.chat_id"
            : "chats c LEFT JOIN (SELECT chat_id, count(*) n, min(ts) first_ts, max(ts) last_ts FROM messages GROUP BY chat_id) s ON s.chat_id = c.chat_id"
        let last = "coalesce(\(hasLastRealCol ? "ifnull(s.last_real_ts, s.last_ts)" : "s.last_ts"), 0)"
        var conds = ["coalesce(c.resolved,0) = 0", "c.jid <> 'status@broadcast'"]
        if !q.trimmingCharacters(in: .whitespaces).isEmpty {
            conds.append("(c.name LIKE '\(like)' OR c.person LIKE '\(like)' OR c.jid LIKE '\(like)')")
        }
        let skip = ignored.filter { !$0.isEmpty }.map { "'" + Self.sqlQuote($0) + "'" }.sorted()
        if !skip.isEmpty { conds.append("c.jid NOT IN (\(skip.joined(separator: ",")))") }
        return """
            SELECT c.chat_id AS id, c.jid AS jid, c.is_group AS grp,
                   coalesce(nullif(c.name,''), nullif(c.person,''), c.jid) AS label,
                   coalesce(s.n, 0) AS n, \(last) AS last_ts,
                   CASE WHEN c.is_group = 1 OR c.jid LIKE '%@g.us' THEN 'group'
                        WHEN c.jid LIKE '%@newsletter' THEN 'newsletter'
                        WHEN c.jid LIKE '%@bot' OR c.jid LIKE '%@broadcast'
                          OR c.jid LIKE '%@temp' OR c.jid LIKE '%@status' THEN 'business'
                        ELSE 'person' END AS k
            FROM \(from) WHERE \(conds.joined(separator: " AND "))
            """
    }
}
