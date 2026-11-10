import SwiftUI
import AppKit

/// Decoded thumbnails, kept in memory so scrolling back up a long gallery does not refetch
/// and re-decode the same covers. Bounded, because a 5,000-link page must not hoard memory.
@MainActor
enum ThumbnailCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    static func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    static func store(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

/// A remote or local thumbnail that checks the memory cache before touching the network.
struct CachedThumbnail: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.black.opacity(0.18)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let hit = ThumbnailCache.image(for: url) {
                image = hit
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = NSImage(data: data) else { return }
            ThumbnailCache.store(decoded, for: url)
            image = decoded
        }
    }
}
