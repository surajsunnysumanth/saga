import SwiftUI
import SagaCore

/// Drives the Unnamed sheet: a paged, filtered read of `VaultStore.unnamedChats`, plus the two writes it
/// offers (a name into `config/overrides.csv`, an ignore into `config/unnamed-ignores.json`).
@MainActor @Observable
final class UnnamedModel {
    /// One page is enough to fill a 700pt sheet twice over; the sentinel at the bottom asks for the next.
    static let pageSize = 100

    var rows: [UnnamedChat] = []
    var counts: [UnnamedKind: Int] = [:]
    var query = ""
    var kind: UnnamedKind?
    var loading = false
    var loadingMore = false
    var hasMore = false
    var hidden: [String] = []
    var error: String?

    var total: Int { counts.values.reduce(0, +) }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Reads one page. `reset` starts from the first row; otherwise it appends, so the list grows a page at
    /// a time instead of materialising 8,700 rows (and their view state) on open.
    func load(_ model: AppModel, reset: Bool = true) {
        guard model.store != nil else { loading = false; return }
        guard let vault = model.prepareVault() else { loading = false; return }
        hidden = UnnamedIgnores.load(vault)
        let path = model.indexURL.path
        let q = query, k = kind, off = reset ? 0 : rows.count, skip = Set(hidden), size = Self.pageSize
        if reset { loading = true } else { loadingMore = true }
        error = nil
        Task {
            let page = await Task.detached { () -> (rows: [UnnamedChat], more: Bool, counts: [UnnamedKind: Int], error: String?) in
                do {
                    let store = try VaultStore(path: path)
                    // Ask for one more than a page: its presence is the whole "is there more" answer,
                    // with no second count query over the same rows.
                    let found = try store.unnamedChats(matching: q, kind: k, excluding: skip,
                                                       limit: size + 1, offset: off)
                    let counts = try store.unnamedChatCounts(excluding: skip)
                    return (Array(found.prefix(size)), found.count > size, counts, nil)
                } catch {
                    return ([], false, [:], error.localizedDescription)
                }
            }.value
            if reset { rows = page.rows } else { rows += page.rows }
            hasMore = page.more
            counts = page.counts
            error = page.error
            loading = false
            loadingMore = false
        }
    }

    /// Saves a name and rebuilds the index, because that is the only way `chats.name` (and the people list,
    /// the sidebars, Wrapped) can show it. The write itself is one row in the vault's overrides file.
    func name(_ chat: UnnamedChat, _ text: String, model: AppModel) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let vault = model.prepareVault() else { return }
        do { try NameOverrides.set(name, for: chat.jid, in: vault) }
        catch {
            model.toast = "Couldn't save that name: \(error.localizedDescription)"
            return
        }
        rows.removeAll { $0.id == chat.id }
        model.toast = "Saving “\(name)” and rebuilding your library…"
        model.rebuildLibrary { [self] _ in
            model.reloadChats()
            model.reloadPeople()
            model.toast = "“\(name)” is saved. It shows everywhere now."
            load(model)
        }
    }

    /// Folds this chat's identity into a person the owner already knows. The merge is an ordinary group in
    /// `config/merges.json` — the existing person's key stays primary, so the name shown is theirs and the
    /// obsolete number is never written into contacts — and the rebuild is what moves the history across and
    /// takes the chat off this list. Nothing is deleted: Merge contacts can unmerge it.
    func merge(_ chat: UnnamedChat, into person: PersonRow, model: AppModel) {
        guard let key = VaultStore.personKey(forJID: chat.jid) else {
            model.toast = "That chat has no number behind it to merge. Give it a name instead."
            return
        }
        guard key != person.key else {
            model.toast = "That is already the same person."
            return
        }
        guard let vault = model.prepareVault() else { return }
        do { try MergeConfig.add(keys: [person.key, key], name: person.name, to: vault) }
        catch {
            model.toast = "Couldn't merge into “\(person.name)”: \\(error.localizedDescription)"
            return
        }
        rows.removeAll { $0.id == chat.id }
        model.toast = "Merging into “\(person.name)” and rebuilding your library…"
        model.rebuildLibrary { [self] _ in
            model.reloadChats()
            model.reloadPeople()
            model.toast = "“\(person.name)” now holds this chat. Unmerge it in Merge contacts."
            load(model)
        }
    }

    func ignore(_ chat: UnnamedChat, model: AppModel) {
        guard let vault = model.prepareVault() else { return }
        do { try UnnamedIgnores.add(chat.jid, to: vault) }
        catch {
            model.toast = "Couldn't hide that chat: \(error.localizedDescription)"
            return
        }
        rows.removeAll { $0.id == chat.id }
        hidden = UnnamedIgnores.load(vault)
        if let store = try? VaultStore(path: model.indexURL.path),
           let fresh = try? store.unnamedChatCounts(excluding: Set(hidden)) {
            counts = fresh
        }
        model.toast = "Hidden from this list. Restore it at the bottom of the sheet."
    }

    /// Undo for the ignore action: every hidden chat comes back. A chat is never deleted, only filtered out.
    func restoreHidden(_ model: AppModel) {
        guard let vault = model.prepareVault() else { return }
        do { try UnnamedIgnores.save([], to: vault) } catch {
            model.toast = "Couldn't restore: \(error.localizedDescription)"
            return
        }
        load(model)
    }
}

/// Chats the archive could not name — the 6,800 unsaved numbers, the `lid:` chats with no phone number, the
/// newsletters and the groups that never had a subject. The point is recognition: read the number, open one,
/// and if it is somebody, type their name.
struct UnnamedChatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var m = UnnamedModel()
    @State private var naming: UnnamedChat?
    @State private var nameText = ""
    /// The row currently being folded into an existing person, and the search that finds them.
    @State private var merging: UnnamedChat?
    @State private var mergeQuery = ""
    @FocusState private var nameFocused: Bool
    /// Set once by the snapshot hook below, so a capture opens the naming panel exactly once.
    @State private var captureOpened = false
    @State private var captureMerged = false

    /// A naming panel is view state that a launch flag cannot reach. The snapshot harness sets
    /// `SAGA_UNNAMED_NAME=1` instead, the same cheap route the Gallery uses for its tabs; `SAGA_UNNAMED_QUERY`
    /// and `SAGA_UNNAMED_KIND` seed the filters so the empty and filtered surfaces can be photographed too.
    /// `SAGA_UNNAMED_MERGE=1` does the same for the Merge into… picker.
    private static var captureNaming: Bool { ProcessInfo.processInfo.environment["SAGA_UNNAMED_NAME"] == "1" }
    private static var captureMerging: Bool { ProcessInfo.processInfo.environment["SAGA_UNNAMED_MERGE"] == "1" }

    init() {
        let model = UnnamedModel()
        let env = ProcessInfo.processInfo.environment
        model.query = env["SAGA_UNNAMED_QUERY"] ?? ""
        if let raw = env["SAGA_UNNAMED_KIND"], let kind = UnnamedKind(key: raw) { model.kind = kind }
        _m = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            header
            controls
            if let chat = naming { namingPanel(chat) }
            if let chat = merging { mergePanel(chat) }
            panel
            footer
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 760, height: 700)
        .background(AppTheme.Surface.page)
        .task(id: "\(m.query)|\(m.kind?.rawValue ?? "")") {
            // Typing narrows the list; the debounce keeps one query per pause, not one per keystroke.
            if !m.query.isEmpty { try? await Task.sleep(for: .milliseconds(220)) }
            guard !Task.isCancelled else { return }
            m.load(model)
        }
        .onChange(of: naming) { _, chat in nameFocused = chat != nil }
        .onChange(of: m.rows.first?.id) { _, _ in
            guard let first = m.rows.first else { return }
            if Self.captureMerging, !captureMerged, merging == nil, naming == nil {
                captureMerged = true
                mergeQuery = ""
                merging = first
                return
            }
            guard Self.captureNaming, !captureOpened, naming == nil else { return }
            captureOpened = true
            nameText = ""
            naming = first
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                Text("Chats without a name")
                    .font(AppTheme.Typography.title)
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                Text(m.loading && m.rows.isEmpty ? "counting…" : "\(m.total.formatted()) unnamed")
                    .font(AppTheme.Typography.callout)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            Text("A number, a WhatsApp ID, a shop, a newsletter, a group with no subject. If you recognise one as a real person, name it — the name is saved in your archive and shows up in every list, after a rebuild too.")
                .font(AppTheme.Typography.callout)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(AppTheme.Surface.textTertiary)
                    TextField("A number, part of an id, or a name", text: $m.query)
                        .textFieldStyle(.plain)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                    if !m.query.isEmpty {
                        Button { m.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Surface.textTertiary)
                            .help("Clear the search")
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.s)
                .frame(height: 30)
                .background(AppTheme.Radius.controlShape.fill(AppTheme.Surface.field))
            }
            HStack(spacing: AppTheme.Spacing.xxs) {
                chip(nil, label: "All unnamed", count: m.total)
                ForEach(UnnamedKind.allCases) { kind in
                    chip(kind, label: kind.plural, count: m.counts[kind])
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A kind filter reads as a quiet word beside its count, the way the chat list's kind filter does —
    /// not as a second row of boxed buttons.
    private func chip(_ kind: UnnamedKind?, label: String, count: Int?) -> some View {
        let selected = m.kind == kind
        return Button { m.kind = kind } label: {
            HStack(spacing: 5) {
                Text(label)
                if let count, count > 0 {
                    Text(count.formatted())
                        .monospacedDigit()
                        .foregroundStyle(selected ? AppTheme.Surface.textSecondary : AppTheme.Surface.textTertiary)
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? AppTheme.Surface.textPrimary : AppTheme.Surface.textSecondary)
            .padding(.horizontal, AppTheme.Spacing.s)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? AppTheme.Surface.field : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: list

    @ViewBuilder private var panel: some View {
        GlassPanel(radius: AppTheme.Radius.panel, padding: 0) {
            if m.loading && m.rows.isEmpty {
                VStack(spacing: AppTheme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Looking through your chats…")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppTheme.Spacing.xxl)
            } else if let error = m.error {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "The list could not be read",
                               message: error, colors: AppTheme.Module.chats.colors, compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if m.rows.isEmpty {
                EmptyStateView(symbol: m.isSearching ? "magnifyingglass" : "checkmark.seal",
                               title: m.isSearching ? "Nothing matches “\(m.query)”" : "Every chat has a name",
                               message: m.isSearching
                                   ? "Try fewer digits, or the start of the id. The search also looks at the full JID."
                                   : "Nothing in this filter is unnamed. Try another kind, or All unnamed.",
                               colors: AppTheme.Module.people.colors,
                               actionTitle: m.isSearching || m.kind != nil ? "Show all unnamed" : nil,
                               action: m.isSearching || m.kind != nil ? {
                                   m.query = ""; m.kind = nil; m.load(model)
                               } : nil,
                               compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.rows) { chat in
                            row(chat)
                            Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1)
                                .padding(.leading, 46)
                        }
                        if m.hasMore {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(AppTheme.Spacing.m)
                                .onAppear { m.load(model, reset: false) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ chat: UnnamedChat) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            // Only the row's own content opens the chat. A tap gesture on the whole row sits above the
            // three actions and swallows their clicks, which reads as dead buttons.
            HStack(spacing: AppTheme.Spacing.m) {
                Image(systemName: chat.kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(chat.kind == .person ? AppTheme.Accent.text : AppTheme.Surface.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(AppTheme.Glass.fill.opacity(0.10)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(chat.identifier)
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.Surface.textPrimary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        badge(chat.kind)
                    }
                    HStack(spacing: AppTheme.Spacing.xs) {
                        if chat.count == 0 {
                            Text("No messages in this chat")
                        } else {
                            Text("\(chat.count.formatted()) messages")
                            Text("·")
                            Text("last \(chat.last.formatted(.dateTime.month(.abbreviated).year()))")
                        }
                        if let subtitle = chat.subtitle {
                            Text("·")
                            Text(subtitle).lineLimit(1)
                        }
                    }
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: AppTheme.Spacing.s)
            }
            .contentShape(Rectangle())
            .onTapGesture { open(chat) }
            // One fixed-width action block: without `.fixedSize()` an HStack squeezes these into a
            // column of wrapped labels the moment the sheet is narrower than the design.
            HStack(spacing: AppTheme.Spacing.xs) {
                if chat.kind == .person {
                    Button("Merge into…") { nameText = ""; naming = nil; mergeQuery = ""; merging = chat }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("This is an old number of someone you already have — fold it into their history")
                }
                Button("Name…") { nameText = ""; merging = nil; naming = chat }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Give this chat a name")
                Menu {
                    Button { open(chat) } label: { Label("Open the conversation", systemImage: "bubble.left.and.bubble.right") }
                    Divider()
                    Button { m.ignore(chat, model: model) } label: { Label("Not a person — hide it", systemImage: "eye.slash") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open it, or hide it from this list")
            }
            .fixedSize()
        }
        .padding(.horizontal, AppTheme.Spacing.m)
        .padding(.vertical, AppTheme.Spacing.s)
    }

    private func badge(_ kind: UnnamedKind) -> some View {
        Text(kind.rawValue)
            .font(AppTheme.Typography.micro)
            .foregroundStyle(kind == .person ? AppTheme.Accent.text
                             : kind == .business ? AppTheme.Feedback.warning
                             : AppTheme.Surface.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(AppTheme.Glass.fill.opacity(0.10)))
    }

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            Text(m.isSearching ? "\(m.rows.count.formatted()) shown" : "Showing \(m.rows.count.formatted()) of \(m.total.formatted())")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            if !m.hidden.isEmpty {
                Button("Restore \(m.hidden.count.formatted()) hidden") { m.restoreHidden(model) }
                    .controlSize(.small)
                    .help("Bring every chat you marked “not a person” back into this list")
            }
            Button("Done") { dismiss() }
                // Escape closes the sheet; Return belongs to the name field, so Done is not the default button.
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: naming

    /// Naming happens in place, not in a sheet on top of a sheet: the list stays visible, so the number you are
    /// reading is still on screen while you type the name. Two sheets deep is also where macOS starts refusing
    /// to present anything at all.
    private func namingPanel(_ chat: UnnamedChat) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.s) {
                Text(chat.identifier)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .textSelection(.enabled)
                badge(chat.kind)
                Spacer(minLength: AppTheme.Spacing.s)
                Button("Cancel") { cancelNaming() }
                    .controlSize(.small)
                Button("Save name") { save(chat) }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Accent.primaryFill)
                    .controlSize(.small)
                    .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Their name", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { save(chat) }
            Text("Saved in this archive's overrides file, so it survives a rebuild and shows in every list. It changes nothing on your phone.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary)
        }
        .padding(AppTheme.Spacing.m)
        .glassSurface(radius: AppTheme.Radius.panel)
    }

    // MARK: merging

    /// Merging reads as one more in-place panel, the same shape as naming: the row's number stays on screen
    /// while the owner finds the person they already know. Picking a name is the whole action — the merge is
    /// written and the library rebuilt, exactly like Save name.
    private func mergePanel(_ chat: UnnamedChat) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.s) {
                Text(chat.identifier)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .textSelection(.enabled)
                badge(chat.kind)
                Spacer(minLength: AppTheme.Spacing.s)
                Button("Cancel") { cancelMerging() }
                    .controlSize(.small)
            }
            TextField("Find the person this number belongs to", text: $mergeQuery)
                .textFieldStyle(.roundedBorder)
            let candidates = mergeCandidates(for: chat)
            if candidates.isEmpty {
                Text(mergeQuery.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "No named people in your archive yet — name this chat instead."
                     : "No one matches “\(mergeQuery)”. Try a different spelling, or Name… instead.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { person in
                        Button { applyMerge(chat, into: person) } label: {
                            HStack(spacing: AppTheme.Spacing.s) {
                                Avatar(name: person.name, size: 22)
                                Text(person.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(AppTheme.Surface.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: AppTheme.Spacing.xs)
                                Text("\(person.received.formatted()) messages")
                                    .font(AppTheme.Typography.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(AppTheme.Surface.textSecondary)
                            }
                            .padding(.horizontal, AppTheme.Spacing.s)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if person.id != candidates.last?.id {
                            Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1)
                        }
                    }
                }
            }
            Text("Their messages join this person's history under their own name, and the number stops being offered here. Nothing is deleted — Merge contacts can unmerge it.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.m)
        .glassSurface(radius: AppTheme.Radius.panel)
    }

    /// Who the row can be merged into: the people already in the sidebar while the field is empty, and the
    /// index's own search once anything is typed — so a filter on the sidebar can never hide the person
    /// the owner is looking for.
    private func mergeCandidates(for chat: UnnamedChat) -> [PersonRow] {
        let q = mergeQuery.trimmingCharacters(in: .whitespaces)
        let people: [PersonRow]
        if q.isEmpty {
            people = Array(model.people.lazy.filter(\.resolved).prefix(5))
        } else if let st = model.store {
            people = (try? st.people(matching: q, sort: .mostMessages, namedOnly: true, limit: 5)) ?? []
        } else {
            people = []
        }
        let selfKey = VaultStore.personKey(forJID: chat.jid)
        return people.filter { $0.key != selfKey }
    }

    private func applyMerge(_ chat: UnnamedChat, into person: PersonRow) {
        cancelMerging()
        m.merge(chat, into: person, model: model)
    }

    private func cancelMerging() {
        merging = nil
        mergeQuery = ""
    }

    private func save(_ chat: UnnamedChat) {
        let name = nameText
        cancelNaming()
        m.name(chat, name, model: model)
    }

    private func cancelNaming() {
        naming = nil
        nameText = ""
        nameFocused = false
    }

    private func open(_ chat: UnnamedChat) {
        model.section = .chats
        model.openChat(id: chat.id)
        dismiss()
    }
}
