import XCTest
@testable import SagaCore

/// Laughter is not only what people type. A 😂 tapped on a message is a laugh at that message,
/// and the archive now records it — never as a laugh at the reactor's own words, and never a 👍.
final class ReactionLaughsTests: XCTestCase {

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-reactions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A minimal decrypted msgstore. Three people in one group; `reactionSQL` is inserted verbatim,
    /// and `withReactionTables: false` models an older backup that never recorded reactions.
    @discardableResult
    private func source(_ dir: URL, withReactionTables: Bool = true, reactionSQL: String = "") throws -> String {
        let path = dir.appendingPathComponent("msgstore.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'1203630000','g.us',0,0,0,'1203630000@g.us'),
                               (2,'5550000001','s.whatsapp.net',0,0,0,'5550000001@s.whatsapp.net'),
                               (3,'5550000002','s.whatsapp.net',0,0,0,'5550000002@s.whatsapp.net'),
                               (4,'5550000003','s.whatsapp.net',0,0,0,'5550000003@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,'Quiz club');
        INSERT INTO message VALUES
          (100,10,0,2,1700000000000,0,'I once got the wrong bus and ended up in another state','k1'),
          (101,10,0,3,1700100000000,0,'the printer is out of paper again','k2'),
          (102,10,1,NULL,1700200000000,0,'I will bring the spare one','k3'),
          (103,10,0,4,1700300000000,0,'someone moved my chair and I said nothing for three days','k4');
        """)
        if withReactionTables {
            try db.exec("""
            CREATE TABLE message_add_on(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, key_id TEXT,
                                        sender_jid_row_id INT, parent_message_row_id INT, timestamp INT,
                                        status INT, message_add_on_type INT);
            CREATE TABLE message_add_on_reaction(message_add_on_row_id INTEGER PRIMARY KEY, reaction TEXT, sender_timestamp INT);
            """)
            if !reactionSQL.isEmpty { try db.exec(reactionSQL) }
        }
        return path
    }

    private func index(_ dir: URL, _ source: String) throws -> (VaultStore, ImportSummary, String) {
        let out = dir.appendingPathComponent("index.db").path
        let summary = try Importer.run(ImportOptions(sourceDB: source, outputDB: out,
                                                     extraContacts: ["5550000001": "Asha", "5550000002": "Ben",
                                                                     "5550000003": "Chitra"]))
        return (try VaultStore(path: out), summary, out)
    }

    // MARK: - Import

    func testReactionRowsAreImportedWithTheReactorAndTheMessage() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Asha wrote 100; Ben, Chitra and the owner each tap an emoji on it.
        let sql = """
        INSERT INTO message_add_on VALUES
          (1,10,0,'a1',3,100,1700000060000,0,56),
          (2,10,0,'a2',4,100,1700000070000,0,56),
          (3,10,0,'a3',2,100,1700000080000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000060000),(2,'👍',1700000070000),(3,'😂',1700000080000);
        """
        let (store, summary, indexPath) = try index(dir, try source(dir, reactionSQL: sql))
        XCTAssertEqual(summary.reactions, 3)
        let byMessage = try MessageReactions.load(store.db)
        let rows = try XCTUnwrap(byMessage[100])
        XCTAssertEqual(rows.count, 3)
        // The reactor is the person who tapped the emoji, not the message author (Asha wrote 100).
        XCTAssertEqual(Set(rows.map(\.sender)), ["5550000001", "5550000002", "5550000003"])
        XCTAssertEqual(Set(rows.map(\.senderName)), ["Asha", "Ben", "Chitra"])
        XCTAssertEqual(rows.filter(\.isLaugh).count, 2)
    }

    func testChangedReactionIsStoredOnceAndReimportDoesNotDoubleCount() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Same person, same message: an old 😂 replaced by ❤️. WhatsApp keeps both history rows.
        let sql = """
        INSERT INTO message_add_on VALUES
          (1,10,0,'a1',3,100,1700000060000,0,56),
          (2,10,0,'a2',3,100,1700000090000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000060000),(2,'❤️',1700000090000);
        """
        let (store, summary, indexPath) = try index(dir, try source(dir, reactionSQL: sql))
        XCTAssertEqual(summary.reactions, 1)
        let rows = try XCTUnwrap(try MessageReactions.load(store.db)[100])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.emoji, "❤️")

        // Importing the same rows again is an upsert, not a second laugh.
        let writable = try SQLiteDB(path: indexPath, readOnly: false)
        try MessageReactions.insert(try MessageReactions.load(store.db).values.flatMap { $0 }, into: writable)
        XCTAssertEqual(try MessageReactions.load(writable)[100]?.count, 1)
    }

    func testArchiveWithoutReactionTablesStillImportsCleanly() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, summary, indexPath) = try index(dir, try source(dir, withReactionTables: false))
        XCTAssertEqual(summary.reactions, 0)
        XCTAssertEqual(try MessageReactions.load(store.db).count, 0)
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM messages"), 4)
        // A table exists, so every query path stays valid; it is simply empty.
        XCTAssertEqual(try store.db.scalarInt("SELECT count(*) FROM reactions"), 0)
    }

    // MARK: - Counting

    func testThreeLaughReactionsMakeAMessageFunnyWithoutAnyReply() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sql = """
        INSERT INTO message_add_on VALUES
          (1,10,0,'a1',3,100,1700000060000,0,56),
          (2,10,0,'a2',4,100,1700000070000,0,56),
          (3,10,1,'a3',NULL,100,1700000080000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000060000),(2,'😂',1700000070000),(3,'😂',1700000080000);
        """
        let (store, _, _) = try index(dir, try source(dir, reactionSQL: sql))
        let w = try await GroupWrappedBuilder.build(store: store, chatID: 10, me: "Sam", fetchTitles: false)
        XCTAssertEqual(w.laughsByReaction, 1)
        let asha = try XCTUnwrap(w.funniest.first { $0.name == "Asha" })
        XCTAssertGreaterThanOrEqual(asha.laughsEarned, 1)
        XCTAssertEqual(asha.messages, 1)             // denominator is messages written, unchanged by reactions
        XCTAssertEqual(asha.rate, Double(asha.laughsEarned), accuracy: 0.0001)
        // The card names the message that carried the joke, not the reaction.
        XCTAssertTrue(w.moments.contains { $0.messageID == 100 && $0.reply.contains("😂") })
    }

    func testThumbsUpAndSelfReactionsAreNotLaughs() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 👍 and 👍🏽 by others, plus Ben tapping 😂 on his own message — none is a laugh from someone else.
        let sql = """
        INSERT INTO message_add_on VALUES
          (1,10,0,'a1',2,101,1700100060000,0,56),
          (2,10,0,'a2',4,101,1700100070000,0,56),
          (3,10,0,'a3',3,101,1700100080000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'👍',1700100060000),(2,'👍🏽',1700100070000),(3,'😂',1700100080000);
        """
        let (store, _, _) = try index(dir, try source(dir, reactionSQL: sql))
        let w = try await GroupWrappedBuilder.build(store: store, chatID: 10, me: "Sam", fetchTitles: false)
        XCTAssertEqual(w.laughsByReaction, 0)
        XCTAssertTrue(w.funniest.isEmpty)
        // And a 👍 does not leak into the detector's text vocabulary either.
        XCTAssertEqual(WrappedReactionDetector().laughScore("👍🏽"), 0)
    }

    func testLaughFamilyNormalisesVariationSelectors() {
        XCTAssertTrue(WrappedReactionDetector.isLaughEmoji("😂"))
        XCTAssertTrue(WrappedReactionDetector.isLaughEmoji("💀"))
        XCTAssertTrue(WrappedReactionDetector.isLaughEmoji("☠️"))       // skull and crossbones + selector
        XCTAssertTrue(WrappedReactionDetector.isLaughEmoji("🥹"))
        XCTAssertFalse(WrappedReactionDetector.isLaughEmoji("👍"))
        XCTAssertFalse(WrappedReactionDetector.isLaughEmoji("👍🏿"))
        XCTAssertFalse(WrappedReactionDetector.isLaughEmoji("❤️"))
    }

    func testDuoCreditsTheReactionToThePersonWhoGaveIt() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A one-to-one chat: Ben says something ordinary, the owner reacts 😂 to it, and the
        // owner's later message gets 👍 — which must not become a laugh for Ben.
        let path = dir.appendingPathComponent("dm.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        CREATE TABLE message_add_on(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, key_id TEXT,
                                    sender_jid_row_id INT, parent_message_row_id INT, timestamp INT, status INT, message_add_on_type INT);
        CREATE TABLE message_add_on_reaction(message_add_on_row_id INTEGER PRIMARY KEY, reaction TEXT, sender_timestamp INT);
        INSERT INTO jid VALUES (1,'5550000001','s.whatsapp.net',0,0,0,'5550000001@s.whatsapp.net');
        INSERT INTO chat VALUES (20,1,NULL);
        INSERT INTO message VALUES
          (1,20,0,1,1700000000000,0,'I have been carrying this umbrella for six months and it has not rained once','k1'),
          (2,20,1,NULL,1700003600000,0,'that umbrella is a personality now','k2');
        INSERT INTO message_add_on VALUES (1,20,1,'r1',NULL,1,1700000100000,0,56),
                                          (2,20,0,'r2',1,2,1700003700000,0,56);
        INSERT INTO message_add_on_reaction VALUES (1,'😂',1700000100000),(2,'👍',1700003700000);
        """)
        let (store, summary, indexPath) = try index(dir, path)
        XCTAssertEqual(summary.reactions, 2)
        var chatID: Int64 = 0
        try store.db.query("SELECT chat_id FROM chats") { chatID = $0.int(0) }
        let w = try await DuoWrappedBuilder.build(store: store, chatID: chatID, me: "Sam", fetchTitles: false)
        XCTAssertEqual(w.laughsByReaction, 1)
        // The owner reacted to Ben's message, so it is the owner who laughed, not Ben.
        XCTAssertEqual(w.madeMeLaugh, 1)
        XCTAssertEqual(w.madeThemLaugh, 0, "the 👍 on the owner's own message is not laughter")
    }

    // MARK: - Copy

    func testYearCopyStopsCallingEveryLaughAReply() {
        XCTAssertEqual(WrappedCopy.yearLaughs(count: 243), "243 messages earned a proper laugh out loud.")
        XCTAssertEqual(WrappedCopy.yearLaughs(count: 1), "One message earned a proper laugh out loud.")
        XCTAssertEqual(WrappedCopy.yearLaughs(count: 0), "No laugh came back this year. Very serious correspondence.")
    }
}
