import Foundation

/// Index reads for meaning-based search. The semantic worker owns this file, so the shared `VaultStore` and the index
/// schema stay untouched; everything here is a read-only query against the visible index (pruning and contact merges
/// are already applied there).
extension VaultStore {
    /// One message's text, as input for an embedding. The uid is the durable identity; the row id is only a cursor.
    public struct SemanticText: Sendable {
        public let id: Int64
        public let chatID: Int64
        public let ts: Int64
        public let uid: String
        public let text: String
    }

    /// Messages worth embedding: real text, a durable uid, and at least a few characters. Blank/system rows, media-only
    /// rows and rows without a uid are skipped. Written once so the count stat and the scan can never disagree.
    static let semanticEligibleSQL = "(COALESCE(m.text,'') <> '' AND m.uid IS NOT NULL AND m.uid <> '' AND length(trim(m.text)) >= 3)"

    public func semanticEligibleCount() throws -> Int {
        Int(try db.scalarInt("SELECT count(*) FROM messages m WHERE \(Self.semanticEligibleSQL)"))
    }

    /// Oldest-first page of eligible messages, paged by `(ts, id)` so equal timestamps are never skipped.
    public func semanticScanPage(afterTs: Int64, afterId: Int64, limit: Int = 500) throws -> (rows: [SemanticText], lastTs: Int64, lastId: Int64) {
        var out: [SemanticText] = []
        try db.query("""
            SELECT m.id, m.chat_id, m.ts, m.uid, m.text FROM messages m
            WHERE \(Self.semanticEligibleSQL) AND (m.ts > \(afterTs) OR (m.ts = \(afterTs) AND m.id > \(afterId)))
            ORDER BY m.ts, m.id LIMIT \(max(1, limit))
            """) {
            out.append(SemanticText(id: $0.int(0), chatID: $0.int(1), ts: $0.int(2), uid: $0.text(3) ?? "", text: $0.text(4) ?? ""))
        }
        guard let last = out.last else { return ([], afterTs, afterId) }
        return (out, last.ts, last.id)
    }

    /// Every eligible uid in the visible index. Used to drop vectors for messages that were pruned or merged away.
    public func semanticEligibleUIDs() throws -> Set<String> {
        var out = Set<String>()
        try db.query("SELECT m.uid FROM messages m WHERE \(Self.semanticEligibleSQL)") { out.insert($0.text(0) ?? "") }
        return out
    }

    /// Eligible uids of one chat, for the "only in this chat" filter.
    public func semanticChatUIDs(chat: Int64) throws -> Set<String> {
        var out = Set<String>()
        try db.query("SELECT m.uid FROM messages m WHERE \(Self.semanticEligibleSQL) AND m.chat_id=\(chat)") { out.insert($0.text(0) ?? "") }
        return out
    }

    /// Resolves ranked uids against the current index. Unresolved (pruned, merged away or never here) uids are simply
    /// absent from the result, so a recycled row id can never be shown as a source.
    public func semanticMessages(uids: [String], chat: Int64? = nil) throws -> [ContextMessage] {
        guard !uids.isEmpty else { return [] }
        let chatSQL = chat.map { " AND m.chat_id=\($0)" } ?? ""
        var out: [ContextMessage] = []
        let unique = Array(Set(uids.filter { !$0.isEmpty }))
        for batch in stride(from: 0, to: unique.count, by: 400).map({ Array(unique[$0..<min($0 + 400, unique.count)]) }) {
            let list = batch.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
            try db.query("""
                SELECT m.id, m.chat_id, c.name, m.ts, m.from_me, m.sender, m.text, m.uid
                FROM messages m JOIN chats c USING(chat_id)
                WHERE m.uid IN (\(list)) AND COALESCE(m.text,'') <> ''\(chatSQL)
                """) {
                out.append(ContextMessage(id: $0.int(0), chatID: $0.int(1), chat: $0.text(2) ?? "", ts: VaultStore.date($0.int(3)),
                                          fromMe: $0.int(4) == 1, sender: $0.text(5) ?? "", text: $0.text(6) ?? "", uid: $0.text(7) ?? ""))
            }
        }
        return out
    }

    /// Same-chat neighbours of a seed message, oldest first, skipping empty/system rows.
    public func semanticNeighbours(seedMessageID: Int64, chatID: Int64, before: Int = 2, after: Int = 2) throws -> [ContextMessage] {
        var ts: Int64 = 0
        try db.query("SELECT ts FROM messages WHERE id=\(seedMessageID)") { ts = $0.int(0) }
        guard ts > 0 else { return [] }
        func read(_ sql: String) throws -> [ContextMessage] {
            var rows: [ContextMessage] = []
            try db.query(sql) {
                rows.append(ContextMessage(id: $0.int(0), chatID: $0.int(1), chat: $0.text(2) ?? "", ts: VaultStore.date($0.int(3)),
                                          fromMe: $0.int(4) == 1, sender: $0.text(5) ?? "", text: $0.text(6) ?? "", uid: $0.text(7) ?? ""))
            }
            return rows
        }
        let select = "SELECT m.id, m.chat_id, c.name, m.ts, m.from_me, m.sender, m.text, m.uid FROM messages m JOIN chats c USING(chat_id)"
        let visible = "COALESCE(m.text,'') <> ''"
        var out: [ContextMessage] = []
        if before > 0 {
            out += try read("""
                \(select) WHERE m.chat_id=\(chatID) AND \(visible)
                AND (m.ts < \(ts) OR (m.ts = \(ts) AND m.id < \(seedMessageID)))
                ORDER BY m.ts DESC, m.id DESC LIMIT \(before)
                """).reversed()
        }
        if after > 0 {
            out += try read("""
                \(select) WHERE m.chat_id=\(chatID) AND \(visible)
                AND (m.ts > \(ts) OR (m.ts = \(ts) AND m.id > \(seedMessageID)))
                ORDER BY m.ts, m.id LIMIT \(after)
                """)
        }
        return out
    }

    /// Ranked keyword seed uids (bm25, best first), without the neighbour expansion `retrieve` does. Same term rules as
    /// `retrieve`, so a hybrid answer searches the same keywords a keyword-only answer would.
    public func semanticFTSSearch(question: String, chat: Int64?, limit: Int = 30) throws -> [String] {
        let hasFTS = (try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='msg_fts'")) ?? 0
        guard hasFTS > 0 else { return [] }
        let words = question.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !VaultStore.stopwords.contains($0) }
        var seen = Set<String>(); let terms = words.filter { seen.insert($0).inserted }.prefix(8)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
        let st = try db.prepare("""
            SELECT m.uid FROM msg_fts JOIN messages m ON m.id = msg_fts.rowid
            WHERE msg_fts MATCH ? AND m.uid IS NOT NULL AND m.uid <> ''\(chat.map { " AND m.chat_id=\($0)" } ?? "")
            ORDER BY bm25(msg_fts), m.uid LIMIT \(max(1, limit))
            """)
        sqlite3_bindText(st, match)
        var out: [String] = [], added = Set<String>()
        while try st.step() {
            let uid = st.text(0) ?? ""
            if !uid.isEmpty, added.insert(uid).inserted { out.append(uid) }
        }
        return out
    }
}
