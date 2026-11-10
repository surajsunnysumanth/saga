import XCTest
@testable import SagaCore

final class WrappedReactionTests: XCTestCase {
    func testQuotesSurviveIngestReindexAndOldSegmentEnrichment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reaction-ingest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.db").path
        let src = try SQLiteDB(path: source, readOnly: false)
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INT, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES(1,'10000000001','s.whatsapp.net','10000000001@s.whatsapp.net');
        INSERT INTO chat VALUES(1,1,NULL);
        INSERT INTO message VALUES(1,1,1,NULL,1700000000000,0,'original story','A'),(2,1,0,1,1700000001000,0,'hahahahaha','B');
        """)
        let vault = try Vault(url: dir.appendingPathComponent("vault"))
        _ = try vault.ingest(msgstore: source, label: "old", fullSnapshot: false)
        try src.exec("""
        CREATE TABLE message_quoted(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, parent_message_chat_row_id INT, from_me INT, key_id TEXT);
        INSERT INTO message_quoted VALUES(2,1,1,1,'A');
        """)
        let enriched = try vault.ingest(msgstore: source, label: "quotes", fullSnapshot: false)
        XCTAssertEqual(enriched.added, 0)
        XCTAssertNotNil(enriched.segment)
        let idx = dir.appendingPathComponent("index.db").path
        _ = try VaultIndexer.build(vault: vault, out: idx)
        let db = try SQLiteDB(path: idx, readOnly: true)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM message_replies r JOIN messages m ON m.uid=r.uid JOIN messages t ON t.uid=r.target_uid WHERE m.id<>t.id"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM messages"), 2)
        let direct = dir.appendingPathComponent("direct.db").path
        _ = try Importer.run(ImportOptions(sourceDB: source, outputDB: direct))
        XCTAssertEqual(try SQLiteDB(path: direct, readOnly: true).scalarInt("SELECT count(*) FROM message_replies"), 1)
        XCTAssertNil(try vault.ingest(msgstore: source, label: "again", fullSnapshot: false).segment)
    }

    func testQuotedRepliesOverrideProximityAndTimeWindow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS message_replies(uid TEXT PRIMARY KEY, target_uid TEXT NOT NULL);
        INSERT INTO chats VALUES(1,'test',0,'Friend',1,'friend');
        INSERT INTO messages VALUES
          (1,1,1,'me','me',1700000000000,0,'the original funny story','a'),
          (2,1,1,'me','me',1700000001000,0,'an unrelated nearby story','b'),
          (3,1,0,'Friend','friend',1700000002000,0,'hahahahaha','c'),
          (4,1,1,'me','me',1700000010000,0,'https://youtu.be/dQw4w9WgXcQ','d'),
          (5,1,1,'me','me',1700000020000,0,'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC','e'),
          (6,1,0,'Friend','friend',1700086400000,0,'soooo gooood','f');
        INSERT INTO message_replies VALUES('c','a'),('f','d');
        """)
        let w = try await DuoWrappedBuilder.build(store: VaultStore(path: path), chatID: 1, me: "Me", fetchTitles: false)
        XCTAssertEqual(w.madeThemLaugh, 1)
        XCTAssertEqual(w.funniest.map(\.messageID), [1])
        XCTAssertEqual(w.tracks.first?.landed, 1)
        XCTAssertEqual(w.tracks.last?.landed, 0)
        XCTAssertEqual(w.total, 6)
        // Missing target must not redirect an explicit reply to the adjacent story.
        try db.exec("UPDATE message_replies SET target_uid='missing' WHERE uid='c'")
        let missing = try await DuoWrappedBuilder.build(store: VaultStore(path: path), chatID: 1, me: "Me", fetchTitles: false)
        XCTAssertEqual(missing.madeThemLaugh, 0)
    }

    func testLikingAndConfiguration() {
        let detector = WrappedReactionDetector()
        for line in ["soooo gooood", "LOVEeee", "mast hai", "zabardast", "बहुत बढ़िया", "❤️🔥"] { XCTAssertTrue(detector.likes(line), line) }
        for line in ["nice", "don't love this", "not amazing 🔥", "mast nahi", "perfect /s", "best #sarcasm", "https://example.test/love", "> love this\nokay", "firewall"] { XCTAssertFalse(detector.likes(line), line) }
        var config = WrappedReactionConfiguration()
        config.languages = []; config.emojiEnabled = false
        config.additionalLaughPhrases = ["tee hee", "[fun]"]
        config.additionalLikePhrases = ["chef kiss"]
        config.excludedPhrases = ["only kidding"]
        let custom = WrappedReactionDetector(configuration: config)
        XCTAssertEqual(custom.laughScore("haha 😂"), 0)
        XCTAssertGreaterThan(custom.laughScore("tee hee"), 0)
        XCTAssertGreaterThan(custom.laughScore("[fun]"), 0)
        XCTAssertEqual(custom.laughScore("fun"), 0)
        XCTAssertTrue(custom.likes("chef kiss"))
        XCTAssertFalse(custom.likes("chef kiss only kidding"))
        XCTAssertFalse(custom.likes("love ❤️"))
    }

    func testSyntheticLanguageCorpus() {
        let detector = WrappedReactionDetector()
        for line in ["hahahahaha", "HAAAHAAA", "loooool", "😂🤣", "hasi aa gayi", "हाहाहा"] {
            XCTAssertGreaterThan(detector.laughScore(line), 0, line)
        }
        for line in ["challenge", "Shall we go", "https://example.test/hahaha", "lol /s", "haha #sarcasm", "not funny 😂"] {
            XCTAssertEqual(detector.laughScore(line), 0, line)
        }
        XCTAssertGreaterThan(detector.laughScore("hahahahaha"), detector.laughScore("lol"))
        XCTAssertEqual(detector.laughScore(String(repeating: "😂", count: 30)), 6)
    }
}
