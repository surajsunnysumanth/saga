import XCTest
@testable import SagaCore

final class PruneTests: XCTestCase {
    func vaultWithSpam() throws -> (Vault, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net'),(2,'1203630000','g.us',0,0,0,'1203630000@g.us'),
                               (3,'919800000001','s.whatsapp.net',0,0,0,'919800000001@s.whatsapp.net'),(4,'1203630001','g.us',0,0,0,'1203630001@g.us');
        INSERT INTO chat VALUES (10,1,NULL),(11,2,'Promo Group'),(12,4,'Other Group');
        INSERT INTO message VALUES
         (1,11,0,3,1000,0,'BUY NOW great offer click here today','k1'),
         (2,11,0,3,2000,0,'buy now   GREAT offer click here today','k2'),
         (3,11,0,3,3000,0,'https://spam.example/a','k3'),
         (4,11,0,3,4000,1,NULL,'k4'),
         (5,11,0,3,5000,1,NULL,'k5'),
         (6,11,0,3,6000,1,'caption stays','k6'),
         (7,11,1,NULL,7000,0,'my own message','k7'),
         (8,10,0,NULL,8000,0,'hi from a friend','k8'),
         (9,12,0,3,9000,0,'buy now great offer click here today','k9');
        INSERT INTO message_media VALUES (4,11,'image/jpeg','Media/a.jpg',10,'H1',NULL),(5,11,'image/jpeg','Media/b.jpg',10,'H1',NULL),(6,11,'image/jpeg','Media/c.jpg',10,'H2','caption stays');
        """)
        let v = try Vault(url: dir.appendingPathComponent("v"))
        _ = try v.ingest(msgstore: dir.appendingPathComponent("m.db").path, label: "t")
        return (v, dir)
    }
    func count(_ idx: String, _ sql: String) throws -> Int { Int(try SQLiteDB(path: idx, readOnly: true).scalarInt(sql)) }

    func testRulesHideWithoutDeletingAndAreReversible() throws {
        let (v, dir) = try vaultWithSpam(); let idx = dir.appendingPathComponent("i.db").path
        let before = v.segmentFiles().map { try! Data(contentsOf: $0) }
        _ = try VaultIndexer.build(vault: v, out: idx)
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM messages"), 9)

        var r = PruneRule(chat: "1203630000@g.us", label: "Promo Group")
        r.dropDuplicates = true; r.dropLinkOnly = true; r.dropMedia = true
        try PruneConfig.save([r], to: v)
        let s = try VaultIndexer.build(vault: v, out: idx)
        // hidden: dup text (#2), link (#3), media-only (#4, #5); kept: first text, caption (text kept, media dropped), my message, other chats
        XCTAssertEqual(s.prunedMessages, 4)
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM messages WHERE chat_id=(SELECT chat_id FROM chats WHERE jid='1203630000@g.us')"), 3)
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM media m JOIN chats c USING(chat_id) WHERE c.jid='1203630000@g.us'"), 0)
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM messages WHERE text='buy now great offer click here today'"), 1)   // other group untouched
        XCTAssertEqual(v.segmentFiles().map { try! Data(contentsOf: $0) }, before)          // vault itself is unchanged

        try PruneConfig.save([], to: v)                                                      // remove the rule: everything is back
        _ = try VaultIndexer.build(vault: v, out: idx)
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM messages"), 9)
    }

    func testHideChatDropSenderAndMediaDuplicates() throws {
        let (v, dir) = try vaultWithSpam(); let idx = dir.appendingPathComponent("i.db").path
        var hide = PruneRule(chat: "1203630001@g.us", label: "Other Group"); hide.hideChat = true
        var files = PruneRule(chat: "1203630000@g.us", label: "Promo Group"); files.dropDuplicates = true
        try PruneConfig.save([hide, files], to: v)
        _ = try VaultIndexer.build(vault: v, out: idx)
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM chats WHERE jid='1203630001@g.us'"), 0)
        // same file (hash H1) posted twice: second copy hidden; captioned unique file stays
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM media m JOIN chats c USING(chat_id) WHERE c.jid='1203630000@g.us'"), 2)
        let me = try count(idx, "SELECT count(*) FROM messages WHERE from_me=1")
        XCTAssertEqual(me, 1)                                                                // your own messages are never touched by repeat rules
    }

    func testScanSuggestsCleanupForSpammyGroupOnly() throws {
        let (v, dir) = try vaultWithSpam(); let idx = dir.appendingPathComponent("i.db").path
        _ = try VaultIndexer.build(vault: v, out: idx)
        let st = try VaultStore(path: idx)
        let all = try PruneScan.scan(store: st, minMessages: 1)
        let promo = try XCTUnwrap(all.first { $0.name == "Promo Group" })
        XCTAssertGreaterThan(promo.repeatedText, 0); XCTAssertGreaterThan(promo.repeatedFiles, 0)
        XCTAssertNotNil(promo.suggestion)
    }

    func testLinkOnlyDetection() {
        XCTAssertTrue(Pruner.isLinkOnly("https://a.example/x"))
        XCTAssertTrue(Pruner.isLinkOnly("https://a.example/x https://b.example"))
        XCTAssertFalse(Pruner.isLinkOnly("look at https://a.example/x"))
    }
}
