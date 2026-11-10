import SwiftUI
import Charts
import SagaCore

// The native Wrapped story. One column of paper-coloured sections inside the app,
// on `docs/DESIGN.md` tokens and the WhatsApp palette: teal cover, green-soft
// highlights, ink type. Every quoted message keeps a jump arrow back to the chat.
// The exported HTML page is generated from the same stats and the same copy
// helpers, so the story and the shareable file never drift apart.

// MARK: - Scaffold and shared components

/// The story column: one 720pt measure, generous vertical rhythm, paper background.
struct WrappedStory<Content: View>: View {
    /// `false` lays the sections out at full height instead of inside a scroller,
    /// so a snapshot can capture the whole story in one image.
    var scrolling = true
    @ViewBuilder var content: Content
    var body: some View {
        if scrolling {
            ScrollView {
                column
            }
            .background(AppTheme.Surface.page)
        } else {
            column
        }
    }

    private var column: some View {
        VStack(spacing: AppTheme.Spacing.xxl) { content }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AppTheme.Spacing.gutter)
            .padding(.top, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.xxxl)
    }
}

/// A card section with an eyebrow, a headline and its own content.
struct StoryCard<Content: View>: View {
    var eyebrow: String? = nil
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    AppTheme.Typography.eyebrow(eyebrow).foregroundStyle(AppTheme.Surface.textSecondary)
                }
                Text(title).font(.system(size: 21, weight: .bold)).foregroundStyle(AppTheme.Surface.textPrimary)
                if let subtitle {
                    Text(subtitle).font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Surface.card)
        .clipShape(AppTheme.Radius.cardShape)
        .overlay(AppTheme.Radius.cardShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        .shadow(color: AppTheme.Elevation.card.color, radius: AppTheme.Elevation.card.radius, y: AppTheme.Elevation.card.y)
    }
}

/// The dark cover: the one hero element of the story, in the palette's teal.
struct WrappedCover: View {
    let eyebrow: String
    let title: String
    let range: String
    let total: String
    let sub: String
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(alignment: .center) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.6)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(0.14), in: Capsule())
                }
            }
            Text(title)
                .font(.system(size: 34, weight: .bold)).tracking(-0.6)
                .foregroundStyle(.white).lineLimit(2)
            Text(range).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            Text(total)
                .font(.system(size: 78, weight: .black, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white).minimumScaleFactor(0.5).lineLimit(1)
                .padding(.top, 6)
            Text(sub)
                .font(.system(size: 14)).foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(colors: [AppTheme.Palette.teal, AppTheme.Palette.fern],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [AppTheme.Palette.green.opacity(0.28), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 420)
            }
        )
        .clipShape(AppTheme.Radius.cardShape)
        .shadow(color: AppTheme.Palette.teal.opacity(0.22), radius: 18, y: 8)
    }
}

struct StoryStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 23, weight: .semibold)).monospacedDigit()
                .foregroundStyle(AppTheme.Surface.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Surface.field)
        .clipShape(AppTheme.Radius.controlShape)
    }
}

struct StoryStatGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) { content }
    }
}

/// Two-sided bar: you on the left in green-soft ink, them on the right in indigo.
struct StorySplit: View {
    let title: String
    let aName: String, aValue: Int
    let bName: String, bValue: Int
    var unit: String = ""

    var body: some View {
        let total = max(aValue + bValue, 1)
        let share = Double(aValue) / Double(total)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    Capsule().fill(AppTheme.Palette.greenInk)
                        .frame(width: max(2, (geo.size.width - 2) * share))
                    Capsule().fill(AppTheme.Palette.fern.opacity(0.72))
                }
            }
            .frame(height: 9)
            HStack(spacing: 0) {
                Text(aName).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                Text(" \(WrappedCopy.n(aValue))\(unit)").font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                Spacer(minLength: 12)
                Text("\(WrappedCopy.n(bValue))\(unit) ").font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                Text(bName).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
    }
}

/// A quoted message. Outgoing is green-soft, incoming is the field grey with a hairline.
struct StoryBubble: View {
    let author: String
    let text: String
    var mine = false
    var compact = false
    /// Printed inline after the message (`6 reacts`), never on a line of its own.
    var trailing: String? = nil

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? 12 : 15, style: .continuous) }

    /// The text with the count in the same run, so a moment reads `MESSAGE (6 reacts)`.
    private var line: Text {
        let body = Text(text)
        guard let trailing, !trailing.isEmpty else { return body }
        return body + Text("  (\(trailing))")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(mine ? AppTheme.Palette.tealDeep.opacity(0.85) : AppTheme.Surface.textSecondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(author.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                .foregroundStyle(mine ? AppTheme.Palette.tealDeep.opacity(0.75) : AppTheme.Surface.textSecondary)
            line
                .font(.system(size: compact ? 13 : 14))
                .foregroundStyle(mine ? AppTheme.Palette.ink : AppTheme.Surface.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(mine ? AppTheme.Palette.greenSoft : AppTheme.Surface.field)
        .clipShape(shape)
        .overlay(shape.strokeBorder(mine ? Color.clear : AppTheme.Surface.hairline, lineWidth: 1))
        .frame(maxWidth: 470, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

struct StoryJump: View {
    var title = "See it in the chat"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AppTheme.Accent.text)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(AppTheme.Accent.tint.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Jump to this message in the chat")
    }
}

/// One notable moment, in the shape the owner asked for: the message with its reaction count
/// beside it, then the replies that quoted it, indented under a quiet marker.
///
///   The most hilarious moments
///   MESSAGE  (6 reacts)
///      ↳ the reply that earned it
///      ↳ another thing someone said back
struct StoryMoment: View {
    let date: Date
    let author: String
    let text: String
    let me: String
    /// Distinct people who reacted — never raw rows, and never the author's own tap.
    var reactors = 0
    /// `😂 4  ❤️ 2`, the emoji breakdown under the message.
    var reactionSummary = ""
    /// The replies that quoted the message, the one that earned the moment first.
    var quoted: [QuotedReply] = []
    let onJump: () -> Void

    private var countLabel: String? {
        switch reactors {
        case 0: return nil
        case 1: return "1 react"
        default: return "\(WrappedCopy.n(reactors)) reacts"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
            StoryBubble(author: author, text: text, mine: author == me, trailing: countLabel)
            if !reactionSummary.isEmpty {
                Text(reactionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .padding(.leading, 2)
            }
            if !quoted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(quoted) { reply in StoryQuote(reply: reply) }
                }
                .padding(.leading, 14)
            }
            StoryJump(action: onJump)
        }
    }
}

/// A reply that quoted the moment: indented under the message, with a quiet arrow, so it
/// reads as something said *about* the message above rather than as another moment.
struct StoryQuote: View {
    let reply: QuotedReply

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppTheme.Surface.textTertiary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.fromMe ? "You replied" : "\(reply.author) replied")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                Text(reply.text)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Surface.textPrimary.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Small flow layout so tags wrap without a table of equal-width cells.
struct StoryFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct StoryTag: View {
    let text: String
    var count: Int? = nil
    var big = false
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: big ? 16 : 13, weight: .medium))
                .foregroundStyle(AppTheme.Palette.tealDeep)
            if let count {
                Text(WrappedCopy.n(count)).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
        .padding(.horizontal, big ? 13 : 10).padding(.vertical, big ? 7 : 5)
        .background(AppTheme.Accent.tint.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(AppTheme.Palette.greenInk.opacity(0.18), lineWidth: 1))
    }
}

func wrappedPlayerHeight(_ service: MediaService, _ kind: String) -> CGFloat {
    switch service {
    case .spotify: return kind == "track" || kind == "episode" ? 152 : 352
    case .soundCloud: return kind == "playlist" ? 450 : 166
    case .appleMusic: return kind == "track" ? 175 : 450
    case .youtube, .youtubeMusic: return 215
    }
}

/// Artwork for the story cards. The live view loads it with `AsyncImage`; an export has to
/// have the pixels *before* it renders, so it preloads the same URLs into this small cache.
@MainActor
enum StoryArtwork {
    private static var images: [String: NSImage] = [:]

    static func cached(_ url: String) -> NSImage? { images[url] }

    static func preload(_ urls: [String]) async {
        let wanted = Array(Set(urls.filter { images[$0] == nil })).prefix(12)
        guard !wanted.isEmpty else { return }
        // Fetch raw bytes in the tasks (Data is Sendable) and build NSImage back on the main actor:
        // handing NSImage across isolation boundaries is rejected by the stricter compiler on CI.
        await withTaskGroup(of: (String, Data?).self) { group in
            for url in wanted { group.addTask { (url, await fetchData(url)) } }
            for await (url, data) in group { if let data, let image = NSImage(data: data) { images[url] = image } }
        }
    }

    private static func fetchData(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// One shared song: real title and artwork when titles were looked up, a title-less
/// card when they were not, a player that opens in place, and a jump to the message.
struct StoryTrack: View {
    let title: String?
    let author: String?
    let service: MediaService
    let kind: String
    let artwork: String?
    let role: String?
    let detail: String
    let reactionBy: String?
    let reaction: String?
    let me: String
    let embed: String
    let url: String
    let onJump: () -> Void

    @State private var open = false

    private var playerHeight: CGFloat { wrappedPlayerHeight(service, kind) }
    private var canPlay: Bool { !embed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let reaction, let reactionBy {
                if !reaction.isEmpty {
                    StoryBubble(author: reactionBy, text: reaction, mine: reactionBy == me, compact: true)
                }
            }
            if open, canPlay { player }
        }
        .padding(13)
        .background(AppTheme.Surface.field.opacity(0.55))
        .clipShape(AppTheme.Radius.panelShape)
        .overlay(AppTheme.Radius.panelShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            artworkView
            meta
            Spacer(minLength: 8)
            controls
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let role {
                Text(role.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(AppTheme.Accent.text)
            }
            Text(title ?? "\(service.rawValue) \(kind)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.Surface.textPrimary).lineLimit(2)
            if let author, !author.isEmpty {
                Text(author).font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary).lineLimit(1)
            }
            Text(detail).font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary).lineLimit(1)
        }
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if canPlay { playButton }
            HStack(spacing: 8) {
                Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(AppTheme.Surface.textSecondary)
                .help("Open in \(service.rawValue)")
                Button(action: onJump) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(AppTheme.Surface.textSecondary)
                .help("Jump to the message")
            }
        }
    }

    private var playButton: some View {
        Button { withAnimation(AppTheme.Motion.standard) { open.toggle() } } label: {
            Image(systemName: open ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 20)).foregroundStyle(AppTheme.Accent.text)
        }
        .buttonStyle(.plain)
        .help(open ? "Close the player" : "Play it here")
    }

    private var player: some View {
        EmbedView(url: embed, height: playerHeight)
            .frame(height: playerHeight)
            .clipShape(AppTheme.Radius.controlShape)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder private var artworkView: some View {
        ZStack {
            AppTheme.Surface.field
            if let artwork, let ready = StoryArtwork.cached(artwork) {
                Image(nsImage: ready).resizable().scaledToFill()
            } else if let artwork, let u = URL(string: artwork) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { ProgressView().controlSize(.small) }
            } else {
                Image(systemName: service.symbol).font(.system(size: 22))
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(AppTheme.Radius.controlShape)
    }
}

/// Month-by-month activity, as a native chart.
struct StoryChart: View {
    let monthly: [(month: String, count: Int)]
    private static let parser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"
        return f
    }()

    var body: some View {
        let points = monthly.compactMap { m -> (date: Date, count: Int)? in
            Self.parser.date(from: m.month).map { ($0, m.count) }
        }
        let months = max(points.count, 1)
        let strideCount = max(1, Int(ceil(Double(months) / 7.0)))
        Chart(points, id: \.date) { p in
            BarMark(x: .value("Month", p.date), y: .value("Messages", p.count))
                .foregroundStyle(AppTheme.Palette.greenInk.gradient)
                .cornerRadius(1.5)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(AppTheme.Surface.hairline)
                AxisValueLabel().foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: strideCount)) { _ in
                AxisGridLine().foregroundStyle(AppTheme.Surface.hairline)
                AxisValueLabel(format: .dateTime.month(.abbreviated).year())
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
        .frame(height: 150)
    }
}

// MARK: - Duo story

struct DuoWrappedStory: View {
    let w: DuoWrapped
    let onJump: (Int64) -> Void
    let onExport: () -> Void
    let onSavePDF: () -> Void
    var scrolling = true
    /// Offscreen snapshots cannot rasterise AppKit-backed buttons; the live sheet always shows them.
    var showsExportActions = true

    var body: some View {
        WrappedStory(scrolling: scrolling) {
            cover
            if let f = w.firstText { started(f) }
            balance
            laughs
            if w.heartsMine + w.heartsTheirs > 0 { hearts }
            if w.hasMusic { soundtrack }
            if !w.stickers.isEmpty { stickers }
            if !w.insideJokes.isEmpty || !w.myWords.isEmpty || !w.theirWords.isEmpty { jokes }
            if !w.emojiTogether.isEmpty { emoji }
            years
            superlatives
            outro
        }
    }

    // Cover
    private var cover: some View {
        let pace = w.bestYear.flatMap { WrappedCopy.pace(count: $0.count, year: $0.year, activeDays: $0.activeDays) }
        let sub = [WrappedCopy.opening(total: w.total),
                   WrappedCopy.span(spanDays: w.spanDays, activeDays: w.activeDays, first: w.first),
                   pace].compactMap { $0 }.joined(separator: " ")
        return WrappedCover(
            eyebrow: "Heartbeat",
            title: "\(w.me) & \(w.them)",
            range: "\(WrappedCopy.date(w.first, "MMMM yyyy")) – \(WrappedCopy.date(w.last, "MMMM yyyy"))",
            total: WrappedCopy.n(w.total),
            sub: sub,
            badge: "On this Mac only")
    }

    // How it started
    private func started(_ f: (date: Date, author: String, text: String)) -> some View {
        StoryCard(eyebrow: "The first message", title: "How it started",
                  subtitle: WrappedCopy.date(f.date, "EEEE, d MMMM yyyy")) {
            StoryBubble(author: f.author, text: f.text, mine: f.author == w.me)
            Text(WrappedCopy.firstKicker(text: f.text))
                .font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textSecondary)
        }
    }

    // Balance
    private var balance: some View {
        StoryCard(eyebrow: "Who carries it", title: "The split", subtitle: WrappedCopy.balance(me: w.me, them: w.them, mine: w.mine, theirs: w.theirs)) {
            VStack(spacing: 14) {
                StorySplit(title: "Messages sent", aName: w.me, aValue: w.mine, bName: w.them, bValue: w.theirs)
                StorySplit(title: "Words typed", aName: w.me, aValue: w.wordsMine, bName: w.them, bValue: w.wordsTheirs)
                StorySplit(title: "Conversations started", aName: w.me, aValue: w.startsMine, bName: w.them, bValue: w.startsTheirs)
            }
            if let race = WrappedCopy.replyRace(me: w.me, them: w.them, mine: w.medianReplyMine, theirs: w.medianReplyTheirs,
                                                mineSamples: w.replyCountMine, theirsSamples: w.replyCountTheirs,
                                                mineSlow: w.slowReplyMine, theirsSlow: w.slowReplyTheirs) {
                Text(race).font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StoryStatGrid {
                StoryStat(value: WrappedCopy.duration(w.medianReplyMine), label: "your typical reply")
                StoryStat(value: WrappedCopy.duration(w.medianReplyTheirs), label: "\(w.them)'s typical reply")
                StoryStat(value: "\(WrappedCopy.n(w.activeDays))", label: WrappedCopy.noun(w.activeDays, "day") + " you talked")
                StoryStat(value: "\(WrappedCopy.n(w.longestStreak))", label: WrappedCopy.noun(w.longestStreak, "day") + " in a row at best")
            }
        }
    }

    // Laughs
    private var laughs: some View {
        let copy = WrappedCopy.laughs(me: w.me, them: w.them, madeThemLaugh: w.madeThemLaugh,
                                     madeMeLaugh: w.madeMeLaugh, peakMonth: w.laughMonth.map { (month: $0.month, count: $0.count) })
        return StoryCard(eyebrow: "The laugh track", title: "What landed", subtitle: copy) {
            if w.madeThemLaugh + w.madeMeLaugh > 0 {
                StorySplit(title: "Laughs earned from the other one", aName: w.me, aValue: w.madeThemLaugh,
                           bName: w.them, bValue: w.madeMeLaugh, unit: "×")
            }
            if !w.funniest.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The most hilarious moments").font(AppTheme.Typography.section).foregroundStyle(AppTheme.Surface.textPrimary)
                    ForEach(Array(w.funniest.enumerated()), id: \.offset) { _, m in
                        StoryMoment(date: m.date, author: m.author, text: m.text, me: w.me,
                                    reactors: m.reactors, reactionSummary: m.reactionSummary,
                                    quoted: m.quoted) {
                            onJump(m.messageID)
                        }
                    }
                }
            }
        }
    }

    // Hearts — affection, counted separately from laughter
    private var hearts: some View {
        let copy = WrappedCopy.hearts(me: w.me, them: w.them, mine: w.heartsMine, theirs: w.heartsTheirs)
        return StoryCard(eyebrow: "The heart track", title: "What you loved", subtitle: copy) {
            StorySplit(title: "Messages that earned a heart", aName: w.me, aValue: w.heartsMine,
                       bName: w.them, bValue: w.heartsTheirs, unit: "❤")
            if let loved = w.loved {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The one that collected the most").font(AppTheme.Typography.section).foregroundStyle(AppTheme.Surface.textPrimary)
                    StoryMoment(date: loved.date, author: loved.author, text: loved.text, me: w.me,
                                reactors: loved.reactors, reactionSummary: loved.summary,
                                quoted: loved.quoted) { onJump(loved.messageID) }
                }
            }
        }
    }

    // Stickers — counted, never quoted: a sticker has no words to print
    private var stickers: some View {
        let s = w.stickers
        let copy = WrappedCopy.stickers(total: s.total, distinct: s.distinct, topCount: s.topCount)
        return StoryCard(eyebrow: "Stickers", title: "What did the talking", subtitle: copy) {
            StoryStatGrid {
                StoryStat(value: WrappedCopy.n(s.total), label: WrappedCopy.noun(s.total, "sticker", "stickers") + " sent")
                StoryStat(value: WrappedCopy.n(s.distinct), label: "different ones")
                if let top = s.top.first { StoryStat(value: "\(WrappedCopy.n(top.count))×", label: "the busiest one") }
            }
            if let top = s.top.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Same file every time — identified by its SHA-256, not by what it looked like.")
                        .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(top.hash.prefix(24)) + "…")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(AppTheme.Surface.textTertiary)
                }
            }
        }
    }

    // Soundtrack
    private var soundtrack: some View {
        let dj = w.linksMine >= w.linksTheirs ? w.me : w.them
        let copy = WrappedCopy.soundtrack(me: w.me, them: w.them, total: w.linksTotal,
                                          mine: w.linksMine, theirs: w.linksTheirs, twins: w.twinTracks)
        return StoryCard(eyebrow: "Your soundtrack", title: "What you sent each other", subtitle: copy) {
            StoryStatGrid {
                StoryStat(value: "\(WrappedCopy.n(w.linksTotal))", label: WrappedCopy.noun(w.linksTotal, "song or video", "songs & videos") + " shared")
                StoryStat(value: dj, label: "shared most of them")
                if w.twinTracks > 0 { StoryStat(value: "\(WrappedCopy.n(w.twinTracks))", label: "sent by both of you") }
                if let peak = w.musicPeakMonth {
                    StoryStat(value: WrappedCopy.month(peak.month), label: "\(WrappedCopy.plural(peak.count, "share")) that month")
                }
            }
            StorySplit(title: "Shared", aName: w.me, aValue: w.linksMine, bName: w.them, bValue: w.linksTheirs)
            VStack(spacing: 10) {
                ForEach(Array(w.tracks.enumerated()), id: \.offset) { _, t in
                    StoryTrack(title: t.title, author: t.author, service: t.service, kind: t.kind,
                               artwork: t.thumbnail, role: t.role,
                               detail: WrappedCopy.trackDetail(by: t.firstBy, date: t.firstDate, times: t.times),
                               reactionBy: t.reaction.isEmpty ? nil : t.reactionBy,
                               reaction: t.reaction.isEmpty ? nil : t.reaction,
                               me: w.me, embed: t.embed, url: t.url) { onJump(t.messageID) }
                }
            }
        }
    }

    // Inside jokes
    private var jokes: some View {
        let copy = WrappedCopy.jokes(count: w.insideJokes.count, top: w.insideJokes.first?.text, topCount: w.insideJokes.first?.count ?? 0)
        return StoryCard(eyebrow: "Inside jokes", title: "Words that only mean something here", subtitle: copy) {
            if !w.insideJokes.isEmpty {
                StoryFlow { ForEach(Array(w.insideJokes.enumerated()), id: \.offset) { _, p in StoryTag(text: p.text, count: p.count, big: true) } }
            }
            if !w.myWords.isEmpty || !w.theirWords.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    signature(w.me, w.myWords)
                    signature(w.them, w.theirWords)
                }
            }
        }
    }

    private func signature(_ who: String, _ words: [DuoWrapped.Phrase]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(who.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(AppTheme.Surface.textSecondary)
            StoryFlow { ForEach(Array(words.enumerated()), id: \.offset) { _, p in StoryTag(text: p.text, count: p.count) } }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // Emoji
    private var emoji: some View {
        let pair = w.emojiPair
        let line = pair.map { WrappedCopy.emojiPair(a: $0.a, b: $0.b, count: $0.count) }
            ?? WrappedCopy.emojiLeaders(me: w.me, them: w.them, mine: w.emojiMine.first?.text, theirs: w.emojiTheirs.first?.text)
        return StoryCard(eyebrow: "Emoji", title: pair == nil ? "Your favourites" : "Your pair", subtitle: line) {
            VStack(spacing: 16) {
                Text(pair.map { $0.a + $0.b } ?? w.emojiTogether.first?.text ?? "🙂")
                    .font(.system(size: 84)).lineLimit(1).minimumScaleFactor(0.5)
                HStack(alignment: .top, spacing: 18) {
                    emojiColumn(w.me, w.emojiMine)
                    emojiColumn(w.them, w.emojiTheirs)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func emojiColumn(_ who: String, _ list: [DuoWrapped.Phrase]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(who.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(AppTheme.Surface.textSecondary)
            if list.isEmpty {
                Text("none in this chat").font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            } else {
                ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 8) {
                        Text(p.text).font(.system(size: 22))
                        Text(WrappedCopy.n(p.count)).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // Years
    private var years: some View {
        StoryCard(eyebrow: w.spanDays < 400 ? "Over the months" : "Over the years", title: "The shape of it",
                  subtitle: WrappedCopy.peakMonth(month: w.peakMonth?.month ?? "", count: w.peakMonth?.count ?? 0, total: w.total)) {
            StoryChart(monthly: w.monthly)
            if let q = w.quietestYear {
                let next = w.byYear.first { $0.year == q.year + 1 }
                if let line = WrappedCopy.quietYear(year: q.year, count: q.count, nextYear: next?.year, nextCount: next?.count) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(AppTheme.Palette.fern)
                        Text(line).font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.Palette.fern.opacity(0.07))
                    .clipShape(AppTheme.Radius.controlShape)
                }
            }
            StoryStatGrid {
                StoryStat(value: WrappedCopy.hour(w.busiestHour), label: "your busiest hour")
                StoryStat(value: "\(WrappedCopy.n(w.busiestDay?.count ?? 0))",
                          label: WrappedCopy.noun(w.busiestDay?.count ?? 0, "message") + " on your busiest day")
                StoryStat(value: "\(WrappedCopy.n(w.longestStreak))", label: WrappedCopy.noun(w.longestStreak, "day") + " in a row at best")
            }
            if let night = WrappedCopy.night(me: w.me, them: w.them, mine: w.nightMine, theirs: w.nightTheirs) {
                Text(night).font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let owl = w.nightOwl {
                VStack(alignment: .leading, spacing: 8) {
                    Text(WrappedCopy.nightOwlLead(author: owl.author, hour: owl.hour, minute: owl.minute, on: owl.date))
                        .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                    StoryBubble(author: owl.author, text: owl.text, mine: owl.author == w.me)
                    StoryJump(action: { onJump(owl.messageID) })
                }
            }
            if let gap = WrappedCopy.gap(days: w.longestGapDays, from: w.gapFrom, to: w.gapTo, brokenBy: w.gapBrokenBy) {
                Text(gap).font(AppTheme.Typography.callout).foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Superlatives
    private var superlatives: some View {
        let longest = (w.longestMine?.text.count ?? 0) >= (w.longestTheirs?.text.count ?? 0) ? w.longestMine : w.longestTheirs
        let longestWho = (w.longestMine?.text.count ?? 0) >= (w.longestTheirs?.text.count ?? 0) ? w.me : w.them
        let copy = WrappedCopy.longestMessage(me: w.me, them: w.them,
                                              mine: w.longestMine?.text.count ?? 0, theirs: w.longestTheirs?.text.count ?? 0)
        return StoryCard(eyebrow: "Little superlatives", title: "For the record", subtitle: copy) {
            let media = [(w.photos.mine + w.photos.theirs, "photo"), (w.videos.mine + w.videos.theirs, "video"),
                         (w.voice.mine + w.voice.theirs, "voice note"), (w.docs.mine + w.docs.theirs, "document")].filter { $0.0 > 0 }
            if !media.isEmpty {
                StoryStatGrid { ForEach(Array(media.enumerated()), id: \.offset) { _, item in
                    StoryStat(value: WrappedCopy.n(item.0), label: WrappedCopy.noun(item.0, item.1))
                } }
            }
            if let longest {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The longest one — \(longestWho), \(WrappedCopy.date(longest.date))")
                        .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                    StoryBubble(author: longestWho, text: longest.text, mine: longestWho == w.me)
                    if longest.messageID > 0 { StoryJump(action: { onJump(longest.messageID) }) }
                }
            }
        }
    }

    // Outro
    private var outro: some View {
        VStack(spacing: 14) {
            Text(WrappedCopy.n(w.total)).font(.system(size: 64, weight: .black, design: .rounded)).monospacedDigit()
                .foregroundStyle(AppTheme.Surface.textPrimary)
            Text("messages and still going.").font(.system(size: 15)).foregroundStyle(AppTheme.Surface.textSecondary)
            if showsExportActions {
                HStack(spacing: 10) {
                    Button("Save a copy", action: onExport).buttonStyle(.bordered)
                    Button("Save as PDF", action: onSavePDF).buttonStyle(.bordered)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("Built on this Mac. Nothing left it.").font(AppTheme.Typography.caption)
            }.foregroundStyle(AppTheme.Surface.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.xl)
    }
}

// MARK: - Group story

struct GroupWrappedStory: View {
    let w: GroupWrapped
    let onJump: (Int64) -> Void
    let onExport: () -> Void
    let onSavePDF: () -> Void
    var scrolling = true
    /// Offscreen snapshots cannot rasterise AppKit-backed buttons; the live sheet always shows them.
    var showsExportActions = true

    var body: some View {
        WrappedStory(scrolling: scrolling) {
            cover
            voices
            if !w.moments.isEmpty || !w.funniest.isEmpty { laughs }
            if w.heartsByReaction > 0 { hearts }
            if w.hasMusic { soundtrack }
            if !w.stickers.isEmpty { stickers }
            if !w.insideJokes.isEmpty { jokes }
            if !w.emoji.isEmpty { emoji }
            years
            outro
        }
    }

    private var spanDays: Int { max(w.spanDays, 1) }

    private var cover: some View {
        let range: String = {
            guard let first = w.first, let last = w.last else { return "" }
            return "\(WrappedCopy.date(first, "MMMM yyyy")) – \(WrappedCopy.date(last, "MMMM yyyy"))"
        }()
        return WrappedCover(
            eyebrow: "Heartbeat",
            title: w.name,
            range: range,
            total: WrappedCopy.n(w.total),
            sub: WrappedCopy.groupOpening(name: w.name, total: w.total, contributors: w.contributors.count,
                                          spanDays: spanDays, activeDays: w.activeDays),
            badge: "\(WrappedCopy.people(w.contributors.count))")
    }

    private var voices: some View {
        let f = w.funniest.first
        let copy = WrappedCopy.groupVoices(top: w.contributors.first?.name, topCount: w.contributors.first?.messages ?? 0,
                                           funniest: f?.name, laughs: f?.laughsEarned ?? 0, of: f?.messages ?? 0,
                                           runnerUpRate: w.witRunnerUpRate, roomRate: w.laughRate)
        return StoryCard(eyebrow: "Who talks", title: "The room", subtitle: copy) {
            let top = max(w.contributors.first?.messages ?? 1, 1)
            VStack(spacing: 9) {
                ForEach(Array(w.contributors.prefix(8).enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 10) {
                        Avatar(name: c.name, size: 24)
                        Text(c.name).font(AppTheme.Typography.rowName).foregroundStyle(AppTheme.Surface.textPrimary)
                            .lineLimit(1).frame(width: 120, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(AppTheme.Palette.greenInk.opacity(0.75))
                                .frame(width: max(4, geo.size.width * CGFloat(c.messages) / CGFloat(top)), height: 8)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }.frame(height: 14)
                        Text(WrappedCopy.n(c.messages)).font(AppTheme.Typography.caption).monospacedDigit()
                            .foregroundStyle(AppTheme.Surface.textSecondary).frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var laughs: some View {
        StoryCard(eyebrow: "The laugh track", title: "Who gets the laughs",
                  subtitle: w.funniest.first.map { "\($0.name) drew \(WrappedCopy.plural($0.laughsEarned, "laugh")) from the room." })
        {
            if !w.moments.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The most hilarious moments").font(AppTheme.Typography.section).foregroundStyle(AppTheme.Surface.textPrimary)
                    ForEach(Array(w.moments.enumerated()), id: \.offset) { _, m in
                        StoryMoment(date: m.date, author: m.author, text: m.text, me: "you",
                                    reactors: m.reactors, reactionSummary: m.reactionSummary,
                                    quoted: m.quoted) { onJump(m.messageID) }
                    }
                }
            } else {
                Text("No single moment stood out yet.").font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
    }

    private var hearts: some View {
        let copy = "\(WrappedCopy.plural(w.heartsByReaction, "message")) earned a heart from someone else."
        return StoryCard(eyebrow: "The heart track", title: "What the room loved", subtitle: copy) {
            if let loved = w.loved {
                StoryMoment(date: loved.date, author: loved.author, text: loved.text, me: "you",
                            reactors: loved.reactors, reactionSummary: loved.reactionSummary,
                            quoted: loved.quoted) { onJump(loved.messageID) }
            }
        }
    }

    private var stickers: some View {
        let s = w.stickers
        let copy = WrappedCopy.stickers(total: s.total, distinct: s.distinct, topCount: s.topCount)
        return StoryCard(eyebrow: "Stickers", title: "What did the talking", subtitle: copy) {
            StoryStatGrid {
                StoryStat(value: WrappedCopy.n(s.total), label: WrappedCopy.noun(s.total, "sticker", "stickers") + " sent")
                StoryStat(value: WrappedCopy.n(s.distinct), label: "different ones")
                if let top = s.top.first {
                    StoryStat(value: "\(WrappedCopy.n(top.count))×", label: top.sender ?? "the busiest one")
                }
            }
        }
    }

    private var soundtrack: some View {
        let top = w.linkSharers.first
        let copy = WrappedCopy.groupSoundtrack(total: w.linksTotal, sharers: w.linkSharers.count,
                                               top: top?.name, topCount: top?.messages ?? 0)
        return StoryCard(eyebrow: "The soundtrack", title: "What the room was playing", subtitle: copy) {
            VStack(spacing: 10) {
                ForEach(Array(w.tracks.enumerated()), id: \.offset) { _, t in
                    StoryTrack(title: t.title, author: t.author, service: t.service, kind: t.kind,
                               artwork: t.thumbnail, role: nil,
                               detail: WrappedCopy.trackDetail(by: t.firstBy, date: t.firstDate, times: t.times),
                               reactionBy: nil, reaction: nil, me: "you",
                               embed: t.embed, url: t.url) { onJump(t.messageID) }
                }
            }
        }
    }

    private var jokes: some View {
        let copy = WrappedCopy.jokes(count: w.insideJokes.count, top: w.insideJokes.first?.text, topCount: w.insideJokes.first?.count ?? 0)
        return StoryCard(eyebrow: "Inside jokes", title: "The group's own language", subtitle: copy) {
            StoryFlow { ForEach(Array(w.insideJokes.enumerated()), id: \.offset) { _, p in StoryTag(text: p.text, count: p.count, big: true) } }
        }
    }

    private var emoji: some View {
        let pair = w.emojiPair
        let line = pair.map { WrappedCopy.emojiPair(a: $0.a, b: $0.b, count: $0.count) }
            ?? "The emoji this group actually types."
        return StoryCard(eyebrow: "Emoji", title: pair == nil ? "Favourites" : "The group's pair", subtitle: line) {
            VStack(spacing: 14) {
                if let pair {
                    Text(pair.a + pair.b).font(.system(size: 78)).lineLimit(1)
                }
                StoryFlow { ForEach(Array(w.emoji.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 6) {
                        Text(p.text).font(.system(size: 24))
                        Text(WrappedCopy.n(p.count)).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                    }
                } }
            }
        }
    }

    private var years: some View {
        StoryCard(eyebrow: spanDays < 400 ? "Over the months" : "Over the years", title: "The shape of it",
                  subtitle: w.peakMonth.map { "\(WrappedCopy.month($0.month)) was the loudest: \(WrappedCopy.plural($0.count, "message"))." }) {
            StoryChart(monthly: w.monthly)
            StoryStatGrid {
                StoryStat(value: "\(WrappedCopy.n(w.activeDays))", label: WrappedCopy.noun(w.activeDays, "day") + " with a message")
                StoryStat(value: "\(WrappedCopy.n(w.contributors.count))", label: WrappedCopy.noun(w.contributors.count, "person", "people") + " who took part")
                if let peak = w.peakMonth { StoryStat(value: WrappedCopy.n(peak.count), label: "messages in \(WrappedCopy.month(peak.month))") }
            }
        }
    }

    private var outro: some View {
        VStack(spacing: 14) {
            Text(WrappedCopy.n(w.total)).font(.system(size: 64, weight: .black, design: .rounded)).monospacedDigit()
                .foregroundStyle(AppTheme.Surface.textPrimary)
            Text("messages from \(WrappedCopy.people(w.contributors.count)).").font(.system(size: 15))
                .foregroundStyle(AppTheme.Surface.textSecondary)
            if showsExportActions {
                HStack(spacing: 10) {
                    Button("Save a copy", action: onExport).buttonStyle(.bordered)
                    Button("Save as PDF", action: onSavePDF).buttonStyle(.bordered)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("Built on this Mac. Nothing left it.").font(AppTheme.Typography.caption)
            }.foregroundStyle(AppTheme.Surface.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.xl)
    }
}
