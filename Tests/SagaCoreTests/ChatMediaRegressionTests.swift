import XCTest
@testable import SagaCore

/// Regression tests for the on-demand chat media feature (task brief 01-media-on-demand.md).
/// Guards two safety properties of `MediaFileResolver`:
/// 1. A filename alone never identifies an attachment: the filename fallback runs only with a positive recorded size.
/// 2. Resolving reads metadata only — it never opens or reads file contents.
final class ChatMediaRegressionTests: XCTestCase {

    private func makeRoot() throws -> (root: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Media/WhatsApp Images"),
                                                withIntermediateDirectories: true)
        return (root, source)
    }

    /// A filename match without a positive size must not resolve: the same name can occur in many chats.
    func testFilenameFallbackRequiresPositiveSize() throws {
        let (root, source) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("Media/WhatsApp Images/photo.jpg")
        try Data([1, 2, 3]).write(to: file)
        let resolver = MediaFileResolver()

        // Exact relative path still works regardless of size (stage 1 lookup).
        let byPath = ChatMedia(uid: "by-path", kind: "image", filePath: "Media/WhatsApp Images/photo.jpg")
        XCTAssertEqual(resolver.resolve(byPath, sources: [source], driveRoots: [])?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())

        // Filename-only fallback (path recorded elsewhere) needs size > 0 to match.
        let noSize = ChatMedia(uid: "no-size", kind: "image", filePath: "old/WhatsApp Images/photo.jpg")
        XCTAssertNil(resolver.resolve(noSize, sources: [source], driveRoots: []))
        let zeroSize = ChatMedia(uid: "zero-size", kind: "image", filePath: "old/WhatsApp Images/photo.jpg", size: 0)
        XCTAssertNil(resolver.resolve(zeroSize, sources: [source], driveRoots: []))
        let negativeSize = ChatMedia(uid: "negative-size", kind: "image", filePath: "old/WhatsApp Images/photo.jpg", size: -1)
        XCTAssertNil(resolver.resolve(negativeSize, sources: [source], driveRoots: []))
        let matching = ChatMedia(uid: "matching", kind: "image", filePath: "old/WhatsApp Images/photo.jpg", size: 3)
        XCTAssertEqual(resolver.resolve(matching, sources: [source], driveRoots: [])?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }

    /// Resolution must be metadata-only: a file with no read permission still resolves
    /// (stat gives kind and size), proving the resolver never opens the file.
    func testResolveUsesMetadataOnly() throws {
        let (root, source) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("Media/WhatsApp Images/photo.jpg")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let media = ChatMedia(uid: "unreadable", kind: "image", filePath: "Media/WhatsApp Images/photo.jpg", size: 3)
        let resolver = MediaFileResolver()
        XCTAssertEqual(resolver.resolve(media, sources: [source], driveRoots: [])?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())

        // And the filename fallback likewise inspects metadata only, without reading.
        let moved = ChatMedia(uid: "moved", kind: "image", filePath: "gone/photo.jpg", size: 3)
        XCTAssertEqual(resolver.resolve(moved, sources: [source], driveRoots: [])?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
    }

    /// A size recorded in the index never vetoes a *path* the archive itself recorded: the
    /// folder and the hashed filename are the identity, and a re-export or an online-only copy
    /// can legitimately differ from the byte count taken on the phone. A filename-only hit is
    /// still gated by the size, because nothing else says which attachment it is.
    func testExactPathTrustsTheRecordedPathAndAFilenameOnlyHitNeedsTheSize() throws {
        let (root, source) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("Media/WhatsApp Images/photo.jpg")
        try Data([1, 2, 3]).write(to: file)
        let resolver = MediaFileResolver()

        let driftedSize = ChatMedia(uid: "drifted", kind: "image", filePath: "Media/WhatsApp Images/photo.jpg", size: 4)
        XCTAssertEqual(resolver.resolve(driftedSize, sources: [source], driveRoots: [])?.resolvingSymlinksInPath(),
                       file.resolvingSymlinksInPath())
        let unknownSize = ChatMedia(uid: "unknown", kind: "image", filePath: "Media/WhatsApp Images/photo.jpg", size: 0)
        XCTAssertEqual(resolver.resolve(unknownSize, sources: [source], driveRoots: [])?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        // A different path that only shares the filename is not confirmed by a wrong size.
        let elsewhere = ChatMedia(uid: "elsewhere", kind: "image", filePath: "gone/photo.jpg", size: 4)
        XCTAssertNil(resolver.resolve(elsewhere, sources: [source], driveRoots: []))
    }

    /// An unrecorded or empty path means there is nothing to look up: no source is searched and nothing is opened.
    func testUnrecordedPathResolvesNothing() throws {
        let (root, source) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("Media/WhatsApp Images/photo.jpg"))
        let resolver = MediaFileResolver()
        for path in [nil, ""] as [String?] {
            let media = ChatMedia(uid: "no-path", kind: "image", filePath: path)
            XCTAssertNil(resolver.resolve(media, sources: [source], driveRoots: []))
            XCTAssertEqual(ChatMediaPresentation(media), .labelOnly)
        }
    }
}
