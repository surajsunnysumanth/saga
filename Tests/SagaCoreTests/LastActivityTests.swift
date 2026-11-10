import XCTest
@testable import SagaCore

final class LastActivityTests: XCTestCase {
    func testSystemNoticesDoNotBumpChatsOrChangePreview() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-last-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net'),(2,'919900011122','s.whatsapp.net',0,0,0,'919900011122@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL),(11,2,NULL);
        INSERT INTO message VALUES
          (1,10,0,NULL,1000,0,'old chat, real message','a'),
          (2,10,0,NULL,9000,7,'Your security code with Asha changed. Tap to learn more.','b'),
          (3,11,1,NULL,5000,0,'newer real message','c');
        """)
        let idx = dir.appendingPathComponent("i.db").path
        _ = try Importer.run(ImportOptions(sourceDB: dir.appendingPathComponent("m.db").path, outputDB: idx))
        let st = try VaultStore(path: idx)
        XCTAssertTrue(st.hasLastRealCol)
        let rows = try st.chats(sort: .recent, minMessages: 1)
        XCTAssertEqual(rows.map(\.count), [1, 2])          // newer real message first
        // the chat with the newer *real* message comes first, even though the other one has a later system notice
        XCTAssertGreaterThan(rows[0].last, rows[1].last)
        // preview shows the last real message, not the security notice
        XCTAssertFalse(rows[1].preview.contains("security code"))
        XCTAssertTrue(rows[1].preview.contains("old chat"))
        // the notice is still stored and still reachable
        XCTAssertEqual(try SQLiteDB(path: idx, readOnly: true).scalarInt("SELECT count(*) FROM messages WHERE type=7"), 1)
    }
}
