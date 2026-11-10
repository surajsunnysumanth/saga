import Foundation

/// A WhatsApp emoji reaction: one person's one emoji on one message.
///
/// WhatsApp keeps these in `message_add_on` / `message_add_on_reaction`, entirely separate from
/// the message text. Before this table existed the archive could not see them at all, so a
/// message with twenty 😂 reactions scored the same as a message nobody answered.
public struct MessageReaction: Sendable, Hashable {
    /// Index message id (`messages.id`) this reaction is attached to.
    public let messageID: Int64
    public let chatID: Int64
    /// Person key of the reactor, `"me"` for the owner.
    public let sender: String
    /// Display name of the reactor, resolved at import time (falls back to the person key).
    public let senderName: String
    public let emoji: String
    /// Milliseconds since 1970, in the source's clock (the same clock as `messages.ts`).
    public let ts: Int64

    public var isMine: Bool { sender == "me" }
    public var isLaugh: Bool { WrappedReactionDetector.isLaughEmoji(emoji) }
    public var isHeart: Bool { WrappedReactionDetector.isHeartEmoji(emoji) }
}

/// Reads reactions out of a decrypted msgstore.db and stores them in `vault_index.db`.
///
/// Two rules keep the numbers repeatable:
///  * identity is `(message_id, sender)` — WhatsApp allows one current reaction per person per
///    message, so re-importing the same backup replaces a row instead of adding a second count;
///  * a source without the reaction tables imports as zero reactions, exactly as before.
enum MessageReactions {
    /// A row before index ids are assigned: `messageID`/`chatID` are source row ids.
    struct SourceRow: Sendable {
        let messageID: Int64, chatID: Int64, sender: String, senderName: String, emoji: String, ts: Int64
    }

    /// A row as the source stores it, before any name resolution: the message it sits on, which JID
    /// row tapped it (`0` for the owner), when, and the emoji. The vault path needs the row rather
    /// than a resolved name, because a vault segment carries JID facts and the index resolves the
    /// person — exactly like it does for a message sender.
    struct RawRow: Sendable {
        let messageID: Int64, chatID: Int64, senderRowID: Int64, ts: Int64, emoji: String
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS reactions(
      message_id INTEGER NOT NULL, chat_id INTEGER NOT NULL, sender TEXT NOT NULL,
      sender_name TEXT NOT NULL, emoji TEXT NOT NULL, ts INTEGER NOT NULL,
      PRIMARY KEY(message_id, sender)
    );
    CREATE INDEX IF NOT EXISTS ix_reactions_chat ON reactions(chat_id);
    CREATE INDEX IF NOT EXISTS ix_reactions_message ON reactions(message_id);
    """

    private static func tables(_ db: SQLiteDB) throws -> Set<String> {
        var out = Set<String>()
        try db.query("SELECT name FROM sqlite_master WHERE type='table'") { out.insert($0.text(0) ?? "") }
        return out
    }
    private static func columns(_ db: SQLiteDB, _ table: String) throws -> Set<String> {
        var out = Set<String>()
        try db.query("PRAGMA table_info(\(table))") { out.insert($0.text(1) ?? "") }
        return out
    }

    /// Guarded so an older or newer backup without these tables simply has no reactions.
    static func hasSource(_ db: SQLiteDB) -> Bool {
        guard let names = try? tables(db), names.contains("message_add_on"), names.contains("message_add_on_reaction"),
              let addOn = try? columns(db, "message_add_on"), let reaction = try? columns(db, "message_add_on_reaction")
        else { return false }
        return Set(["parent_message_row_id", "chat_row_id", "from_me", "sender_jid_row_id", "timestamp"]).isSubset(of: addOn)
            && Set(["message_add_on_row_id", "reaction"]).isSubset(of: reaction)
    }

    /// Rows as the source archive stores them, with no name resolution.
    static func rawRows(_ db: SQLiteDB) throws -> [RawRow] {
        guard hasSource(db) else { return [] }
        var out: [RawRow] = []
        try db.query("""
            SELECT a.parent_message_row_id, a.chat_row_id, a.from_me, a.sender_jid_row_id,
                   COALESCE(NULLIF(r.sender_timestamp,0), a.timestamp) AS ts, r.reaction
            FROM message_add_on a JOIN message_add_on_reaction r ON r.message_add_on_row_id = a._id
            WHERE a.parent_message_row_id IS NOT NULL AND a.parent_message_row_id <> 0
              AND r.reaction IS NOT NULL AND r.reaction <> ''
            ORDER BY a.parent_message_row_id
            """) { row in
            // A reaction the owner gave themselves carries no sender row; 0 is that "me".
            let reactor: Int64 = (row.int(2) == 0 && !row.isNull(3) && row.int(3) != 0) ? row.int(3) : 0
            out.append(RawRow(messageID: row.int(0), chatID: row.int(1), senderRowID: reactor,
                              ts: row.int(4), emoji: row.text(5) ?? ""))
        }
        return out
    }

    /// Rows as the source archive stores them. `person` resolves a `sender_jid_row_id` to a
    /// person key/name; it is never called for a reaction the owner gave themselves.
    static func source(_ db: SQLiteDB, person: (Int64) -> Resolver.P) throws -> [SourceRow] {
        try rawRows(db).map { r in
            let reactor = r.senderRowID == 0 ? Resolver.P(key: "me", name: "me", resolved: 1) : person(r.senderRowID)
            return SourceRow(messageID: r.messageID, chatID: r.chatID, sender: reactor.key,
                             senderName: reactor.name, emoji: r.emoji, ts: r.ts)
        }
    }

    /// Newest reaction per (message, sender): a changed reaction leaves history rows in
    /// `message_add_on`, and only the latest one is what the phone shows.
    static func dedupe(_ rows: [MessageReaction]) -> [MessageReaction] {
        var latest: [String: MessageReaction] = [:]
        for r in rows {
            let key = "\(r.messageID)|\(r.sender)"
            if let old = latest[key], old.ts > r.ts { continue }
            latest[key] = r
        }
        return latest.values.sorted { $0.messageID != $1.messageID ? $0.messageID < $1.messageID : $0.sender < $1.sender }
    }

    static func load(_ db: SQLiteDB, chatID: Int64? = nil) throws -> [Int64: [MessageReaction]] {
        var out: [Int64: [MessageReaction]] = [:]
        guard ((try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='reactions'")) ?? 0) > 0 else { return out }
        try db.query("""
            SELECT message_id, chat_id, sender, sender_name, emoji, ts FROM reactions
            \(chatID.map { "WHERE chat_id=\($0)" } ?? "") ORDER BY message_id, ts
            """) {
            let r = MessageReaction(messageID: $0.int(0), chatID: $0.int(1), sender: $0.text(2) ?? "",
                                    senderName: $0.text(3) ?? "", emoji: $0.text(4) ?? "", ts: $0.int(5))
            out[r.messageID, default: []].append(r)
        }
        return out
    }

    /// Idempotent upsert keyed on (message_id, sender).
    static func insert(_ rows: [MessageReaction], into db: SQLiteDB) throws {
        guard !rows.isEmpty else { return }
        let statement = try db.prepare("""
            INSERT INTO reactions(message_id, chat_id, sender, sender_name, emoji, ts) VALUES(?,?,?,?,?,?)
            ON CONFLICT(message_id, sender) DO UPDATE SET
              chat_id=excluded.chat_id, sender_name=excluded.sender_name, emoji=excluded.emoji, ts=excluded.ts
            WHERE excluded.ts >= reactions.ts
            """)
        for r in rows {
            try statement.run([.int(r.messageID), .int(r.chatID), .text(r.sender), .text(r.senderName), .text(r.emoji), .int(r.ts)])
        }
    }
}
