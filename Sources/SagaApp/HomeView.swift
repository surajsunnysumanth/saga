import SwiftUI
import AppKit
import Charts
import SagaCore

/// Home: one hero card for the current task, four gradient-squircle module tiles,
/// then the archive's insight panels.
///
/// Every colour, radius, type size, space and motion curve comes from `AppTheme`
/// (`docs/DESIGN.md`, section "App (SwiftUI)"). Nothing here hard-codes a colour or
/// a corner radius, so the palette can change in one place.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // GeometryReader gives the pane's real width, so the tile grid picks its column
        // count from the space it actually has (1 / 2 / 4) with no feedback loop.
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                    header
                    if let s = model.stats, model.vaultOK, !model.updating {
                        ArchiveHeroCard(stats: s, updating: false, action: runHeroAction)
                    } else {
                        HeroStatusCard(
                            eyebrow: hero.eyebrow,
                            title: hero.title,
                            detail: hero.detail,
                            actionTitle: hero.action,
                            busy: hero.busy,
                            action: runHeroAction
                        )
                    }
                    modules(width: proxy.size.width)
                    if let release = model.announcedUpdate { updateBanner(release) }
                    if let waiting = model.replyWaitingCount, waiting > 0 { replyCard(waiting) }
                    bottomRow(width: proxy.size.width)
                    if let s = model.stats { insights(s, width: proxy.size.width) }
                }
                .padding(.horizontal, AppTheme.Spacing.gutter)
                .padding(.vertical, AppTheme.Spacing.xxl)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color.clear)
        }
        .task {
            model.loadSharedLinkCount()
            model.loadReplyWaitingCount()
            if model.showOnThisDayOnHome { await model.loadOnThisDay() }
        }
        // The hero's "Add a backup" belongs to this view, so this view hosts the sheet. It was on
        // `ContentView`'s chain with six others, where it had no reliable presentation slot.
        .sheet(isPresented: Binding(get: { model.showFoldIn }, set: { model.showFoldIn = $0 })) {
            FoldInView().environment(model)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Your archive")
                .font(AppTheme.Typography.display)
                .tracking(AppTheme.Typography.displayTracking)
                .foregroundStyle(AppTheme.Surface.textPrimary)
            Text(headerDetail)
                .font(AppTheme.Typography.callout)
                .foregroundStyle(AppTheme.Surface.textSecondary)
        }
    }

    private var headerDetail: String {
        guard let s = model.stats else { return "Everything stays on this Mac." }
        let first = s.first.formatted(.dateTime.month(.wide).year())
        let last = s.last.formatted(.dateTime.month(.wide).year())
        return first == last
            ? "\(first) · \(s.messages.formatted()) messages · everything stays on this Mac"
            : "\(first) – \(last) · \(s.messages.formatted()) messages · everything stays on this Mac"
    }

    // MARK: - Hero

    private struct Hero {
        let eyebrow: String
        let title: String
        let detail: String
        let action: String
        let busy: Bool
    }

    private var hero: Hero {
        if !model.vaultOK {
            return Hero(eyebrow: "Needs attention",
                        title: "Your archive folder isn't reachable",
                        detail: "Reconnect the drive or choose the folder again. Nothing has been lost — Saga just can't read it right now.",
                        action: "Choose folder", busy: false)
        }
        if model.updating {
            return Hero(eyebrow: "Updating",
                        title: "Bringing in the latest from your phone",
                        detail: model.toast ?? "Reading the newest WhatsApp backup and merging it into your archive.",
                        action: "Updating…", busy: true)
        }
        if model.stats == nil {
            return Hero(eyebrow: "Get started",
                        title: "Nothing in your archive yet",
                        detail: "Add your phone's WhatsApp backup and Saga builds a searchable archive on this Mac.",
                        action: "Add a backup", busy: false)
        }
        if let hint = model.phoneHint {
            return Hero(eyebrow: "Ready when you are",
                        title: "A newer backup is waiting on your phone",
                        detail: "\(hint) · Only missing messages are added.",
                        action: "Update from phone", busy: false)
        }
        let last = model.stats.map { "Last message \($0.last.formatted(.dateTime.day().month(.abbreviated).year()))." } ?? ""
        return Hero(eyebrow: "Up to date",
                    title: "Your library is up to date",
                    detail: "\(last) Pull the latest backup whenever you're ready.".trimmingCharacters(in: .whitespaces),
                    action: "Update from phone", busy: false)
    }

    private func runHeroAction() {
        if !model.vaultOK { chooseFolder(); return }
        if model.stats == nil { model.showFoldIn = true; return }
        model.updateFromPhone()
    }

    /// Same behaviour as the "Change archive folder…" menu item.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Pick the folder that holds your Saga archive"
        if panel.runModal() == .OK, let url = panel.url { model.moveVault(to: url) }
    }


    /// The human half of the page: what you were talking about lately, next to what you
    /// were talking about on this day. Two columns, same gutter as everything else.
    private func bottomRow(width: CGFloat) -> some View {
        // LazyVGrid stretches the items of a row to the tallest one, which is what makes
        // the pair read as a band instead of two orphaned cards.
        let columns = Array(repeating: GridItem(.flexible(minimum: 260), spacing: AppTheme.Spacing.gap),
                            count: width >= 780 ? 2 : 1)
        return LazyVGrid(columns: columns, spacing: AppTheme.Spacing.gap) {
            recentCard
            if model.showOnThisDayOnHome { OnThisDayHomeCard(expands: true) }
        }
    }

    /// A to-do belongs where a person looks first, and only when there is one: a permanent
    /// "0 waiting" card would be a chore on the one screen that is meant to be a library.
    private func replyCard(_ count: Int) -> some View {
        Button { model.openReplyReview() } label: {
            HStack(spacing: AppTheme.Spacing.m) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.text)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AppTheme.Surface.accentWash))
                VStack(alignment: .leading, spacing: 1) {
                    Text(count == 1 ? "1 might need your reply" : "\(count.formatted()) might need your reply")
                        .font(AppTheme.Typography.section)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                    Text("Questions in one-to-one chats your archive shows unanswered.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                }
                Spacer(minLength: AppTheme.Spacing.s)
                Text("Review…")
                    .font(AppTheme.Typography.callout.weight(.medium))
                    .foregroundStyle(AppTheme.Accent.text)
            }
            .padding(AppTheme.Spacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(radius: AppTheme.Radius.panel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) questions might need your reply. Review them.")
    }

    /// A release notice is one quiet line in the page flow, not a modal: it sits under the tiles,
    /// links straight to the DMG, and the × dismisses that version only.
    private func updateBanner(_ release: UpdateRelease) -> some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Accent.text)
                .accessibilityHidden(true)
            Text("Saga \(release.versionText) is available")
                .font(AppTheme.Typography.callout.weight(.medium))
                .foregroundStyle(AppTheme.Surface.textPrimary)
                .lineLimit(1)
            Button("Download") { model.openUpdate(release) }
                .buttonStyle(.plain)
                .font(AppTheme.Typography.callout.weight(.semibold))
                .foregroundStyle(AppTheme.Accent.text)
                .help("Download Saga \(release.versionText)")
            Spacer(minLength: AppTheme.Spacing.s)
            Button { model.skipUpdate(release) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.Surface.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Skip this version")
            .accessibilityLabel("Skip version \(release.versionText)")
        }
        .padding(.leading, AppTheme.Spacing.l)
        .padding(.trailing, AppTheme.Spacing.s)
        .padding(.vertical, AppTheme.Spacing.xs)
        .glassSurface(radius: AppTheme.Radius.panel)
    }

    @ViewBuilder private var recentCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Recent conversations")
                .font(AppTheme.Typography.section)
                .foregroundStyle(AppTheme.Surface.textPrimary)
            VStack(spacing: 0) {
                ForEach(Array(model.chats.prefix(4).enumerated()), id: \.element.id) { index, chat in
                    if index > 0 { Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1) }
                    Button {
                        model.section = .chats
                        model.openChat(chat)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.m) {
                            Avatar(name: chat.name, group: chat.isGroup, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(chat.name)
                                    .font(AppTheme.Typography.rowName)
                                    .foregroundStyle(AppTheme.Surface.textPrimary)
                                    .lineLimit(1)
                                Text(chat.preview.replacingOccurrences(of: "\n", with: " "))
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(AppTheme.Surface.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: AppTheme.Spacing.s)
                            Text(chat.last.listLabel)
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Surface.textTertiary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, AppTheme.Spacing.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(chat.name)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSurface(radius: AppTheme.Radius.panel)
    }

    // MARK: - Module tiles

    fileprivate struct Tile: Identifiable {
        let module: AppTheme.ModuleAppearance
        let value: String
        let caption: String
        /// The existing "Go" menu shortcut for this module, shown as a hint. Tiles
        /// never register new shortcuts, so the menu keeps owning them.
        let shortcut: String?
        var id: String { module.id }
    }

    private var tiles: [Tile] {
        let s = model.stats
        // The hero already owns the message count; this card answers "how many rooms".
        let chatsValue = s.map { $0.chats.formatted() } ?? "—"
        let peopleValue = s.map { $0.namedPeople.formatted() } ?? "—"
        let wrappedYear = s?.yearly.last?.year ?? model.wrappedYear
        let linksValue = model.sharedLinkCount.map { $0.formatted() } ?? "—"
        let linksCaption = model.sharedLinkCount == 0 ? "No links yet · Spotify, YouTube" : "Links from Spotify and YouTube"
        return [
            Tile(module: AppTheme.Module.chats, value: chatsValue,
                 caption: "Conversations, all searchable",
                 shortcut: "⌘1"),
            Tile(module: AppTheme.Module.people, value: peopleValue,
                 caption: "People and groups you talk to",
                 shortcut: "⌘2"),
            Tile(module: AppTheme.Module.wrapped, value: wrappedYear,
                 caption: "Your year in messages and hours",
                 shortcut: "⌘3"),
            Tile(module: AppTheme.Module.music, value: linksValue,
                 caption: linksCaption,
                 shortcut: nil),
        ]
    }

    private func modules(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            AppTheme.Typography.eyebrow("Modules")
                .foregroundStyle(AppTheme.Surface.textSecondary)
            LazyVGrid(columns: gridColumns(width), spacing: AppTheme.Spacing.gap) {
                ForEach(tiles) { t in
                    ModuleTile(tile: t) { model.openModule(t.module.id) }
                }
            }
        }
    }

    private func gridColumns(_ width: CGFloat) -> [GridItem] {
        // Four across at desktop widths, the way the mockup reads: the row is the point,
        // a 2x2 grid makes the modules look like the main content.
        let count = width >= 740 ? 4 : (width >= 460 ? 2 : 1)
        return Array(repeating: GridItem(.flexible(minimum: 150), spacing: AppTheme.Spacing.gap), count: count)
    }

    // MARK: - Insights

    private func insightColumns(_ width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 260), spacing: AppTheme.Spacing.gap),
              count: width >= 840 ? 2 : 1)
    }

    private func insights(_ s: VaultStats, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            AppTheme.Typography.eyebrow("Insights")
                .foregroundStyle(AppTheme.Surface.textSecondary)
            LazyVGrid(columns: insightColumns(width), spacing: AppTheme.Spacing.gap) {
                panel("Messages per year") {
                    Chart {
                        ForEach(s.yearly, id: \.year) { y in
                            BarMark(x: .value("Year", y.year), y: .value("Messages", y.sent))
                                .foregroundStyle(by: .value("Type", "Sent"))
                            BarMark(x: .value("Year", y.year), y: .value("Messages", y.count - y.sent))
                                .foregroundStyle(by: .value("Type", "Received"))
                        }
                    }
                    .chartForegroundStyleScale(["Sent": AppTheme.Accent.primary,
                                                "Received": AppTheme.Surface.textSecondary.opacity(0.5)])
                    .chartLegend(position: .top, alignment: .trailing)
                    .frame(height: 200)
                }
                panel("Time of day") {
                    Chart(s.hourly, id: \.hour) { h in
                        BarMark(x: .value("Hour", h.hour), y: .value("Messages", h.count))
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                    .chartXScale(domain: 0...24)
                    .frame(height: 200)
                }
            }
            panel("Most active chats") {
                VStack(spacing: 0) {
                    ForEach(Array(s.topChats.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1) }
                        Button {
                            model.section = .chats
                            model.openChat(c)
                        } label: {
                            HStack(spacing: AppTheme.Spacing.m) {
                                Avatar(name: c.name, group: c.isGroup, size: 28)
                                Text(c.name)
                                    .font(AppTheme.Typography.rowName)
                                    .foregroundStyle(AppTheme.Surface.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: AppTheme.Spacing.s)
                                Text(c.count.formatted())
                                    .font(AppTheme.Typography.rowMeta)
                                    .foregroundStyle(AppTheme.Surface.textSecondary)
                            }
                            .padding(.vertical, AppTheme.Spacing.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(c.name)")
                    }
                }
            }
        }
    }

    private func panel<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text(title)
                .font(AppTheme.Typography.section)
                .foregroundStyle(AppTheme.Surface.textPrimary)
            content()
        }
        .padding(AppTheme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Radius.cardShape.fill(AppTheme.Surface.card))
        .overlay(AppTheme.Radius.cardShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        .themeShadow(AppTheme.Elevation.card)
    }
}

// MARK: - Hero card

/// One wide card for whatever the app wants you to do next (DESIGN.md, "Hero card").
/// The pill is a plain `Button`, so it joins the keyboard focus order on its own.

/// The archive's own number, set as the subject of the screen. Grafted from the Opus
/// attempt onto Kimi's information order: the count first, the facts under it, the one
/// action on the right where a Mac app puts its primary verb.
private struct ArchiveHeroCard: View {
    let stats: VaultStats
    let updating: Bool
    let action: () -> Void

    private var span: String {
        let first = stats.first.formatted(.dateTime.month(.abbreviated).year())
        let last = stats.last.formatted(.dateTime.month(.abbreviated).year())
        return "\(first) – \(last)"
    }

    private var days: Int {
        max(1, Calendar.current.dateComponents([.day], from: stats.first, to: stats.last).day ?? 1)
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                AppTheme.Typography.eyebrow("Your archive · \(span)")
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                    Text(stats.messages.formatted())
                        .font(AppTheme.Typography.heroNumber)
                        .tracking(AppTheme.Typography.heroTracking)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("messages, still yours")
                        .font(AppTheme.Typography.section)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(stats.chats.formatted()) conversations · \(stats.namedPeople.formatted()) people · \(days.formatted()) days · searchable offline")
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
            .layoutPriority(1)

            Spacer(minLength: AppTheme.Spacing.xl)

            // Status and the one action, laid out as a column with a shared left edge.
            // A panel inside the hero panel made this corner muddy; it needs no surface of
            // its own, just quiet type and one solid pill.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(AppTheme.Accent.primary).frame(width: 7, height: 7)
                    Text("Up to date")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                }
                Text("Last message \(stats.last.formatted(.dateTime.day().month(.abbreviated).year()))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .padding(.top, 3)
                Button(action: action) {
                    HStack(spacing: 6) {
                        if updating { ProgressView().controlSize(.mini).tint(AppTheme.Accent.onAccent) }
                        Text("Update from phone")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HeroPillStyle())
                .disabled(updating)
                .padding(.top, 14)
            }
            .frame(width: 196, alignment: .leading)
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A green wash lives inside the glass, so the hero has a temperature without
            // becoming an opaque slab.
            LinearGradient(colors: [AppTheme.Accent.tint.opacity(0.22), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous))
        }
        .glassSurface(radius: AppTheme.Radius.card)
    }

    private var orb: some View {
        Circle()
            .fill(
                RadialGradient(colors: [AppTheme.Accent.primary.opacity(0.22), AppTheme.Accent.primary.opacity(0.01)],
                               center: .center, startRadius: 2, endRadius: 150)
            )
            .frame(width: 260, height: 260)
            .offset(x: 96, y: -104)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct HeroStatusCard: View {
    let eyebrow: String
    let title: String
    let detail: String
    let actionTitle: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                AppTheme.Typography.eyebrow(eyebrow)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                Text(title)
                    .font(AppTheme.Typography.title)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: AppTheme.Spacing.l)
            Button(action: action) {
                HStack(spacing: AppTheme.Spacing.s) {
                    if busy { ProgressView().controlSize(.small).tint(AppTheme.Accent.onAccent) }
                    Text(actionTitle).font(AppTheme.Typography.section)
                }
            }
            .buttonStyle(HeroPillStyle())
            .fixedSize(horizontal: true, vertical: false)
            .disabled(busy)
            .help(detail)
            .accessibilityHint("Runs the suggested step")
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Radius.heroShape.fill(AppTheme.Surface.hero))
        .overlay(AppTheme.Radius.heroShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
        .themeShadow(AppTheme.Elevation.card)
    }
}

/// Filled teal pill with white text (7.7:1) — `AppTheme.Accent.primaryFill`, never
/// `Palette.green`, which cannot carry white text at this size.
private struct HeroPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppTheme.Accent.onAccent)
            .padding(.horizontal, AppTheme.Spacing.l)
            .padding(.vertical, AppTheme.Spacing.s + 1)
            .background(Capsule().fill(configuration.isPressed ? AppTheme.Accent.pressed : AppTheme.Accent.primaryFill))
            .opacity(configuration.isPressed ? 0.92 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Module tile

/// A 20pt-radius card holding a gradient squircle icon, the module's number, its
/// title and a one-line status. Hover lifts it 2pt and warms the border; a press dips it and
/// fills the card, so the whole tile reads as the control it is.
private struct ModuleTile: View {
    let tile: HomeView.Tile
    let action: () -> Void
    @State private var hovering = false
    /// Keyboard focus, so the tile is operable without a mouse (VoiceOver and Full Keyboard
    /// Access both land here).
    @Environment(\.isFocused) private var focused

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    icon
                    Spacer(minLength: AppTheme.Spacing.s)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hovering ? AppTheme.Accent.text : AppTheme.Surface.textTertiary)
                }
                Spacer(minLength: AppTheme.Spacing.m)
                Text(tile.value)
                    .font(AppTheme.Typography.number)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(tile.module.title)
                    .font(AppTheme.Typography.section)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .padding(.top, AppTheme.Spacing.xxs)
                Text(tile.caption)
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Spacing.hair)
            }
            .padding(AppTheme.Spacing.cardPadding)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .glassSurface(radius: AppTheme.Radius.panel)
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.panel, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: focused ? 2 : 1)
            }
            .offset(y: hovering ? -AppTheme.Spacing.lift : 0)
            // The whole card is the hit area, not just the words in it.
            .contentShape(AppTheme.Radius.tileShape)
        }
        .buttonStyle(ModuleTileStyle())
        .focusable(true)
        .onHover { hovering = $0 }
        .themeAnimation(AppTheme.Motion.quick, value: hovering)
        .help("Open \(tile.module.title)")
        .accessibilityLabel("\(tile.module.title), \(tile.value). \(tile.caption)")
        .accessibilityHint("Opens \(tile.module.title)")
    }

    private var borderColor: Color {
        if focused { return AppTheme.Accent.primary }
        return hovering ? AppTheme.Accent.primary.opacity(0.5) : .clear
    }

    /// Gradient squircle with the module's SF Symbol. Every gradient stop keeps a
    /// white symbol at ≥ 4:1 (verified with the token layer).
    private var icon: some View {
        AppTheme.Radius.squircle(AppTheme.Radius.icon + 2)
            .fill(tile.module.gradient)
            .frame(width: 52, height: 52)
            .overlay(
                Image(systemName: tile.module.symbol)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Press feedback for a whole tile: a slight dip and a dim, so a click lands visibly even
/// when the destination takes a moment to draw.
private struct ModuleTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(AppTheme.Motion.quick, value: configuration.isPressed)
    }
}
