import Foundation

/// The media list identifies each row by the item its link points at. A short share
/// link (`spotify.link`, `on.soundcloud.com`) only learns that identity after it is
/// expanded, so the same song can arrive twice: once as the short link, once as the
/// full link. Once a row resolves, the list should keep one row per item.
public enum MediaLinkFolding {
    /// Index of the other row that already shows `key`, so the newer row can be folded
    /// into it. The earlier row wins, and rows that were themselves expanded count.
    /// Rows from different chats never fold: "Everywhere" shows one row per chat.
    /// - Parameters:
    ///   - key: the item key a row resolved to (e.g. `sp:…`, `sc:…`).
    ///   - items: the list in display order.
    ///   - resolved: item keys learned by expansion, by row id. Missing ids use the row's own key.
    ///   - id: the row that just resolved; never matches itself.
    ///   - chatID: the chat of the row that just resolved.
    public static func duplicateIndex(of key: String, in items: [(link: SharedLink, times: Int)],
                                      resolved: [String: String], excluding id: String, chatID: Int64) -> Int? {
        items.indices.first { index in
            let row = items[index].link
            return row.id != id && row.chatID == chatID && (resolved[row.id] ?? row.key) == key
        }
    }
}
