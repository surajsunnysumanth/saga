import XCTest
@testable import SagaCore

/// A heart is affection, not a punchline. These pin the separation: one vocabulary for each
/// family, one message counted once per family, and never a heart added to a laugh count.
final class HeartReactionTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-hearts-\(UUID().uuidString)")
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

    // MARK: - Vocabulary

    func testHeartFamilyNormalisesVariationSelectorsAndExcludesLaughs() {
        let detector = WrappedReactionDetector.self
        for emoji in ["❤️", "❤", "😍", "🥰", "😘", "💕", "💖", "💗"] {
            XCTAssertTrue(detector.isHeartEmoji(emoji), emoji)
        }
        for emoji in ["👍", "👍🏽", "😂", "🤣", "😆", "💀", "☠️", "🥹", "🔥", "🙏"] {
            XCTAssertFalse(detector.isHeartEmoji(emoji), emoji)
        }
        // The other direction matters too: a heart is never a laugh.
        for emoji in ["❤️", "❤", "😍", "🥰"] { XCTAssertFalse(detector.isLaughEmoji(emoji), emoji) }
        XCTAssertEqual(WrappedReactionDetector.normalizedEmoji("❤️"), "❤")
    }

    // MARK: - Year attribution

    func testYearCountsHeartsAndLaughsSeparately() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seed, indexPath) = try index(dir)
        let t: Int64 = 1_735_689_600_000                     // 2025-01-01
        try seed.exec("""
        INSERT INTO chats VALUES(1,'chat',0,'Alex',1,'alex');
        INSERT INTO people VALUES('alex','Alex',1),('sam','Sam',1),('me','me',0);
        INSERT INTO messages VALUES
          (1,1,0,'Alex','alex',\(t),0,'the printer story','u1'),
          (2,1,1,'me','me',\(t + 1000),0,'my own line','u2'),
          (3,1,0,'Alex','alex',\(t + 2000),0,'a joke about the bus','u3'),
          (4,1,0,'Sam','sam',\(t + 3000),0,'an ordinary line','u4');
        INSERT INTO reactions VALUES
          (1,1,'sam','Sam','❤️',\(t + 10)),
          (1,1,'me','me','❤',\(t + 11)),                     -- the owner's heart counts, once
          (2,1,'alex','Alex','😍',\(t + 1010)),
          (2,1,'me','me','❤️',\(t + 1011)),                    -- self-reaction: ignored
          (3,1,'sam','Sam','😂',\(t + 2010)),
          (3,1,'alex','Alex','🤣',\(t + 2011)),                -- the author's own laugh: ignored
          (4,1,'alex','Alex','👍',\(t + 3010));                 -- not a heart
        """)
        let w = try await YearWrappedBuilder.build(store: try VaultStore(path: indexPath), year: "2025")
        XCTAssertEqual(w.hearts, 2, "message 1 (two hearts, one reactor is the owner) and message 2 (a heart from Alex)")
        XCTAssertEqual(w.laughs, 1, "only message 3 earned an outside laugh")
        XCTAssertEqual(w.heartMoment?.messageID, 1)
        XCTAssertEqual(w.heartMoment?.score, 2)
        XCTAssertEqual(w.laughMoment?.messageID, 3)
        // A thumbs-up is in neither family.
        XCTAssertEqual(w.hearts + w.laughs, 3)
    }

    // MARK: - Duo attribution

    func testDuoCreditsHeartsToThePersonWhoGaveThem() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seed, indexPath) = try index(dir)
        let t: Int64 = 1_735_689_600_000
        // Ben's line gets one heart from the owner; the owner's line gets one heart from Ben.
        // Ben tapping a heart on his own line must not count.
        try seed.exec("""
        INSERT INTO chats VALUES(7,'dm',0,'Ben',1,'ben');
        INSERT INTO people VALUES('ben','Ben',1),('me','me',0);
        INSERT INTO messages VALUES
          (11,7,0,'Ben','ben',\(t),0,'I have been carrying this umbrella for six months','d1'),
          (12,7,1,'me','me',\(t + 60_000),0,'that umbrella is a personality now','d2'),
          (13,7,0,'Ben','ben',\(t + 120_000),0,'the umbrella has rights','d3');
        INSERT INTO reactions VALUES
          (11,7,'me','me','❤️',\(t + 10)),
          (11,7,'ben','Ben','❤️',\(t + 11)),                  -- self: ignored
          (12,7,'ben','Ben','😍',\(t + 60_010));
        """)
        let w = try await DuoWrappedBuilder.build(store: try VaultStore(path: indexPath), chatID: 7, me: "Sam", fetchTitles: false)
        XCTAssertEqual(w.heartsMine, 1, "the owner's message 12 earned a heart")
        XCTAssertEqual(w.heartsTheirs, 1, "Ben's message 11 earned a heart")
        XCTAssertEqual(w.loved?.messageID, 12, "one heart each, so the more recent message wins the tie")
        XCTAssertEqual(w.loved?.by, "Ben")
        XCTAssertEqual(w.madeMeLaugh, 0, "a heart is not a laugh")
        XCTAssertEqual(w.madeThemLaugh, 0)
    }

    // MARK: - Group attribution

    func testGroupHeartsIgnoreTheAuthorAndThumbsUp() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (seed, indexPath) = try index(dir)
        let t: Int64 = 1_735_689_600_000
        try seed.exec("""
        INSERT INTO chats VALUES(3,'group',1,'Quiz club',1,NULL);
        INSERT INTO people VALUES('asha','Asha',1),('ben','Ben',1),('chitra','Chitra',1),('me','me',0);
        INSERT INTO messages VALUES
          (21,3,0,'Asha','asha',\(t),0,'I once got the wrong bus and ended up in another state','g1'),
          (22,3,0,'Ben','ben',\(t + 1000),0,'the printer is out of paper again','g2');
        INSERT INTO reactions VALUES
          (21,3,'ben','Ben','❤️',\(t + 10)),
          (21,3,'chitra','Chitra','😍',\(t + 11)),
          (21,3,'asha','Asha','❤️',\(t + 12)),                 -- self: ignored
          (22,3,'asha','Asha','👍',\(t + 1010));
        """)
        let w = try await GroupWrappedBuilder.build(store: try VaultStore(path: indexPath), chatID: 3, me: "Sam", fetchTitles: false)
        XCTAssertEqual(w.heartsByReaction, 1)
        XCTAssertEqual(w.loved?.messageID, 21)
        XCTAssertEqual(w.loved?.reply, "❤️😍")
        XCTAssertEqual(w.laughsByReaction, 0)
    }

    // MARK: - Copy

    func testHeartCopyReadsForOneTwoAndMany() {
        XCTAssertNil(WrappedCopy.hearts(me: "You", them: "Ben", mine: 0, theirs: 0))
        XCTAssertEqual(WrappedCopy.hearts(me: "You", them: "Ben", mine: 3, theirs: 3),
                       "Hearts landed evenly: 3 messages of yours and 3 of theirs.")
        XCTAssertEqual(WrappedCopy.hearts(me: "You", them: "Ben", mine: 4, theirs: 1),
                       "4 messages of yours got a heart, against 1 of theirs.")
        XCTAssertNil(WrappedCopy.yearHearts(count: 0))
        XCTAssertEqual(WrappedCopy.yearHearts(count: 1), "One message got a heart from someone else.")
        XCTAssertEqual(WrappedCopy.yearHearts(count: 58), "58 messages got a heart from someone else.")
    }
}
