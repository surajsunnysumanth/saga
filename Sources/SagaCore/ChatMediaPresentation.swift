import Foundation

/// How a bubble presents its attachment. Pure logic so it can be tested without UI.
public enum ChatMediaPresentation: Equatable, Sendable {
    /// Image or video poster: thumbnail loads when the bubble appears.
    case thumbnail
    /// Voice note / audio: play control; the file is resolved only on tap.
    case audio
    /// Document or other file: icon, opened on tap.
    case file
    /// Nothing recorded for this attachment: plain label, no fetching.
    case labelOnly

    public init(_ media: ChatMedia?) {
        guard let media, media.filePath?.isEmpty == false else { self = .labelOnly; return }
        switch media.kind {
        case "image", "video", "sticker": self = .thumbnail
        case "audio": self = .audio
        default: self = .file
        }
    }

    /// Only thumbnails are fetched on appear; everything else waits for an explicit tap.
    public var loadsOnAppear: Bool { self == .thumbnail }
}

/// Load state shown in a bubble.
public enum ChatMediaLoadState: Equatable, Sendable {
    case idle, loading, loaded(URL), missing
}
