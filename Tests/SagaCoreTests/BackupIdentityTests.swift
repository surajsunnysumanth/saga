import XCTest
@testable import SagaCore

final class BackupIdentityTests: XCTestCase {
    private func store(_ name: String, jids: [(String, String, String)] = [
        ("111", "s.whatsapp.net", "111@s.whatsapp.net"),
        ("222", "g.us", "222@g.us"),
        ("333", "s.whatsapp.net", "333@s.whatsapp.net"),
    ]) throws -> (SQLiteDB, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, timestamp INT, key_id TEXT);
        """)
        for (i, j) in jids.enumerated() {
            let subject = j.1 == "g.us" ? "'Group'" : "NULL"
            try db.exec("INSERT INTO jid VALUES (\(i+1),'\(j.0)','\(j.1)','\(j.2)');")
            try db.exec("INSERT INTO chat VALUES (\(i+1),\(i+1),\(subject));")
        }
        return (db, path)
    }

    func testIdentityCountsAndNonReversibility() throws {
        let (db, path) = try store("msgstore.db")
        for i in 0..<10 {
            try db.exec("INSERT INTO message VALUES (\(i+1), 1, 1, \(1_700_000_000_000 + i * 1000), 'k\(i)')")
        }
        let id = try BackupIdentityReader.read(msgstore: path, source: "android-crypt15")
        XCTAssertEqual(id.messages, 10)
        XCTAssertEqual(id.chats, 3)
        XCTAssertEqual(id.uidPrint.count, 10)
        XCTAssertTrue(id.chatPrint.allSatisfy { $0.count == 16 })      // hashes, not JIDs
        XCTAssertFalse(id.chatPrint.joined().contains("111"))          // nothing raw leaks
    }

    func testNewerCopyWithOverlapIsContinuation() throws {
        let (db, path) = try store("msgstore.db")
        for i in 0..<40 {
            try db.exec("INSERT INTO message VALUES (\(i+1), 1, \(i % 2), \(1_700_000_000_000 + i * 60_000), 'k\(i)')")
        }
        let old = try BackupIdentityReader.read(msgstore: path, source: "android-crypt15")
        var profile = VaultProfile(name: "Pixel", identity: old)

        // The same account, a month later: more messages, same conversations.
        for i in 40..<60 {
            try db.exec("INSERT INTO message VALUES (\(i+1), 1, \(i % 2), \(1_700_000_000_000 + i * 60_000), 'k\(i)')")
        }
        let newer = try BackupIdentityReader.read(msgstore: path, source: "android-crypt15")
        let (match, verdict) = ProfileMatcher.compare(newer, to: [profile])
        XCTAssertEqual(match?.id, profile.id)
        guard case let .continuation(chats, uids, new) = verdict else { return XCTFail("expected continuation, got \(verdict)") }
        XCTAssertGreaterThanOrEqual(chats, 0.99)
        XCTAssertGreaterThanOrEqual(uids, 0.4)
        XCTAssertGreaterThan(new, 0)
        XCTAssertFalse(verdict.recommendsSeparate)

        profile.absorb(newer)
        XCTAssertEqual(profile.messages, 60)
    }

    func testDifferentAccountRecommendsSeparate() throws {
        let (db, path) = try store("mine.db")
        for i in 0..<20 {
            try db.exec("INSERT INTO message VALUES (\(i+1), 1, 1, \(1_700_000_000_000 + i * 1000), 'a\(i)')")
        }
        let mine = try BackupIdentityReader.read(msgstore: path, source: "android-crypt15")

        let (otherDB, otherPath) = try store("theirs.db", jids: [
            ("999", "s.whatsapp.net", "999@s.whatsapp.net"),
            ("222", "g.us", "222@g.us"),
        ])
        for i in 0..<20 {
            try otherDB.exec("INSERT INTO message VALUES (\(i+1), 1, 1, \(1_700_000_000_000 + i * 1000), 'b\(i)')")
        }
        let theirs = try BackupIdentityReader.read(msgstore: otherPath, source: "ios-backup")
        let (_, verdict) = ProfileMatcher.compare(theirs, to: [VaultProfile(name: "Mine", identity: mine)])
        guard case .different = verdict else { return XCTFail("expected different, got \(verdict)") }
        XCTAssertTrue(verdict.recommendsSeparate)
        XCTAssertTrue(verdict.detail.contains("different account"))
    }

    func testFirstImportHasNothingToCompare() throws {
        let (db, path) = try store("first.db")
        try db.exec("INSERT INTO message VALUES (1, 1, 1, 1_700_000_000_000, 'only')")
        let id = try BackupIdentityReader.read(msgstore: path, source: "android-crypt15")
        let (match, verdict) = ProfileMatcher.compare(id, to: [])
        XCTAssertNil(match)
        XCTAssertEqual(verdict, .first)
        XCTAssertFalse(verdict.recommendsSeparate)
    }
}
