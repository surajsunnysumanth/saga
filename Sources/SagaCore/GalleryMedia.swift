import Foundation

/// Where a media lookup may look: the vault's own media folders, the folders beside the vault,
/// and the Google Drive backup. One definition, so a chat bubble, a photo tile and a voice-note
/// row can never disagree about whether a file is on this Mac.
public enum MediaSearchPath {
    /// Read exactly the way chat bubbles read it — through the Keychain-backed vault open, so an
    /// encrypted archive that is remembered on this Mac still resolves its media folders. A vault
    /// opened by path alone throws `.locked` there, which used to leave the Gallery with no
    /// sources at all while the conversation drew the same photo perfectly well.
    public static func sources(vaultURL: URL) -> [URL] {
        var roots: [URL] = []
        if let vault = try? Vault.open(url: vaultURL, create: false),
           let saved = try? MediaSources.load(in: vault) {
            roots.append(contentsOf: saved)
        }
        // Demo and portable archives keep media beside the vault folder.
        let beside = vaultURL.deletingLastPathComponent()
        if !roots.contains(where: { $0.standardizedFileURL == beside.standardizedFileURL }) {
            roots.append(beside)
        }
        return roots
    }

    /// The Drive folder the reader configured, plus — only when that folder is not there —
    /// every signed-in Google Drive account's "My Drive". The configured folder stays first:
    /// it is the folder whose layout the archive's own paths were recorded against, and
    /// searching a whole "My Drive" is far too much work to do on every miss.
    public static func driveRoots(configured: URL?) -> [URL] {
        if let configured, FileManager.default.fileExists(atPath: configured.path) {
            return [configured]
        }
        return MediaFileResolver.driveRoots()
    }

    public static func roots(vaultURL: URL, configuredDrive: URL?) -> (sources: [URL], drive: [URL]) {
        (sources(vaultURL: vaultURL), driveRoots(configured: configuredDrive))
    }
}

/// A whole Gallery screen's worth of lookups in one pass, through the same resolver the chat
/// uses. Requests keep their row id so a view can publish a dictionary and draw immediately.
public struct GalleryMediaFiles: Sendable {
    public struct Request: Sendable, Hashable {
        public let id: Int64
        public let kind: String
        public let path: String
        public let size: Int64
        public init(id: Int64, kind: String, path: String, size: Int64) {
            self.id = id; self.kind = kind; self.path = path; self.size = size
        }
        public var media: ChatMedia {
            ChatMedia(uid: "\(id)", kind: kind, filePath: path, size: size > 0 ? size : nil)
        }
    }

    private let sources: [URL]
    private let driveRoots: [URL]
    private let resolver = MediaFileResolver()

    public init(sources: [URL], driveRoots: [URL]) {
        self.sources = sources
        self.driveRoots = driveRoots
    }

    /// Metadata-only resolution. A miss is returned as absent; callers may retry the misses
    /// once because a cloud mount that is still warming up looks empty for its first moments.
    public func resolve(_ requests: [Request]) -> [Int64: URL] {
        var out: [Int64: URL] = [:]
        out.reserveCapacity(requests.count)
        for request in requests {
            if Task.isCancelled { return out }
            guard !request.path.isEmpty else { continue }
            if let url = resolver.resolve(request.media, sources: sources, driveRoots: driveRoots) {
                out[request.id] = url
            }
        }
        return out
    }

    /// The rows that still have nowhere to come from, in the order they were asked for.
    public func missing(in requests: [Request], after hits: [Int64: URL]) -> [Request] {
        requests.filter { $0.path.isEmpty == false && hits[$0.id] == nil }
    }
}
