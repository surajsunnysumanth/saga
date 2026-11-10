import XCTest
@testable import SagaCore

/// The Gallery must find the same files a chat bubble finds. These tests pin the two things
/// that used to make it disagree: a vault that can only be opened through the Keychain, and an
/// existence test that demanded a byte-exact local copy (which a re-export or an online-only
/// Drive file never is).
final class GalleryMediaTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: fixtures

    /// The shape of a phone export: `Media/WhatsApp Voice Notes/<year>/Media/<chat>/…`.
    @discardableResult
    private func writeVoiceNote(relative: String, bytes: Int, under base: URL) throws -> URL {
        let file = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: file)
        return file
    }

    private func makeVault() throws -> Vault {
        let vault = try Vault(url: root.appendingPathComponent("vault"))
        return vault
    }

    // MARK: search path

    func testSearchPathKeepsSavedLocationsAndTheFolderBesideTheVault() throws {
        let vault = try makeVault()
        let saved = root.appendingPathComponent("phone-media")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try MediaSources.save([saved], in: vault)

        let sources = MediaSearchPath.sources(vaultURL: vault.url)
        XCTAssertTrue(sources.contains { $0.standardizedFileURL == saved.standardizedFileURL })
        XCTAssertTrue(sources.contains { $0.standardizedFileURL == root.standardizedFileURL },
                      "media beside the vault (demo and portable archives) must be searched")
    }

    func testConfiguredDriveFolderWinsOverDiscovery() throws {
        let drive = root.appendingPathComponent("My Drive/BACKUP/Whatsapp")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        XCTAssertEqual(MediaSearchPath.driveRoots(configured: drive).map(\.path), [drive.path])
    }

    func testMissingConfiguredDriveFolderFallsBackToDiscovery() {
        let gone = root.appendingPathComponent("not-mounted")
        // Discovery lists the real accounts on this Mac; either way the missing folder must not
        // be the only root, or every Drive row would report missing until a relaunch.
        let roots = MediaSearchPath.driveRoots(configured: gone)
        XCTAssertFalse(roots.contains { $0.standardizedFileURL == gone.standardizedFileURL })
    }

    // MARK: resolution

    func testDriveVoiceNoteAndImageResolveThroughTheArchiveLayout() throws {
        let drive = root.appendingPathComponent("My Drive/BACKUP/Whatsapp")
        let voice = "WhatsApp Voice Notes/201901/Media/15550001@s.whatsapp.net/9/a/deadbeef.opus"
        let image = "WhatsApp Images/Private/IMG-20190101-WA0001.jpg"
        try writeVoiceNote(relative: voice, bytes: 40, under: drive)
        try writeVoiceNote(relative: image, bytes: 90, under: drive)

        let files = GalleryMediaFiles(sources: [], driveRoots: [drive])
        let hits = files.resolve([
            .init(id: 1, kind: "audio", path: "Media/" + voice, size: 40),
            .init(id: 2, kind: "image", path: "Media/" + image, size: 90),
        ])
        XCTAssertEqual(hits[1]?.standardizedFileURL, drive.appendingPathComponent(voice).standardizedFileURL)
        XCTAssertEqual(hits[2]?.standardizedFileURL, drive.appendingPathComponent(image).standardizedFileURL)
    }

    func testRecordedSizeThatDriftedFromTheCopyStillResolves() throws {
        // WhatsApp's own exports are re-encoded: a sticker or photo can be a few hundred bytes
        // off the size recorded on the phone. The path is the evidence, not the byte count.
        let drive = root.appendingPathComponent("My Drive/BACKUP/Whatsapp")
        try writeVoiceNote(relative: "WhatsApp Video/Private/VID-20190101-WA0001.mp4", bytes: 120, under: drive)

        let files = GalleryMediaFiles(sources: [], driveRoots: [drive])
        let hit = files.resolve([.init(id: 9, kind: "video",
                                       path: "Media/WhatsApp Video/Private/VID-20190101-WA0001.mp4",
                                       size: 9_999)])
        XCTAssertNotNil(hit[9], "a byte count that differs from the phone's record must not hide a file")
    }

    func testOnlineOnlyPlaceholderWithNoLocalSizeResolves() throws {
        // A file that exists but has not been downloaded reports no local size. Resolving it
        // must not depend on reading it — the read happens when it is played.
        let drive = root.appendingPathComponent("My Drive/BACKUP/Whatsapp")
        let relative = "WhatsApp Voice Notes/201902/PTT-20190202-WA0003.opus"
        try writeVoiceNote(relative: relative, bytes: 0, under: drive)   // placeholder: no bytes yet

        let files = GalleryMediaFiles(sources: [], driveRoots: [drive])
        let hit = files.resolve([.init(id: 3, kind: "audio", path: "Media/" + relative, size: 5_000)])
        XCTAssertNotNil(hit[3], "an online-only copy is present, not missing")
    }

    func testFilenameOnlyHitNeedsTheRecordedSize() throws {
        let source = root.appendingPathComponent("phone-media")
        let one = source.appendingPathComponent("a/duplicate.jpg")
        let two = source.appendingPathComponent("b/duplicate.jpg")
        for file in [one, two] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10).write(to: file)
        }
        let files = GalleryMediaFiles(sources: [source], driveRoots: [])

        // Two candidates, neither the recorded size: no safe answer.
        XCTAssertNil(files.resolve([.init(id: 1, kind: "image", path: "gone/duplicate.jpg", size: 11)])[1])
        // Two candidates, one matches the size.
        let sized = files.resolve([.init(id: 2, kind: "image", path: "gone/duplicate.jpg", size: 10)])[2]
        XCTAssertNotNil(sized)
        XCTAssertTrue([one, two].contains { $0.standardizedFileURL == sized?.standardizedFileURL })
        // No recorded size at all: a lone filename is never evidence, however few candidates.
        try FileManager.default.removeItem(at: two)
        XCTAssertNil(files.resolve([.init(id: 3, kind: "image", path: "gone/duplicate.jpg", size: 0)])[3])
    }

    func testMissesAreReportedSoTheNextPassCanRetryThem() throws {
        // A Drive mount that is still warming up looks empty. The first pass misses; once the
        // tree exists, retrying exactly the misses fills the screen without a relaunch.
        let drive = root.appendingPathComponent("My Drive/BACKUP/Whatsapp")
        let request = GalleryMediaFiles.Request(id: 4, kind: "image",
                                                path: "Media/WhatsApp Images/IMG-20190303-WA0002.jpg",
                                                size: 30)
        let files = GalleryMediaFiles(sources: [], driveRoots: [drive])
        let first = files.resolve([request])
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(files.missing(in: [request], after: first), [request])

        try writeVoiceNote(relative: "WhatsApp Images/IMG-20190303-WA0002.jpg", bytes: 30, under: drive)
        let second = files.resolve(files.missing(in: [request], after: first))
        XCTAssertNotNil(second[4])
    }

    func testRowsWithNoRecordedPathAreNeverGuessed() throws {
        let drive = root.appendingPathComponent("My Drive/BACKUP/Whatsapp")
        try writeVoiceNote(relative: "WhatsApp Voice Notes/PTT-20190101-WA0001.opus", bytes: 30, under: drive)
        let files = GalleryMediaFiles(sources: [], driveRoots: [drive])
        XCTAssertTrue(files.resolve([.init(id: 5, kind: "audio", path: "", size: 30)]).isEmpty,
                      "a row the archive never named is not silently matched to someone else's file")
        XCTAssertTrue(files.missing(in: [.init(id: 5, kind: "audio", path: "", size: 30)], after: [:]).isEmpty,
                      "an unnamed row is not retried 400 times either")
    }

    func testMaterialiseReturnsTheSameURLForALocalFile() throws {
        let file = root.appendingPathComponent("local.opus")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(MediaFileResolver.materialise(file), file)
    }

    func testPathTraversalIsRejected() throws {
        let drive = root.appendingPathComponent("My Drive/BACKUP/Whatsapp")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.opus")
        try Data([1]).write(to: secret)
        let files = GalleryMediaFiles(sources: [], driveRoots: [drive])
        XCTAssertNil(files.resolve([.init(id: 6, kind: "audio",
                                          path: "Media/../../secret.opus", size: 1)])[6])
    }
}
