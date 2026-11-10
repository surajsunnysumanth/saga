import Foundation

extension VaultStore {
    /// Message types that are notices about the chat rather than something a person wrote
    /// (the same list the indexer uses for `chat_stats.content` and `last_real_ts`).
    static let replySystemTypes: [Int64] = [7, 27, 36, 55, 90]

    /// One row per archived chat: its latest substantive message, with the participant the
    /// index resolved for that chat.
    ///
    /// A single statement with a correlated `LIMIT 1` per chat, riding the `(chat_id, ts)`
    /// index, instead of reading every chat's history: the reply rule only depends on each
    /// chat's last word, so a 100k-message archive costs the same rows as a 100k-chat one.
    /// "Substantive" mirrors the conversation list — not a system notice, and text, caption
    /// or media. Groups are filtered here because they are never evaluated.
    func replyLatestEvidence() throws -> [ReplyLatestEvidence] {
        let systems = Self.replySystemTypes.map(String.init).joined(separator: ",")
        var out: [ReplyLatestEvidence] = []
        try db.query("""
            SELECT c.chat_id, COALESCE(c.jid,''), COALESCE(c.name,''), COALESCE(c.is_group,0), COALESCE(c.person,''),
                   m.id, COALESCE(m.uid,''), m.ts, COALESCE(m.from_me,0),
                   TRIM(COALESCE(NULLIF(TRIM(m.text, char(32,9,10,13)),''), TRIM(COALESCE(md.caption,''), char(32,9,10,13))), char(32,9,10,13)),
                   md.kind
            FROM chats c
            JOIN messages m ON m.id = (
                SELECT m2.id FROM messages m2 LEFT JOIN media md2 ON md2.msg_id = m2.id
                WHERE m2.chat_id = c.chat_id
                  AND COALESCE(m2.type, 0) NOT IN (\(systems))
                  AND (TRIM(COALESCE(m2.text,''), char(32,9,10,13)) <> ''
                       OR TRIM(COALESCE(md2.caption,''), char(32,9,10,13)) <> '' OR md2.kind IS NOT NULL)
                ORDER BY m2.ts DESC, m2.id DESC LIMIT 1)
            LEFT JOIN media md ON md.msg_id = m.id
            WHERE COALESCE(c.is_group,0) = 0
            ORDER BY c.chat_id
            """) { row in
            out.append(ReplyLatestEvidence(chatID: row.int(0), chatJID: row.text(1) ?? "", chatName: row.text(2) ?? "",
                                           person: row.text(4) ?? "", isGroup: row.int(3) != 0,
                                           messageID: row.int(5), uid: row.text(6) ?? "", tsMS: row.int(7),
                                           fromMe: row.int(8) != 0, text: row.text(9) ?? "", mediaKind: row.text(10)))
        }
        return out
    }
}
