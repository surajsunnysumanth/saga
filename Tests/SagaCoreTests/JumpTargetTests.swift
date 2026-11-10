import XCTest
@testable import SagaCore

/// A stored message identity is not durable: rebuilding the index renumbers row ids and a
/// prune deletes rows, so a story that quotes a message can outlive it. These pin what a jump
/// is allowed to promise — the message, the conversation, or nothing at all.
final class JumpTargetTests: XCTestCase {
    private let t: Int64 = 1_735_689_600_000

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-jump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func index(_ dir: URL) throws -> (SQLiteDB, String) {
        let path = dir.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec(Importer.finish)
        return (db, path)
    }

    /// Two conversations: a DM (chat 5) and a group (chat 6), each with a couple of messages.
    private func seed(_ db: SQLiteDB) throws {
        try db.exec("""
        INSERT INTO chats VALUES(5,'dm',0,'Flat 4B',1,NULL);
        INSERT INTO chats VALUES(6,'group',1,'Sunday Football XI',1,NULL);
        INSERT INTO people VALUES('asha','Asha',1),('ben','Ben',1),('me','me',0);
        INSERT INTO messages VALUES
          (101,5,0,'Asha','asha',\(t),0,'the keys are under the mat','a1'),
          (102,5,1,'me','me',\(t + 60_000),0,'found them','a2'),
          (201,6,0,'Ben','ben',\(t + 120_000),0,'who is bringing the ball','b1'),
          (202,6,0,'Asha','asha',\(t + 180_000),0,'not me','b2');
        """)
    }

    func testAMessageThatIsStillThereResolvesToItself() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)
        let store = try VaultStore(path: path)

        guard case .message(let id, let chatID, let at) = store.jumpTarget(messageID: 102, chatID: 5) else {
            return XCTFail("a message that exists in the asked conversation must resolve to it")
        }
        XCTAssertEqual(id, 102)
        XCTAssertEqual(chatID, 5)
        XCTAssertEqual(at.timeIntervalSince1970, Double(t + 60_000) / 1000, accuracy: 0.001)
    }

    func testAMissingMessageStillOpensItsConversation() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)
        let store = try VaultStore(path: path)

        // A pruned / renumbered id: the chat is here, the message is not.
        XCTAssertEqual(store.jumpTarget(messageID: 987_654_321, chatID: 5), .chat(chatID: 5))
        XCTAssertEqual(store.jumpTarget(messageID: 0, chatID: 5), .chat(chatID: 5))
    }

    func testAMessageBelongingToAnotherConversationNeverJumpsIntoIt() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)
        let store = try VaultStore(path: path)

        // 201 is real, but it lives in the group. A moment that named the DM must not highlight
        // a stranger's message: it opens the DM, with no highlight.
        XCTAssertEqual(store.jumpTarget(messageID: 201, chatID: 5), .chat(chatID: 5))
    }

    func testAnEmptyArchiveHasNowhereToGo() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, path) = try index(dir)
        let store = try VaultStore(path: path)

        XCTAssertEqual(store.jumpTarget(messageID: 101, chatID: 5), .gone)
        XCTAssertEqual(store.jumpTarget(messageID: 0, chatID: 0), .gone)
        XCTAssertFalse(store.chatExists(5))
    }

    // MARK: - The page the highlight lands on

    func testTheLoadedPageAlwaysContainsTheMessageItHighlights() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        // A dense run: 500 messages a second apart. A page loaded from "three hours before"
        // (the old rule) starts 500 rows back, so the message itself fell off the end.
        var sql = """
        INSERT INTO chats VALUES(7,'dm',0,'Long chat',1,NULL);
        INSERT INTO messages VALUES
        """
        sql += (0..<500).map { "(\(1000 + $0),7,0,'Asha','asha',\(t + Int64($0) * 1_000),0,'line \($0)','l\($0)')" }
            .joined(separator: ",\n") + ";"
        try seedDB.exec(sql)
        let store = try VaultStore(path: path)

        let target: Int64 = 1450
        let page = try store.messages(chat: 7, around: target)
        XCTAssertEqual(page.rows.count, 200)
        XCTAssertTrue(page.found, "the page ends at the message, so the highlight is always on screen")
        XCTAssertEqual(page.rows.last?.id, target)
    }

    func testAPageForAMessageThatIsNotHereSaysSo() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)
        let store = try VaultStore(path: path)

        let page = try store.messages(chat: 5, around: 201)   // belongs to chat 6
        XCTAssertFalse(page.found)
        XCTAssertTrue(page.rows.allSatisfy { $0.id != 201 })
    }

    /// The rule that was there before: "load from three hours before the message". In a busy
    /// conversation that is hundreds of rows, so the message itself fell outside the page and
    /// the highlight pointed at nothing. Pinned so the window cannot come back.
    func testAThreeHourWindowIsNotEnoughForADenseConversation() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        var sql = """
        INSERT INTO chats VALUES(9,'dm',0,'Dense',1,NULL);
        INSERT INTO messages VALUES
        """
        sql += (0..<500).map { "(\(2000 + $0),9,0,'Asha','asha',\(t + Int64($0) * 1_000),0,'line \($0)','d\($0)')" }
            .joined(separator: ",\n") + ";"
        try seedDB.exec(sql)
        let store = try VaultStore(path: path)

        let target: Int64 = 2450
        let when = try XCTUnwrap(store.messageDate(id: target))
        let oldWindow = try store.messages(chat: 9, from: when.addingTimeInterval(-3 * 3600))
        XCTAssertFalse(oldWindow.contains { $0.id == target },
                       "three hours back is 500 rows here: the old rule loaded past the message")
        XCTAssertTrue(try store.messages(chat: 9, around: target).found)
    }
}
