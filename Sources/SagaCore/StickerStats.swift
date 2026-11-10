import Foundation

/// Which stickers a conversation keeps reaching for.
///
/// A sticker is identified by its file's SHA-256, never by its position in the archive: the
/// same picture sent forty times is forty sends of *one* sticker, and two copies of the same
/// file under different names are still one sticker. A sticker has no words to quote, so the
/// honest thing a card can say is how many went round, how many were different, and how often
/// the busiest one came back — plus the hash and path, so the exact file can be found again.
public enum Stickers {
    public struct Use: Sendable, Equatable {
        /// SHA-256 of the sticker file. Two sends of the same file share this.
        public let hash: String
        /// The path the archive recorded for it, when it recorded one.
        public let path: String?
        /// How many times it was sent in scope.
        public let count: Int
        /// The person who sent it most in scope ("You" for the owner).
        public let sender: String?
        public init(hash: String, path: String?, count: Int, sender: String?) {
            self.hash = hash; self.path = path; self.count = count; self.sender = sender
        }
    }

    public struct Summary: Sendable, Equatable {
        /// Sticker messages in scope, including rows whose file had no hash.
        public var total = 0
        /// Distinct sticker files, by SHA-256.
        public var distinct = 0
        /// Sticker rows with no recorded hash: counted, never named, because there is no
        /// identity to count them by.
        public var unhashed = 0
        /// Sticker messages the owner sent, and everyone else sent.
        public var mine = 0, theirs = 0
        /// Most-used first, at most three. Empty when the archive recorded no sticker hashes.
        public var top: [Use] = []
        public var topCount: Int { top.first?.count ?? 0 }
        public var isEmpty: Bool { total == 0 }
        public init() {}
    }

    public struct PersonUse: Sendable, Equatable {
        public let person: String
        public let name: String
        public let total: Int
        public let distinct: Int
        public let top: Use?
    }

    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    /// The shared scope clause. `stickerOnly` is always applied: a photo in `WhatsApp Images`
    /// is never counted here just because it is an image.
    private static func scope(chatID: Int64?, year: String?, person: String?) -> String {
        // A path is not required: a sticker with no recorded path still happened, and its hash
        // can still identify it. Only the identity comes from the file, never the count.
        var parts = ["md.kind='sticker'"]
        if let chatID { parts.append("m.chat_id=\(chatID)") }
        if let year {
            let safe = esc(year)
            parts.append("strftime('%Y',m.ts/1000,'unixepoch','localtime')='\(safe)'")
        }
        if let person, !person.isEmpty { parts.append("m.person='\(esc(person))'") }
        return parts.joined(separator: " AND ")
    }

    private static let grouped = """
        SELECT md.file_hash, COALESCE(NULLIF(md.file_path,''), ''), m.person, m.from_me,
               COALESCE(NULLIF(p.name,''), NULLIF(m.sender,''), ''),
               count(*) AS sends
        FROM messages m
        JOIN media md ON md.msg_id = m.id
        LEFT JOIN people p ON p.person = m.person
        WHERE %@
        GROUP BY md.file_hash, m.person
        """

    /// Aggregate one scope. A single grouped pass gives the totals, the distinct files, the
    /// busiest sticker and who sends it, so every number in the card comes from the same rows.
    public static func summary(store: VaultStore, chatID: Int64? = nil, year: String? = nil,
                               person: String? = nil) throws -> Summary {
        var out = Summary()
        let whereSQL = scope(chatID: chatID, year: year, person: person)
        try store.db.query("""
            SELECT count(*), COALESCE(sum(m.from_me),0),
                   COALESCE(sum(CASE WHEN COALESCE(md.file_hash,'')='' THEN 1 ELSE 0 END),0)
            FROM messages m JOIN media md ON md.msg_id = m.id
            WHERE \(whereSQL)
            """) {
            out.total = Int($0.int(0)); out.mine = Int($0.int(1)); out.unhashed = Int($0.int(2))
        }
        out.theirs = max(0, out.total - out.mine)
        guard out.total > 0 else { return out }

        struct Agg { var count = 0; var path = ""; var senders: [String: Int] = [:] }
        var byHash: [String: Agg] = [:]
        try store.db.query(grouped.replacingOccurrences(of: "%@", with: whereSQL)) { row in
            let hash = row.text(0) ?? ""
            guard !hash.isEmpty else { return }
            let person = row.text(2) ?? ""
            let n = Int(row.int(5))
            var a = byHash[hash] ?? Agg()
            a.count += n
            if a.path.isEmpty { a.path = row.text(1) ?? "" }
            // Grouped by person key, not display name, so a merged identity is one sender.
            a.senders[person.isEmpty ? "unknown" : person, default: 0] += n
            byHash[hash] = a
        }
        out.distinct = byHash.count
        // Broken into a loop on purpose: a single `map` + `sorted` + `prefix` chain here is more
        // than GitHub's type checker will do in reasonable time ("unable to type-check this
        // expression"), even though it compiles locally. The steps say the same thing.
        var uses: [Use] = []
        uses.reserveCapacity(byHash.count)
        for (hash, a) in byHash {
            let path: String? = a.path.isEmpty ? nil : a.path
            uses.append(Use(hash: hash, path: path, count: a.count,
                            sender: topSender(a.senders, store: store)))
        }
        uses.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return (a.path ?? "") < (b.path ?? "")
        }
        out.top = Array(uses.prefix(3))
        return out
    }

    /// A sender key is not a name; resolve it once here so the copy can name the person.
    private static func topSender(_ senders: [String: Int], store: VaultStore) -> String? {
        guard let best = senders.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        if best.key == "me" || best.key == "self" { return "You" }
        var name = ""
        try? store.db.query("SELECT name FROM people WHERE person='\(esc(best.key))' LIMIT 1") { name = $0.text(0) ?? "" }
        return name.isEmpty ? nil : name
    }

    /// Each person's own sticker habit in one conversation, busiest sender first.
    public static func byPerson(store: VaultStore, chatID: Int64) throws -> [PersonUse] {
        let whereSQL = scope(chatID: chatID, year: nil, person: nil)
        struct Agg { var total = 0; var byHash: [String: Int] = [:]; var paths: [String: String] = [:]; var name = "" }
        var people: [String: Agg] = [:]
        try store.db.query(grouped.replacingOccurrences(of: "%@", with: whereSQL)) { row in
            let hash = row.text(0) ?? ""
            let key = row.text(2) ?? ""
            let name = row.int(3) != 0 ? "You" : (row.text(4) ?? "")
            let n = Int(row.int(5))
            var a = people[key] ?? Agg()
            a.total += n
            // A row with no hash still counts as a send, but can never be the "most used" pick:
            // there is no file identity to count it by.
            if !hash.isEmpty {
                a.byHash[hash, default: 0] += n
                if a.paths[hash] == nil { a.paths[hash] = row.text(1) ?? "" }
            }
            a.name = name.isEmpty ? (key.isEmpty ? "Unknown" : key) : name
            people[key] = a
        }
        return people.compactMap { key, a in
            let top = a.byHash.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            return PersonUse(person: key, name: a.name, total: a.total, distinct: a.byHash.count,
                             top: top.map { Use(hash: $0.key, path: a.paths[$0.key].flatMap { $0.isEmpty ? nil : $0 },
                                                count: $0.value, sender: a.name) })
        }.sorted { a, b in a.total != b.total ? a.total > b.total : a.name < b.name }
    }
}
