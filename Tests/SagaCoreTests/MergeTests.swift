import XCTest
@testable import SagaCore

final class MergeTests: XCTestCase {
    func vault() throws -> (Vault, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net'),(2,'971501234567','s.whatsapp.net',0,0,0,'971501234567@s.whatsapp.net'),
          (3,'1203630000','g.us',0,0,0,'1203630000@g.us'),(4,'919800000009','s.whatsapp.net',0,0,0,'919800000009@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL),(11,2,NULL),(12,3,'Club'),(13,4,NULL);
        INSERT INTO message VALUES (1,10,0,NULL,1000,0,'old number hi','a'),(2,11,0,NULL,5000,0,'new number hi','b'),(3,12,0,2,6000,0,'in the group','c'),(4,13,0,NULL,7000,0,'someone else','d');
        """)
        let v = try Vault(url: dir.appendingPathComponent("v")); _ = try v.ingest(msgstore: dir.appendingPathComponent("m.db").path, label: "t")
        return (v, dir)
    }
    func testMergeJoinsChatsAndPeopleAndIsReversible() throws {
        let (v, dir) = try vault(); let idx = dir.appendingPathComponent("i.db").path
        let names = ["9833052771": "Asha", "1501234567": "Asha"]
        _ = try VaultIndexer.build(vault: v, out: idx, extraContacts: names)
        let st = try VaultStore(path: idx)
        XCTAssertEqual(try st.mergeSuggestions().count, 1)                                  // same name, two numbers
        XCTAssertEqual(try st.mergeSuggestions().first?.people.count, 2)
        XCTAssertEqual(try SQLiteDB(path: idx, readOnly: true).scalarInt("SELECT count(*) FROM chats WHERE is_group=0"), 3)

        try MergeConfig.add(keys: ["9833052771", "1501234567"], name: "Asha", to: v)       // second key: last 10 digits of the +971 number
        _ = try VaultIndexer.build(vault: v, out: idx, extraContacts: names)
        let q = try SQLiteDB(path: idx, readOnly: true)
        XCTAssertEqual(try q.scalarInt("SELECT count(*) FROM chats WHERE is_group=0"), 2)    // the two Asha chats became one
        XCTAssertEqual(try q.scalarInt("SELECT count(*) FROM messages m JOIN chats c USING(chat_id) WHERE c.name='Asha'"), 2)
        XCTAssertEqual(try q.scalarInt("SELECT count(DISTINCT person) FROM messages WHERE text IN ('old number hi','new number hi','in the group')"), 1)
        XCTAssertEqual(try VaultStore(path: idx).mergeSuggestions().count, 0)

        try MergeConfig.remove(MergeConfig.load(v)[0], from: v)                              // undo
        _ = try VaultIndexer.build(vault: v, out: idx, extraContacts: names)
        XCTAssertEqual(try SQLiteDB(path: idx, readOnly: true).scalarInt("SELECT count(*) FROM chats WHERE is_group=0"), 3)
    }
    func testAddFoldsOverlappingGroups() throws {
        let (v, _) = try vault()
        try MergeConfig.add(keys: ["a", "b"], name: "X", to: v); try MergeConfig.add(keys: ["b", "c"], name: "X", to: v)
        XCTAssertEqual(MergeConfig.load(v).count, 1); XCTAssertEqual(Set(MergeConfig.load(v)[0].keys), ["a", "b", "c"])
    }
}
