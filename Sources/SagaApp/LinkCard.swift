import SwiftUI
import SagaCore

/// A player card: cover, title, service, date. Drawn the way a streaming service draws its
/// own cards, so a shared link reads at a glance instead of as a line of text.
struct LinkCard: View {
    let link: SharedLink
    let times: Int
    let meta: LinkMeta?
    let open: () -> Void
    let jump: () -> Void
    let copy: () -> Void

    @State private var loaded: LinkMeta?

    /// The card resolves its own metadata when it appears, so a gallery of a thousand links
    /// costs one request per card the reader actually looks at.
    private var shown: LinkMeta? { loaded ?? meta }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            caption
        }
        .task(id: link.id) {
            guard meta == nil, loaded == nil else { return }
            loaded = await LinkMetaLoader.shared.meta(for: link)
        }
        .cardSurface(radius: AppTheme.Radius.panel)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.panel))
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Show the message that shared it", action: jump)
            Button("Copy link", action: copy)
            Button("Open in browser", action: open)
        }
    }

    private var cover: some View {
        // A square that is measured by width and clipped once, so a 16:9 YouTube still
        // cannot spill over the neighbouring card.
        Rectangle()
            .fill(.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    artwork
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.5)],
                                   startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.black.opacity(0.45)))
                            .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                        Spacer()
                        if times > 1 {
                            Text("\(times)×")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.black.opacity(0.45)))
                        }
                    }
                    .padding(9)
                }
            }
            .clipped()
    }

    /// YouTube thumbnails need no API: the video id is in the link, and the still lives at a
    /// predictable URL. That is why a YouTube card gets a cover even when oEmbed is rate
    /// limited or the title could not be read.
    private var coverURL: URL? {
        if let thumb = shown?.thumbnail, let url = URL(string: thumb) { return url }
        if let id = link.youtubeID, !id.isEmpty {
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        return nil
    }

    @ViewBuilder private var artwork: some View {
        if let url = coverURL {
            CachedThumbnail(url: url)
        } else {
            serviceField
        }
    }

    private var serviceField: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: link.service.symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var colors: [Color] {
        switch link.service {
        case .spotify: [Color(red: 0.18, green: 0.62, blue: 0.36), Color(red: 0.09, green: 0.30, blue: 0.19)]
        case .appleMusic: [Color(red: 0.96, green: 0.35, blue: 0.42), Color(red: 0.55, green: 0.10, blue: 0.35)]
        case .youtube, .youtubeMusic: [Color(red: 0.78, green: 0.12, blue: 0.12), Color(red: 0.33, green: 0.05, blue: 0.08)]
        case .soundCloud: [Color(red: 0.95, green: 0.51, blue: 0.16), Color(red: 0.48, green: 0.20, blue: 0.06)]
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(captionTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Image(systemName: link.service.symbol).font(.system(size: 9))
                Text(captionSubtitle).lineLimit(1)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(AppTheme.Surface.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var captionTitle: String {
        if let t = shown?.title, !t.isEmpty { return t }
        if let slug = link.slugTitle, !slug.isEmpty { return slug }
        guard let u = URL(string: link.url) else { return link.url }
        let last = u.lastPathComponent.replacingOccurrences(of: "-", with: " ")
        // A bare id is not a title. Say what the thing is instead of showing the hash.
        let isOpaque = last.range(of: "^[A-Za-z0-9]{16,}$", options: .regularExpression) != nil
        if !last.isEmpty, last != "/", !isOpaque { return last.removingPercentEncoding ?? last }
        if isOpaque { return "\(link.service.rawValue) \(link.kind)" }
        return u.host ?? link.url
    }

    private var captionSubtitle: String {
        if let a = shown?.author, !a.isEmpty { return a }
        let chat = link.chatName.isEmpty ? link.ts.formatted(.dateTime.day().month(.abbreviated)) : link.chatName
        return "\(link.service.rawValue) · \(chat)"
    }
}
