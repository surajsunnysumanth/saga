import XCTest
@testable import SagaCore

final class OnThisDayTests: XCTestCase {
    private func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Int64 {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return Int64((Calendar.current.date(from: c) ?? Date()).timeIntervalSince1970 * 1000)
    }

    private func index() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-otd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("idx.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec("""
        INSERT INTO chats VALUES (1,'demo-jules@lid',0,'Jules',1,'demo-jules'),(2,'demo-weekend@g.us',1,'Weekend Club',1,NULL);
        INSERT INTO people VALUES ('demo-jules','Jules',1),('demo-river','River',1);
        INSERT INTO messages VALUES
          (1,1,0,'Jules','demo-jules',\(ts(2023,2,14,0,14)),0,'The tiny robot finally learned to dance','uid-1'),
          (2,1,1,'me','me',\(ts(2023,2,14,0,16)),0,'Haha, its signature move is still falling over 😂','uid-2'),
          (3,2,0,'Jules','demo-jules',\(ts(2023,2,14,21,40)),0,'Birthday picnic by the blue kite','uid-3'),
          (4,2,1,'me','me',\(ts(2023,2,14,21,45)),0,'I will bring the moon cookies','uid-4'),
          (5,1,0,'Jules','demo-jules',\(ts(2023,2,14,23,55)),0,'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC','uid-5'),
          (6,2,1,'me','me',\(ts(2023,2,14,23,58)),0,'goodnight','uid-6'),
          (7,1,1,'me','me',\(ts(2026,2,14,9,0)),0,'three years later','uid-7'),
          (8,1,0,'Jules','demo-jules',\(ts(2026,2,14,9,1)),0,'hahahaha still the same robot','uid-8'),
          (9,2,1,'me','me',\(ts(2023,2,15,10,0)),0,'hahahaha that was the best','uid-9'),
          (10,1,0,'Jules','demo-jules',\(ts(2024,2,29,12,0)),0,'leap day hello','uid-10'),
          (11,1,0,'Jules','demo-jules',\(ts(2025,2,14,9,0)),0,'Three years of the same picnic spot','uid-11'),
          (12,1,1,'me','me',\(ts(2025,2,14,22,5)),0,'https://youtu.be/dQw4w9WgXcQ','uid-12');
        INSERT INTO media VALUES
          (3,2,\(ts(2023,2,14,21,40)),'image/jpeg','image','media/picnic.jpg',1200,'hash-1','Picnic by the kite',NULL),
          (4,2,\(ts(2023,2,14,21,45)),'video/mp4','video','media/cookies.mp4',9000,'hash-2',NULL,NULL);
        INSERT INTO message_replies VALUES ('uid-9','uid-1');
        """)
        return path
    }

    func testBuildsEveryYearOnTheDate() throws {
        let store = try VaultStore(path: try index())
        let day = try OnThisDayBuilder.build(store: store, month: 2, day: 14, now: ts(2026, 11, 7, 12, 0).date)
        XCTAssertEqual(day.total, 10)
        XCTAssertEqual(day.years.map(\.year), [2026, 2025, 2023])
        XCTAssertEqual(day.firstEver?.text, "The tiny robot finally learned to dance")

        let y2023 = try XCTUnwrap(day.years.first(where: { $0.year == 2023 }))
        XCTAssertEqual(y2023.count, 6)
        XCTAssertEqual(y2023.sent, 3)
        XCTAssertEqual(y2023.chatCount, 2)
        XCTAssertEqual(y2023.first?.text, "The tiny robot finally learned to dance")
        XCTAssertEqual(y2023.last?.text, "goodnight")
        XCTAssertEqual(y2023.mediaCount, 2)
        XCTAssertEqual(y2023.media.map(\.media.kind), ["image", "video"])
        XCTAssertEqual(y2023.links.count, 1)
        XCTAssertEqual(y2023.links.first?.service, .spotify)

        let y2025 = try XCTUnwrap(day.years.first(where: { $0.year == 2025 }))
        XCTAssertEqual(y2025.last?.preview(), "YouTube video")
        XCTAssertEqual(y2025.first?.preview(), "Three years of the same picnic spot")

        // Quoted reply a day later still counts as a laugh for the message it answers.
        let highlight = try XCTUnwrap(y2023.highlight)
        XCTAssertEqual(highlight.messageID, 1)
        XCTAssertEqual(highlight.uid, "uid-1")
        XCTAssertEqual(highlight.reactionBy, "me")
        XCTAssertTrue(highlight.reaction?.contains("hahahaha") == true)

        // Quiet years are reported rather than silently skipped.
        XCTAssertEqual(day.quietYears, [2024])
        XCTAssertEqual(day.peek?.year.year, 2023)
        XCTAssertEqual(day.peek?.headline, "6 messages")
    }

    func testEmptyDateAndLeapDay() throws {
        let store = try VaultStore(path: try index())
        let empty = try OnThisDayBuilder.build(store: store, month: 11, day: 7)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.peek)
        XCTAssertTrue(empty.years.isEmpty)

        let leap = try OnThisDayBuilder.build(store: store, month: 2, day: 29)
        XCTAssertEqual(leap.total, 1)
        XCTAssertEqual(leap.years.map(\.year), [2024])
        XCTAssertEqual(leap.strip.first(where: { $0.year == 2023 })?.dateExists, false)
        XCTAssertEqual(leap.strip.first(where: { $0.year == 2024 })?.dateExists, true)
        XCTAssertEqual(leap.quietYears, [])
    }

    func testSurpriseNeverPicksTheShownDateAndLandsOnABusyDay() throws {
        let store = try VaultStore(path: try index())
        var rng: any RandomNumberGenerator = TestRandom()
        let pick = try XCTUnwrap(OnThisDayBuilder.surpriseDate(store: store, excluding: 2, day: 14, random: &rng))
        XCTAssertFalse(pick.month == 2 && pick.day == 14)
        let day = try OnThisDayBuilder.build(store: store, month: pick.month, day: pick.day)
        XCTAssertFalse(day.isEmpty)
    }

    func testCaptionCacheRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-otd-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = try AICache(path: dir.appendingPathComponent("ai.db").path)
        XCTAssertNil(cache.caption(key: "otd:v1:2-14:2023:1"))
        cache.saveCaption(key: "otd:v1:2-14:2023:1", text: "A day of moon cookies.")
        XCTAssertEqual(cache.caption(key: "otd:v1:2-14:2023:1"), "A day of moon cookies.")
        cache.saveCaption(key: "otd:v1:2-14:2023:1", text: "A day of moon cookies, again.")
        XCTAssertEqual(cache.caption(key: "otd:v1:2-14:2023:1"), "A day of moon cookies, again.")
        XCTAssertNil(cache.caption(key: "otd:v1:2-14:2024:1"))
    }

    func testLaughPreFilterMatchesTheDetector() {
        for text in ["hahahaha", "Haha, of course", "hehe", "lol", "lmfao", "rofl", "😂😂", "हाहाहा", "hasi aa gayi"] {
            XCTAssertTrue(OnThisDayBuilder.hasLaughSignal(text), text)
            XCTAssertGreaterThan(WrappedReactionDetector().laughScore(text), 0, text)
        }
        for text in ["good morning", "the capital city", "shall we go"] {
            XCTAssertFalse(OnThisDayBuilder.hasLaughSignal(text), text)
        }
    }
}

/// Deterministic generator so "Surprise me" can be tested.
private struct TestRandom: RandomNumberGenerator {
    var state: UInt64 = 42
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

private extension Int64 {
    var date: Date { Date(timeIntervalSince1970: Double(self) / 1000) }
}
