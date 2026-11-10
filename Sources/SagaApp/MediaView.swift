import SwiftUI
import WebKit
import SagaCore

/// Fetches titles/artwork from Spotify and YouTube (only when the user has allowed it), a few at a time, and remembers them.
actor MetaLoader {
    static let shared = MetaLoader()
    private var cache: LinkMetaCache?
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inflight: [String: Task<LinkMeta?, Never>] = [:]
    private var resolving: [String: Task<SharedLink, Never>] = [:]

    func resolve(_ link: SharedLink, allowNetwork: Bool) async -> SharedLink {
        guard link.embedURL.isEmpty else { return link }
        if !allowNetwork { return await MediaLinks.resolve(link, allowNetwork: false, cache: db()) }
        if let task = resolving[link.key] { return await task.value }
        let cache = db()
        let task = Task {
            await self.acquire(); defer { self.release() }
            return await MediaLinks.resolve(link, allowNetwork: true, cache: cache)
        }
        resolving[link.key] = task
        let result = await task.value
        resolving[link.key] = nil
        return result
    }

    private func db() -> LinkMetaCache? {
        if cache == nil { cache = try? LinkMetaCache(path: AppModel.supportDir.appendingPathComponent("link_meta.db").path) }
        return cache
    }
    func cached(_ l: SharedLink) -> LinkMeta? { db()?.get(l.key) }

    func meta(_ original: SharedLink, allowNetwork: Bool) async -> LinkMeta? {
        let l = await resolve(original, allowNetwork: allowNetwork)
        guard !l.embedURL.isEmpty else { return nil }
        if let m = db()?.get(l.key) { return m }
        if l.service == .appleMusic, let m = await MediaLinks.fetchMeta(l) { return m }   // from the URL itself, no network
        guard allowNetwork else { return nil }
        if let t = inflight[l.key] { return await t.value }
        let t = Task<LinkMeta?, Never> {
            await self.acquire(); defer { Task { await self.release() } }
            return await MediaLinks.fetchMeta(l)
        }
        inflight[l.key] = t
        let m = await t.value
        inflight[l.key] = nil
        if let m { db()?.put(l.key, m) }
        return m
    }
    private func acquire() async {
        if running < 4 { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() { if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() } }
}

@MainActor @Observable
final class MediaBrowser {
    enum Scope: String, CaseIterable { case chat = "This chat", all = "Everywhere" }
    var chat: ChatRow?
    var scope: Scope = .chat
    var services = Set(MediaService.allCases)
    var newestFirst = false
    var items: [(link: SharedLink, times: Int)] = []
    var loading = false
    var expanded: String?
    var collapsed = Set<String>()          // cards closed by hand while "Show players" is on
    var folded: [String: String] = [:]     // row id -> the item key it resolved to (short links)

    var shown: [(link: SharedLink, times: Int)] {
        let f = items.filter { services.contains($0.link.service) }
        return newestFirst ? f.reversed() : f
    }
    var counts: [MediaService: Int] { Dictionary(grouping: items, by: { $0.link.service }).mapValues(\.count) }

    func open(chat c: ChatRow?, model: AppModel) {
        chat = c; scope = c == nil ? .all : .chat; expanded = nil
        reload(model: model)
    }
    func reload(model: AppModel) {
        guard model.store != nil else { return }
        let path = model.indexURL.path, cid: Int64? = scope == .chat ? chat?.id : nil
        loading = true; items = []; folded = [:]
        Task {
            let r = await Task.detached { () -> [(link: SharedLink, times: Int)] in
                (try? VaultStore(path: path)).flatMap { try? $0.sharedLinks(chat: cid) } ?? []
            }.value
            items = r; loading = false
        }
    }
    /// A short link that turns out to name an item already listed is one row, not two:
    /// the earlier row keeps the place and the share counts add up.
    func fold(_ resolved: SharedLink, replacing id: String) {
        guard let i = items.firstIndex(where: { $0.link.id == id }) else { return }
        folded[id] = resolved.key
        guard let j = MediaLinkFolding.duplicateIndex(of: resolved.key, in: items, resolved: folded, excluding: id, chatID: resolved.chatID) else { return }
        let keep = min(i, j), drop = max(i, j)
        let droppedID = items[drop].link.id
        items[keep].times += items[drop].times
        folded[items[keep].link.id] = resolved.key
        items.remove(at: drop)
        folded[droppedID] = nil
    }

    var youtubeIDs: [String] { shown.compactMap(\.link.youtubeID) }
}

// MARK: - Player

struct EmbedView: NSViewRepresentable {
    let url: String
    let height: CGFloat

    func makeCoordinator() -> MediaPlayerCoordinator { MediaPlayerCoordinator() }
    func makeNSView(context: Context) -> PlayerBoxView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.userContentController.add(context.coordinator, name: "sagaPlayback")
        cfg.userContentController.addUserScript(WKUserScript(source: MediaPlayerPage.mediaEvents, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = w
        context.coordinator.load(url: url, height: Int(height))
        return PlayerBoxView(web: w)
    }
    func updateNSView(_ box: PlayerBoxView, context: Context) {
        if context.coordinator.url != url || context.coordinator.height != Int(height) {
            context.coordinator.load(url: url, height: Int(height))
        }
    }
    static func dismantleNSView(_ box: PlayerBoxView, coordinator: MediaPlayerCoordinator) {
        coordinator.dismantle()
    }
}

func embedHeight(_ l: SharedLink, width: CGFloat) -> CGFloat {
    switch l.service {
    case .spotify: return l.kind == "track" || l.kind == "episode" ? 152 : 352
    case .soundCloud: return l.kind == "playlist" ? 450 : 166
    case .appleMusic: return l.kind == "track" ? 175 : 450
    case .youtube, .youtubeMusic: return l.kind == "playlist" ? width * 9 / 16 + 40 : width * 9 / 16
    }
}

// MARK: - List

struct MediaPanelView: View {
    @Environment(AppModel.self) var model
    @AppStorage("loadLinkPreviews") private var previews = false
    @AppStorage("showPlayers") private var showPlayers = false

    var body: some View {
        @Bindable var b = model.media
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(b.scope == .chat ? (b.chat?.name ?? "Music & video") : "Music & video from every chat").font(.headline).lineLimit(1)
                Spacer()
            }
            HStack {
                if b.chat != nil {
                    Picker("", selection: $b.scope) { ForEach(MediaBrowser.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .onChange(of: b.scope) { _, _ in b.reload(model: model) }
                }
                Picker("", selection: $b.newestFirst) { Text("Oldest first").tag(false); Text("Newest first").tag(true) }.labelsHidden().fixedSize()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MediaService.allCases, id: \.self) { s in
                        let n = b.counts[s] ?? 0
                        if n > 0 {
                            Toggle(isOn: Binding(get: { b.services.contains(s) }, set: { on in if on { b.services.insert(s) } else { b.services.remove(s) } })) {
                                Label("\(s.rawValue) \(n.formatted())", systemImage: s.symbol).font(.caption)
                            }.toggleStyle(.button).controlSize(.small)
                        }
                    }
                }
            }
            Toggle(isOn: $previews) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show titles and artwork").font(.callout)
                    Text(previews ? "Shared links are sent to Spotify, YouTube or SoundCloud for titles/artwork and to Spotify or SoundCloud to expand short links. Results are saved on this Mac." : "Off: no title fetching or short-link requests. Cached titles can still appear; opening a player or external link contacts its service.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).controlSize(.small)
            Toggle(isOn: $showPlayers) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show players").font(.callout)
                    Text("Every card opens its player as you scroll (loads from Spotify/YouTube/Apple). Starting one pauses the others, or unloads players that cannot pause. Off: tap play on the ones you want.").font(.caption2).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).controlSize(.small)
                .onChange(of: showPlayers) { _, _ in b.expanded = nil; b.collapsed = [] }
            HStack(spacing: 12) {
                if let u = MediaLinks.youtubePlaylistURL(ids: b.youtubeIDs) {
                    Button { NSWorkspace.shared.open(u) } label: { Label("Play YouTube as playlist (first \(min(50, Set(b.youtubeIDs).count)))", systemImage: "play.square.stack") }
                        .buttonStyle(.link).help("Opens a temporary YouTube playlist in your browser, in the order shown")
                }
                Button { copyList(b.shown) } label: { Label("Copy list", systemImage: "doc.on.doc") }.buttonStyle(.link)
                Menu { Button("Playlist text (.m3u)") { export(b.shown, csv: false) }; Button("Spreadsheet (.csv)") { export(b.shown, csv: true) } } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .menuStyle(.borderlessButton).fixedSize().help("Save this list; titles included only if already saved on this Mac")
            }.font(.caption)
            Divider()
            if b.loading { HStack { ProgressView().controlSize(.small); Text("Looking for links…") } }
            else if b.shown.isEmpty {
                if b.items.isEmpty {
                    EmptyStateView(
                        symbol: "music.note.tv",
                        title: "No music or video yet",
                        message: b.scope == .chat
                            ? "Nobody has shared a Spotify, YouTube or Apple Music link in this chat yet."
                            : "No chat in your archive has shared a music or video link yet.",
                        colors: AppTheme.Module.music.colors,
                        compact: true)
                } else {
                    EmptyStateView(
                        symbol: "line.3.horizontal.decrease.circle",
                        title: "Every service is hidden",
                        message: "Turn a service back on above to see the links that came from it.",
                        colors: AppTheme.Module.music.colors,
                        actionTitle: "Show all services",
                        action: { b.services = Set(MediaService.allCases) },
                        compact: true)
                }
            }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups(b.shown), id: \.title) { g in
                            Section {
                                ForEach(g.items, id: \.link.id) { it in
                                    LinkRow(item: it, previews: previews, showChat: b.scope == .all, showPlayers: showPlayers)
                                }
                            } header: {
                                Text(g.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).background(.bar)
                            }
                        }
                    }
                }
                Text("\(b.shown.count.formatted()) item\(b.shown.count == 1 ? "" : "s"). Play opens the official player inside Saga.").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(14)
        .task(id: "\(b.items.count)|\(previews)") { await prefetch(b.items.map(\.link)) }
    }

    /// Warms the title cache for the whole list (a few requests at a time) so scrolling shows titles immediately.
    func prefetch(_ links: [SharedLink]) async {
        guard previews, links.count <= 600 else { return }
        for l in links { if Task.isCancelled { return }; _ = await MetaLoader.shared.meta(l, allowNetwork: true) }
    }

    struct Group { let title: String; var items: [(link: SharedLink, times: Int)] }
    func groups(_ items: [(link: SharedLink, times: Int)]) -> [Group] {
        // Append in place: copying each group's array per item is quadratic once a
        // single month holds thousands of links.
        var out: [Group] = []
        var current = ""
        for it in items {
            let t = it.link.ts.formatted(.dateTime.month(.wide).year())
            if out.isEmpty || t != current {
                out.append(Group(title: t, items: [it])); current = t
            } else {
                out[out.count - 1].items.append(it)
            }
        }
        return out
    }
    func export(_ items: [(link: SharedLink, times: Int)], csv: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = csv ? "saga-music-links.csv" : "saga-music-links.m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            var rows: [(link: SharedLink, title: String?, times: Int)] = []
            for it in items { rows.append((it.link, await MetaLoader.shared.cached(it.link)?.title, it.times)) }
            let text = csv ? MediaLinkExport.csv(rows) : MediaLinkExport.m3u(rows.map { ($0.link, $0.title) })
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    func copyList(_ items: [(link: SharedLink, times: Int)]) {
        let text = items.map { "- \($0.link.ts.formatted(date: .abbreviated, time: .omitted)) · \($0.link.service.rawValue) · \($0.link.url)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

struct LinkRow: View {
    @Environment(AppModel.self) var model
    let item: (link: SharedLink, times: Int)
    let previews: Bool
    let showChat: Bool
    let showPlayers: Bool
    @State private var meta: LinkMeta?
    @State private var loading = false
    @State private var resolved: SharedLink?

    var body: some View {
        let l = resolved ?? item.link
        let open = !l.embedURL.isEmpty && (showPlayers ? !model.media.collapsed.contains(item.link.id) : model.media.expanded == item.link.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                thumb(l).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta?.title ?? l.slugTitle ?? (loading ? "Loading title…" : "\(l.service.rawValue) \(l.kind)"))
                        .foregroundStyle(meta == nil && l.slugTitle == nil ? .secondary : .primary).lineLimit(2).font(.callout.weight(.medium))
                    if let a = meta?.author, !a.isEmpty { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Text("\(l.ts.formatted(date: .abbreviated, time: .omitted)) · \(l.fromMe ? "You" : l.sender)" + (showChat ? " · \(l.chatName)" : "") + (item.times > 1 ? " · shared \(item.times)×" : ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Button { toggle(item.link.id, open: open) } label: { Image(systemName: open ? "stop.circle.fill" : "play.circle.fill").font(.title2) }
                        .buttonStyle(.borderless).disabled(l.embedURL.isEmpty).help(l.embedURL.isEmpty ? "Turn on titles to resolve this short link, or open it in \(l.service.rawValue)" : open ? "Close player" : "Play here")
                    HStack(spacing: 8) {
                        Button { model.jump(toMessage: l.messageID, in: l.chatID) } label: { Image(systemName: "arrow.turn.down.right") }.help("Jump to the message")
                        Button { if let u = URL(string: l.url) { NSWorkspace.shared.open(u) } } label: { Image(systemName: "arrow.up.right.square") }.help("Open in \(l.service.rawValue)")
                    }.buttonStyle(.borderless).font(.caption)
                }
            }
            if open { EmbedView(url: l.embedURL, height: embedHeight(l, width: 340)).frame(height: embedHeight(l, width: 340)) }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(open ? 0.5 : 0.25)))
        .task(id: "\(item.link.key)|\(previews)") {
            loading = previews
            let target = await MetaLoader.shared.resolve(item.link, allowNetwork: previews)
            guard !Task.isCancelled else { return }
            resolved = target
            if target.key != item.link.key { model.media.fold(target, replacing: item.link.id) }
            let title = await MetaLoader.shared.meta(target, allowNetwork: previews)
            guard !Task.isCancelled else { return }
            meta = title; loading = false
        }
    }

    func toggle(_ id: String, open: Bool) {
        if showPlayers { if open { model.media.collapsed.insert(id) } else { model.media.collapsed.remove(id) } }
        else { model.media.expanded = open ? nil : id }
    }

    @ViewBuilder func thumb(_ l: SharedLink) -> some View {
        if previews, let t = meta?.thumbnail, let u = URL(string: t) {
            AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
        } else {
            ZStack { Color.gray.opacity(0.18); Image(systemName: l.service.symbol).font(.title3).foregroundStyle(.secondary) }
        }
    }
}
