import XCTest
@testable import SagaCore

final class VaultTests: XCTestCase {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("saga-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
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
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net'),
                               (2,'1203630000','g.us',0,0,0,'1203630000@g.us'),
                               (3,'555123','lid',0,0,0,'555123@lid'),
                               (4,'919900011122','s.whatsapp.net',0,0,0,'919900011122@s.whatsapp.net');
        INSERT INTO jid_map VALUES (3,4,0);
        INSERT INTO chat VALUES (10,1,NULL),(11,2,'Friends');
        \(rows)
        \(media)
        """)
        return path
    }

    func testGzipRoundTrip() {
        let d = Data((0..<100_000).map { UInt8($0 % 251) })
        XCTAssertEqual(Gzip.decompress(Gzip.compress(d)), d)
        XCTAssertNil(Gzip.decompress(Data([1, 2, 3])))
    }

    func testIngestIsIdempotentAndIndexMatchesDirectImport() throws {
        let dir = try tmp()
        let rows = """
        INSERT INTO message VALUES (1,10,0,NULL,1000,0,'hi','a'),(2,11,0,3,2000,0,'hello @555123 group','b'),(3,11,1,NULL,3000,0,'me here','c'),(4,11,0,3,4000,1,NULL,'d');
        """
        let media = "INSERT INTO message_media VALUES (4,11,'image/jpeg','Media/WhatsApp Images/x.jpg',10,'hash1','cap');"
        let db = try makeDB(dir, "a.db", rows, media: media)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let r1 = try vault.ingest(msgstore: db, label: "t")
        XCTAssertEqual(r1.added, 4)
        let r2 = try vault.ingest(msgstore: db, label: "t")
        XCTAssertEqual(r2.added, 0); XCTAssertNil(r2.segment)               // nothing new -> no segment written
        XCTAssertEqual(vault.segmentFiles().count, 1)

        let a = dir.appendingPathComponent("a.idx").path, b = dir.appendingPathComponent("b.idx").path
        let names = ["9833052771": "Asha", "9900011122": "Ben"]
        _ = try VaultIndexer.build(vault: vault, out: a, extraContacts: names)
        _ = try Importer.run(ImportOptions(sourceDB: db, outputDB: b, extraContacts: names))
        let ia = try SQLiteDB(path: a, readOnly: true), ib = try SQLiteDB(path: b, readOnly: true)
        var ra: [String] = [], rb: [String] = []
        let q = "SELECT m.uid, c.jid, m.from_me, m.sender, m.person, m.ts, ifnull(m.text,'~'), ifnull(x.kind,'-'), (SELECT name FROM aliases WHERE alias='555123') FROM messages m JOIN chats c USING(chat_id) LEFT JOIN media x ON x.msg_id=m.id ORDER BY m.ts"
        try ia.query(q) { r in ra.append((0..<9).map { r.text(Int32($0)) ?? "\(r.int(Int32($0)))" }.joined(separator: "|")) }
        try ib.query(q) { r in rb.append((0..<9).map { r.text(Int32($0)) ?? "\(r.int(Int32($0)))" }.joined(separator: "|")) }
        XCTAssertEqual(ra, rb); XCTAssertEqual(ra.count, 4)
    }

    func testNewBackupAddsOnlyDeltaAndFlagsMessagesGoneFromPhone() throws {
        let dir = try tmp()
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let old = try makeDB(dir, "old.db", "INSERT INTO message VALUES (1,10,0,NULL,1000,0,'one','K1'),(2,10,0,NULL,2000,0,'deleted later','K2'),(3,10,0,NULL,3000,0,'three','K3');")
        _ = try vault.ingest(msgstore: old, label: "t")
        // newer backup (different row ids): K2 deleted on the phone, K4 new
        let new = try makeDB(dir, "new.db", "INSERT INTO message VALUES (7,10,0,NULL,1000,0,'one','K1'),(8,10,0,NULL,3000,0,'three','K3'),(9,10,0,NULL,5000,0,'four','K4');")
        let r = try vault.ingest(msgstore: new, label: "t")
        XCTAssertEqual(r.added, 1); XCTAssertEqual(r.skipped, 2); XCTAssertEqual(r.gone, 1)
        let out = dir.appendingPathComponent("i.db").path
        _ = try VaultIndexer.build(vault: vault, out: out)
        let idx = try SQLiteDB(path: out, readOnly: true)
        XCTAssertEqual(try idx.scalarInt("SELECT count(*) FROM messages"), 4)                 // the "deleted" one is kept
        XCTAssertEqual(try idx.scalarInt("SELECT count(*) FROM gone g JOIN messages m USING(uid) WHERE m.text='deleted later'"), 1)
        // a partial import (e.g. a retained file) never flags anything as gone
        let part = try makeDB(dir, "part.db", "INSERT INTO message VALUES (1,10,0,NULL,1500,0,'extra','K9');")
        XCTAssertEqual(try vault.ingest(msgstore: part, label: "t", fullSnapshot: false).gone, 0)
    }
}
