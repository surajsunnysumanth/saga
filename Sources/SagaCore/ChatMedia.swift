import Foundation

/// Stable message identity and index metadata; constructing this never touches a media file.
public struct ChatMedia: Hashable, Sendable {
    public let uid: String
    public let kind: String
    public let filePath: String?
    public let size: Int64?
    public let mime: String?
    public let fileHash: String?
    public let caption: String?
    public init(uid: String, kind: String, filePath: String?, size: Int64? = nil,
                mime: String? = nil, fileHash: String? = nil, caption: String? = nil) {
        self.uid = uid; self.kind = kind; self.filePath = filePath; self.size = size
        self.mime = mime; self.fileHash = fileHash; self.caption = caption
    }
}

/// Metadata-only lookup. Call on a background task, not the main actor.
public final class MediaFileResolver: @unchecked Sendable {
    private let lock = NSLock()
    private struct Catalog { let at: Date; let names: [String: [URL]] }
    // Protected by lock; built only when exact paths fail, never on launch.
    private var catalogs: [URL: Catalog] = [:]
    public init() {}

    public func invalidateMetadataCache() { lock.withLock { catalogs.removeAll() } }

    private func candidates(named name: String, under root: URL) -> [URL] {
        lock.withLock {
            if let cached = catalogs[root], Date().timeIntervalSince(cached.at) < 60 {
                return cached.names[name] ?? []
            }
            var names: [String: [URL]] = [:]
            if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in walk {
                    if Task.isCancelled { return [] } // Never retain a partial catalog.
                    names[file.lastPathComponent, default: []].append(file)
                }
            }
            catalogs[root] = Catalog(at: Date(), names: names)
            return names[name] ?? []
        }
    }

    /// A file is *present* when its path exists and it is not a directory. Nothing is read, so
    /// an online-only iCloud or Drive copy is still found; the read happens when it is opened.
    private func contained(_ url: URL, in root: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }

    private func present(_ url: URL, in root: URL) -> Bool {
        guard contained(url, in: root) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return !isDir.boolValue
    }

    /// The recorded size comes from the phone's own export, and a copy that was re-encoded or
    /// re-exported can differ by a few bytes; an online-only copy has no local size at all.
    /// So a size only ever *confirms* a hit, it never vetoes one — `nil` means "cannot tell".
    private func sizeConfirms(_ url: URL, _ recorded: Int64?) -> Bool? {
        guard let recorded, recorded > 0 else { return nil }
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = v.fileSize, size > 0 else {
            return nil   // a placeholder: size unknown until it is downloaded, so it cannot veto
        }
        return Int64(size) == recorded
    }

    /// Metadata-only lookup. A path the archive itself recorded is authoritative: the folder and
    /// the hashed filename in it identify the attachment, so its presence is the answer — and it
    /// is answered without a read, which is the only way an online-only Drive copy can answer.
    /// Size still gates a filename-only hit, where nothing else says which attachment it is.
    public func resolve(_ media: ChatMedia, sources: [URL], driveRoots: [URL]) -> URL? {
        guard let path = media.filePath, !path.isEmpty else { return nil }
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.contains(".."), let name = parts.last else { return nil }
        var relativePaths = [parts.joined(separator: "/")]
        if let i = parts.firstIndex(of: "Media") {
            relativePaths.append(parts[i...].joined(separator: "/"))
            relativePaths.append(parts.dropFirst(i + 1).joined(separator: "/"))
        }
        // All exact local paths precede local filename fallback; Drive is tried last.
        for roots in [sources, driveRoots] {
            for root in roots {
                for relative in relativePaths where !relative.isEmpty {
                    let file = root.appendingPathComponent(relative)
                    if present(file, in: root) { return file }
                }
            }
            // A filename alone is not enough to identify an attachment safely: it needs the
            // recorded size, and a placeholder whose local size is unknown cannot supply it.
            guard let recorded = media.size, recorded > 0 else { continue }
            for root in roots {
                for file in candidates(named: name, under: root) {
                    if Task.isCancelled { return nil }
                    guard present(file, in: root), sizeConfirms(file, recorded) == true else { continue }
                    return file
                }
            }
        }
        return nil
    }

    /// Makes an online-only copy readable now. Drive and Dropbox materialise on open; iCloud
    /// needs to be told. Returns the same URL: the reader opens it either way.
    @discardableResult
    public static func materialise(_ url: URL) -> URL {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true,
           v.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        return url
    }

    /// Lists only the immediate mount directory, one root per signed-in Google Drive account.
    /// No recursive scan, no content reads, and no assumption about the user's folder layout:
    /// the root searched is the account's "My Drive", never a named subfolder.
    public static func driveRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let mounts = home.appendingPathComponent("Library/CloudStorage")
        return ((try? FileManager.default.contentsOfDirectory(at: mounts, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
            .sorted { $0.path < $1.path }
            .map { $0.appendingPathComponent("My Drive") }
    }
}
