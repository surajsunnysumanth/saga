import XCTest
@testable import SagaCore

final class MediaCoverageTests: XCTestCase {
    func testDetectsWhatsAppMediaFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-media-\(UUID().uuidString)")
        let media = root.appendingPathComponent("Media")
        for dir in ["WhatsApp Images", "WhatsApp Video"] {
            try FileManager.default.createDirectory(at: media.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        XCTAssertEqual(MediaCoverage.looksLikeWhatsAppMedia(root)?.standardizedFileURL,
                       media.standardizedFileURL)
        let unrelated = FileManager.default.temporaryDirectory.appendingPathComponent("saga-nomedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        XCTAssertNil(MediaCoverage.looksLikeWhatsAppMedia(unrelated))
    }

    func testCoverageCountsByFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-cover-\(UUID().uuidString)")
        let images = root.appendingPathComponent("WhatsApp Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Data([0x1]).write(to: images.appendingPathComponent("IMG-1.jpg"))

        let dir = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let index = dir.appendingPathComponent("index.db").path
        let writable = try SQLiteDB(path: index, readOnly: false)
        try writable.exec("CREATE TABLE media(msg_id INTEGER PRIMARY KEY, chat_id INT, ts INT, kind TEXT, file_path TEXT)")
        try writable.exec("""
        INSERT INTO media VALUES (1,1,1,'image','Media/WhatsApp Images/IMG-1.jpg'),
                                 (2,1,1,'image','Media/WhatsApp Images/IMG-2.jpg')
        """)
        let store = try VaultStore(path: index)
        let report = try MediaCoverage.check(store: store, sources: [root])
        XCTAssertEqual(report.total, 2)
        XCTAssertEqual(report.present, 1)
        XCTAssertEqual(report.missing, 1)
        XCTAssertEqual(report.byKind["image"], 1)
    }
}
