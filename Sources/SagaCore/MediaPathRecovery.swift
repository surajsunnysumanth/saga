import Foundation

/// One rule for the media rows the phone never downloaded: identical content may donate a path,
/// nothing else may.
///
/// When WhatsApp has not downloaded a piece of media, its `message_media` row carries no
/// `file_path` — only a hash, a media key and a CDN location. The same bytes often reach the
/// archive twice anyway: a forward, a "keep in chat", or an older/newer backup of the same
/// message. The copy that *was* downloaded has a real path on disk, and `file_hash` is the
/// SHA-256 of the plaintext file, so matching that hash identifies the same bytes without
/// trusting a filename, a size or an extension.
///
/// A size-only or name-only match is deliberately not accepted: those produce plausible paths
/// for the wrong file, which is worse than an honest miss — the Gallery would open a photo the
/// conversation never contained.
public struct MediaPathIndex: Sendable {
    private var byHash: [String: String] = [:]

    public init() {}

    /// Remembers the first usable path seen for a piece of content.
    public mutating func record(hash: String?, path: String?) {
        guard let h = Self.cleanHash(hash), let p = Self.cleanPath(path) else { return }
        if byHash[h] == nil { byHash[h] = p }
    }

    /// The path already on record for identical content, if there is one.
    public func path(for hash: String?) -> String? {
        guard let h = Self.cleanHash(hash) else { return nil }
        return byHash[h]
    }

    public var count: Int { byHash.count }

    /// A path that is worth storing: present, not blank.
    public static func cleanPath(_ path: String?) -> String? {
        guard let p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p
    }

    /// A hash that is worth matching on: present, not blank.
    public static func cleanHash(_ hash: String?) -> String? {
        guard let h = hash?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        return h
    }

    /// The exact shape a recovery can fix: no path, but a hash to recognise the file by.
    public static func needsPath(_ path: String?, hash: String?) -> Bool {
        cleanPath(path) == nil && cleanHash(hash) != nil
    }
}
