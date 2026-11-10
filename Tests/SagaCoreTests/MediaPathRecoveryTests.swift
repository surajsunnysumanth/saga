import Foundation
import Testing
@testable import SagaCore

/// The Gallery can only show a file whose path the archive recorded. These tests pin the two
/// places a path can legitimately come from when the phone's own `message_media` row has none:
/// an identical file already recorded under another message, and a later backup that finally
/// saw the file downloaded. Nothing may invent a path from a size or a filename.
@Suite struct MediaPathRecoveryTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("saga-mpr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A minimal decrypted msgstore: one chat, the messages and media rows the test needs.
    func makeDB(_ dir: URL, _ name: String, _ rows: String, media: String = "") throws -> String {
        let path = dir.appendingPathComponent(name).path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE jid_map(lid_row_id INTEGER PRIMARY KEY, jid_row_id INT, sort_id INT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER PRIMARY KEY, display_name TEXT, username TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL);
        \(rows)
        \(media)
        """)
        return path
    }

    func index(_ vault: Vault, _ dir: URL, _ name: String = "i.db") throws -> (SQLiteDB, ImportSummary) {
        let out = dir.appendingPathComponent(name).path
        let s = try VaultIndexer.build(vault: vault, out: out)
        return (try SQLiteDB(path: out, readOnly: true), s)
    }

    func paths(_ idx: SQLiteDB) throws -> [String?] {
        var out: [String?] = []
        try idx.query("SELECT file_path FROM media ORDER BY msg_id") { out.append($0.text(0)) }
        return out
    }

    @Test func pathlessRowBorrowsPathOfIdenticalContent() throws {
        let dir = try tmp()
        let db = try makeDB(dir, "a.db", """
        INSERT INTO message VALUES (1,10,1,NULL,1000,1,NULL,'K1'),(2,10,1,NULL,2000,1,NULL,'K2');
        """, media: """
        INSERT INTO message_media VALUES
          (1,10,'image/jpeg','Media/WhatsApp Images/IMG-1.jpg',10,'same-hash',''),
          (2,10,'image/jpeg',NULL,10,'same-hash','');
        """)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: db, label: "t")
        let (idx, summary) = try index(vault, dir)
        #expect(try paths(idx) == ["Media/WhatsApp Images/IMG-1.jpg", "Media/WhatsApp Images/IMG-1.jpg"])
        #expect(summary.media == 2)
    }

    @Test func forwardedFileIsRecordedWhenItIsImported() throws {
        let dir = try tmp()
        let db = try makeDB(dir, "a.db", """
        INSERT INTO message VALUES (1,10,1,NULL,1000,1,NULL,'K1'),(2,10,1,NULL,2000,1,NULL,'K2');
        """, media: """
        INSERT INTO message_media VALUES
          (1,10,'video/mp4','Media/WhatsApp Video/VID-1.mp4',10,'h',''),
          (2,10,'video/mp4','',10,'h','');
        """)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: db, label: "t")
        // Proof at the segment, not just the index: the record itself carries the borrowed path.
        var recorded: [String: String] = [:]
        try vault.readAll { r in
            guard r["k"] as? String == "m", let u = r["u"] as? String,
                  let md = r["md"] as? [String: Any] else { return }
            recorded[u] = md["path"] as? String ?? ""
        }
        #expect(recorded.count == 2)
        #expect(recorded.values.allSatisfy { $0 == "Media/WhatsApp Video/VID-1.mp4" })
    }

    @Test func laterBackupFillsThePathOfAKnownMessage() throws {
        let dir = try tmp()
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let rows = "INSERT INTO message VALUES (1,10,1,NULL,1000,1,NULL,'K1');"
        // First backup: WhatsApp had not downloaded the photo, so the row has no path.
        let first = try makeDB(dir, "first.db", rows,
                               media: "INSERT INTO message_media VALUES (1,10,'image/jpeg',NULL,10,'h1','');")
        let r1 = try vault.ingest(msgstore: first, label: "t")
        #expect(r1.added == 1); #expect(r1.pathsUpdated == 0)
        let (before, _) = try index(vault, dir, "before.db")
        #expect(try paths(before) == [nil])

        // Second backup: the file is on the phone now. The message is already stored, so the path
        // must arrive as its own record or it can never be written at all.
        let second = try makeDB(dir, "second.db", rows,
                                media: "INSERT INTO message_media VALUES (1,10,'image/jpeg','Media/WhatsApp Images/IMG-2.jpg',10,'h1','');")
        let r2 = try vault.ingest(msgstore: second, label: "t")
        #expect(r2.added == 0); #expect(r2.skipped == 1); #expect(r2.pathsUpdated == 1)
        let (after, _) = try index(vault, dir, "after.db")
        #expect(try paths(after) == ["Media/WhatsApp Images/IMG-2.jpg"])
        #expect(try after.scalarInt("SELECT count(*) FROM messages") == 1)
    }

    @Test func aFileThatExistsNowhereStaysPathless() throws {
        let dir = try tmp()
        let db = try makeDB(dir, "a.db", "INSERT INTO message VALUES (1,10,1,NULL,1000,1,NULL,'K1');",
                            media: "INSERT INTO message_media VALUES (1,10,'image/jpeg',NULL,10,'only-this','');")
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: db, label: "t")
        let (idx, summary) = try index(vault, dir)
        #expect(try paths(idx) == [nil])
        #expect(try idx.scalarInt("SELECT count(*) FROM media") == 1)
        #expect(summary.mediaPathsRecovered == 0)
    }

    @Test func differentContentNeverDonatesAPath() throws {
        let dir = try tmp()
        let db = try makeDB(dir, "a.db", """
        INSERT INTO message VALUES (1,10,1,NULL,1000,1,NULL,'K1'),(2,10,1,NULL,2000,1,NULL,'K2');
        """, media: """
        INSERT INTO message_media VALUES
          (1,10,'image/jpeg','Media/WhatsApp Images/IMG-1.jpg',10,'hash-a',''),
          (2,10,'image/jpeg',NULL,10,'hash-b','');
        """)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: db, label: "t")
        let (idx, _) = try index(vault, dir)
        #expect(try paths(idx) == ["Media/WhatsApp Images/IMG-1.jpg", nil])
    }

    @Test func directImportUsesTheSameRule() throws {
        let dir = try tmp()
        let db = try makeDB(dir, "a.db", """
        INSERT INTO message VALUES (1,10,1,NULL,1000,1,NULL,'K1'),(2,10,1,NULL,2000,1,NULL,'K2');
        """, media: """
        INSERT INTO message_media VALUES
          (1,10,'audio/ogg','Media/WhatsApp Voice Notes/PTT-1.opus',10,'h',''),
          (2,10,'audio/ogg',NULL,10,'h','');
        """)
        let out = dir.appendingPathComponent("direct.db").path
        let s = try Importer.run(ImportOptions(sourceDB: db, outputDB: out))
        #expect(s.mediaPathsRecovered == 1)
        let idx = try SQLiteDB(path: out, readOnly: true)
        #expect(try paths(idx) == ["Media/WhatsApp Voice Notes/PTT-1.opus", "Media/WhatsApp Voice Notes/PTT-1.opus"])
    }
}
