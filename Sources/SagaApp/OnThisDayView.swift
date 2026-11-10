import SwiftUI
import AppKit
import SagaCore

/// "On this day" — what the archive holds for one calendar date, across every year.
///
/// The owner's shape: a compact Home card with one human hook, opening into this
/// sheet. Everything here is scripted from the library first; the caption switch
/// is off by default and only ever talks to a local model. Visual language follows
/// `docs/DESIGN.md` and the Wrapped cards: WhatsApp palette, big rounded numbers,
/// the wrapped gradient (teal → indigo) used once per year block.
struct OnThisDayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var date: Date
    @State private var scrollTarget: Int?
    @State private var captions = OnThisDayCaptionStore()

    init(date: Date = Date()) {
        _date = State(initialValue: date)
    }

    private var calendar: Calendar { .current }
    private var month: Int { calendar.component(.month, from: date) }
    private var dayNumber: Int { calendar.component(.day, from: date) }
    private var currentYear: Int { calendar.component(.year, from: Date()) }

    /// The loaded day, but only when it belongs to the date currently shown — so a
    /// date change never flashes the previous day's numbers.
    private var loaded: OnThisDay? {
        guard let d = model.onThisDay, d.month == month, d.day == dayNumber else { return nil }
        return d
    }

    private var dateTitle: String { date.formatted(.dateTime.day().month(.wide)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let loaded, !loaded.years.isEmpty { yearStrip(loaded) }
            Hairline()
            content
        }
        .frame(minWidth: 860, minHeight: 700)
        .background(AppTheme.Surface.page)
        .task { await model.loadOnThisDay(date: date) }
        .onChange(of: date) { _, newValue in
            Task { await model.loadOnThisDay(date: newValue) }
        }
        .task(id: captionTaskKey) {
            guard captions.enabled, let loaded else { return }
            await captions.prepare()
            for year in loaded.years {
                await captions.generate(for: year, month: loaded.month, day: loaded.day)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.l) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    AppTheme.Typography.eyebrow("On this day")
                        .foregroundStyle(AppTheme.Accent.text)
                    Text(dateTitle)
                        .font(AppTheme.Typography.display)
                        .tracking(AppTheme.Typography.displayTracking)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                    Text(summaryLine)
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                }
                Spacer(minLength: AppTheme.Spacing.l)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(AppTheme.Surface.field))
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close On this day")
            }
            controls
        }
        .padding(.horizontal, AppTheme.Spacing.gutter)
        .padding(.top, AppTheme.Spacing.xxl)
        .padding(.bottom, AppTheme.Spacing.l)
    }

    private var summaryLine: String {
        if model.onThisDayError != nil { return "Something went wrong reading this date." }
        guard let loaded else { return model.onThisDayLoading ? "Looking through your archive…" : "Everything stays on this Mac." }
        if loaded.isEmpty { return "Nothing in your archive for this date." }
        return "\(loaded.total.formatted()) messages across \(loaded.years.count) year\(loaded.years.count == 1 ? "" : "s") · everything stays on this Mac"
    }

    private var controls: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            HStack(spacing: 0) {
                Button { shiftDay(-1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .help("Previous day")
                .accessibilityLabel("Previous day")
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .frame(width: 128)
                    .accessibilityLabel("Date")
                Button { shiftDay(1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .help("Next day")
                .accessibilityLabel("Next day")
            }
            .padding(.horizontal, AppTheme.Spacing.xxs)
            .background(AppTheme.Radius.controlShape.fill(AppTheme.Surface.card))
            .overlay(AppTheme.Radius.controlShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))

            pill("Today", symbol: "calendar") {
                date = Date()
            }
            .disabled(calendar.isDateInToday(date))

            pill("Surprise me", symbol: "dice") {
                Task { if let d = await model.surpriseOnThisDay() { date = d } }
            }
            .help("Pick one of the busiest dates in your archive")

            Spacer(minLength: AppTheme.Spacing.s)

            if let note = captions.note, captions.enabled {
                Text(note)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help(note)
            }
            Toggle(isOn: $captions.enabled) {
                Label("Captions", systemImage: "sparkles")
                    .font(AppTheme.Typography.caption.weight(.semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(AppTheme.Accent.primaryFill)
            .help("One warm line per year, written by a local model. Off by default; nothing leaves this Mac.")
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(AppTheme.Typography.caption.weight(.semibold))
                .padding(.horizontal, AppTheme.Spacing.m)
                .padding(.vertical, AppTheme.Spacing.xs)
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .background(Capsule().fill(AppTheme.Surface.card))
                .overlay(Capsule().strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func shiftDay(_ delta: Int) {
        if let next = calendar.date(byAdding: .day, value: delta, to: date) { date = next }
    }

    // MARK: - Year strip

    private func yearStrip(_ day: OnThisDay) -> some View {
        let peak = max(day.strip.map(\.count).max() ?? 0, 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.m) {
                ForEach(day.strip) { s in
                    Button {
                        guard s.count > 0 else { return }
                        scrollTarget = s.year
                    } label: {
                        VStack(spacing: AppTheme.Spacing.hair) {
                            Text(s.count > 0 ? s.count.formatted() : "—")
                                .font(AppTheme.Typography.micro)
                                .foregroundStyle(s.count > 0 ? AppTheme.Surface.textSecondary : AppTheme.Surface.textTertiary)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(s.count > 0 ? AnyShapeStyle(AppTheme.Module.wrapped.gradient) : AnyShapeStyle(AppTheme.Surface.hairline))
                                .frame(width: 26, height: barHeight(s, peak: peak))
                            Text(String(s.year))
                                .font(AppTheme.Typography.caption.weight(.semibold))
                                .foregroundStyle(s.year == currentYear ? AppTheme.Accent.text : AppTheme.Surface.textTertiary)
                        }
                        .padding(.horizontal, AppTheme.Spacing.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(s.count == 0 || !s.dateExists)
                    .help(s.dateExists ? "\(s.count.formatted()) messages on this date in \(String(s.year))" : "This date does not exist in \(String(s.year))")
                    .accessibilityLabel("\(String(s.year)), \(s.count) messages")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.gutter)
            .padding(.vertical, AppTheme.Spacing.s)
        }
        .background(AppTheme.Surface.card.opacity(0.55))
    }

    private func barHeight(_ s: OnThisDay.StripYear, peak: Int) -> CGFloat {
        guard s.dateExists, s.count > 0 else { return 3 }
        return 8 + 30 * CGFloat(s.count) / CGFloat(peak)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let error = model.onThisDayError {
            ErrorStateView(title: "Couldn't read this date",
                           message: "Saga couldn't look through the archive just now. Try again, or pick another day.",
                           detail: error,
                           retryTitle: "Try again",
                           retry: { Task { await model.loadOnThisDay(date: date, force: true) } })
        } else if loaded == nil, model.onThisDayLoading {
            loading
        } else if let day = loaded {
            if day.isEmpty {
                EmptyStateView(
                    symbol: "calendar",
                    title: "Nothing happened on \(dateTitle)",
                    message: "No messages in your archive carry this date. Try another day — or let Saga pick a busy one.",
                    colors: AppTheme.Module.wrapped.colors,
                    actionTitle: "Surprise me",
                    action: { Task { if let d = await model.surpriseOnThisDay() { date = d } } })
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                            ForEach(day.years) { year in
                                YearBlockView(
                                    year: year,
                                    date: date,
                                    currentYear: currentYear,
                                    caption: captions.text(for: year, month: day.month, day: day.day))
                                    .id(year.year)
                            }
                            if let first = day.firstEver, day.years.count > 1 {
                                firstEver(first, day: day)
                            }
                            if !day.quietYears.isEmpty {
                                Text("Quiet on this date: \(day.quietYears.map(String.init).joined(separator: ", ")).")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(AppTheme.Surface.textTertiary)
                                    .padding(.top, AppTheme.Spacing.xxs)
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.gutter)
                        .padding(.vertical, AppTheme.Spacing.xxl)
                        .frame(maxWidth: 1000, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: scrollTarget) { _, year in
                        guard let year else { return }
                        withAnimation(AppTheme.Motion.animation(AppTheme.Motion.gentle, reduceMotion: reduceMotion)) {
                            proxy.scrollTo(year, anchor: .top)
                        }
                        scrollTarget = nil
                    }
                }
            }
        } else {
            loading
        }
    }

    private var loading: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            ProgressView().controlSize(.large)
            Text("Looking through \(dateTitle) across your years…")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Surface.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The one block that is not per-year: the very first message the archive holds
    /// for this date, whichever year it came from.
    private func firstEver(_ moment: OnThisDay.Moment, day: OnThisDay) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AppTheme.Typography.eyebrow("The first ever message on this date")
                .foregroundStyle(AppTheme.Accent.text)
            Text("“\(moment.preview(220))”")
                .font(AppTheme.Typography.section)
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.s) {
                Avatar(name: moment.sender, size: 22)
                Text(moment.fromMe ? "You" : moment.sender)
                    .font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                Text(moment.ts.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Radius.panelWash)
        .overlay(AppTheme.Radius.cardShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
    }

    private var captionTaskKey: String {
        "\(month)-\(dayNumber)-\(loaded.map { $0.years.map(\.year).map(String.init).joined(separator: ",") } ?? "")-\(captions.enabled)"
    }
}

// MARK: - One year

private struct YearBlockView: View {
    let year: OnThisDay.Year
    let date: Date
    let currentYear: Int
    let caption: String?

    private var dateLong: String {
        var comps = DateComponents()
        comps.year = year.year
        comps.month = Calendar.current.component(.month, from: date)
        comps.day = Calendar.current.component(.day, from: date)
        let d = Calendar.current.date(from: comps) ?? year.firstDay
        return d.formatted(.dateTime.day().month(.wide).year())
    }

    private var relative: String {
        if year.year == currentYear { return "This year" }
        if year.year == currentYear - 1 { return "Last year" }
        return "\(currentYear - year.year) years ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            header
            if let caption, !caption.isEmpty {
                Text("“\(caption)”")
                    .font(AppTheme.Typography.body)
                    .italic()
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let highlight = year.highlight { highlightCard(highlight) }
            if year.first != nil || year.last != nil { firstAndLast }
            if !year.people.isEmpty { people }
            if !year.media.isEmpty { media }
            if !year.links.isEmpty { links }
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Radius.cardShape.fill(AppTheme.Surface.card))
        .overlay(AppTheme.Radius.cardShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        .themeShadow(AppTheme.Elevation.card)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                AppTheme.Typography.eyebrow(relative)
                    .foregroundStyle(AppTheme.Accent.text)
                Text(dateLong)
                    .font(AppTheme.Typography.title)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                Text("\(year.chatCount) chat\(year.chatCount == 1 ? "" : "s") · \(year.sent.formatted()) from you")
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
            Spacer(minLength: AppTheme.Spacing.m)
            Text(year.count.formatted())
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.Module.wrapped.gradient)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .accessibilityLabel("\(year.count) messages")
        }
    }

    private func highlightCard(_ h: OnThisDay.Moment) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                AppTheme.Typography.eyebrow(h.reaction == nil ? "The day's biggest laugh" : "The exchange that got the biggest laugh")
                    .foregroundStyle(AppTheme.Accent.text)
                Spacer(minLength: AppTheme.Spacing.s)
            }
            Text("“\(h.preview(260))”")
                .font(AppTheme.Typography.section)
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AppTheme.Spacing.s) {
                Avatar(name: h.sender, size: 22)
                Text(h.fromMe ? "You" : h.sender)
                    .font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                Text(h.ts.formatted(date: .omitted, time: .shortened))
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
                Spacer(minLength: AppTheme.Spacing.s)
                if let reaction = h.reaction {
                    Text("↩ \(reaction)")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(AppTheme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Radius.panelWash)
    }

    private var firstAndLast: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            if let first = year.first { momentCard("First message", moment: first) }
            if let last = year.last { momentCard("Last message", moment: last) }
        }
    }

    private func momentCard(_ title: String, moment: OnThisDay.Moment) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            AppTheme.Typography.eyebrow(title)
                .foregroundStyle(AppTheme.Surface.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                Text(moment.ts.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                Text(moment.fromMe ? "You" : moment.sender)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .lineLimit(1)
            }
            Text(moment.preview(110))
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppTheme.Radius.controlShape.fill(AppTheme.Surface.field))
        .overlay(AppTheme.Radius.controlShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AppTheme.Typography.eyebrow("Who you talked to")
                .foregroundStyle(AppTheme.Surface.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.s) {
                    ForEach(year.people) { p in
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Avatar(name: p.name, group: p.isGroup, size: 20)
                            Text(p.name)
                                .font(AppTheme.Typography.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.Surface.textPrimary)
                                .lineLimit(1)
                            Text(p.count.formatted())
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Surface.textTertiary)
                        }
                        .padding(.horizontal, AppTheme.Spacing.s)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(Capsule().fill(AppTheme.Surface.field))
                    }
                }
            }
        }
    }

    private var media: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack {
                AppTheme.Typography.eyebrow("Photos and videos")
                    .foregroundStyle(AppTheme.Surface.textTertiary)
                Spacer()
                if year.mediaCount > year.media.count {
                    Text("+\(year.mediaCount - year.media.count) more")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.s) {
                    ForEach(year.media.prefix(24)) { item in
                        OnThisDayMediaThumb(item: item)
                    }
                }
                .padding(.vertical, AppTheme.Spacing.hair)
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            AppTheme.Typography.eyebrow("Music and video shared")
                .foregroundStyle(AppTheme.Surface.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.s) {
                    ForEach(year.links) { link in
                        OnThisDayLinkChip(link: link)
                    }
                }
            }
        }
    }
}

// MARK: - Media thumbnail

private struct OnThisDayMediaThumb: View {
    @Environment(AppModel.self) private var model
    let item: OnThisDay.MediaItem
    @State private var thumb: NSImage?
    @State private var failed = false
    @State private var viewing: URL?
    @State private var opening = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous) }

    var body: some View {
        Button { open() } label: {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    shape.fill(AppTheme.Surface.field)
                        .overlay {
                            if failed {
                                Image(systemName: item.media.kind == "video" ? "video.slash" : "photo")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(AppTheme.Surface.textTertiary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                }
                if item.media.kind == "video" {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(radius: 2)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(shape)
            .overlay(shape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(item.media.caption?.isEmpty == false ? (item.media.caption ?? "") : "\(item.chatName) · \(item.ts.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityLabel("\(item.media.kind == "video" ? "Video" : "Photo") from \(item.chatName), \(item.ts.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityHint("Opens the full attachment")
        .task(id: model.mediaGeneration) { await loadThumb() }
        .sheet(item: Binding(get: { viewing.map(Item.init) }, set: { viewing = $0?.url })) { item in
            MediaViewer(url: item.url, isVideo: self.item.media.kind == "video")
        }
    }

    private struct Item: Identifiable { let url: URL; var id: URL { url } }

    private func loadThumb() async {
        guard !opening else { return }
        let url = try? await model.mediaLoader()?.thumbnail(for: item.media)
        if Task.isCancelled { return }
        if let url, let image = NSImage(contentsOf: url) { thumb = image; failed = false } else { failed = true }
    }

    private func open() {
        guard !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            if let url = try? await model.mediaLoader()?.file(for: item.media) { viewing = url }
            else { failed = true }
        }
    }
}

// MARK: - Link chip

private enum OnThisDayLinkMeta {
    static let cache: LinkMetaCache? = try? LinkMetaCache(path: AppModel.supportDir.appendingPathComponent("link_meta.db").path)
}

private struct OnThisDayLinkChip: View {
    let link: OnThisDay.Link
    @State private var hovering = false

    private var title: String {
        if let cached = OnThisDayLinkMeta.cache?.get(link.key)?.title, !cached.isEmpty { return cached }
        return "\(link.service.rawValue) \(link.kind)"
    }

    var body: some View {
        Button {
            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: AppTheme.Spacing.s) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                    .fill(AppTheme.Module.music.gradient)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: link.service.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(AppTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                        .lineLimit(1)
                    Text("\(link.service.rawValue) · \(link.fromMe ? "You" : link.sender)")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .lineLimit(1)
                }
                if link.times > 1 {
                    Text("×\(link.times)")
                        .font(AppTheme.Typography.micro)
                        .foregroundStyle(AppTheme.Surface.textTertiary)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.s)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: 260, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.input, style: .continuous).fill(hovering ? AppTheme.Surface.hover : AppTheme.Surface.field))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.input, style: .continuous).strokeBorder(hovering ? AppTheme.Accent.primary.opacity(0.5) : AppTheme.Surface.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .themeAnimation(AppTheme.Motion.quick, value: hovering)
        .help(link.url)
        .accessibilityLabel("\(title), \(link.service.rawValue)")
        .accessibilityHint("Opens in your browser")
    }
}

// MARK: - Home card

/// The compact Home entry point: one number, one hook, a thumbnail or song when
/// the day has one. Tapping opens the sheet; hiding is a context-menu action (and
/// a Go-menu toggle).
struct OnThisDayHomeCard: View {
    @Environment(AppModel.self) private var model
    /// In a row beside a taller card, the strip grows so both cards end on the same line.
    var expands = false
    @State private var hovering = false

    private var peek: OnThisDay.Peek? { model.onThisDay?.peek }
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    private var eyebrow: String {
        guard let year = peek?.year.year else { return "On this day" }
        return "On this day · \(year == currentYear ? "this year" : year == currentYear - 1 ? "last year" : "\(currentYear - year) years ago")"
    }

    private var title: String {
        if let peek { return peek.headline }
        if model.onThisDay?.isEmpty == true { return "Nothing on \(Date().formatted(.dateTime.day().month(.wide)))" }
        return "What happened on \(Date().formatted(.dateTime.day().month(.wide)))?"
    }

    private var detail: String {
        if let peek { return peek.detail }
        if model.onThisDay?.isEmpty == true { return "Your archive is quiet on this date. Open it to pick another day." }
        return "Messages, photos and songs from this date, across every year."
    }

    var body: some View {
        Button { model.openOnThisDay() } label: {
            HStack(spacing: AppTheme.Spacing.l) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.icon + 2, style: .continuous)
                    .fill(AppTheme.Module.wrapped.gradient)
                    .frame(width: 52, height: 52)
                    .overlay(Image(systemName: "calendar.badge.clock").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    AppTheme.Typography.eyebrow(eyebrow)
                        .foregroundStyle(AppTheme.Accent.text)
                    Text(title)
                        .font(AppTheme.Typography.title)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                        .lineLimit(1)
                    Text(detail)
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.m)
                if let media = peek?.media {
                    HomeThumb(media: media)
                } else if let link = peek?.link {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: link.service.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: AppTheme.Radius.control).fill(AppTheme.Module.music.gradient))
                        Text(link.service.rawValue)
                            .font(AppTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Surface.textSecondary)
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            }
            .padding(AppTheme.Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: expands ? .infinity : nil, alignment: .center)
            .background(AppTheme.Radius.cardShape.fill(AppTheme.Surface.card))
            .overlay(AppTheme.Radius.cardShape.strokeBorder(hovering ? AppTheme.Accent.primary.opacity(0.55) : AppTheme.Surface.hairline, lineWidth: 1))
            .themeShadow(hovering ? AppTheme.Elevation.floating : AppTheme.Elevation.card)
            .offset(y: hovering ? -AppTheme.Spacing.lift : 0)
            .contentShape(AppTheme.Radius.cardShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .themeAnimation(AppTheme.Motion.quick, value: hovering)
        .contextMenu {
            Button("Hide from Home") { model.showOnThisDayOnHome = false }
            Button("Open On this day…") { model.openOnThisDay() }
        }
        .help("What happened on this date across your years")
        .accessibilityLabel("\(eyebrow). \(title). \(detail)")
        .accessibilityHint("Opens On this day")
    }
}

private struct HomeThumb: View {
    @Environment(AppModel.self) private var model
    let media: OnThisDay.MediaItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control).fill(AppTheme.Surface.field)
                    .overlay(Image(systemName: media.media.kind == "video" ? "video" : "photo").font(.system(size: 16)).foregroundStyle(AppTheme.Surface.textTertiary))
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous).strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        .task(id: model.mediaGeneration) {
            if let url = try? await model.mediaLoader()?.thumbnail(for: media.media) { image = NSImage(contentsOf: url) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Captions (local model, off by default)

/// One line per year block, generated by a local model and cached by date + the
/// message the line describes, so a caption is never regenerated for the same day.
@MainActor @Observable
final class OnThisDayCaptionStore {
    var enabled: Bool = (UserDefaults.standard.bool(forKey: "onThisDayCaptions") || ProcessInfo.processInfo.arguments.contains("--otd-captions")) {
        didSet {
            guard AppModel.demoRoot == nil, !ProcessInfo.processInfo.arguments.contains("--otd-captions") else { return }
            UserDefaults.standard.set(enabled, forKey: "onThisDayCaptions")
        }
    }
    var note: String?
    private(set) var texts: [String: String] = [:]
    private var model: AIModel?
    private var detecting = false
    private var cache: AICache?

    init() {
        cache = try? AICache(path: AppModel.supportDir.appendingPathComponent("ai_cache.db").path)
    }

    func prepare() async {
        guard enabled, model == nil, !detecting else { return }
        detecting = true
        let found = await LocalAI.detect()
        model = found.models.first(where: { $0.kind == .apple }) ?? found.models.first
        if model == nil { note = found.hints.first ?? "No local model found. Apple Intelligence or Ollama can write these." }
        detecting = false
    }

    func text(for year: OnThisDay.Year, month: Int, day: Int) -> String? {
        texts[key(year, month, day)]
    }

    func generate(for year: OnThisDay.Year, month: Int, day: Int) async {
        guard enabled, let model else { return }
        let k = key(year, month, day)
        if texts[k] != nil { return }
        if let cached = cache?.caption(key: k) { texts[k] = cached; return }
        let prompt = prompt(year, month, day)
        do {
            let line = try await LocalAI.oneLine(
                system: "You write one short, warm, specific caption for a private chat archive. Use only the facts given. Never invent details, never mention being an AI, and do not start with \"On this day\".",
                prompt: prompt, model: model)
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            guard !clean.isEmpty else { return }
            cache?.saveCaption(key: k, text: clean)
            texts[k] = clean
            note = nil
        } catch is CancellationError {
            // Changing the date cancels the caption request; that is not a failure to report.
        } catch {
            note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func key(_ year: OnThisDay.Year, _ month: Int, _ day: Int) -> String {
        // Date + the stable uid of the message the line describes. Row IDs change on
        // rebuild; uids do not, so a caption never lands on a different message.
        let anchor = [year.highlight?.uid, year.first?.uid].compactMap { $0 }.first { !$0.isEmpty } ?? "year"
        return "otd:v1:\(month)-\(day):\(year.year):\(anchor)"
    }

    private func prompt(_ year: OnThisDay.Year, _ month: Int, _ day: Int) -> String {
        var comps = DateComponents(); comps.year = year.year; comps.month = month; comps.day = day
        let date = Calendar.current.date(from: comps) ?? year.firstDay
        var lines = [
            "Date: \(date.formatted(.dateTime.day().month(.wide).year())).",
            "Messages: \(year.count) across \(year.chatCount) chats; \(year.sent) from me.",
            "People and chats: \(year.people.map(\.name).joined(separator: ", "))."
        ]
        if let first = year.first { lines.append("First message at \(first.ts.formatted(date: .omitted, time: .shortened)) — \(first.sender): \(OnThisDay.clip(first.text, 120))") }
        if let last = year.last { lines.append("Last message at \(last.ts.formatted(date: .omitted, time: .shortened)) — \(last.sender): \(OnThisDay.clip(last.text, 120))") }
        if let h = year.highlight {
            lines.append("Biggest laugh: \(h.sender) said \"\(OnThisDay.clip(h.text, 160))\"")
            if let r = h.reaction { lines.append("Reply: \(r)") }
        }
        if year.mediaCount > 0 { lines.append("Photos and videos: \(year.mediaCount).") }
        if let link = year.links.first { lines.append("Music shared: \(link.service.rawValue) \(link.kind).") }
        lines.append("Write one sentence of at most 18 words capturing what this day felt like. Plain language, no emoji, no hashtags.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Theme helpers

private extension AppTheme.Radius {
    /// Panel wash used by the highlight and first-ever cards: one step warmer than the
    /// page, with the wrapped accent at low opacity so white text never sits on it.
    static var panelWash: some ShapeStyle {
        LinearGradient(colors: [AppTheme.Surface.accentWash, AppTheme.Surface.card],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
