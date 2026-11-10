import XCTest
@testable import SagaCore

final class FoldInTests: XCTestCase {
    func testScanClassifiesDatabasesMediaAndQuirks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("saga-foldin-\(UUID().uuidString)")
        func touch(_ p: String, _ bytes: Int = 4) throws {
            let u = root.appendingPathComponent(p); try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data(repeating: 1, count: bytes))
        }
        try touch("Databases/msgstore-2020-11-22.1.db.crypt12")
        try touch("Databases/msgstore-2026-03-18.1.db.crypt14")
        try touch("Databases/msgstore.db.crypt15")
        try touch("Databases/msgstore-increment-1.db.crypt15")
        try touch("Databases/wa.db.crypt15")                                   // contacts db: not a chat database
        try touch("Media/WhatsApp Images/IMG-20240313-WA0015.jpeg", 10)
        try touch("Media/WhatsApp Images/Sent/IMG-20240314-WA0001.jpg", 10)
        try touch("Media/WhatsApp Images/Private/IMG-20240315-WA0001.jpg", 10)
        try touch("Media/WhatsApp Voice Notes/2021-W41/PTT-20211010-WA0001.opus", 10)
        try touch("Media/WhatsApp Images/Sent/IMG-20240313-WA0015.jpeg", 10)    // duplicate name+size
        try fm.createDirectory(at: root.appendingPathComponent("Media/WhatsApp Video/Empty"), withIntermediateDirectories: true)
        let r = FoldIn.scan(root: root)
        XCTAssertEqual(r.databases.count, 4)
        XCTAssertEqual(r.databases.filter(\.usable).count, 1)
        XCTAssertEqual(r.databases.first { $0.url.lastPathComponent.contains("2020") }?.format, .crypt12)
        XCTAssertEqual(r.databases.first { $0.url.lastPathComponent.contains("increment") }?.format, .increment)
        XCTAssertEqual(r.media.first { $0.name == "WhatsApp Images" }?.files, 4)
        XCTAssertEqual(r.media.first { $0.name == "WhatsApp Voice Notes" }?.files, 1)
        XCTAssertEqual(r.duplicateFiles, 1)
        XCTAssertGreaterThanOrEqual(r.emptyFolders, 1)
        XCTAssertTrue(r.quirks.contains { $0.contains("Sent") })
        XCTAssertTrue(r.quirks.contains { $0.contains("Weekly") })
        XCTAssertNotNil(r.oldestMedia)
    }

    func testRunFoldsPlainDatabaseDryRunThenReal() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("saga-foldin2-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("src/msgstore.db").path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO chat VALUES (5,1,NULL);
        INSERT INTO message VALUES (1,5,0,NULL,1000,0,'one','K1'),(2,5,1,NULL,2000,0,'two','K2');
        """)
        let rep = FoldIn.scan(root: dir.appendingPathComponent("src"))
        XCTAssertEqual(rep.databases.first?.format, .plain)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        let dry = await FoldIn.run(report: rep, vault: vault, keyHex: nil, dryRun: true)
        XCTAssertEqual(dry.first?.added, 2); XCTAssertTrue(vault.segmentFiles().isEmpty)     // dry run writes nothing
        let real = await FoldIn.run(report: rep, vault: vault, keyHex: nil, dryRun: false)
        XCTAssertEqual(real.first?.added, 2); XCTAssertEqual(vault.segmentFiles().count, 1)
        let again = await FoldIn.run(report: rep, vault: vault, keyHex: nil, dryRun: false)
        XCTAssertEqual(again.first?.added, 0)                                                // idempotent
    }
}
