import Foundation

/// What people did to one message, collapsed the way a conversation draws it: one chip per
/// distinct emoji with the number of people behind it, and their names for the detail card.
///
/// The index stores one row per `(message, reactor)` — WhatsApp allows a single current
/// reaction per person. This is the read-side shape, so a 900-message chat costs one query and
/// the bubbles never aggregate anything themselves.
public struct MessageReactionSummary: Sendable, Hashable {
    /// One emoji and the people who used it on this message.
    public struct Tally: Sendable, Hashable, Identifiable {
        public let emoji: String
        public let count: Int
        /// Display names in the order people reacted; `You` for the owner, never a raw JID.
        public let names: [String]
        public var id: String { emoji }

        /// Long lists are clipped in the card: twenty names in a popover is a wall, and the
        /// count is the fact that matters. `and 12 more` still says how many are hidden.
        public var namesLabel: String {
            let shown = names.prefix(8)
            let rest = names.count - shown.count
            return rest > 0 ? shown.joined(separator: ", ") + " and \(rest) more"
                            : shown.joined(separator: ", ")
        }

        /// What VoiceOver reads for one chip.
        public var spoken: String {
            count == 1 ? "\(emoji) from \(namesLabel)" : "\(emoji) \(count) times from \(namesLabel)"
        }
    }

    /// Biggest first would reorder a chat every time someone taps; WhatsApp keeps the emoji in
    /// the order they first arrived, and so does this — a stable row is easier to read.
    public let tallies: [Tally]

    public var isEmpty: Bool { tallies.isEmpty }
    public var total: Int { tallies.reduce(0) { $0 + $1.count } }
    /// The chips as one line, for the hover text and the accessibility label.
    public var spoken: String { tallies.map(\.spoken).joined(separator: "; ") }

    public init(tallies: [Tally]) {
        self.tallies = tallies
    }

    /// Collapse the rows for one message.
    ///
    /// Rows may arrive with history (the index upserts on `(message_id, sender)`, but an index
    /// built by an older importer can hold a changed reaction twice), so the newest row per
    /// reactor wins before anything is counted: one person is one reaction, never two.
    public static func build(_ rows: [MessageReaction]) -> MessageReactionSummary {
        var latest: [String: MessageReaction] = [:]
        for r in rows {
            if let old = latest[r.sender], old.ts > r.ts { continue }
            latest[r.sender] = r
        }
        let ordered = latest.values.sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.sender < $1.sender }
        var order: [String] = []
        var counts: [String: Int] = [:]
        var names: [String: [String]] = [:]
        for r in ordered {
            let emoji = r.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty emoji is a corrupt row, not a reaction: drawing a blank chip would look
            // like the app lost something.
            guard !emoji.isEmpty else { continue }
            if counts[emoji] == nil { order.append(emoji) }
            counts[emoji, default: 0] += 1
            names[emoji, default: []].append(reactorName(key: r.sender, stored: r.senderName))
        }
        return MessageReactionSummary(tallies: order.map {
            Tally(emoji: $0, count: counts[$0] ?? 0, names: names[$0] ?? [])
        })
    }

    /// The same naming rules the rest of the app uses for a person: `You` for the owner, a
    /// saved name when the index has one, a number's last four digits when all that is left is
    /// a `lid:`, and never the word "Unknown" where somebody is being credited.
    public static func reactorName(key: String, stored: String) -> String {
        VoiceNote.senderLabel(fromMe: key == "me", sender: stored, person: key)
    }

    /// One message's summary for a single chip, when a caller wants to ask about one emoji.
    public func tally(for emoji: String) -> Tally? { tallies.first { $0.emoji == emoji } }
}
