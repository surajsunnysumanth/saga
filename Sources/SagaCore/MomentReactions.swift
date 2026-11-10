import Foundation

/// A reply that quoted a message, as the story prints it: indented under the message it
/// answered, with the person who wrote it.
public struct QuotedReply: Sendable, Equatable, Identifiable {
    public let uid: String
    public let author: String
    public let text: String
    public let fromMe: Bool
    public var id: String { uid }

    public init(uid: String, author: String, text: String, fromMe: Bool) {
        self.uid = uid
        self.author = author
        self.text = text
        self.fromMe = fromMe
    }
}

/// What a moment collected from other people: how many reacted to it, with which emoji, and
/// the replies that quoted it. The card prints these as `MESSAGE (6 reacts)` with one line
/// per quoted reply underneath, so a moment is never just a floating sentence.
///
/// The count is people, not rows: WhatsApp stores one row per person per message, and a
/// re-import can carry the same reaction twice, so the loader de-duplicates by reactor. The
/// author's own reaction to their own message is not counted — the same rule the laugh and
/// heart totals already use — because the card's claim is that *other people* reacted.
public struct MomentReactions: Sendable, Equatable {
    public struct Emoji: Sendable, Equatable {
        public let emoji: String
        public let count: Int
        public init(emoji: String, count: Int) { self.emoji = emoji; self.count = count }
    }

    /// Distinct people who reacted, excluding the author.
    public var reactors = 0
    /// One entry per emoji, biggest first; ties in a fixed alphabetical order so the line
    /// does not shuffle between builds.
    public var emoji: [Emoji] = []
    /// Replies that quoted the message, oldest first, one per person, at most three.
    public var quoted: [QuotedReply] = []

    public init() {}

    public var isEmpty: Bool { reactors == 0 && quoted.isEmpty }

    /// `6 reacts`, `1 react`, or nothing at all — the label beside the message.
    public var label: String {
        switch reactors {
        case 0: return ""
        case 1: return "1 react"
        default: return "\(reactors) reacts"
        }
    }

    /// `😂 4  ❤️ 2` — the breakdown printed under the message. Capped at three emoji so the
    /// line stays a caption instead of a wall.
    public var summary: String {
        emoji.prefix(3).map { "\($0.emoji) \($0.count)" }.joined(separator: "  ")
    }

    /// The stack the card draws: the reply that earned the moment first (the story already
    /// knows it), then the other replies that quoted the message, each printed once.
    public static func stack(lead: QuotedReply?, others: [QuotedReply], limit: Int = 3) -> [QuotedReply] {
        var out: [QuotedReply] = []
        var seen = Set<String>()
        func key(_ r: QuotedReply) -> String {
            r.text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
        }
        for r in ([lead].compactMap { $0 } + others) where out.count < limit {
            guard !r.text.isEmpty, seen.insert(key(r)).inserted else { continue }
            out.append(r)
        }
        return out
    }
}

/// One pass that reads reactions and quoted replies for the messages a story picked.
///
/// All three stories (year, duo, group) call this, so the number next to a message means the
/// same thing everywhere and can never drift from the totals in the card's subtitle.
public enum MomentReactionsLoader {
    public struct Target: Sendable {
        public let id: Int64
        public let uid: String
        /// The person key (or sender) who wrote the message, so their own reaction is skipped.
        public let author: String
        public init(id: Int64, uid: String, author: String) {
            self.id = id; self.uid = uid; self.author = author
        }
    }

    /// - Parameter chatID: the conversation the moments came from; reactions are read for it.
    public static func load(store: VaultStore, chatID: Int64, targets: [Target],
                            quotedLimit: Int = 3) -> [Int64: MomentReactions] {
        guard !targets.isEmpty else { return [:] }
        var out: [Int64: MomentReactions] = [:]
        let byUID = Dictionary(targets.map { ($0.uid, $0.id) }, uniquingKeysWith: { a, _ in a })
        let authors = Dictionary(targets.map { ($0.id, $0.author) }, uniquingKeysWith: { a, _ in a })
        for t in targets { out[t.id] = MomentReactions() }

        // Reactions: one row per person per message in the index, but count distinct people
        // anyway so a re-imported duplicate can never inflate the number.
        var reactors: [Int64: Set<String>] = [:]
        var emoji: [Int64: [String: Set<String>]] = [:]
        for batch in batches(targets.map(\.id)) {
            let list = batch.map(String.init).joined(separator: ",")
            try? store.db.query("""
                SELECT message_id, sender, emoji FROM reactions
                WHERE chat_id=\(chatID) AND message_id IN (\(list))
                """) {
                let id = $0.int(0), sender = $0.text(1) ?? ""
                let symbol = $0.text(2) ?? ""
                guard !sender.isEmpty, sender != authors[id] else { return }   // own reaction: not counted
                reactors[id, default: []].insert(sender)
                if !symbol.isEmpty { emoji[id, default: [:]][symbol, default: []].insert(sender) }
            }
        }

        // Quoted replies: `message_replies` maps the reply's uid to the message it answered.
        if !byUID.isEmpty {
            var quoted: [Int64: [QuotedReply]] = [:]
            var seen: [Int64: Set<String>] = [:]
            var seenPeople: [Int64: Set<String>] = [:]
            for batch in batches(Array(byUID.keys)) {
                let list = batch.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
                guard !list.isEmpty else { continue }
                try? store.db.query("""
                    SELECT r.target_uid, COALESCE(m.uid,''), COALESCE(m.sender,''), COALESCE(m.text,''), m.from_me
                    FROM message_replies r JOIN messages m ON m.uid=r.uid
                    WHERE r.target_uid IN (\(list)) AND COALESCE(m.text,'')<>''
                    ORDER BY m.ts
                    """) {
                    let target = $0.text(0) ?? ""
                    guard let id = byUID[target] else { return }
                    let uid = $0.text(1) ?? ""
                    let me = $0.int(4) != 0
                    let sender = $0.text(2) ?? ""
                    let text = WrappedCopy.quote(store.resolveMentions($0.text(3) ?? ""), limit: 140)
                    guard !text.isEmpty, seen[id, default: []].insert(text.lowercased()).inserted else { return }
                    // One reply per person is enough to show the shape of the thread.
                    let who = me ? "me" : sender
                    guard !who.isEmpty, seenPeople[id, default: []].insert(who).inserted else { return }
                    quoted[id, default: []].append(QuotedReply(uid: uid,
                                                              author: me ? "You" : (sender.isEmpty ? "Someone" : sender),
                                                              text: text, fromMe: me))
                }
            }
            for (id, list) in quoted {
                out[id]?.quoted = Array(list.prefix(quotedLimit))
            }
        }

        for (id, people) in reactors {
            guard var r = out[id] else { continue }
            r.reactors = people.count
            r.emoji = (emoji[id] ?? [:]).map { MomentReactions.Emoji(emoji: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji < $1.emoji }
            out[id] = r
        }
        return out
    }

    private static func batches<T>(_ values: [T]) -> [[T]] {
        stride(from: 0, to: values.count, by: 400).map { Array(values[$0..<min($0 + 400, values.count)]) }
    }
}
