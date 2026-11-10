import Foundation

/// Search-as-you-type over the conversation list. The Gallery holds thousands of chats and a
/// menu of all of them is both unusable and expensive to build; this answers one query at a
/// time and returns a handful of rows ranked by how well they match a name or a number.
public struct ChatFilterIndex: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: Int64
        public let name: String
        public let jid: String
        public init(id: Int64, name: String, jid: String = "") {
            self.id = id; self.name = name; self.jid = jid
        }
    }

    private struct Row: Sendable {
        let entry: Entry
        let name: String        // folded, lowercased
        let words: [String]     // folded name, split on anything that isn't a letter or digit
        let digits: String      // every digit in the name and the JID
    }

    private let rows: [Row]

    public init(_ entries: [Entry]) {
        rows = entries.map { entry in
            let name = ChatFilterIndex.fold(entry.name)
            return Row(entry: entry,
                       name: name,
                       words: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init),
                       digits: ChatFilterIndex.digits(of: name + " " + ChatFilterIndex.fold(entry.jid)))
        }
    }

    public var count: Int { rows.count }

    /// Empty query means "every conversation": there is nothing to narrow down to, so the
    /// caller keeps its "All conversations" state rather than a list of nine thousand rows.
    public func matches(_ query: String, limit: Int = 8) -> [Entry] {
        let q = ChatFilterIndex.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty, limit > 0 else { return [] }
        let qDigits = ChatFilterIndex.digits(of: q)
        var scored: [(score: Int, row: Row)] = []
        scored.reserveCapacity(min(rows.count, 64))
        for row in rows {
            guard let score = rank(row: row, query: q, digits: qDigits) else { continue }
            scored.append((score, row))
            if scored.count > 512 { // keep the working set bounded on a very broad query
                scored.sort { ($0.score, $0.row.name) < ($1.score, $1.row.name) }
                scored.removeLast(scored.count - 256)
            }
        }
        scored.sort { a, b in
            a.score == b.score ? (a.row.name == b.row.name ? a.row.entry.id < b.row.entry.id
                                                            : a.row.name < b.row.name)
                               : a.score < b.score
        }
        return scored.prefix(limit).map(\.row.entry)
    }

    public func name(for id: Int64) -> String? {
        guard let entry = rows.first(where: { $0.entry.id == id })?.entry, !entry.name.isEmpty else { return nil }
        return entry.name
    }

    /// Lower score wins. `nil` means "not a match at all".
    private func rank(row: Row, query q: String, digits qDigits: String) -> Int? {
        if row.name == q { return 0 }
        if row.name.hasPrefix(q) { return 1 }
        if row.words.contains(where: { $0.hasPrefix(q) }) { return 2 }
        if row.name.contains(q) { return 3 }
        if !qDigits.isEmpty {
            if row.digits == qDigits { return 4 }
            if row.digits.hasSuffix(qDigits) { return 5 }
            if row.digits.contains(qDigits) { return 6 }
        }
        // "pri men" should find "Priya Menon": every word of the query is a prefix of some word
        // in the name, in any order.
        let qWords = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if qWords.count > 1, qWords.allSatisfy({ part in row.words.contains { $0.hasPrefix(part) } }) {
            return 3
        }
        return nil
    }

    /// Case- and accent-insensitive, so "jose" finds "José" and "MÜLLER" finds "muller".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    static func digits(of text: String) -> String {
        text.filter(\.isNumber)
    }
}
