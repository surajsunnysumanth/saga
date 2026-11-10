import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import AVFoundation
@testable import SagaCore

final class ChatMediaTests: XCTestCase {
    func testVideoPosterAndMissingOrUnsupportedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(url: root.appendingPathComponent("vault"))
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try MediaSources.save([source], in: vault.url)
        let video = source.appendingPathComponent("movie.mov")
        try makeVideo(at: video)
        let loader = ChatMediaLoader(vaultURL: vault.url, cacheDirectory: root.appendingPathComponent("cache"), driveRoots: [])
        let poster = try await loader.thumbnail(for: ChatMedia(uid: "video", kind: "video", filePath: "movie.mov"))
        XCTAssertNotNil(poster)
        let absent = try await loader.thumbnail(for: ChatMedia(uid: "absent", kind: "image", filePath: "absent.png"))
        XCTAssertNil(absent)
        try Data([0, 1, 2]).write(to: source.appendingPathComponent("bad.png"))
        let corrupt = try await loader.thumbnail(for: ChatMedia(uid: "bad", kind: "image", filePath: "bad.png"))
        XCTAssertNil(corrupt)
        let audio = ChatMedia(uid: "audio", kind: "audio", filePath: "bad.png")
        let noPoster = try await loader.thumbnail(for: audio)
        XCTAssertNil(noPoster)
        let playable = try await loader.file(for: audio)
        XCTAssertNotNil(playable)
    }

    private func makeVideo(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, 0, CVPixelBufferGetDataSize(pixels)) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        XCTAssertTrue(adaptor.append(pixels, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 30))
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(writer.status, .completed)
    }

    func testThumbnailIsLazyDownsampledAndSurvivesMissingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(url: root.appendingPathComponent("vault"))
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try MediaSources.save([source], in: vault.url)
        let image = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let original = source.appendingPathComponent("photo.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(original as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let cache = root.appendingPathComponent("cache")
        let loader = ChatMediaLoader(vaultURL: vault.url, cacheDirectory: cache, maxConcurrentLoads: 2, maxPixelSize: 16, driveRoots: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        let media = ChatMedia(uid: "stable-image", kind: "image", filePath: "photo.png")
        let loaded = try await loader.thumbnail(for: media)
        let thumbnail = try XCTUnwrap(loaded)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))
        let preview = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(preview.width, 16)
        XCTAssertEqual(preview.height, 8)
        try FileManager.default.removeItem(at: original)
        let reloaded = ChatMediaLoader(vaultURL: vault.url, cacheDirectory: cache, maxPixelSize: 16, driveRoots: [])
        let cached = try await reloaded.thumbnail(for: media)
        XCTAssertEqual(cached, thumbnail)
        let missing = try await loader.file(for: media)
        XCTAssertNil(missing)
        let different = try await loader.thumbnail(for: ChatMedia(uid: "different", kind: "image", filePath: "photo.png"))
        XCTAssertNil(different)
    }

    func testQueueBoundsWorkAndCancelsQueuedRequest() async throws {
        let queue = MediaLoadQueue(limit: 2)
        let counter = LoadCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<500 {
                group.addTask {
                    try await queue.run {
                        await counter.start()
                        try await Task.sleep(for: .milliseconds(5))
                        await counter.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        XCTAssertEqual(peak, 2)
        let cancelled = Task { try await queue.run { 42 } }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled work must not run") }
        catch is CancellationError {} 
        let serial = MediaLoadQueue(limit: 1)
        let running = LoadCounter()
        let first = Task {
            try await serial.run {
                await running.start()
                try await Task.sleep(for: .milliseconds(100))
                await running.end()
            }
        }
        while await running.active == 0 { await Task.yield() }
        let waiting = Task { try await serial.run { await running.start() } }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancelled queued work ran") }
        catch is CancellationError {}
        try await first.value
        let active = await running.active
        XCTAssertEqual(active, 0)
    }

    func testDriveFallbackAndRecordedSourcesTakePriority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        let drive = root.appendingPathComponent("Library/CloudStorage/GoogleDrive-synthetic/My Drive")
        try FileManager.default.createDirectory(at: local.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: drive.appendingPathComponent("Images/photo.jpg"))
        let media = ChatMedia(uid: "drive", kind: "image", filePath: "Media/Images/photo.jpg", size: 3)
        let resolver = MediaFileResolver()
        let mounts = MediaFileResolver.driveRoots(home: root)
        XCTAssertEqual(mounts.map { $0.resolvingSymlinksInPath().path }, [drive.resolvingSymlinksInPath().path])
        XCTAssertEqual(resolver.resolve(media, sources: [local], driveRoots: mounts)?.resolvingSymlinksInPath(), drive.appendingPathComponent("Images/photo.jpg").resolvingSymlinksInPath())
        let localFile = local.appendingPathComponent("nested/photo.jpg")
        try Data([3, 2, 1]).write(to: localFile)
        resolver.invalidateMetadataCache()
        XCTAssertEqual(resolver.resolve(media, sources: [local], driveRoots: mounts)?.resolvingSymlinksInPath(), localFile.resolvingSymlinksInPath())
        let outside = root.appendingPathComponent("outside.jpg")
        try Data([1, 2, 3]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("escape.jpg"), withDestinationURL: outside)
        XCTAssertNil(resolver.resolve(ChatMedia(uid: "escape", kind: "image", filePath: "escape.jpg", size: 3), sources: [local], driveRoots: []))
    }

    func testFallbackCatalogCanRefreshAfterSourceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let resolver = MediaFileResolver()
        let media = ChatMedia(uid: "fallback", kind: "doc", filePath: "old/path/file.pdf", size: 3)
        XCTAssertNil(resolver.resolve(media, sources: [root], driveRoots: []))
        let file = root.appendingPathComponent("nested/file.pdf")
        try Data([1, 2, 3]).write(to: file)
        resolver.invalidateMetadataCache()
        XCTAssertEqual(resolver.resolve(media, sources: [root], driveRoots: [])?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        let wrongSize = ChatMedia(uid: "wrong", kind: "doc", filePath: "old/path/file.pdf", size: 4)
        XCTAssertNil(resolver.resolve(wrongSize, sources: [root], driveRoots: []))
    }

    func testSourceSettingsPersistPerVaultAndFoldInRemainsCompatible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try Vault(url: root.appendingPathComponent("vault"))
        let source = root.appendingPathComponent("source")
        FoldIn.recordMediaSource(source, in: vault)
        XCTAssertEqual(try MediaSources.load(in: vault.url), [source])
        try MediaSources.save([source, source], in: vault.url)
        XCTAssertEqual(try MediaSources.load(in: vault.url).count, 1)
        try MediaSources.save([], in: vault.url)
        XCTAssertEqual(try MediaSources.load(in: vault.url), [])
    }

    func testStoreReturnsMetadataWithoutReadingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec("INSERT INTO messages VALUES(1,10,0,'Synthetic','fake',1000,1,NULL,'stable'); INSERT INTO media VALUES(1,10,1000,'image/jpeg','image','Media/absent.jpg',3,'hash',NULL,NULL)")
        let store = try VaultStore(path: path)
        let message = try XCTUnwrap(store.messages(chat: 10).first)
        XCTAssertEqual(message.media?.uid, "stable")
        XCTAssertEqual(message.media?.filePath, "Media/absent.jpg")
        XCTAssertEqual(message.media?.size, 3)
    }

    func testRelativePathWinsOverFilenameFallbackAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Media/Images"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("Media/Images/photo.jpg")
        try Data([1, 2, 3]).write(to: file)
        let resolver = MediaFileResolver()
        let media = ChatMedia(uid: "synthetic", kind: "image", filePath: "Media/Images/photo.jpg", size: 3)
        XCTAssertEqual(resolver.resolve(media, sources: [source], driveRoots: []), file)
        let unsafe = ChatMedia(uid: "unsafe", kind: "image", filePath: "../secret.jpg", size: 3)
        XCTAssertNil(resolver.resolve(unsafe, sources: [source], driveRoots: []))
    }
}

private actor LoadCounter {
    var active = 0
    var peak = 0
    func start() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}
