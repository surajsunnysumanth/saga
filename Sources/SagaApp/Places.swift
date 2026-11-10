import SwiftUI
import AppKit
import SagaCore

// MARK: - Gallery

/// What a gallery body is looking at. The Gallery place browses `everywhere`; a chat's
/// Media tab is the same browser pinned to one conversation, so photos, video, voice notes,
/// music, links and documents look and behave identically in both places.
enum GalleryScope: Equatable {
    case everywhere
    case chat(id: Int64, name: String)

    var chatID: Int64? {
        if case .chat(let id, _) = self { return id }
        return nil
    }
    var chatName: String? {
        if case .chat(_, let name) = self { return name }
        return nil
    }
    var isChat: Bool { chatID != nil }
    /// Stable identity for `.task(id:)`, so switching chats reloads and the Gallery place does not.
    var key: String { chatID.map { "chat-\($0)" } ?? "all" }
}

/// Everything the archive holds, browsed as cards. Images, video and documents come from
/// the media index; music and links come from the shared-link index and are drawn the way
/// a player card would be, because that is what people recognise.
struct GalleryView: View {
    var body: some View {
        GlassPanel(radius: AppTheme.Radius.card, padding: 0) {
            GalleryBody(scope: .everywhere)
        }
    }
}

/// The reusable browser. It carries the kind tabs, the filters and every card treatment;
/// the caller decides only whether it is scoped to a conversation. In a chat the header
/// shows the chat's own counts and the conversation filter is a pinned, non-editable chip —
/// the reader is already inside that chat, so a picker there is noise.
struct GalleryBody: View {
    @Environment(AppModel.self) private var model
    let scope: GalleryScope

    @State private var kind: Kind = Kind(rawValue: ProcessInfo.processInfo.environment["SAGA_GALLERY_KIND"] ?? "") ?? .images
    @State private var counts: [String: Int] = [:]
    @State private var items: [MediaItem] = []
    @State private var mediaFiles: [Int64: URL] = [:]
    @State private var voiceNotes: [VoiceNote] = []
    @State private var voiceFiles: [Int64: URL] = [:]
    @StateObject private var voicePlayer = VoiceNotePlayer()
    @State private var links: [(link: SharedLink, times: Int)] = []
    @State private var metas: [String: LinkMeta] = [:]
    @State private var loading = false

    @State private var chatFilter: Int64?
    /// Built from the chat list once, so typing in the conversation filter never walks
    /// thousands of chats to decide what to draw.
    @State private var chatIndex: ChatFilterIndex?
    @State private var yearFilter: Int?
    @State private var sort: Sort = .newest
    @State private var years: [Int] = []
    @State private var loadToken = 0
    /// The filtered, sorted list the grid draws. Computed once per state change instead of
    /// on every body evaluation: with five thousand links, doing this inside `body` is what
    /// made the page crawl.
    @State private var displayed: [(link: SharedLink, times: Int)] = []
    /// The whole filtered list, and how much of it the grid is currently showing. A page of
    /// a few hundred is enough to fill any screen; growing the grid a page at a time keeps
    /// SwiftUI from building five thousand cards' worth of state on first paint.
    @State private var filtered: [(link: SharedLink, times: Int)] = []
    @State private var page = 240
    @State private var musicCount = 0
    @State private var linkCount = 0
    /// Which scope the link list was loaded for, so switching chats reloads it even though the
    /// view identity is reused and the Gallery place never re-reads its links.
    @State private var loadedScope: String?

    enum Kind: String, CaseIterable, Identifiable {
        case images = "Images", video = "Video", audio = "Voice notes", music = "Music", links = "Links", documents = "Documents"
        var id: String { rawValue }
        var indexKind: String? {
            switch self {
            case .images: "image"
            case .video: "video"
            case .audio: "audio"
            case .documents: "doc"
            case .music, .links: nil
            }
        }
        var isLinkList: Bool { self == .music || self == .links }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest first", oldest = "Oldest first", conversation = "By conversation", mostShared = "Most shared"
        var id: String { rawValue }
        var media: MediaSort {
            switch self {
            case .oldest: .oldest
            case .conversation: .about
            default: .newest
            }
        }
    }

    private var availableSorts: [Sort] { kind.isLinkList ? [.newest, .oldest, .mostShared] : Sort.allCases }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            filterBar
            Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1)
            content
        }
        .task(id: scope.key) {
            // A chat swap is a different library: drop the previous chat's links before reading.
            guard loadedScope != scope.key else { await loadCounts(); return }
            loadedScope = scope.key
            links = []; filtered = []; displayed = []
            await loadCounts()
        }
        .task(id: model.galleryTab) {
            // A place change can name the tab it wants (Home's Music tile). The request is
            // consumed once, so browsing on from there behaves normally.
            guard !scope.isChat, let raw = model.galleryTab, let wanted = Kind(rawValue: raw) else { return }
            if wanted != kind { kind = wanted }
            model.galleryTab = nil
        }
        .task(id: model.chats.count) {
            // One pass over the chat list per library load; the field itself only ever looks
            // at this index. A chat's Media tab does not offer the picker, so it never builds it.
            guard !scope.isChat else { return }
            let rows = model.chats.map { ChatFilterIndex.Entry(id: $0.id, name: $0.name, jid: $0.jid) }
            chatIndex = await Task.detached { ChatFilterIndex(rows) }.value
        }
        .task(id: "prefetch-\(loadToken)-\(kind.rawValue)-\(sort.rawValue)-\(effectiveChat.map(String.init) ?? "all")-\(String(describing: yearFilter))-\(scope.key)") {
            await prefetchVisibleTitles()
        }
        .task(id: "\(scope.key)-\(kind.rawValue)-\(sort.rawValue)-\(effectiveChat.map(String.init) ?? "all")-\(String(describing: yearFilter))") {
            if kind.isLinkList, sort == .conversation { sort = .newest; return }
            if !kind.isLinkList, sort == .mostShared { sort = .newest; return }
            if kind.isLinkList { refreshDisplay() }
            await loadItems()
        }
    }

    /// The conversation everything is filtered to: pinned when this body belongs to a chat,
    /// otherwise whatever the Gallery's own filter field says.
    private var effectiveChat: Int64? { scope.chatID ?? chatFilter }

    // MARK: header

    /// The Gallery place keeps its one-line header. A chat pane is narrower — six tabs plus a
    /// title do not fit at the minimum window width — so there the tabs take their own line,
    /// left-aligned, and scroll if the window gets narrower still. Nothing is hidden off the edge.
    @ViewBuilder private var header: some View {
        if scope.isChat {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.m) {
                    titleText
                    subtitleText
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) { kindTabs }
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.top, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.m)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.m) {
                titleText
                subtitleText
                Spacer(minLength: AppTheme.Spacing.s)
                kindTabs
            }
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.top, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.m)
        }
    }

    private var titleText: some View {
        Text(scope.isChat ? "Media" : "Gallery")
            .font(AppTheme.Typography.display)
            .tracking(AppTheme.Typography.displayTracking)
            .foregroundStyle(AppTheme.Surface.textPrimary)
            .fixedSize()
    }

    private var subtitleText: some View {
        Text(scope.isChat ? "everything this chat shared"
                          : "across \(model.stats?.chats.formatted() ?? "—") chats")
            .font(AppTheme.Typography.callout)
            .foregroundStyle(AppTheme.Surface.textSecondary)
            .lineLimit(1)
    }

    private var kindTabs: some View {
        HStack(spacing: 2) {
            ForEach(Kind.allCases) { k in
                Button { kind = k } label: {
                    HStack(spacing: 5) {
                        Text(k.rawValue)
                        if let n = count(for: k) {
                            Text(n.formatted())
                                .foregroundStyle(AppTheme.Surface.textTertiary)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 12.5, weight: kind == k ? .semibold : .regular))
                    .foregroundStyle(kind == k ? AppTheme.Surface.textPrimary : AppTheme.Surface.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(kind == k ? AppTheme.Glass.fill.opacity(0.14) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.Glass.fill.opacity(0.07)))
    }

    private var filterBar: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            if let name = scope.chatName {
                PinnedChatChip(name: name)
            } else {
                GalleryConversationFilter(index: chatIndex, selection: chatFilter) { chatFilter = $0 }
            }

            Menu {
                Button("All years") { yearFilter = nil }
                Divider()
                ForEach(years, id: \.self) { y in
                    Button(String(y)) { yearFilter = y }
                }
            } label: {
                FilterChip(text: yearFilter.map(String.init) ?? "All years", active: yearFilter != nil)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                ForEach(availableSorts) { s in
                    Button {
                        sort = s
                    } label: {
                        if s == sort { Label(s.rawValue, systemImage: "checkmark") } else { Text(s.rawValue) }
                    }
                }
            } label: {
                FilterChip(text: sort.rawValue, active: sort != .newest)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer(minLength: AppTheme.Spacing.s)
            Text("\((kind.isLinkList ? filtered.count : kind == .audio ? voiceNotes.count : items.count).formatted()) \(kind.isLinkList ? "links" : kind == .audio ? "voice notes" : "items")")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Surface.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.bottom, AppTheme.Spacing.m)
        .zIndex(1)      // the conversation filter's results draw over the grid below
    }

    private func count(for k: Kind) -> Int? {
        switch k {
        case .music: return musicCount == 0 ? nil : musicCount
        case .links: return linkCount == 0 ? nil : linkCount
        default: return k.indexKind.flatMap { counts[$0] }
        }
    }

    // MARK: body

    @ViewBuilder private var content: some View {
        if kind.isLinkList {
            linkGrid
        } else if kind == .audio {
            voiceList
        } else if loading && items.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            EmptyStateView(symbol: mediaEmptySymbol,
                           title: mediaEmptyTitle,
                           message: mediaEmptyMessage,
                           colors: AppTheme.Module.chats.colors)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: mediaColumns, spacing: 12) {
                    ForEach(items) { (item: MediaItem) in
                        mediaCell(item)
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
    }

    /// Empty states name the kind and say whose shelf is empty. In a chat "Nothing here yet"
    /// is misleading — the archive has media, this conversation just does not share that kind.
    private var mediaEmptyTitle: String {
        guard scope.isChat else { return "Nothing here yet" }
        switch kind {
        case .images: return "No photos in this chat"
        case .video: return "No video in this chat"
        case .documents: return "No documents in this chat"
        default: return "Nothing in this chat yet"
        }
    }

    private var mediaEmptyMessage: String {
        guard scope.isChat else { return "Media appears once the archive has imported attachments." }
        switch kind {
        case .images: return "Photos this conversation shared will appear here."
        case .video: return "Video this conversation shared will appear here."
        case .documents: return "Documents this conversation shared will appear here."
        default: return "Attachments this conversation shared will appear here."
        }
    }

    private var mediaEmptySymbol: String {
        guard scope.isChat else { return "photo.on.rectangle.angled" }
        switch kind {
        case .video: return "video"
        case .documents: return "doc.text"
        default: return "photo.on.rectangle.angled"
        }
    }

    /// Voice notes get a list, not a grid: there is no thumbnail that tells you who spoke,
    /// and in a group that is the only thing worth knowing before you press play.
    @ViewBuilder private var voiceList: some View {
        if loading && voiceNotes.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if voiceNotes.isEmpty {
            EmptyStateView(symbol: "waveform",
                           title: scope.isChat ? "No voice notes in this chat"
                                : (chatFilter == nil ? "No voice notes here" : "No voice notes in this conversation"),
                           message: scope.isChat
                                ? "Voice messages this conversation shared will appear here."
                                : "Voice messages appear here once the archive has imported them.",
                           colors: AppTheme.Module.chats.colors)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(voiceNotes) { note in
                        VoiceNoteRow(note: note,
                                     file: voiceFiles[note.id],
                                     player: voicePlayer,
                                     onJump: { model.jump(toMessage: note.id, in: note.chatID) },
                                     onFetch: { await fetchVoiceNote(note) })
                    }
                }
                .padding(AppTheme.Spacing.xl)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onDisappear { voicePlayer.stop() }
        }
    }

    private var mediaColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 12)]
    }

    private func mediaCell(_ item: MediaItem) -> some View {
        MediaCard(item: item, file: mediaFiles[item.id], showsChat: !scope.isChat) {
            model.jump(toMessage: item.id, in: item.chatID)
        }
    }

    // MARK: links

    /// Spotify, Apple Music, YouTube Music and SoundCloud are music by definition. YouTube
    /// is a mixed bag, so a video's own title decides: "Official video", "lyric video",
    /// "visualizer", "audio" and their variants are songs, not clips.
    private func isMusicLink(_ link: SharedLink) -> Bool {
        switch link.service {
        case .spotify, .appleMusic, .youtubeMusic, .soundCloud:
            return true
        case .youtube:
            let title = [metas[link.key]?.title, link.slugTitle, link.url]
                .compactMap { $0 }
                .joined(separator: " ")
            return title.range(of: Self.musicMarkers, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Phrases that mark a YouTube link as a song rather than a video.
    private static let musicMarkers = #"(official\s+(music\s+)?video|music\s+video|official\s+audio|lyric\s+video|lyrical\s+video|visuali[sz]er|with\s+lyrics|video\s+song|\baudio\s+only\b|\bmv\b|\bm\/v\b)"#

    /// Rebuilds the grid's list and the two link counts. Called when the source data or a
    /// filter changes, never from `body`.
    private func refreshDisplay(resetPaging: Bool = true) {
        linkCount = links.count
        musicCount = links.filter { isMusicLink($0.link) }.count

        var out = kind == .music ? links.filter { isMusicLink($0.link) } : links
        if let chat = effectiveChat { out = out.filter { $0.link.chatID == chat } }
        if let yearFilter {
            out = out.filter { Calendar.current.component(.year, from: $0.link.ts) == yearFilter }
        }
        switch sort {
        case .oldest: out.sort { $0.link.ts < $1.link.ts }
        case .mostShared: out.sort { ($0.times, $0.link.ts) > ($1.times, $1.link.ts) }
        default: out.sort { $0.link.ts > $1.link.ts }
        }
        filtered = out
        if resetPaging { page = 240 }
        displayed = Array(out.prefix(page))
    }

    /// Grows the grid by one page when the reader reaches the end of what is drawn.
    private func showMore() {
        guard displayed.count < filtered.count else { return }
        page += 240
        displayed = Array(filtered.prefix(page))
    }

    @ViewBuilder private var linkGrid: some View {
        if loading && links.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if displayed.isEmpty {
            EmptyStateView(symbol: kind == .music ? "music.note.list" : "link",
                           title: scope.isChat ? (kind == .music ? "No music in this chat" : "No links in this chat")
                                : (kind == .music ? "No music here" : "No links here"),
                           message: scope.isChat
                                ? "Links this conversation shared are filed here by service."
                                : "Links shared in a conversation are filed here by service.",
                           colors: AppTheme.Module.music.colors)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 232), spacing: 12)], spacing: 12) {
                    ForEach(displayed, id: \.link.id) { entry in
                        linkCard(entry.link, times: entry.times)
                    }
                }
                .padding(AppTheme.Spacing.xl)

                if displayed.count < filtered.count {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, AppTheme.Spacing.xl)
                        .onAppear(perform: showMore)
                }
            }
        }
    }

    private func linkCard(_ link: SharedLink, times: Int) -> some View {
        LinkCard(link: link, times: times, meta: metas[link.key],
                 open: { open(link) },
                 jump: { model.jump(toMessage: link.messageID, in: link.chatID) },
                 copy: {
                     NSPasteboard.general.clearContents()
                     NSPasteboard.general.setString(link.url, forType: .string)
                 })
    }


    private func open(_ link: SharedLink) {
        if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }
    }

    private func title(for link: SharedLink, meta: LinkMeta?) -> String {
        if let t = meta?.title, !t.isEmpty { return t }
        if let slug = link.slugTitle, !slug.isEmpty { return slug }
        guard let u = URL(string: link.url) else { return link.url }
        let last = u.lastPathComponent.replacingOccurrences(of: "-", with: " ")
        // A bare id is not a title. Say what the thing is instead of showing the hash.
        let isOpaque = last.range(of: "^[A-Za-z0-9]{16,}$", options: .regularExpression) != nil
        if !last.isEmpty, last != "/", !isOpaque { return last.removingPercentEncoding ?? last }
        if isOpaque { return "\(link.service.rawValue) \(link.kind)" }
        return u.host ?? link.url
    }

    private func subtitle(for link: SharedLink, meta: LinkMeta?) -> String {
        if let a = meta?.author, !a.isEmpty { return a }
        let chat = link.chatName.isEmpty ? link.ts.formatted(.dateTime.day().month(.abbreviated)) : link.chatName
        return "\(link.service.rawValue) · \(chat)"
    }

    // MARK: loading

    private func loadCounts() async {
        let path = model.indexURL.path
        let chat = scope.chatID
        counts = await Task.detached { (try? VaultStore(path: path).mediaCounts(chatID: chat)) ?? [:] }.value
        let mediaYears = await Task.detached { (try? VaultStore(path: path).mediaYears(chatID: chat)) ?? [] }.value
        if links.isEmpty {
            let all = await Task.detached { (try? VaultStore(path: path).sharedLinks(chat: chat)) ?? [] }.value
            links = all
            loadToken += 1
            refreshDisplay()
            let linkYears = Set(all.map { Calendar.current.component(.year, from: $0.link.ts) })
            years = Array(Set(mediaYears).union(linkYears)).sorted(by: >)
            await resolveMeta(all)
        } else {
            years = mediaYears
        }
    }

    private func loadItems() async {
        let path = model.indexURL.path
        loading = true
        if kind.isLinkList {
            if links.isEmpty {
                let all = await Task.detached { (try? VaultStore(path: path).sharedLinks(chat: scope.chatID)) ?? [] }.value
                links = all
                loadToken += 1
                await resolveMeta(all)
                refreshDisplay()
            }
            loading = false
            return
        }
        guard let indexKind = kind.indexKind else { items = []; loading = false; return }
        let chat = effectiveChat, year = yearFilter, s = sort.media
        if kind == .audio {
            let loaded = await Task.detached {
                (try? VaultStore(path: path).voiceNotes(chatID: chat, year: year, sort: s, limit: 400)) ?? []
            }.value
            voiceNotes = loaded
            voiceFiles = await resolveVoiceFiles(loaded)
            loading = false
            // The phone is asked only after the screen has been drawn from what is on this Mac.
            voiceFiles = await withPhoneFallback(loaded.map {
                ($0.id, ($0.path as NSString).lastPathComponent)
            }, into: voiceFiles)
            return
        }
        let loaded = await Task.detached {
            (try? VaultStore(path: path).media(kind: indexKind, chatID: chat, year: year, sort: s, limit: 400)) ?? []
        }.value
        items = loaded
        mediaFiles = await resolveFiles(loaded)
        loading = false
        mediaFiles = await withPhoneFallback(loaded.map {
            ($0.id, ($0.path as NSString).lastPathComponent)
        }, into: mediaFiles)
    }

    /// The media table stores paths relative to the phone's storage, so the Gallery resolves
    /// them through exactly the folder list chat bubbles use — same sources, same Drive roots —
    /// otherwise every tile is a grey box next to a chat that shows the photo perfectly well.
    private func resolveFiles(_ items: [MediaItem]) async -> [Int64: URL] {
        let requests = items.map {
            GalleryMediaFiles.Request(id: $0.id, kind: $0.kind, path: $0.path, size: $0.size)
        }
        var out = await resolve(requests)
        // A cloud mount that is still warming up looks empty for its first moments. One retry
        // of the misses is enough to turn a screen of "not here" into real tiles.
        let misses = await resolve(pendingMisses(of: requests, after: out))
        out.merge(misses) { first, _ in first }
        return out
    }

    /// Resolves a batch off the main thread with the shared search path.
    private func resolve(_ requests: [GalleryMediaFiles.Request]) async -> [Int64: URL] {
        guard !requests.isEmpty else { return [:] }
        let vault = AppModel.vaultURL
        let drive = AppModel.driveRoot
        return await Task.detached {
            let (sources, driveRoots) = MediaSearchPath.roots(vaultURL: vault, configuredDrive: drive)
            return GalleryMediaFiles(sources: sources, driveRoots: driveRoots).resolve(requests)
        }.value
    }

    /// The phone is the last resort, one ADB pull per row and never for a whole screen: the
    /// rows that already resolved must be drawn before any of this runs, or a slow cable makes
    /// a fully-indexed Gallery look empty.
    private func withPhoneFallback(_ rows: [(Int64, String)], into hits: [Int64: URL]) async -> [Int64: URL] {
        var out = hits
        let unresolved = rows.filter { out[$0.0] == nil && !$0.1.isEmpty }.prefix(24)
        for (id, name) in unresolved {
            if let url = await Task.detached(operation: {
                PhoneLink.fetchMedia(named: name, into: PhoneLink.mediaCache)
            }).value {
                out[id] = url
            }
        }
        return out
    }

    private func pendingMisses(of requests: [GalleryMediaFiles.Request],
                               after hits: [Int64: URL]) async -> [GalleryMediaFiles.Request] {
        let missing = requests.filter { hits[$0.id] == nil && !$0.path.isEmpty }
        guard !missing.isEmpty else { return [] }
        try? await Task.sleep(for: .milliseconds(700))
        return missing
    }

    /// Voice notes use exactly the same resolution path as bubbles and photo tiles: the
    /// vault's media folders, the Google Drive roots, then one lazy ADB pull when the phone
    /// is connected. A miss is a real miss and the row says so.
    private func resolveVoiceFiles(_ notes: [VoiceNote]) async -> [Int64: URL] {
        let requests = notes.map {
            GalleryMediaFiles.Request(id: $0.id, kind: "audio", path: $0.path, size: $0.size)
        }
        var out = await resolve(requests)
        let misses = await resolve(pendingMisses(of: requests, after: out))
        out.merge(misses) { first, _ in first }
        return out
    }

    /// The explicit "Fetch" button on a missing row. Same one-file ADB pull the chat uses.
    private func fetchVoiceNote(_ note: VoiceNote) async {
        guard model.phone.isConnected else {
            model.flash("Plug the phone in with USB debugging to fetch this voice note.")
            return
        }
        PhoneLink.mediaFallbackEnabled = true
        let name = (note.path as NSString).lastPathComponent
        guard !name.isEmpty else { model.flash("This voice note has no file name to look up."); return }
        let url = await Task.detached { PhoneLink.fetchMedia(named: name, into: PhoneLink.mediaCache) }.value
        if let url { voiceFiles[note.id] = url }
        else { model.flash("That voice note isn't on your phone either.") }
    }

    /// Fills the first screenful and a bit more before the reader scrolls, four at a time.
    /// Cards still fetch their own metadata on appearance; this only makes the first paint
    /// feel finished instead of filling in title by title.
    private func prefetchVisibleTitles() async {
        guard kind.isLinkList else { return }
        let wanted = Array(displayed.prefix(48))
        guard !wanted.isEmpty else { return }
        await withTaskGroup(of: (String, LinkMeta?).self) { group in
            var index = 0
            func addNext() {
                guard index < wanted.count else { return }
                let link = wanted[index].link
                index += 1
                group.addTask { (link.key, await LinkMetaLoader.shared.meta(for: link)) }
            }
            for _ in 0..<4 { addNext() }
            var batch: [String: LinkMeta] = [:]
            for await (key, meta) in group {
                if let meta, !meta.title.isEmpty {
                    batch[key] = meta
                    // Publish in batches: one state change per 24 titles instead of one per
                    // title, which was re-running the whole grid on every network answer.
                    if batch.count >= 64 {
                        metas.merge(batch) { a, _ in a }
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                addNext()
            }
            if !batch.isEmpty { metas.merge(batch) { a, _ in a } }
            refreshDisplay(resetPaging: false)
        }
    }

    /// Spotify, YouTube and SoundCloud answer oEmbed with a title and a cover; Apple Music
    /// carries a title in the URL. Results go to the same cache the chat's Media tab uses,
    /// so a card costs one request ever, not one per visit.
    private func resolveMeta(_ all: [(link: SharedLink, times: Int)]) async {
        guard let cache = try? LinkMetaCache(path: AppModel.supportDir.appendingPathComponent("link_meta.db").path) else { return }
        let seeded = cache.all()
        if !seeded.isEmpty { metas.merge(seeded) { a, _ in a } }

        // Anything not in the cache is fetched by the card itself when it scrolls into view,
        // which keeps a 5,000-link gallery from firing thousands of requests up front.

    }
}

/// One media thumbnail with its conversation and date. A plain struct, not a builder
/// closure, because a grid of these is where the type checker gives up on inference.
private struct MediaCard: View {
    let item: MediaItem
    let file: URL?
    /// False inside a conversation: the chat's name is already in the header above every
    /// card, so the caption's job there is the date, with the day rather than only the month.
    var showsChat = true
    let action: () -> Void

    var body: some View {
        Button(action: action) { card }
            .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(.clear)
                .aspectRatio(1, contentMode: .fit)
                .overlay { artwork.frame(maxWidth: .infinity, maxHeight: .infinity).clipped() }
                .clipped()
            footer
        }
        .cardSurface(radius: AppTheme.Radius.panel)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous))
    }

    private var artwork: some View {
        ZStack {
            Color.black.opacity(0.18)
            if let url = file {
                CachedThumbnail(url: url)
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(AppTheme.Surface.textTertiary.opacity(0.7))
            }
            if item.kind == "video" {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
        }
    }

    private var glyph: String {
        switch item.kind {
        case "video": "video"
        case "doc": "doc.text"
        case "audio": "waveform"
        default: "photo"
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if showsChat {
                Text(item.chatName.isEmpty ? item.ts.formatted(.dateTime.day().month(.abbreviated)) : item.chatName)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(item.ts.formatted(.dateTime.month(.abbreviated).year()))
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            } else {
                Text(item.ts.formatted(.dateTime.day().month(.abbreviated).year()))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(AppTheme.Surface.textSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }
}

/// The conversation filter when the gallery is already inside a chat: a chip that shows which
/// chat it is pinned to and offers no picker. The reader is in the chat; changing it from here
/// is noise, so this is not a button.
struct PinnedChatChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "pin.fill")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.55)
            Text(name).lineLimit(1)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(AppTheme.Surface.textPrimary)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background {
            Capsule().fill(AppTheme.Glass.fill.opacity(0.12))
                .overlay(Capsule().strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        }
        .help("Showing media from this chat only")
        .accessibilityLabel("Pinned to this chat: \(name)")
    }
}

struct FilterChip: View {
    let text: String
    var active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
        }
        .font(.system(size: 11.5, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? AppTheme.Surface.textPrimary : AppTheme.Surface.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background {
            Capsule().fill(AppTheme.Glass.fill.opacity(active ? 0.12 : 0.06))
                .overlay(Capsule().strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Settings place

/// Settings as a place in the chrome, not a separate window.
struct SettingsPlace: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel(radius: AppTheme.Radius.card, padding: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    Text("Settings")
                        .font(AppTheme.Typography.display)
                        .tracking(AppTheme.Typography.displayTracking)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                    SettingsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(AppTheme.Spacing.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
