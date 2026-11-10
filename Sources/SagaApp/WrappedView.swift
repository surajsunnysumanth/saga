import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import SagaCore

// The year Wrapped: the whole archive's year as one story, in the same shape as the
// duo and group stories — cover, the shape of the year, who you talked to, what made
// you laugh, the soundtrack, the message that says the most, a closing line. Copy comes
// from `WrappedCopy`, colour and type from `AppTheme`, and every quoted message keeps
// a jump arrow into the chat. Built once per year and cached by content.

struct WrappedSidebar: View {
    @Environment(AppModel.self) var model

    private var years: [(year: String, count: Int, sent: Int)] { model.stats?.yearly ?? [] }

    var body: some View {
        Group {
            if years.isEmpty {
                EmptyStateView(
                    symbol: "gift",
                    title: "No years yet",
                    message: "Your Wrapped builds from the messages in your archive, so it appears once there are some.",
                    colors: AppTheme.Module.wrapped.colors,
                    compact: true)
            } else {
                // The list takes the height it needs and the summary sits on the floor of
                // the column, so a short list reads as a column with a footer, not as a hole.
                VStack(spacing: 0) {
                    List(selection: Binding(get: { model.wrappedYear }, set: { if let y = $0 { model.wrappedYear = y } })) {
                        Section {
                            ForEach(years.reversed(), id: \.year) { y in
                                HStack(spacing: 8) {
                                    Text(y.year)
                                        .font(AppTheme.Typography.rowName)
                                        .foregroundStyle(AppTheme.Surface.textPrimary)
                                    Spacer(minLength: 6)
                                    Text("\(y.count.formatted())")
                                        .font(AppTheme.Typography.rowMeta).monospacedDigit()
                                        .foregroundStyle(AppTheme.Surface.textTertiary)
                                }
                                .padding(.vertical, 3)
                                .tag(y.year)
                            }
                        } header: {
                            AppTheme.Typography.eyebrow("Your years")
                                .foregroundStyle(AppTheme.Surface.textTertiary)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)

                    Hairline()
                    archiveFooter
                }
                .background(Color.clear)
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
    }

    // MARK: - The floor of the column

    /// What the year list does not say: the whole archive in one line and a bar per
    /// year, so the empty half of the column carries the scale of the archive.
    private var archiveFooter: some View {
        let total = years.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AppTheme.Typography.eyebrow("Across all years")
                .foregroundStyle(AppTheme.Surface.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(total.formatted())
                    .font(AppTheme.Typography.section).monospacedDigit()
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                Text(years.count == 1 ? "message" : "messages")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
            sparkline
            if let first = model.stats?.first, let last = model.stats?.last {
                Text("\(first.formatted(.dateTime.month(.abbreviated).year())) – \(last.formatted(.dateTime.month(.abbreviated).year()))")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.vertical, AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One bar per year, scaled to the busiest one; the year on screen is the inked bar.
    private var sparkline: some View {
        let peak = max(years.map(\.count).max() ?? 0, 1)
        let labelsEveryYear = years.count <= 6
        return HStack(alignment: .bottom, spacing: AppTheme.Spacing.xxs) {
            ForEach(years, id: \.year) { y in
                let selected = y.year == model.wrappedYear
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AppTheme.Accent.text.opacity(selected ? 0.9 : 0.3))
                        .frame(height: 3 + 19 * CGFloat(y.count) / CGFloat(peak))
                    Group {
                        if labelsEveryYear || y.year == years.first?.year || y.year == years.last?.year {
                            Text(String(y.year.suffix(2)))
                                .font(selected ? AppTheme.Typography.micro.weight(.semibold) : AppTheme.Typography.micro)
                                .monospacedDigit()
                                .foregroundStyle(selected ? AppTheme.Surface.textPrimary : AppTheme.Surface.textSecondary)
                        } else {
                            Text(" ").font(AppTheme.Typography.micro)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(height: 38, alignment: .bottom)
    }
}

struct WrappedView: View {
    @Environment(AppModel.self) var model
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
        }
        .background(AppTheme.Surface.page)
    }

    // MARK: - Header (a quiet bar; the story itself is the screen)

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            ZStack {
                AppTheme.Module.wrapped.gradient
                Image(systemName: "gift.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .clipShape(AppTheme.Radius.iconShape)

            VStack(alignment: .leading, spacing: 1) {
                AppTheme.Typography.eyebrow("Wrapped").foregroundStyle(AppTheme.Surface.textTertiary)
                Text(outputYear)
                    .font(AppTheme.Typography.title)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
            }
            Spacer(minLength: AppTheme.Spacing.m)
            if let w = model.yearWrapped, w.total > 0 {
                storyControls(w)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.gutter)
        .padding(.vertical, AppTheme.Spacing.s)
        .background(AppTheme.Surface.bar)
    }

    private var outputYear: String { model.yearWrapped?.year ?? model.wrappedYear }

    /// Looking titles up and saving the story are both things you do *to* the story, so
    /// they read as one cluster: a lone switch in the corner looked like an orphan.
    private func storyControls(_ w: YearWrapped) -> some View {
        HStack(spacing: 0) {
            titlesToggle(w)
                .padding(.leading, AppTheme.Spacing.m)
                .padding(.trailing, AppTheme.Spacing.m)
            Rectangle()
                .fill(AppTheme.Surface.hairline)
                .frame(width: 1, height: 16)
            exportMenu(w)
                .padding(.horizontal, AppTheme.Spacing.m)
                .padding(.vertical, 4)
        }
        .padding(.vertical, 3)
        .background(AppTheme.Radius.controlShape.fill(AppTheme.Surface.field))
        .overlay(AppTheme.Radius.controlShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
    }

    private func titlesToggle(_ w: YearWrapped) -> some View {
        Toggle(isOn: Binding(get: { model.wrappedTitles }, set: { model.setWrappedTitles($0) })) {
            Text("Titles").font(AppTheme.Typography.callout)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(AppTheme.Accent.primaryFill)
        .help("Look up the real song and video titles (asks Spotify, YouTube or SoundCloud for the \(w.tracks.count) in this story). Nothing is sent unless this is on.")
    }

    private func exportMenu(_ w: YearWrapped) -> some View {
        Menu {
            Button { save(w, asPDF: true) } label: { Label("Save as PDF", systemImage: "doc.richtext") }
            Button { save(w, asPDF: false) } label: { Label("Save as image", systemImage: "photo") }
        } label: {
            Label(exporting ? "Saving…" : "Export", systemImage: "square.and.arrow.up")
                .font(AppTheme.Typography.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(exporting)
        .help("A copy to share. The story lives in the app; this is the secondary action.")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let w = model.yearWrapped {
            if w.total > 0 {
                YearWrappedStory(w: w,
                                 onJump: { id, chatID in
                                     model.section = .chats
                                     // The story is the place the reader is leaving, so the way
                                     // back is Wrapped even though the section has already moved.
                                     model.jump(toMessage: id, in: chatID,
                                                origin: ChatOrigin(place: .insights, date: Date()))
                                 },
                                 onOpenChat: { id in model.section = .chats; model.openChat(id: id) })
            } else {
                empty(w)
            }
        } else if let error = model.wrappedError {
            ErrorStateView(title: "That year wouldn't build",
                           message: error + " Your archive itself is untouched — try the year again.",
                           retryTitle: "Try again",
                           retry: { model.loadWrapped(force: true) })
                .background(AppTheme.Surface.page)
        } else {
            VStack(spacing: AppTheme.Spacing.m) {
                ProgressView().controlSize(.small)
                Text("Reading \(model.wrappedYear)…").font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.Surface.page)
        }
    }

    private func empty(_ w: YearWrapped) -> some View {
        let latest = model.stats?.yearly.last?.year
        return EmptyStateView(
            symbol: "gift",
            title: "Nothing for \(w.year) yet",
            message: latest == nil
                ? "This archive has no messages to look back on yet."
                : "There are no messages in \(w.year). Your latest year with messages is \(latest!).",
            colors: AppTheme.Module.wrapped.colors,
            actionTitle: latest != nil && latest != w.year ? "Show \(latest!)" : nil,
            action: latest != nil && latest != w.year ? { model.wrappedYear = latest! } : nil)
            .background(AppTheme.Surface.page)
    }

    // MARK: - Saving (secondary by design)

    private func save(_ w: YearWrapped, asPDF: Bool) {
        exporting = true
        Task {
            let image = await YearStoryExport.image(for: w)
            exporting = false
            guard let image else {
                model.toast = "Couldn't render the story."
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = asPDF ? [.pdf] : [.png]
            panel.nameFieldStringValue = "Wrapped \(w.year)." + (asPDF ? "pdf" : "png")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let ok = asPDF ? YearStoryExport.writePDF(image, to: url) : YearStoryExport.writePNG(image, to: url)
            model.toast = ok ? "Saved \(url.lastPathComponent)." : "Couldn't save the file."
            Task { try? await Task.sleep(for: .seconds(5)); model.toast = nil }
        }
    }
}

// MARK: - The story

struct YearWrappedStory: View {
    let w: YearWrapped
    let onJump: (Int64, Int64) -> Void
    let onOpenChat: (Int64) -> Void
    var scrolling = true

    var body: some View {
        WrappedStory(scrolling: scrolling) {
            cover
            shape
            people
            laughs
            if w.hearts > 0 { hearts }
            if w.hasMusic { soundtrack }
            if !w.stickers.isEmpty { stickers }
            if let longest = w.longest, longest.chars > 0 { message(longest) }
            closing
        }
    }

    // The opening number
    private var cover: some View {
        let sub = [WrappedCopy.yearOpening(year: w.year, total: w.total, chats: w.chatCount),
                   WrappedCopy.yearDays(yourDays: w.yourDays, coveredDays: w.coveredDays,
                                        daysInYear: w.daysInYear, partial: w.isPartial)]
            .compactMap { $0 }.joined(separator: " ")
        return WrappedCover(
            eyebrow: "Saga Wrapped",
            title: "Your \(w.year)",
            range: range,
            total: WrappedCopy.n(w.total),
            sub: sub,
            badge: "On this Mac only")
    }

    private var range: String {
        let first = WrappedCopy.monthName(w.firstMonthIndex)
        let last = WrappedCopy.monthName(w.lastMonthIndex)
        if w.months <= 1 { return "\(first) \(w.year)" }
        if !w.isPartial { return "January – December \(w.year)" }
        return "\(first) – \(last) \(w.year)"
    }

    // Month by month, with the months that exist
    private var shape: some View {
        let copy = WrappedCopy.yearShape(month: w.peakMonth?.month ?? "", count: w.peakMonth?.count ?? 0,
                                         busiest: w.busiestDay?.date, busiestCount: w.busiestDay?.count ?? 0,
                                         hour: w.busiestHour)
        let rhythm = [WrappedCopy.yearStreak(days: w.longestStreak),
                      WrappedCopy.yearNight(count: w.nightMessages)].compactMap { $0 }.joined(separator: " ")
        return StoryCard(eyebrow: "Month by month", title: "The shape of the year", subtitle: copy) {
            YearMonthChart(monthly: w.monthly)
            if let note = WrappedCopy.yearPartial(firstMonth: w.firstMonthIndex, lastMonth: w.lastMonthIndex, months: w.months) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: w.isPartial ? "calendar.badge.exclamationmark" : "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.Palette.fern)
                    Text(note).font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Palette.fern.opacity(0.07))
                .clipShape(AppTheme.Radius.controlShape)
            }
            if !rhythm.isEmpty {
                Text(rhythm).font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Who you talked to
    private var people: some View {
        let who = WrappedCopy.yearPeople(top: w.people.first?.name, topCount: w.people.first?.count ?? 0,
                                         people: w.peopleCount)
        let room = WrappedCopy.yearRoom(group: w.groupChats.first?.name, count: w.groupChats.first?.count ?? 0,
                                        groups: w.groupCount)
        let sub = [who, room].compactMap { $0 }.joined(separator: " ")
        return StoryCard(eyebrow: "Who you talked to",
                         title: w.chatCount == 1 ? "One conversation" : "\(WrappedCopy.n(w.chatCount)) conversations",
                         subtitle: sub.isEmpty ? nil : sub) {
            let top = max(w.chats.first?.count ?? 1, 1)
            VStack(spacing: 9) {
                ForEach(w.chats.prefix(8)) { c in
                    Button { onOpenChat(c.id) } label: {
                        HStack(spacing: AppTheme.Spacing.s) {
                            Avatar(name: c.name, group: c.isGroup, size: 26)
                            // A fixed name column and a fixed count column give every
                            // track the same start and the same end, so the bars compare.
                            Text(c.name)
                                .font(AppTheme.Typography.rowName)
                                .foregroundStyle(AppTheme.Surface.textPrimary)
                                .lineLimit(1)
                                .frame(width: 220, alignment: .leading)
                            peopleBar(CGFloat(c.count) / CGFloat(top))
                            Text(WrappedCopy.n(c.count))
                                .font(AppTheme.Typography.caption).monospacedDigit()
                                .foregroundStyle(AppTheme.Surface.textSecondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(c.name)")
                }
            }
            if let more = WrappedCopy.yearMoreChats(w.chatCount - 8) {
                Text(more)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            }
        }
    }

    /// One conversation's share of the busiest one, on a track that runs the whole
    /// column width so the bars share a start and an end.
    private func peopleBar(_ fraction: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.Surface.field)
                Capsule()
                    .fill(AppTheme.Palette.greenInk.opacity(0.75))
                    .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
        .frame(maxWidth: .infinity)
    }

    // What made you laugh
    private var laughs: some View {
        let moment = w.laughMoment
        let sub = [WrappedCopy.yearLaughs(count: w.laughs),
                   moment.map { WrappedCopy.yearLaughMoment(author: $0.author, chat: $0.chatName, on: $0.date) }]
            .compactMap { $0 }.joined(separator: " ")
        return StoryCard(eyebrow: "The laugh track", title: "What made you laugh", subtitle: sub) {
            if let m = moment {
                StoryMoment(date: m.date, author: m.author, text: m.text, me: "You",
                            reactors: m.reactors, reactionSummary: m.reactionSummary,
                            quoted: m.quoted) { onJump(m.messageID, m.chatID) }
            } else {
                Text(WrappedCopy.yearNoMoment(year: w.year))
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
    }

    // The messages that got hearts
    private var hearts: some View {
        let m = w.heartMoment
        let sub = [WrappedCopy.yearHearts(count: w.hearts),
                   m.map { WrappedCopy.yearHeartMoment(author: $0.author, chat: $0.chatName, on: $0.date) }]
            .compactMap { $0 }.joined(separator: " ")
        return StoryCard(eyebrow: "The heart track", title: "What everyone loved", subtitle: sub) {
            if let m {
                StoryMoment(date: m.date, author: m.author, text: m.text, me: "You",
                            reactors: m.reactors, reactionSummary: m.reactionSummary,
                            quoted: m.quoted) { onJump(m.messageID, m.chatID) }
            }
        }
    }

    // The stickers — counted, never quoted
    private var stickers: some View {
        let s = w.stickers
        let copy = WrappedCopy.stickers(total: s.total, distinct: s.distinct, topCount: s.topCount)
        return StoryCard(eyebrow: "Stickers", title: "What did the talking", subtitle: copy) {
            StoryStatGrid {
                StoryStat(value: WrappedCopy.n(s.total), label: WrappedCopy.noun(s.total, "sticker", "stickers") + " sent")
                StoryStat(value: WrappedCopy.n(s.distinct), label: "different ones")
                if let top = s.top.first { StoryStat(value: "\(WrappedCopy.n(top.count))×", label: "the busiest one") }
            }
        }
    }

    // The soundtrack
    private var soundtrack: some View {
        let top = w.linkSenders.first
        let copy = WrappedCopy.yearSoundtrack(total: w.linksTotal, senders: w.linkSenders.count,
                                              top: top?.name ?? "You", topCount: top?.count ?? 0, service: w.topService)
        return StoryCard(eyebrow: "The soundtrack", title: "What you were playing", subtitle: copy) {
            let earliest = w.tracks.map(\.firstDate).min()
            VStack(spacing: 10) {
                ForEach(Array(w.tracks.enumerated()), id: \.offset) { _, t in
                    StoryTrack(title: t.title, author: t.author, service: t.service, kind: t.kind,
                               artwork: t.thumbnail,
                               role: Self.role(t, earliest: earliest),
                               detail: WrappedCopy.trackDetail(by: t.firstBy, date: t.firstDate, times: t.times),
                               reactionBy: nil, reaction: nil, me: "You",
                               embed: t.embed, url: t.url) { onJump(t.messageID, t.chatID) }
                }
            }
            if w.tracks.allSatisfy({ $0.title == nil }) {
                Text("Real titles and artwork are off. Turn on Titles in the bar above to look the songs up; nothing leaves this Mac otherwise.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func role(_ t: YearWrapped.Track, earliest: Date?) -> String {
        if let earliest, t.firstDate == earliest { return "The first one of the year" }
        if t.times >= 3 { return "On repeat" }
        if t.times == 2 { return "Sent twice" }
        return "Shared once"
    }

    // The message that says the most
    private func message(_ l: YearWrapped.Longest) -> some View {
        let media = WrappedCopy.yearMedia(photos: w.media.photos, videos: w.media.videos, voice: w.media.voice)
        return StoryCard(eyebrow: "The message that says the most",
                         title: "The longest thing anyone typed",
                         subtitle: WrappedCopy.yearLongest(chars: l.chars, runnerUp: l.runnerUp, chat: l.chatName, fromMe: l.fromMe, author: l.author)) {
            StoryBubble(author: l.author, text: WrappedCopy.quote(l.text, limit: 600), mine: l.fromMe)
            HStack(spacing: 10) {
                StoryJump(action: { onJump(l.messageID, l.chatID) })
                Text(WrappedCopy.date(l.date, "d MMMM yyyy"))
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
            if let media {
                Text(media).font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Closing line
    private var closing: some View {
        VStack(spacing: 12) {
            Text(WrappedCopy.n(w.total))
                .font(.system(size: 64, weight: .black, design: .rounded)).monospacedDigit()
                .foregroundStyle(AppTheme.Surface.textPrimary)
            Text(WrappedCopy.yearClosing(year: w.year, total: w.total, people: w.peopleCount))
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9))
                Text("Built on this Mac. Nothing left it.").font(AppTheme.Typography.caption)
            }.foregroundStyle(AppTheme.Surface.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppTheme.Spacing.xl)
    }
}

// MARK: - Chart

/// A month-by-month bar chart with one label per month that actually has messages, so a
/// three-month fixture or a library that starts in June reads as a partial year instead
/// of as a chart with broken columns.
struct YearMonthChart: View {
    let monthly: [(month: String, count: Int)]

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let count: Int
        let isPeak: Bool
    }

    var body: some View {
        let peak = monthly.map(\.count).max() ?? 0
        let points = monthly.enumerated().map { i, m in
            Point(id: i, label: Self.short(m.month), count: m.count, isPeak: m.count == peak && peak > 0)
        }
        let labels = points.map(\.label)
        Chart(points) { p in
            BarMark(x: .value("Month", p.label), y: .value("Messages", p.count))
                .foregroundStyle(p.isPeak ? AppTheme.Palette.greenInk : AppTheme.Palette.greenInk.opacity(0.5))
                .cornerRadius(3)
        }
        .chartXScale(domain: labels)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(AppTheme.Surface.hairline)
                AxisValueLabel().foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: labels) { _ in
                AxisGridLine().foregroundStyle(AppTheme.Surface.hairline)
                AxisValueLabel().foregroundStyle(AppTheme.Surface.textSecondary)
            }
        }
        .frame(height: 170)
    }

    private static func short(_ key: String) -> String {
        let month = Int(key.suffix(2)) ?? 1
        return String(WrappedCopy.monthName(month).prefix(3))
    }
}

// MARK: - Export

/// Renders the story offscreen at its reading width. No network, no AppKit controls.
enum YearStoryExport {
    @MainActor static func image(for w: YearWrapped) async -> NSImage? {
        // Offscreen rendering does not wait for `AsyncImage`, so the artwork the export
        // will draw is fetched first; the live window keeps using the same cache.
        await StoryArtwork.preload(w.tracks.compactMap(\.thumbnail))
        let content = YearWrappedStory(w: w, onJump: { _, _ in }, onOpenChat: { _ in }, scrolling: false)
            .frame(width: 760)
            .background(AppTheme.Surface.page)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 760, height: nil)
        return renderer.nsImage
    }

    @MainActor static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    @MainActor static func writePDF(_ image: NSImage, to url: URL) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        var box = CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height))
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return false }
        ctx.beginPDFPage(nil)
        ctx.draw(cg, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return true
    }
}
