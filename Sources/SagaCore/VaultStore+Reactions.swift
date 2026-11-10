import Foundation

extension VaultStore {
    /// The reaction chips for a whole page of messages, in one query.
    ///
    /// The conversation is virtualised and can hold thousands of rows, so this is deliberately
    /// batched: a page of 200 bubbles asks once, not 200 times. Rows come back ordered by
    /// `(message_id, ts)` so each message's emoji keep the order people reacted in, and the
    /// grouping happens here rather than in the view — a bubble only ever looks up a value.
    ///
    /// Messages with no reactions are absent from the result, not present with an empty summary:
    /// the caller keeps its own record of what it has asked about.
    public func reactions(for messageIDs: [Int64]) -> [Int64: MessageReactionSummary] {
        guard hasReactions, !messageIDs.isEmpty else { return [:] }
        var rows: [Int64: [MessageReaction]] = [:]
        // `ix_reactions_message` serves the IN list. Chunked at the same width the rest of the
        // store uses for long id lists, so a caller that hands over a whole 900-row chat still
        // stays inside SQLite's limits.
        var start = 0
        while start < messageIDs.count {
            let end = min(start + 400, messageIDs.count)
            let list = messageIDs[start..<end].map(String.init).joined(separator: ",")
            try? db.query("""
                SELECT message_id, chat_id, sender, sender_name, emoji, ts FROM reactions
                WHERE message_id IN (\(list)) ORDER BY message_id, ts
                """) { row in
                let r = MessageReaction(messageID: row.int(0), chatID: row.int(1),
                                        sender: row.text(2) ?? "", senderName: row.text(3) ?? "",
                                        emoji: row.text(4) ?? "", ts: row.int(5))
                rows[r.messageID, default: []].append(r)
            }
            start = end
        }
        return rows.mapValues(MessageReactionSummary.build)
    }
}
