import Foundation
import CryptoKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Each lane waits for its predecessor, including a cancelled predecessor. Work is off-main.
actor MediaLoadQueue {
    private var lanes: [Task<Void, Never>?]
    private var next = 0
    init(limit: Int) { lanes = Array(repeating: nil, count: max(1, limit)) }

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let lane = next
        next = (next + 1) % lanes.count
        let previous = lanes[lane]
        let task = Task.detached(priority: .utility) {
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        lanes[lane] = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { task.cancel() }
    }
}

/// Share one loader per open vault. Initialization and message paging do no media IO.
/// Call `thumbnail` only for visible bubbles; call `file` on explicit open/play.
public final class ChatMediaLoader: Sendable {
    private let vaultURL: URL
    private let cacheDirectory: URL
    private let maxPixelSize: Int
    private let driveRoots: [URL]
    private let queue: MediaLoadQueue
    private let resolver = MediaFileResolver()

    public init(vaultURL: URL, cacheDirectory: URL? = nil, maxConcurrentLoads: Int = 4,
                maxPixelSize: Int = 480, driveRoots: [URL] = []) {
        self.vaultURL = vaultURL
        self.cacheDirectory = cacheDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Saga/media-thumbnails")
        self.maxPixelSize = max(1, maxPixelSize)
        self.driveRoots = driveRoots
        self.queue = MediaLoadQueue(limit: maxConcurrentLoads)
    }

    /// Missing/unreadable sources are normal nil results, never a user-facing error.
    /// Resolving a URL reads metadata only. Opening it may hydrate an online-only Drive file.
    public func file(for media: ChatMedia) async throws -> URL? {
        try await queue.run { [self] in resolve(media).map { MediaFileResolver.materialise($0) } }
    }

    private func resolve(_ media: ChatMedia) -> URL? {
        // The same folder list the Gallery resolves against, read through the Keychain-backed
        // vault open so an encrypted vault that is remembered on this Mac still resolves media.
        let sources = MediaSearchPath.sources(vaultURL: vaultURL)
        if let hit = resolver.resolve(media, sources: sources, driveRoots: driveRoots) { return hit }
        // Nothing on disk: the newest media usually lives only on the phone. Ask it for this
        // one file instead of copying the whole tree.
        guard let path = media.filePath else { return nil }
        return PhoneLink.fetchMedia(named: (path as NSString).lastPathComponent, into: PhoneLink.mediaCache)
    }

    private func cacheURL(_ media: ChatMedia) -> URL {
        // Length-delimited JSON prevents identity collisions; row IDs never enter the key.
        let identity = ["v1", vaultURL.standardizedFileURL.path, media.uid, media.kind,
                        media.filePath ?? "", media.fileHash ?? "", media.size.map(String.init) ?? "", String(maxPixelSize)]
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(key + ".png")
    }

    /// Cache-first: a warm thumbnail requires no source lookup, enumeration, or hydration.
    /// Cancellation propagates; unsupported/corrupt/missing attachments return nil.
    public func thumbnail(for media: ChatMedia) async throws -> URL? {
        guard media.kind == "image" || media.kind == "video" || media.kind == "sticker" else { return nil }
        return try await queue.run { [self] in
            let cached = cacheURL(media)
            if let source = CGImageSourceCreateWithURL(cached as CFURL, nil),
               CGImageSourceCreateImageAtIndex(source, 0, nil) != nil { return cached }
            guard let file = resolve(media) else { return nil }
            MediaFileResolver.materialise(file)   // an online-only copy is fetched on first use
            try Task.checkCancellation()
            let image: CGImage?
            if media.kind == "video" {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                image = try? await generator.image(at: .zero).image
            } else if let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary)
            } else { image = nil }
            try Task.checkCancellation()
            guard let image else { return nil }
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }
                try (data as Data).write(to: cached, options: .atomic)
                return cached
            } catch { return nil }
        }
    }
}
