import Foundation

/// Quotes use stable source-chat/key/direction UIDs, never rebuildable row IDs.
enum MessageReplies {
    static let schema = "CREATE TABLE message_replies(uid TEXT PRIMARY KEY, target_uid TEXT NOT NULL);"

    static func source(_ db: SQLiteDB) throws -> [String: String] {
        guard try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='message_quoted'") > 0 else { return [:] }
        var columns = Set<String>()
        try db.query("PRAGMA table_info(message_quoted)") { if let name = $0.text(1) { columns.insert(name) } }
        guard Set(["message_row_id", "chat_row_id", "from_me", "key_id"]).isSubset(of: columns) else { return [:] }
        var out: [String: String] = [:]
        try db.query("""
        SELECT j.raw_string,m.key_id,m.from_me,q.key_id,q.from_me,qj.raw_string
        FROM message_quoted q JOIN message m ON m._id=q.message_row_id
        JOIN chat c ON c._id=m.chat_row_id JOIN jid j ON j._id=c.jid_row_id
        JOIN chat qc ON qc._id=q.chat_row_id JOIN jid qj ON qj._id=qc.jid_row_id
        WHERE m.timestamp>0 AND q.key_id<>'' AND m.key_id<>''
        """) { r in
            guard let chat = r.text(0), let key = r.text(1), let targetKey = r.text(3), let targetChat = r.text(5) else { return }
            out[Uid.make(chat: chat, keyId: key, fromMe: r.int(2))] = Uid.make(chat: targetChat, keyId: targetKey, fromMe: r.int(4))
        }
        return out
    }

    static func insert(_ replies: [String: String], into db: SQLiteDB) throws {
        let statement = try db.prepare("INSERT OR IGNORE INTO message_replies(uid,target_uid) VALUES(?,?)")
        for (uid, target) in replies { try statement.run([.text(uid), .text(target)]) }
    }

    static func load(_ db: SQLiteDB) throws -> [String: String] {
        guard try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='message_replies'") > 0 else { return [:] }
        var out: [String: String] = [:]
        try db.query("SELECT uid,target_uid FROM message_replies") { if let uid = $0.text(0), let target = $0.text(1) { out[uid] = target } }
        return out
    }
}
