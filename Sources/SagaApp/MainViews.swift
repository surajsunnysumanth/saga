import SwiftUI
import Charts
import SagaCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        @Bindable var panel = model.aiPanel
        Group {
            if model.store == nil {
                WizardView()
            } else {
                ZStack {
                    FieldBackground()
                    VStack(spacing: 0) {
                        TopBar()
                        content
                    }
                }
                .overlay(alignment: .bottom) {
                    if let t = model.toast {
                        HStack(spacing: 8) { if model.updating { ProgressView().controlSize(.small) }; Text(t) }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(radius: 4).padding(.bottom, 16)
                    }
                }
                .inspector(isPresented: $panel.open) { AIPanelView().inspectorColumnWidth(min: 300, ideal: 380, max: 560) }
                // One host for the window-wide sheets. Stacked `.sheet(isPresented:)` modifiers on a
                // single view give macOS one presentation slot: a flag that flips while another sheet
                // owns it is silently dropped and the menu item looks dead. An item-driven sheet is one
                // modifier, so every case gets a slot. The Unnamed sheet lives on `PeopleSidebar`,
                // Fold-in on `HomeView`, and the Archive/Settings sheets on their own panes.
                .sheet(item: $m.appSheet) { sheet in
                    switch sheet {
                    case .merge: MergeView().environment(model)
                    case .prune: PruneView().environment(model)
                    case .onThisDay: OnThisDayView(date: model.onThisDayDate).environment(model)
                    case .unlock: VaultUnlockView().environment(model)
                    case .needsKey:
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your 64-digit backup key").font(.title3.bold())
                            Text("Needed once to unlock the new backup. It's stored in this Mac's Keychain.").foregroundStyle(.secondary)
                            SecureField("Paste the key", text: $m.keyEntry).textFieldStyle(.roundedBorder).frame(width: 380)
                            HStack { Spacer(); Button("Cancel") { model.needsKey = false }; Button("Update") { model.updateFromPhone() }.buttonStyle(.borderedProminent)
                                .disabled(m.keyEntry.filter { $0.isHexDigit }.count != 64) }
                        }.padding(22)
                    }
                }
            }
        }
        // One accent for every control the system draws: sheets, checkboxes, pickers and
        // `.borderedProminent` buttons were falling back to macOS blue, which is the one
        // colour the palette does not have.
        .tint(AppTheme.Accent.primaryFill)
    }

    /// The content of a place sits in glass panels on the field, never edge to edge.
    @ViewBuilder private var content: some View {
        switch model.pane {
        case .dashboard:
            HomeView()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        case .gallery:
            GalleryView()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        case .settings:
            SettingsPlace()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        case .search:
            GlassPanel(radius: AppTheme.Radius.card, padding: 0) { SearchResultsView() }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        default:
            HStack(spacing: 12) {
                GlassPanel(radius: AppTheme.Radius.card, padding: 0) {
                    VStack(spacing: 0) {
                        // People is a list beside Chats, not a destination only the menu knows.
                        // The top bar can then keep calling this place Chats and still be true.
                        if model.pane == .chat || model.pane == .person { chatsOrPeople }
                        sectionSidebar
                    }
                }
                .frame(width: model.pane == .wrapped ? 260 : 296)
                GlassPanel(radius: AppTheme.Radius.card, padding: 0) {
                    switch model.pane {
                    case .person: PersonDetailView()
                    case .wrapped: WrappedView()
                    default: ConversationView()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    /// Chats | People. Two segments over the same list column: the one switch the audit
    /// asked for instead of a sixth place chip or a Go-only destination.
    private var chatsOrPeople: some View {
        HStack(spacing: 2) {
            sidebarSegment("Chats", on: model.section != .people) { model.section = .chats }
            sidebarSegment("People", on: model.section == .people) { model.section = .people }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.s)
        .padding(.top, AppTheme.Spacing.m)
    }

    private func sidebarSegment(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AppTheme.Surface.textPrimary : AppTheme.Surface.textSecondary)
                .padding(.horizontal, AppTheme.Spacing.m)
                .padding(.vertical, 4)
                .background(Capsule().fill(on ? AppTheme.Surface.field : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder private var sectionSidebar: some View {
        switch model.section {
        case .chats: ChatsSidebar()
        case .people: PeopleSidebar()
        case .wrapped: WrappedSidebar()
        }
    }
}

struct ChatsSidebar: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            header
            SidebarRule()
            if model.chats.isEmpty {
                chatListEmptyState
            } else {
                ScrollViewReader { _ in
                    List(selection: Binding(get: { model.selected?.id }, set: { id in
                        if let id, let c = model.chats.first(where: { $0.id == id }) { model.openChat(c) }
                    })) {
                        ForEach(model.chats) { c in
                            ChatRowView(chat: c, selected: model.selected?.id == c.id, fresh: isFresh(c))
                                .tag(c.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: AppTheme.Spacing.s, bottom: 0, trailing: AppTheme.Spacing.s))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
        }
        .background(Color.clear)
        .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
    }

    /// An empty chat list is either "nothing matches this filter" (with the way
    /// back) or "no conversations yet" (with the next step).
    private var chatListEmptyState: some View {
        let filtered = !model.chatQuery.isEmpty
        var actionTitle: String?
        var action: (() -> Void)?
        if filtered {
            actionTitle = "Clear the filter"
            action = { model.chatQuery = "" }
        } else if model.hideTinyChats {
            actionTitle = "Show every chat"
            action = { model.hideTinyChats = false }
        } else {
            actionTitle = "Update from phone"
            action = { model.updateFromPhone() }
        }
        return EmptyStateView(
            symbol: filtered ? "magnifyingglass" : "bubble.left.and.bubble.right",
            title: filtered ? "Nothing matches “\(model.chatQuery)”" : "No conversations yet",
            message: filtered
                ? "Try fewer letters, or clear the filter to see every chat."
                : (model.hideTinyChats
                   ? "No chat here has more than a message or two. Show every chat to see them anyway."
                   : "Add a backup from your phone and your conversations appear here."),
            colors: AppTheme.Module.chats.colors,
            actionTitle: actionTitle,
            action: action,
            compact: true)
            .frame(maxHeight: .infinity)
    }

    /// Filter, kind and sort live in one header block so the chat rows start at
    /// a predictable height. The status line reserves `LocalOnlyBadge.height`
    /// whether or not the badge has room, so the badge never shifts the list.
    private var header: some View {
        @Bindable var m = model
        return VStack(spacing: AppTheme.Spacing.s) {
            // A filter belongs to the list it filters: quiet words, no container. The
            // boxed control that switches what the chat pane shows lives in the chat
            // header, and the two must not look like the same kind of choice.
            HStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(ChatKind.allCases, id: \.self) { kind in
                    Button { m.chatKind = kind } label: {
                        Text(kind == .all ? "All chats" : (kind == .people ? "Direct" : kind.rawValue))
                            .font(.system(size: 12, weight: model.chatKind == kind ? .semibold : .regular))
                            .foregroundStyle(model.chatKind == kind ? AppTheme.Surface.textPrimary : AppTheme.Surface.textSecondary)
                            .padding(.horizontal, AppTheme.Spacing.s)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(model.chatKind == kind ? AppTheme.Surface.field : Color.clear)
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.chatKind == kind ? [.isSelected] : [])
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(AppTheme.Surface.textTertiary)
                    TextField("Filter chats", text: $m.chatQuery)
                        .textFieldStyle(.plain)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                    if !model.chatQuery.isEmpty {
                        Button { model.chatQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Surface.textTertiary)
                            .help("Clear the filter")
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.s)
                .frame(height: 28)
                .background(AppTheme.Radius.controlShape.fill(AppTheme.Surface.field))
                Menu {
                    Picker("Sort by", selection: $m.chatSort) { ForEach(ChatSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Divider()
                    Toggle("Hide chats with under 10 messages", isOn: $m.hideTinyChats)
                    Divider()
                    Button("Clean up spam…") { model.openCleanUp() }
                    Button("Might need your reply…") { model.openReplyReview() }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().help("Sort chats, or clean up and review them")
            }
            HStack(spacing: AppTheme.Spacing.s) {
                Text(model.chats.isEmpty
                     ? "No chats yet"
                     : "\(model.chats.count.formatted()) chats · \(model.chatSort.rawValue)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: AppTheme.Spacing.xs)
            }
            .frame(height: LocalOnlyBadge.height)
        }
        .padding(.horizontal, 10)
        .padding(.top, AppTheme.Spacing.m)
        .padding(.bottom, AppTheme.Spacing.s)
    }

    /// Unread emphasis for an archive: a chat counts as new while its latest
    /// message sits within the last day of activity in the library. The archive
    /// has no read state, so this is the honest stand-in for "unread" — bold
    /// time, accent count and a dot, all tied to the newest message on record.
    private func isFresh(_ c: ChatRow) -> Bool {
        guard let newest = model.chats.first?.last else { return false }
        return newest.timeIntervalSince(c.last) < 24 * 3600
    }
}

struct ChatRowView: View {
    let chat: ChatRow
    var selected = false
    var fresh = false
    @State private var hovered = false

    private var rowFill: Color {
        if selected { return AppTheme.Surface.selection }
        if hovered { return AppTheme.Surface.hover }
        return .clear
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.m) {
            Avatar(name: chat.name, group: chat.isGroup, size: 34, ringed: chat.isGroup)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.hair) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                    Text(chat.name)
                        .font(AppTheme.Typography.rowName)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: AppTheme.Spacing.xxs)
                    if fresh {
                        Circle().fill(AppTheme.Accent.primary).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(chat.last.listLabel)
                        .font(AppTheme.Typography.rowMeta).monospacedDigit()
                        .foregroundStyle(fresh ? AppTheme.Accent.text : AppTheme.Surface.textSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
                    Text(chat.preview.isEmpty ? "\(chat.count.formatted()) messages" : chat.preview.replacingOccurrences(of: "\n", with: " "))
                        .font(AppTheme.Typography.rowPreview)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: AppTheme.Spacing.xxs)
                }
            }
        }
        .padding(.vertical, AppTheme.Spacing.row)
        .padding(.horizontal, AppTheme.Spacing.s)
        .background(AppTheme.Radius.controlShape.fill(rowFill))
        .overlay(alignment: .bottom) {
            if !selected {
                Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1)
                    .padding(.leading, 34 + AppTheme.Spacing.m)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .themeAnimation(value: hovered)
        .themeAnimation(value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: Conversation
struct ConversationView: View {
    @Environment(AppModel.self) var model
    @State private var jumpDate = Date()
    @State private var showJump = false
    /// The two sheets off the chat's More menu. Two `.sheet` modifiers on one header is the same
    /// single-slot hazard; one item-driven sheet hosts both.
    private enum ChatSheet: String, Identifiable { case prune, topics; var id: String { rawValue } }
    @State private var chatSheet: ChatSheet?

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            if let c = model.selected {
                HStack(spacing: AppTheme.Spacing.s) {
                    Avatar(name: c.name, group: c.isGroup, size: 30, ringed: c.isGroup)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.name)
                            .font(AppTheme.Typography.title)
                            .foregroundStyle(AppTheme.Surface.textPrimary)
                            .lineLimit(1)
                            // At the 900pt minimum the pane gives the title ~236pt and the name
                            // needs ~240: a hair of scale keeps the whole name instead of
                            // "College Gang 2…" — truncation there is what the audit measured.
                            .minimumScaleFactor(0.88)
                        Text("\(c.count.formatted()) messages · since \(c.first.formatted(.dateTime.month(.abbreviated).year()))")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.Surface.textSecondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: AppTheme.Spacing.s)
                    Picker("Chat view", selection: $m.chatMode) {
                        ForEach(ChatMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 218)
                    .help("The messages, the media this chat shared, or its Heartbeat story")
                    Button { model.beginFind() } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.Surface.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Find in this conversation (⌘F)")
                    .accessibilityLabel("Find in this conversation")
                    Menu {
                        Picker("Show", selection: $m.messageFilter) { ForEach(MessageFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Divider()
                        Button { showJump = true } label: { Label("Jump to a date…", systemImage: "calendar") }
                        Button { chatSheet = .prune } label: { Label("Clean up spam, repeats or media…", systemImage: "wand.and.sparkles") }
                        Button { chatSheet = .topics } label: { Label("What this chat talked about…", systemImage: "list.bullet.rectangle") }
                        Divider()
                        Menu("Export") {
                            ForEach(ExportFormat.allCases, id: \.self) { f in Button(f.rawValue) { model.export(chat: c, format: f) } }
                        }
                    } label: {
                        Label("More for this chat", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Filter, jump to a date, clean up, topics and export")
                }
                .padding(.horizontal, AppTheme.Spacing.m)
                .padding(.vertical, AppTheme.Spacing.s)
                .frame(minHeight: 56)
                .background(AppTheme.Surface.bar)
                .popover(isPresented: $showJump) {
                    VStack(spacing: 10) {
                        DatePicker("", selection: $jumpDate, in: c.first...c.last, displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden()
                        Button("Go") { model.jump(toDate: jumpDate); showJump = false }.buttonStyle(.borderedProminent)
                    }.padding(14)
                }
                .sheet(item: $chatSheet) { which in
                    switch which {
                    case .prune: PruneView(chat: c).environment(model)
                    case .topics: TopicsView(chat: c).environment(model)
                    }
                }
                Hairline()
                if let origin = model.jumpOrigin { ReturnBar(origin: origin) }
                if model.findOpen, model.chatMode == .messages { FindBar() }
                switch model.chatMode {
                case .messages:
                    // A conversation swap is a new list: without its own identity the previous
                    // chat's scroll offset and lazy rows are reused, which can leave the new
                    // chat's pane blank until something scrolls it.
                    MessageList(isGroup: c.isGroup).id(c.id)
                case .media:
                    ChatMediaPane(chat: c)
                case .wrapped:
                    if c.isGroup { GroupWrappedView(chat: c, embedded: true).environment(model) }
                    else { DuoWrappedView(chat: c, embedded: true).environment(model) }
                }
            } else {
                EmptyStateView(
                    symbol: "bubble.left.and.bubble.right",
                    title: "Choose a conversation",
                    message: "Pick a chat on the left to read it. Search looks across every chat at once.",
                    colors: AppTheme.Module.chats.colors)
                    .background(Color.clear)
            }
        }
    }
}

// MARK: The way back after a jump

/// A jump from Wrapped or the archive search takes the reader to a message; this strip is the
/// return ticket. It names where they came from, restores the chat, the pane and the message
/// they were on, and can be dismissed — after which the origin is gone for good.
struct ReturnBar: View {
    @Environment(AppModel.self) private var model
    let origin: ChatOrigin

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AppTheme.Accent.text)
            Text(model.jumpOriginSentence)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.s)
            Button("Back to where you were") { model.returnToOrigin() }
                .buttonStyle(.plain)
                .font(AppTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Accent.text)
                .fixedSize()
                .help("Go back to the conversation and the message you were reading")
            Button { model.dismissJumpOrigin() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Dismiss")
            .accessibilityLabel("Dismiss the way back")
        }
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(AppTheme.Surface.bar)
        .overlay(alignment: .bottom) { Hairline() }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Find in the conversation

/// The chat's own find: a field under the conversation header that marks every match in the
/// transcript and steps between them. It replaces the archive search's old "Only this chat"
/// checkbox — the right control in the right place — and never leaves the conversation.
struct FindBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var m = model
        HStack(spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textTertiary)
                TextField("Find in this conversation", text: $m.findQuery)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .focused($focused)
                    .onSubmit { model.stepFind(1) }
                    .onExitCommand { model.closeFind() }
            }
            .padding(.horizontal, AppTheme.Spacing.s)
            .frame(width: 240, height: 28)
            .background(AppTheme.Radius.controlShape.fill(AppTheme.Surface.field))
            .overlay(AppTheme.Radius.controlShape.strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))

            Text(model.findCountLabel)
                .font(AppTheme.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .lineLimit(1)
                .frame(minWidth: 62, alignment: .leading)

            Button { model.stepFind(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(model.findHits.isEmpty)
                .help("Previous match (⇧⌘G)")
            Button { model.stepFind(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(model.findHits.isEmpty)
                .help("Next match (⌘G)")
            Button { model.closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Close find (esc)")
            Spacer(minLength: 0)
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.Surface.textSecondary)
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(minHeight: 40)
        .background(AppTheme.Surface.bar)
        .overlay(alignment: .bottom) { Hairline() }
        .onAppear { focused = true }
        .onChange(of: model.findFocusTick) { _, _ in focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in this conversation")
    }
}

struct MessageList: View {
    @Environment(AppModel.self) var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isGroup: Bool
    var body: some View {
        // One set per body pass, not one per bubble: the marks are what find shows on screen.
        let marks = model.findMatchIDs
        // The rows the ForEach was built from, so the neighbour lookups can never index a
        // newer (shorter) list than the one on screen — that mismatch is an index trap.
        let rows = model.messages
        // Snapshot only (`--react-detail`): a capture cannot hover a chip, so the detail is
        // pinned open on the newest message that has reactions. Nil in every other run.
        let reactionDetailPin: Int64? = Snapshot.reactionDetailPinned
            ? rows.last(where: { !(model.reactionSummaries[$0.id]?.isEmpty ?? true) })?.id : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.hair) {
                    if model.canLoadOlder {
                        Button("Load earlier messages") { model.loadOlder() }
                            .buttonStyle(.bordered).tint(AppTheme.Accent.text)
                            .padding(.vertical, AppTheme.Spacing.m)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, msg in
                        let prev: MessageRow? = i > 0 ? rows[i - 1] : nil
                        let next: MessageRow? = i + 1 < rows.count ? rows[i + 1] : nil
                        let newDay = prev == nil || !Calendar.current.isDate(prev!.ts, inSameDayAs: msg.ts)
                        let head = newDay || prev!.fromMe != msg.fromMe || prev!.sender != msg.sender || msg.ts.timeIntervalSince(prev!.ts) > 300
                        // A message is the last of its sender group when the next one is a
                        // different sender/day, so only that bubble gets the pointed corner.
                        let tail = next == nil || next!.fromMe != msg.fromMe || next!.sender != msg.sender
                            || next!.ts.timeIntervalSince(msg.ts) > 300
                            || !Calendar.current.isDate(next!.ts, inSameDayAs: msg.ts)
                        if newDay { DayDivider(date: msg.ts) }
                        Bubble(msg: msg, showName: isGroup && !msg.fromMe && head, highlight: msg.id == model.focusMessage,
                               reactions: model.reactionSummaries[msg.id], tail: tail,
                               findHit: marks.contains(msg.id), detailPinned: msg.id == reactionDetailPin)
                            .padding(.top, head && !newDay ? AppTheme.Spacing.s : 0).id(msg.id)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.s)
                .frame(maxWidth: .infinity)
            }
            .background(Color.clear)
            .onChange(of: model.messages.last?.id) { _, last in
                if model.focusMessage == nil, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: model.focusMessage) { _, f in
                if let f { reveal(f, in: proxy) }
            }
            .onChange(of: model.revealTick) { _, _ in
                // A return to the message the reader was last shown is not a change of
                // `focusMessage`, so the reveal is asked for by a token instead.
                if let f = model.focusMessage { reveal(f, in: proxy) }
            }
            .onAppear {
                // A jump sets the highlight before this list first appears, so `onChange`
                // never fires for it: reveal it after the first layout pass, or the chat
                // opens with the message the reader asked for off screen.
                if let f = model.focusMessage, rows.contains(where: { $0.id == f }) {
                    let anchor: UnitPoint = rows.last?.id == f ? .bottom : .center
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        proxy.scrollTo(f, anchor: anchor)
                    }
                } else if model.focusMessage == nil, let l = model.messages.last?.id {
                    proxy.scrollTo(l, anchor: .bottom)
                    // A LazyVStack estimates the height of rows it has not laid out, so the
                    // first scroll can stop short by a whole bubble — and with reaction chips
                    // the newest bubble is taller still. Repeating the same scroll once the
                    // rows (and their chips) exist puts the newest message flush with the edge.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(140))
                        proxy.scrollTo(l, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Centres a jumped-to message, honouring Reduce Motion.
    private func reveal(_ id: Int64, in proxy: ScrollViewProxy) {
        AppTheme.Motion.perform(AppTheme.Motion.gentle, reduceMotion: reduceMotion) { proxy.scrollTo(id, anchor: .center) }
    }
}

/// Small centred pill marking the start of a day (DESIGN.md: App › Conversation).
struct DayDivider: View {
    let date: Date
    var body: some View {
        Text(date.formatted(date: .complete, time: .omitted))
            .font(AppTheme.Typography.bubbleMeta)
            .foregroundStyle(AppTheme.Bubble.dayDividerText)
            .padding(.horizontal, AppTheme.Spacing.m)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(Capsule().fill(AppTheme.Bubble.dayDivider))
            .overlay(Capsule().strokeBorder(AppTheme.Surface.hairline, lineWidth: 1))
            .padding(.vertical, AppTheme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct Bubble: View {
    let msg: MessageRow
    let showName: Bool
    let highlight: Bool
    /// What people did to this message. `nil` (or empty) draws nothing at all — a message
    /// nobody reacted to must not gain a blank row.
    var reactions: MessageReactionSummary? = nil
    /// Last message of a sender group: gets the pointed bottom corner.
    var tail = true
    /// One of find's matches: a quiet ring so the count in the bar has something to point at.
    var findHit = false
    /// Snapshot aid: opens the "who reacted" card without a hover (`--react-detail`).
    var detailPinned = false

    private var mine: Bool { msg.fromMe }

    /// 18pt bubble radius from the token layer, with the sender's bottom corner
    /// tightened so grouped messages read as one block.
    private var shape: UnevenRoundedRectangle {
        let r = AppTheme.Radius.bubble
        let pointed: CGFloat = 5
        return UnevenRoundedRectangle(topLeadingRadius: r,
                                     bottomLeadingRadius: mine ? r : (tail ? pointed : r),
                                     bottomTrailingRadius: mine ? (tail ? pointed : r) : r,
                                     topTrailingRadius: r,
                                     style: .continuous)
    }

    /// `1:05 pm` — the bubble's own time, drawn small at the end of the last line.
    private var time: String { msg.ts.formatted(date: .omitted, time: .shortened) }

    private var stampColor: Color {
        mine ? AppTheme.Bubble.onMine.opacity(AppTheme.Bubble.metaOnMine) : AppTheme.Surface.textSecondary
    }

    /// The message and its time as one flowing run, the way WhatsApp does it: the time is
    /// part of the paragraph, so a one-word message is one short line instead of a 560pt
    /// bubble with a second row holding the clock.
    private var textAndTime: Text {
        Text(msg.text)
            .font(AppTheme.Typography.bubble)
            .foregroundStyle(mine ? AppTheme.Bubble.onMine : AppTheme.Bubble.onTheirs)
        + Text("  \(time)")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(stampColor)
    }

    /// The bubble itself, without the chips: name, media, text and clock.
    private var bubble: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            if showName {
                Text(msg.sender)
                    .font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
            if let k = msg.mediaKind { BubbleMedia(msg: msg, kind: k) }
            if !msg.text.isEmpty {
                textAndTime.textSelection(.enabled)
            } else {
                // Media with no caption keeps the clock on its own line, right-aligned.
                HStack(spacing: 0) {
                    Spacer(minLength: AppTheme.Spacing.m)
                    Text(time)
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(stampColor)
                }
            }
        }
        .foregroundStyle(mine ? AppTheme.Bubble.onMine : AppTheme.Bubble.onTheirs)
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, 7)
        // The background hugs the text, then the frame caps the line length: painted the
        // other way round, every bubble was as wide as the column cap, whatever it said.
        .background(shape.fill(mine ? AppTheme.Bubble.mine : AppTheme.Bubble.theirs))
        .overlay(shape.strokeBorder(highlight ? AppTheme.Bubble.highlight
                                            : (findHit ? AppTheme.Accent.primary.opacity(0.55) : (mine ? .clear : AppTheme.Bubble.border)),
                                    lineWidth: highlight ? 2 : 1))
        .frame(maxWidth: AppTheme.Bubble.maxWidth, alignment: mine ? .trailing : .leading)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: AppTheme.Spacing.xl) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 0) {
                bubble
                if let reactions, !reactions.isEmpty {
                    // Attached to the bubble's bottom edge the way WhatsApp draws it: the chips
                    // are 18pt tall but take only 11pt of their own space, so the pills sit over
                    // the bubble's bottom border instead of floating below it — and a reacted
                    // message grows by 11pt, not by a whole chip. They are a sibling of the
                    // bubble, never an overlay, so the bubble's own shape cannot clip them.
                    ReactionChips(summary: reactions, pinned: detailPinned)
                        .frame(height: 11, alignment: .bottom)
                        .padding(.bottom, 3)
                        .padding(mine ? .trailing : .leading, AppTheme.Spacing.s)
                }
            }
            if !mine { Spacer(minLength: AppTheme.Spacing.xl) }
        }
    }
    func icon(_ k: String) -> String {
        switch k { case "image", "sticker": return "photo"; case "video": return "play.rectangle"; case "audio": return "waveform"; case "doc": return "doc"; default: return "paperclip" }
    }
}

/// WhatsApp's reaction chips: one small pill per emoji, each showing the emoji and how many
/// people used it, sitting on the bubble's bottom edge.
///
/// Hovering brightens the pills and puts the names in the app's usual tooltip; clicking opens
/// the card with everyone who reacted. Clicking never navigates — it is a Button with no
/// action beyond the card, so a tap on a chip can never jump the transcript.
struct ReactionChips: View {
    let summary: MessageReactionSummary
    /// Snapshot aid: pins the card open for a capture.
    var pinned = false
    @State private var hovering = false
    @State private var showingDetail = false

    private var detailShown: Binding<Bool> {
        Binding(get: { showingDetail || pinned }, set: { if !$0 { showingDetail = false } })
    }

    var body: some View {
        Button { showingDetail.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xxs) {
                ForEach(summary.tallies) { tally in chip(tally) }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .themeAnimation(value: hovering)
        .help(summary.spoken)
        .popover(isPresented: detailShown, arrowEdge: .top) {
            ReactionDetailCard(summary: summary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.spoken)
        .accessibilityHint("Shows who reacted")
    }

    private func chip(_ tally: MessageReactionSummary.Tally) -> some View {
        HStack(spacing: 3) {
            Text(tally.emoji).font(.system(size: 12))
            Text("\(tally.count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AppTheme.Surface.textPrimary)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Capsule(style: .continuous)
            .fill(hovering ? AppTheme.Bubble.reactionChipHover : AppTheme.Bubble.reactionChip))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(hovering ? AppTheme.Accent.primary.opacity(0.55) : AppTheme.Bubble.reactionChipBorder,
                          lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// Who reacted to one message, one line per emoji, in the order people reacted.
/// The count is printed beside the names so a clipped list still says how many there were.
struct ReactionDetailCard: View {
    let summary: MessageReactionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(summary.total == 1 ? "1 reaction" : "\(summary.total) reactions")
                .font(AppTheme.Typography.micro.weight(.semibold))
                .foregroundStyle(AppTheme.Surface.textSecondary)
            ForEach(summary.tallies) { tally in
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                    Text(tally.emoji).font(.system(size: 13))
                    Text(tally.namesLabel)
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: AppTheme.Spacing.s)
                    Text("\(tally.count)")
                        .font(AppTheme.Typography.micro.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                }
            }
        }
        .padding(AppTheme.Spacing.m)
        .frame(width: 236, alignment: .leading)
        // The card paints its own surface rather than leaning on the popover's material: the
        // material is the window's, not the view's, and a card that carries its own fill is
        // the one thing a capture can prove in both appearances.
        .background(AppTheme.Surface.card)
    }
}

// MARK: Search
struct SearchResultsView: View {
    @Environment(AppModel.self) var model

    /// A failed search keeps its technical text behind Details; the header banner
    /// is for quieter status lines only.
    private var isSearchError: Bool { model.status.hasPrefix("Search error") }

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(model.hits.count.formatted())\(model.hits.count >= 200 ? "+" : "") results for “\(model.query)”").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Clear") { model.query = ""; model.hits = []; model.sectionChanged() }
                }
                HStack(spacing: 14) {
                    Picker("From", selection: $m.searchSender) { ForEach(SenderFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.fixedSize()
                    Picker("Sort", selection: $m.searchSort) { ForEach(SearchSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.fixedSize()
                    DateToggle(title: "After", date: $m.searchFrom)
                    DateToggle(title: "Before", date: $m.searchTo)
                    Spacer()
                }.font(.callout)
                if !model.status.isEmpty && !isSearchError {
                    StatusBanner(level: .warning, message: model.status)
                }
            }.padding(16).background(.bar)
            Divider()
            if model.hits.isEmpty {
                Group {
                    if isSearchError {
                        ErrorStateView(
                            title: "Search didn't run",
                            message: "Saga couldn't read your library just now. Trying again usually fixes it.",
                            detail: model.status,
                            retry: { model.runSearch() })
                    } else if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        EmptyStateView(
                            symbol: "magnifyingglass",
                            title: "Search your archive",
                            message: "Type a word or phrase in the search field above, then press Return. Every chat is searched at once.",
                            colors: AppTheme.Module.chats.colors)
                    } else {
                        EmptyStateView(
                            symbol: "magnifyingglass",
                            title: "No messages match “\(model.query)”",
                            message: "Try fewer words. You can also use AND, OR, “quotes” and prefix*",
                            colors: AppTheme.Module.chats.colors,
                            actionTitle: "Clear search",
                            action: { model.query = ""; model.hits = []; model.sectionChanged() })
                    }
                }
                .background(Color.clear)
            } else {
                List(model.hits) { h in
                    HStack(alignment: .top, spacing: 12) {
                        Avatar(name: h.chat, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(h.chat).font(.system(size: 13, weight: .semibold))
                                if h.fromMe || h.sender != h.chat { Text("· \(h.fromMe ? "You" : h.sender)").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(h.ts.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(h.snippet.highlighted).lineLimit(3)
                        }
                    }.padding(.vertical, 4).contentShape(Rectangle()).onTapGesture { model.jump(to: h) }
                }.listStyle(.inset)
            }
        }
    }
}

struct DateToggle: View {
    let title: String; @Binding var date: Date?
    var body: some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? Date()) : nil })).toggleStyle(.checkbox)
            if date != nil {
                DatePicker("", selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date).labelsHidden().fixedSize()
            }
        }
    }
}


/// The Media tab of a conversation: the Gallery's own browser pinned to this chat. Same kind
/// tabs and counts, same cards, same year/sort filters, same playback and the same
/// Drive/phone resolution path — only the conversation filter differs, and it is not editable
/// because the reader is already inside that chat.
struct ChatMediaPane: View {
    let chat: ChatRow
    var body: some View {
        GalleryBody(scope: .chat(id: chat.id, name: chat.name.isEmpty ? "This chat" : chat.name))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
