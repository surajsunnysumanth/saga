import Foundation
import Testing
@testable import SagaCore

/// Reactions and stickers must arrive through **both** ways into the archive. `Importer` reads a
/// msgstore directly; `Vault.ingest` writes an NDJSON segment that `VaultIndexer` later rebuilds an
/// index from. The reactions and the sticker kind existed only on the first path, so a vault built
/// by `saga vault ingest` reported zero of each while the same data through the direct importer
/// reported tens of thousands. These tests pin the second path, including the cases that decide
/// whether it is usable: a repeat pull must not duplicate, and a reaction that arrives after the
/// message must still land.
@Suite struct ReactionIngestTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("saga-reaction-ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A minimal decrypted msgstore. Message 100 is text from Asha, 101 is a sticker the owner sent
    /// (type 20, file under WhatsApp Stickers), 102 is text from Ben.
    func makeDB(_ dir: URL, _ name: String = "msgstore.db", withReactionTables: Bool = true,
                reactions: String = "", media: String? = nil) throws -> String {
        let path = dir.appendingPathComponent(name).path
        let db = try SQLiteDB(path: path, readOnly: false)
        let mediaSQL = media ?? "INSERT INTO message_media VALUES (101,10,'image/webp','Media/WhatsApp Stickers/STK-1.webp',900,'h-stk','');"
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE jid_map(lid_row_id INTEGER PRIMARY KEY, jid_row_id INT, sort_id INT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER PRIMARY KEY, display_name TEXT, username TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'1203630000','g.us',0,0,0,'1203630000@g.us'),
                               (2,'5550000001','s.whatsapp.net',0,0,0,'5550000001@s.whatsapp.net'),
                               (3,'5550000002','s.whatsapp.net',0,0,0,'5550000002@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,'Quiz club');
        INSERT INTO message VALUES
          (100,10,0,2,1700000000000,0,'the bus story','k1'),
          (101,10,1,NULL,1700100000000,20,NULL,'k2'),
          (102,10,0,3,1700200000000,0,'the printer again','k3');
        \(mediaSQL)
        """)
        if withReactionTables {
            try db.exec("""
            CREATE TABLE message_add_on(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, key_id TEXT,
                                        sender_jid_row_id INT, parent_message_row_id INT, timestamp INT,
                                        status INT, message_add_on_type INT);
            CREATE TABLE message_add_on_reaction(message_add_on_row_id INTEGER PRIMARY KEY, reaction TEXT, sender_timestamp INT);
            """)
            if !reactions.isEmpty { try db.exec(reactions) }
        }
        return path
    }

    func index(_ vault: Vault, _ dir: URL, _ name: String = "index.db") throws -> SQLiteDB {
        let out = dir.appendingPathComponent(name).path
        _ = try VaultIndexer.build(vault: vault, out: out)
        return try SQLiteDB(path: out, readOnly: true)
    }

    func count(_ db: SQLiteDB, _ sql: String) throws -> Int64 { try db.scalarInt(sql) }

    // MARK: - The gap this closes

    @Test func vaultIngestCarriesReactionsAndTheStickerKind() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Ben and the owner both react to Asha's line; Chitra's own laugh on her own message is a
        // different message, so this fixture keeps it to the two reactors.
        let reactions = """
        INSERT INTO message_add_on VALUES
          (1,10,0,'a1',3,100,1700000060000,0,56),
          (2,10,1,'a2',NULL,100,1700000070000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000060000),(2,'❤️',1700000070000);
        """
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let r = try vault.ingest(msgstore: try makeDB(dir, reactions: reactions), label: "t")
        #expect(r.reactionsAdded == 2)

        let idx = try index(vault, dir)
        #expect(try count(idx, "SELECT count(*) FROM reactions") == 2)
        // The reactor is the person who tapped the emoji, resolved from the same JID facts a
        // message sender carries — not a raw row id and not the message's author.
        var rows: [(sender: String, name: String, emoji: String)] = []
        try idx.query("SELECT sender, sender_name, emoji FROM reactions ORDER BY sender") {
            rows.append(($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? ""))
        }
        #expect(rows.map(\.sender) == ["5550000002", "me"])
        #expect(rows.first(where: { $0.sender == "5550000002" })?.name == "+5550000002")
        #expect(Set(rows.map(\.emoji)) == ["😂", "❤️"])
        // The sticker is a sticker, not a photo: message type 20 is the evidence.
        #expect(try count(idx, "SELECT count(*) FROM media WHERE kind='sticker'") == 1)
        #expect(try count(idx, "SELECT count(*) FROM media WHERE kind='image'") == 0)
    }

    // MARK: - Idempotency

    @Test func ingestingTheSameBackupTwiceAddsNoReactionsAndNoSegment() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reactions = """
        INSERT INTO message_add_on VALUES (1,10,0,'a1',3,100,1700000060000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000060000);
        """
        let source = try makeDB(dir, reactions: reactions)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let first = try vault.ingest(msgstore: source, label: "t")
        #expect(first.reactionsAdded == 1)
        #expect(first.added == 3)
        let segments = vault.segmentFiles().count
        #expect(segments == 1)

        // The same backup again: nothing new, so nothing is written and no second segment appears.
        let second = try vault.ingest(msgstore: source, label: "t")
        #expect(second.added == 0)
        #expect(second.reactionsAdded == 0)
        #expect(second.segment == nil)
        #expect(vault.segmentFiles().count == segments)

        let idx = try index(vault, dir)
        #expect(try count(idx, "SELECT count(*) FROM reactions") == 1)
    }

    /// The owner's real case: the vault already holds every message, so a pull adds none — the
    /// reactions still have to arrive, because that is the whole point of re-pulling a backup.
    @Test func reactionsOnAlreadyImportedMessagesStillLand() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let bare = try makeDB(dir, "bare.db", withReactionTables: false)
        let first = try vault.ingest(msgstore: bare, label: "t")
        #expect(first.added == 3)
        #expect(first.reactionsAdded == 0)

        let withReactions = try makeDB(dir, "later.db", reactions: """
        INSERT INTO message_add_on VALUES
          (1,10,0,'a1',3,100,1700000060000,0,56),
          (2,10,0,'a2',3,100,1700000090000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000060000),(2,'👍',1700000090000);
        """)
        // Same messages, so nothing is added — but the changed reaction (😂 replaced by 👍) arrives
        // as its own record, and only the newest one counts.
        let second = try vault.ingest(msgstore: withReactions, label: "t")
        #expect(second.added == 0)
        #expect(second.reactionsAdded == 1)
        #expect(second.segment != nil)

        let idx = try index(vault, dir)
        #expect(try count(idx, "SELECT count(*) FROM reactions") == 1)
        #expect(try count(idx, "SELECT count(*) FROM reactions WHERE emoji='👍'") == 1)
    }

    // MARK: - Older archives

    /// `message_add_on` can point at a `jid` row the backup no longer carries (a deleted contact).
    /// Somebody still reacted, and the direct importer records them as Unknown — the vault path
    /// must agree rather than silently dropping the row.
    @Test func reactionFromAJIDRowTheBackupNoLongerHoldsIsRecordedAsUnknown() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let r = try vault.ingest(msgstore: try makeDB(dir, reactions: """
        INSERT INTO message_add_on VALUES (1,10,0,'a1',99,100,1700000060000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000060000);
        """), label: "t")
        #expect(r.reactionsAdded == 1)
        let idx = try index(vault, dir)
        #expect(try count(idx, "SELECT count(*) FROM reactions WHERE sender='unknown'") == 1)
        #expect(try count(idx, "SELECT count(*) FROM reactions WHERE sender_name='Unknown'") == 1)
    }

    @Test func backupWithoutReactionTablesIngestsCleanly() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let r = try vault.ingest(msgstore: try makeDB(dir, withReactionTables: false), label: "t")
        #expect(r.added == 3)
        #expect(r.reactionsAdded == 0)
        let idx = try index(vault, dir)
        #expect(try count(idx, "SELECT count(*) FROM messages") == 3)
        #expect(try count(idx, "SELECT count(*) FROM reactions") == 0)
        // The sticker is unaffected by the missing table.
        #expect(try count(idx, "SELECT count(*) FROM media WHERE kind='sticker'") == 1)
    }

    /// A photo is a photo: with no type 20 and no sticker folder, an image stays an image. The kind
    /// rule has two pieces of evidence and neither may be invented.
    @Test func ordinaryPhotoIsNotASticker() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: try makeDB(dir, withReactionTables: false, media: """
        INSERT INTO message_media VALUES (100,10,'image/jpeg','Media/WhatsApp Images/IMG-1.jpg',900,'h-img','');
        """), label: "t")
        let idx = try index(vault, dir)
        #expect(try count(idx, "SELECT count(*) FROM media WHERE kind='image'") == 1)
        #expect(try count(idx, "SELECT count(*) FROM media WHERE kind='sticker'") == 0)
    }
}
