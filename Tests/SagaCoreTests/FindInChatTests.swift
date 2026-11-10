import XCTest
@testable import SagaCore

/// The find bar asks a different question from the archive search: one conversation, and a
/// half-typed word that still matches. These pin the two behaviours the bar depends on.
final class FindInChatTests: XCTestCase {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("saga-find-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }

    func makeDB(_ dir: URL, _ name: String, _ rows: String) throws -> String {
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
                               (2,'1203630000','g.us',0,0,0,'1203630000@g.us');
        INSERT INTO chat VALUES (10,1,NULL),(11,2,'Friends');
        \(rows)
        """)
        return path
    }

    /// Index two chats where the same word appears in both. `dm` is the one-to-one chat.
    func index() throws -> (store: VaultStore, dm: Int64, group: Int64) {
        let dir = try tmp()
        let rows = """
        INSERT INTO message VALUES
            (1,10,0,NULL,1000,0,'first goa plan','a'),
            (2,10,1,NULL,2000,0,'goa in December','b'),
            (3,11,0,NULL,3000,0,'goa with the group','c'),
            (4,10,0,NULL,4000,0,'unrelated note','d'),
            (5,10,0,NULL,5000,0,'last goa message','e');
        """
        let db = try makeDB(dir, "m.db", rows)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: db, label: "t")
        let out = dir.appendingPathComponent("index.db").path
        _ = try VaultIndexer.build(vault: vault, out: out)
        let store = try VaultStore(path: out)
        let chats = try store.chats(limit: 20)
        let dm = try XCTUnwrap(chats.first { !$0.isGroup }?.id)
        let group = try XCTUnwrap(chats.first { $0.isGroup }?.id)
        return (store, dm, group)
    }

    func testFindStaysInsideTheConversation() throws {
        let (store, dm, group) = try index()
        let hits = try store.find("goa", in: dm)
        XCTAssertEqual(hits.count, 3, "only the three matches in the one-to-one chat")
        XCTAssertTrue(hits.allSatisfy { $0.chatID == dm })
        XCTAssertEqual(try store.find("goa", in: group).count, 1, "the group has its own one")
    }

    func testFindIsOldestFirstSoTheNumberMatchesTheTranscript() throws {
        let (store, dm, _) = try index()
        let hits = try store.find("goa", in: dm)
        XCTAssertEqual(hits.map(\.ts), hits.map(\.ts).sorted(), "matches are in document order")
        XCTAssertEqual(hits.first?.snippet.contains("first"), true)
        XCTAssertEqual(hits.last?.snippet.contains("last"), true)
    }

    func testFindMatchesAHalfTypedWord() throws {
        let (store, dm, _) = try index()
        XCTAssertEqual(try store.find("go", in: dm).count, 3, "a prefix must match as you type")
        XCTAssertEqual(try store.find("goa dec", in: dm).count, 1, "the last word is the prefix")
    }

    func testFindSurvivesThePunctuationPeopleActuallyType() throws {
        let (store, dm, _) = try index()
        // None of these is a syntax error, and none of them silently returns everything.
        XCTAssertEqual(try store.find("\"", in: dm).count, 0)
        XCTAssertEqual(try store.find("goa \"", in: dm).count, 3)
        XCTAssertEqual(try store.find("goa AND", in: dm).count, 0, "operators are words, not syntax, in a find bar")
        XCTAssertEqual(try store.find("-goa", in: dm).count, 3)
        XCTAssertEqual(try store.find("   ", in: dm).count, 0)
    }

    func testFindHonoursItsCap() throws {
        let (store, dm, _) = try index()
        XCTAssertEqual(try store.find("goa", in: dm, limit: 2).count, 2, "the bar labels a capped count n+")
    }

    func testFindQueryQuotesEveryWord() {
        XCTAssertEqual(VaultStore.findQuery("goa trip"), "\"goa\" \"trip\"*")
        XCTAssertEqual(VaultStore.findQuery("  hello "), "\"hello\"*")
        XCTAssertEqual(VaultStore.findQuery("\""), "")
        XCTAssertEqual(VaultStore.findQuery("---"), "")
    }
}
