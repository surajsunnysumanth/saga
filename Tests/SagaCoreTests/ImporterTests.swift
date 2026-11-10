import XCTest
@testable import SagaCore

final class ImporterTests: XCTestCase {
    func testNamesLidMappingAndMediaMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("msgstore.db").path, out = dir.appendingPathComponent("idx.db").path
        let db = try SQLiteDB(path: src, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE jid_map(lid_row_id INTEGER PRIMARY KEY, jid_row_id INT, sort_id INT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER PRIMARY KEY, display_name TEXT, username TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net'),
                               (2,'1203630000','g.us',0,0,0,'1203630000@g.us'),
                               (3,'55512345678','lid',0,0,0,'55512345678@lid'),
                               (4,'919900011122','s.whatsapp.net',0,0,0,'919900011122@s.whatsapp.net');
        INSERT INTO jid_map VALUES (3,4,0);
        INSERT INTO chat VALUES (10,1,NULL),(11,2,'Friends');
        INSERT INTO message VALUES (100,10,0,NULL,1700000000000,0,'hi','a'),
                                   (101,11,0,3,1700000001000,0,'hello group','b'),
                                   (102,11,1,NULL,1700000002000,0,'me here','c'),
                                   (103,11,0,3,1700000003000,1,'with'||char(0)||'nul','d'),
                                   (104,11,0,3,1700000004000,0,'yo @55512345678 look','e');
        INSERT INTO message_media VALUES (103,11,'image/jpeg','Media/WhatsApp Images/IMG-1.jpg',10,'h','cap');
        """)
        let s = try Importer.run(ImportOptions(sourceDB: src, outputDB: out, extraContacts: ["9833052771": "Asha", "9900011122": "Ben"]))
        XCTAssertEqual(s.messages, 5); XCTAssertEqual(s.chats, 2)
        let idx = try SQLiteDB(path: out, readOnly: true)
        var senders: [Int64: String] = [:]
        try idx.query("SELECT id, sender FROM messages") { senders[$0.int(0)] = $0.text(1) }
        XCTAssertEqual(senders[100], "Asha")      // DM: other party from contacts
        XCTAssertEqual(senders[101], "Ben")       // LID -> phone via jid_map -> contacts
        XCTAssertEqual(senders[102], "me")
        var text103 = ""; try idx.query("SELECT text FROM messages WHERE id=103") { text103 = $0.text(0) ?? "" }
        XCTAssertEqual(text103.utf8.count, 8)  // 'with' + NUL + 'nul'     // embedded NUL preserved
        var kind = ""; try idx.query("SELECT kind FROM media") { kind = $0.text(0) ?? "" }
        XCTAssertEqual(kind, "image")
        XCTAssertEqual(try idx.scalarInt("SELECT count(*) FROM msg_fts WHERE msg_fts MATCH 'hello'"), 1)
        let store = try VaultStore(path: out)
        XCTAssertTrue(try store.messages(chat: 11).contains { $0.text == "yo @Ben look" })   // @mention resolved via aliases
        XCTAssertEqual(try store.people(namedOnly: true).map(\.name).sorted(), ["Asha", "Ben"])
        XCTAssertEqual(try store.wrapped(year: "2023").total, 5)
    }
    func testKeychainRoundTrip() {
        Keychain.save("abc", account: "saga-test"); XCTAssertEqual(Keychain.load(account: "saga-test"), "abc")
        Keychain.delete(account: "saga-test"); XCTAssertNil(Keychain.load(account: "saga-test"))
    }

    func testMergeRecoversMessagesMissingFromNewerBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ name: String, _ rows: String) throws -> String {
            let path = dir.appendingPathComponent(name).path
            let db = try SQLiteDB(path: path, readOnly: false)
            try db.exec("""
            CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
            CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
            CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
            CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
            INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
            INSERT INTO chat VALUES (5,1,NULL);
            \(rows)
            """)
            return path
        }
        // older backup has K1,K2 (K2 later deleted on phone); newer has K1,K3 with *different* row ids
        let old = try make("old.db", "INSERT INTO message VALUES (1,5,0,NULL,1000,0,'one','K1'),(2,5,0,NULL,2000,0,'deleted later','K2');")
        let new = try make("new.db", "INSERT INTO message VALUES (7,5,0,NULL,1000,0,'one','K1'),(8,5,1,NULL,3000,0,'newest','K3');")
        let out = dir.appendingPathComponent("idx.db").path
        let s = try Importer.run(ImportOptions(sourceDB: new, outputDB: out, additionalSources: [old]))
        XCTAssertEqual(s.mergedMessages, 1); XCTAssertEqual(s.messages, 3)
        let idx = try SQLiteDB(path: out, readOnly: true)
        var texts: [String] = []; try idx.query("SELECT text FROM messages ORDER BY ts") { texts.append($0.text(0) ?? "") }
        XCTAssertEqual(texts, ["one", "deleted later", "newest"])
        XCTAssertEqual(try idx.scalarInt("SELECT count(*) FROM chats"), 1)
    }
}
