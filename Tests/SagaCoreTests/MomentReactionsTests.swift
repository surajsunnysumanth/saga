import XCTest
@testable import SagaCore

/// What the moments card prints beside a message: how many *people* reacted, the emoji split,
/// and the replies that quoted it. Pinned here because the three stories share one loader and
/// the number beside a message is a claim about other people, not a row count.
final class MomentReactionsTests: XCTestCase {
    private let t: Int64 = 1_735_689_600_000          // 2025-01-01

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-moment-\(UUID().uuidString)")
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

    /// One group chat, four messages, a laugh on two of them, hearts on one, a self-reaction
    /// that must not count, one thumbs-up that is in neither family, and two replies that
    /// quote the busiest message.
    private func seed(_ db: SQLiteDB) throws {
        try db.exec("""
        INSERT INTO chats VALUES(3,'group',1,'Quiz club',1,NULL);
        INSERT INTO people VALUES('asha','Asha',1),('ben','Ben',1),('chitra','Chitra',1),('me','me',0);
        INSERT INTO messages VALUES
          (21,3,0,'Asha','asha',\(t),0,'I once got the wrong bus and ended up in another state','g1'),
          (22,3,0,'Ben','ben',\(t + 60_000),0,'the printer is out of paper again','g2'),
          (23,3,1,'me','me',\(t + 120_000),0,'that is a personality','g3'),
          (24,3,0,'Chitra','chitra',\(t + 180_000),0,'an ordinary line','g4');
        INSERT INTO reactions VALUES
          (21,3,'ben','Ben','😂',\(t + 10)),
          (21,3,'chitra','Chitra','😂',\(t + 11)),
          (21,3,'me','me','❤️',\(t + 12)),
          (21,3,'asha','Asha','😂',\(t + 13)),                 -- the author's own tap: not counted
          (22,3,'asha','Asha','👍',\(t + 60_010));             -- in neither family
        INSERT INTO message_replies VALUES
          ('g2','g1'),                                          -- Ben quoted Asha
          ('g3','g1'),                                          -- the owner quoted Asha too
          ('g4','g2');
        """)
    }

    private func load(_ path: String, _ targets: [MomentReactionsLoader.Target]) throws -> [Int64: MomentReactions] {
        let store = try VaultStore(path: path)
        return MomentReactionsLoader.load(store: store, chatID: 3, targets: targets)
    }

    func testCountsDistinctPeopleAndSkipsTheAuthorsOwnTap() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)

        let out = try load(path, [.init(id: 21, uid: "g1", author: "asha")])
        let m = try XCTUnwrap(out[21])
        XCTAssertEqual(m.reactors, 3, "Ben, Chitra and the owner reacted; Asha tapping her own line does not count")
        XCTAssertEqual(m.label, "3 reacts")
        XCTAssertEqual(m.summary, "😂 2  ❤️ 1")
        XCTAssertEqual(m.emoji.first?.emoji, "😂")
        XCTAssertEqual(m.emoji.first?.count, 2)
    }

    func testOneReactorReadsAsASingleReact() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)

        // A message with exactly one outside reaction, so the label's plural is exercised.
        try seedDB.exec("INSERT INTO reactions VALUES (23,3,'asha','Asha','😂',\(t + 120_010));")
        let m = try XCTUnwrap(try load(path, [.init(id: 23, uid: "g3", author: "me")])[23])
        XCTAssertEqual(m.reactors, 1)
        XCTAssertEqual(m.label, "1 react")
        XCTAssertEqual(m.summary, "😂 1")
    }

    func testQuotedRepliesAreFoundByUidOldestFirstOnePerPerson() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)

        let m = try XCTUnwrap(try load(path, [.init(id: 21, uid: "g1", author: "asha")])[21])
        XCTAssertEqual(m.quoted.map(\.author), ["Ben", "You"], "two replies quote g1, in time order")
        XCTAssertEqual(m.quoted.first?.fromMe, false)
        XCTAssertEqual(m.quoted.last?.fromMe, true)
        XCTAssertTrue(m.quoted.first?.text.contains("printer") ?? false)
    }

    func testTheReplyThatEarnedTheMomentLeadsAndIsNotRepeated() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)

        let m = try XCTUnwrap(try load(path, [.init(id: 21, uid: "g1", author: "asha")])[21])
        let lead = QuotedReply(uid: "lead", author: "Ben", text: "the printer is out of paper again", fromMe: false)
        let stack = MomentReactions.stack(lead: lead, others: m.quoted)
        XCTAssertEqual(stack.count, 2, "the lead and one other; the quoted copy of the same line is dropped")
        XCTAssertEqual(stack.first?.uid, "lead")
        XCTAssertFalse(stack.dropFirst().contains { $0.text == lead.text })
    }

    func testAMessageWithNothingCollectedCarriesNoLabel() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seedDB, path) = try index(dir)
        try seed(seedDB)

        let m = try XCTUnwrap(try load(path, [.init(id: 24, uid: "g4", author: "chitra")])[24])
        XCTAssertEqual(m.reactors, 0)
        XCTAssertEqual(m.label, "", "a moment nobody reacted to prints no count at all")
        XCTAssertEqual(m.summary, "")
    }

    func testAnEmptyArchiveAnswersWithNothingRatherThanFailing() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, path) = try index(dir)

        let out = try load(path, [.init(id: 999, uid: "nope", author: "asha")])
        XCTAssertEqual(out[999]?.reactors, 0)
        XCTAssertEqual(out[999]?.quoted.isEmpty, true)
        XCTAssertEqual(out[999]?.label, "")
    }
}
