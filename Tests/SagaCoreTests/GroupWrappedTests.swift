import XCTest
@testable import SagaCore

final class GroupWrappedTests: XCTestCase {
    func withStore(_ body: (VaultStore, SQLiteDB) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec("""
            INSERT INTO chats VALUES(10,'team@g.us',1,'Quiz <club>',1,NULL);
            INSERT INTO chats VALUES(20,'friend@s.whatsapp.net',0,'Friend',1,'friend');
            INSERT INTO messages VALUES
            (1,10,0,'Alex','a',1705320000000,0,'The invisible trophy strikes again','u1'),
            (2,10,0,'Blair','b',1705320060000,0,'hahahahaha 😂','u2'),
            (3,10,0,'Alex','a',1705320120000,0,'hahahahaha','u3'),
            (4,10,1,'Me',NULL,1705320180000,0,'https://youtu.be/dQw4w9WgXcQ','u4'),
            (5,10,0,'Blair','b',1710504000000,0,'https://youtu.be/dQw4w9WgXcQ','u5'),
            (6,10,0,'System',NULL,1710504060000,7,'joined','u6'),
            (7,20,0,'Friend','friend',1705320000000,0,'hello there','u7'),
            (8,20,1,'Me',NULL,1705320060000,0,'hello back','u8');
            """)
        try await body(VaultStore(path: path), db)
    }

    func testFunniestMusicAndEscapedHTML() async throws {
        try await withStore { store, _ in
            let w = try await GroupWrappedBuilder.build(store: store, chatID: 10, me: "Sam", fetchTitles: false)
            XCTAssertEqual(w.funniest.map(\.key).sorted(), ["a", "b"])
            XCTAssertEqual(w.funniest.map(\.laughsEarned), [1, 1])
            XCTAssertEqual(w.moments.count, 2)
            XCTAssertEqual(w.linksTotal, 2)
            XCTAssertEqual(w.tracks.count, 1)
            XCTAssertEqual(w.tracks.first?.times, 2)
            XCTAssertEqual(Set(w.linkSharers.map(\.key)), ["self", "b"])
            let html = GroupWrappedHTML.render(w, interactive: false)
            XCTAssertTrue(html.contains("Quiz &lt;club&gt;"))
            XCTAssertFalse(html.contains("Quiz <club>"))
            XCTAssertFalse(html.contains("messageHandlers"))
            XCTAssertTrue(GroupWrappedHTML.render(w, interactive: true).contains("messageHandlers"))
            XCTAssertFalse(html.contains("src=\"http"), "self-contained: no remote resources loaded")
        }
    }

    func testDirectChatCountsAreIndependentOfGroup() async throws {
        try await withStore { store, _ in
            let dm = try await DuoWrappedBuilder.build(store: store, chatID: 20, me: "Sam", fetchTitles: false)
            XCTAssertEqual(dm.total, 2)
            XCTAssertEqual(dm.mine, 1)
        }
    }

    func testContributorsUsePersonIdentityAndCountOnlyGroupContent() async throws {
        try await withStore { store, _ in
            let w = try await GroupWrappedBuilder.build(store: store, chatID: 10, me: "Sam", fetchTitles: false)
            XCTAssertEqual(w.total, 5)
            XCTAssertEqual(w.contributors.map(\.key), ["a", "b", "self"])
            XCTAssertEqual(w.contributors.map(\.messages), [2, 2, 1])
            XCTAssertEqual(w.contributors.last?.name, "Sam")
            XCTAssertEqual(w.monthly.map(\.month), ["2024-01", "2024-02", "2024-03"])
            XCTAssertEqual(w.monthly.map(\.count), [4, 0, 1])
        }
    }
}
