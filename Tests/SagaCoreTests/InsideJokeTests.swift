import XCTest
@testable import SagaCore

/// The inside-jokes extractor used to surface whatever was frequent, including the words left
/// behind by tagging someone. A name is not a catchphrase, a phone number is not a phrase, and
/// a phrase every other chat uses is not an inside joke.
final class InsideJokeTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-jokes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One direct chat with Priya Menon, plus an unrelated second chat so exclusivity is a real
    /// question rather than "there is nowhere else to look".
    private func store(_ dir: URL, otherChatSays: String? = nil) throws -> VaultStore {
        let path = dir.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        var sql = """
        INSERT INTO chats VALUES(1,'dm',0,'Priya Menon',1,'priya'),(2,'other',1,'Other room',1,NULL);
        INSERT INTO people VALUES('priya','Priya Menon',1),('me','me',0),('ben','Ben',1);
        INSERT INTO messages VALUES
          (1,1,0,'Priya Menon','priya',1735689600000,0,'@Priya Menon look','u1'),
          (2,1,0,'Priya Menon','priya',1735689601000,0,'@Priya Menon look','u2'),
          (3,1,0,'Priya Menon','priya',1735689602000,0,'@Priya Menon look','u3'),
          (4,1,0,'Priya Menon','priya',1735689603000,0,'@Priya Menon look','u4'),
          (5,1,0,'Priya Menon','priya',1735689604000,0,'@Priya Menon look','u5'),
          (6,1,0,'Priya Menon','priya',1735689605000,0,'@Priya Menon look','u6'),
          (7,1,0,'Priya Menon','priya',1735689606000,0,'9876543210','u7'),
          (8,1,0,'Priya Menon','priya',1735689607000,0,'9876543210','u8'),
          (9,1,0,'Priya Menon','priya',1735689608000,0,'9876543210','u9'),
          (10,1,0,'Priya Menon','priya',1735689609000,0,'the blue kettle is back','u10'),
          (11,1,0,'Priya Menon','priya',1735689610000,0,'blue kettle status report','u11'),
          (12,1,1,'me','me',1735689611000,0,'we do not discuss the blue kettle','u12'),
          (13,1,0,'Priya Menon','priya',1735689612000,0,'see you tomorrow','u13'),
          (14,1,0,'Priya Menon','priya',1735689613000,0,'see you tomorrow','u14'),
          (15,1,0,'Priya Menon','priya',1735689614000,0,'see you tomorrow','u15');
        """
        if let other = otherChatSays {
            sql += """
            INSERT INTO messages VALUES (90,2,0,'Ben','ben',1735689700000,0,'\(other)','v90');
            """
        }
        try db.exec(sql)
        try db.exec(Importer.finish)
        return try VaultStore(path: path)
    }

    func testMentionsNumbersAndNamesNeverBecomeInsideJokes() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try store(dir)
        let w = try await DuoWrappedBuilder.build(store: store, chatID: 1, me: "Sam", fetchTitles: false)

        XCTAssertEqual(w.insideJokes.map(\.text), ["blue kettle"],
                       "only the phrase that lives in this chat, with no name or number in it")
        for joke in w.insideJokes {
            XCTAssertFalse(joke.text.contains("priya"), joke.text)
            XCTAssertFalse(joke.text.contains("menon"), joke.text)
            XCTAssertFalse(joke.text.contains("@"), joke.text)
            XCTAssertNil(joke.text.rangeOfCharacter(from: .decimalDigits), joke.text)
        }
        // The separate signature-word list is filtered the same way: it used to surface the
        // tagged person's own name as a "word only they use".
        for word in w.myWords + w.theirWords {
            XCTAssertFalse(["priya", "menon", "sam"].contains(word.text), word.text)
            XCTAssertNil(word.text.rangeOfCharacter(from: .decimalDigits), word.text)
        }
    }

    func testPhraseUsedInAnotherChatIsNotAnInsideJoke() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The same phrase, once, in a room that is not this one: sharing it is what disqualifies it.
        let store = try store(dir, otherChatSays: "the blue kettle is elsewhere")
        let w = try await DuoWrappedBuilder.build(store: store, chatID: 1, me: "Sam", fetchTitles: false)
        XCTAssertFalse(w.insideJokes.contains { $0.text == "blue kettle" })
        XCTAssertTrue(w.insideJokes.isEmpty, "nothing else reaches three uses and one-room exclusivity")
    }

    func testGroupJokesRejectEveryMemberName() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec("""
        INSERT INTO chats VALUES(5,'group',1,'Quiz club',1,NULL);
        INSERT INTO people VALUES('asha','Asha Iyer',1),('ben','Ben Rao',1),('me','me',0);
        INSERT INTO messages VALUES
          (21,5,0,'Asha Iyer','asha',1735689600000,0,'Asha Iyer look at this','g1'),
          (22,5,0,'Asha Iyer','asha',1735689601000,0,'Asha Iyer look at this','g2'),
          (23,5,0,'Asha Iyer','asha',1735689602000,0,'Asha Iyer look at this','g3'),
          (24,5,0,'Ben Rao','ben',1735689603000,0,'Ben Rao will love it','g4'),
          (25,5,0,'Ben Rao','ben',1735689604000,0,'Ben Rao will love it','g5'),
          (26,5,0,'Ben Rao','ben',1735689605000,0,'Ben Rao will love it','g6'),
          (27,5,0,'Asha Iyer','asha',1735689606000,0,'pigeon tribunal is in session','g7'),
          (28,5,0,'Asha Iyer','asha',1735689607000,0,'the pigeon tribunal will see you now','g8'),
          (29,5,0,'Ben Rao','ben',1735689608000,0,'pigeon tribunal never adjourns','g9');
        """)
        try db.exec(Importer.finish)
        let store = try VaultStore(path: path)
        let w = try await GroupWrappedBuilder.build(store: store, chatID: 5, me: "Sam", fetchTitles: false)
        let texts = w.insideJokes.map(\.text)
        XCTAssertTrue(texts.contains("pigeon tribunal"), "\(texts)")
        for name in ["asha", "iyer", "ben", "rao"] {
            XCTAssertFalse(texts.contains { $0.contains(name) }, "\(name) leaked: \(texts)")
        }
    }
}
