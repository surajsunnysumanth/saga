import SwiftUI
import SagaCore

/// Settings as a place in the chrome. Form/List rows paint an opaque surface on macOS,
/// which is what made this screen read flat; these are glass groups instead.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab

    init(initialTab: Tab = .archive) { _tab = State(initialValue: initialTab) }

    enum Tab: String, CaseIterable, Identifiable {
        case archive = "Archive"
        case people = "People & cleanup"
        case home = "Home"
        case privacy = "Privacy"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            Picker("Settings section", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 460)

            Group {
                switch tab {
                case .archive: ArchiveSettingsPane()
                case .people: PeopleSettingsPane()
                case .home: HomeSettingsPane()
                case .privacy: PrivacySettingsPane()
                }
            }
            .environment(model)
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

// MARK: - Building blocks

private struct GlassGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(AppTheme.Surface.textTertiary)
            VStack(spacing: 0) { content }
                .glassSurface(radius: AppTheme.Radius.panel)
            if let footer {
                Text(footer)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var isAction = false
    /// Paths, commands and identifiers stay monospaced; prose does not. Setting every
    /// detail line in mono made the pane read like a diagnostic dump.
    var mono = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.section)
                    .foregroundStyle(isAction ? AppTheme.Accent.text : AppTheme.Surface.textPrimary)
                if let detail {
                    Text(detail)
                        .font(mono ? .system(.caption, design: .monospaced) : AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: AppTheme.Spacing.s)
            trailing
        }
        .padding(.horizontal, AppTheme.Spacing.l)
        .padding(.vertical, AppTheme.Spacing.m)
        .contentShape(Rectangle())
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(AppTheme.Surface.hairline).frame(height: 1)
            .padding(.leading, AppTheme.Spacing.l)
    }
}

// MARK: - Archive

private struct ArchiveSettingsPane: View {
    @Environment(AppModel.self) private var model
    /// Three sheets used to be stacked on this pane's modifier chain — the same single-slot hazard
    /// as `ContentView`. One item-driven sheet hosts all three.
    private enum ArchiveSheet: String, Identifiable { case foldIn, mediaSources, missing; var id: String { rawValue } }
    @State private var sheet: ArchiveSheet?
    @State private var profiles: [VaultProfile] = []
    @State private var coverage: MediaCoverage.Detailed?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            GlassGroup(title: "Where the archive lives",
                       footer: "The archive is a folder of plain files. Keep it on this Mac, a NAS, or a synced folder; Saga rebuilds its searchable library from it.") {
                SettingRow(title: "Folder", detail: AppModel.demoRoot == nil ? AppModel.vaultURL.path : "~/Archives/Saga", mono: true) {
                    Button("Change…") { changeFolder() }
                }
            }

            GlassGroup(title: "Backups",
                       footer: "Adding an older backup merges it into the same archive. Messages missing from the newer phone copy stay, flagged as deleted.") {
                SettingRow(title: "Add old backups…", isAction: true) { EmptyView() }
                    .onTapGesture { sheet = .foldIn }
                RowDivider()
                SettingRow(title: "Back the phone up again", isAction: true) { EmptyView() }
                    .onTapGesture { model.updateFromPhone() }
                RowDivider()
                SettingRow(title: "Import from iPhone over USB", isAction: true) { EmptyView() }
                    .onTapGesture { model.updateFromIPhone() }
            }

            if !profiles.isEmpty {
                GlassGroup(title: "Sources",
                           footer: "Each backup is filed under a source. A copy of the same history updates its source; a copy that shares no private chats is kept apart, so two numbers or two people never merge by accident.") {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { i, profile in
                        if i > 0 { RowDivider() }
                        SettingRow(title: profile.name,
                                   detail: [profile.messages.formatted() + " messages",
                                            profile.chats.formatted() + " chats",
                                            profile.lastImportAt.map { "last added " + $0.formatted(.dateTime.day().month(.abbreviated).year()) } ?? "no import yet",
                                            profile.source].joined(separator: " · ")) {
                            EmptyView()
                        }
                    }
                }
            }

            GlassGroup(title: "Media",
                       footer: "Photos and video load only when you open a conversation, and never leave the folders you choose here.") {
                SettingRow(title: "Media folders…", detail: AppModel.demoRoot == nil ? AppModel.driveRoot.map { $0.path } : "Not checked in demo", isAction: true, mono: true) { EmptyView() }
                    .onTapGesture { sheet = .mediaSources }
                RowDivider()
                if let coverage {
                    ForEach(Array(coverage.byLocation.enumerated()), id: \.offset) { _, entry in
                        SettingRow(title: entry.location.label,
                                   detail: "\(entry.present.formatted()) files · \(entry.location.kindLabel)") { EmptyView() }
                        RowDivider()
                    }
                    if let top = coverage.missingByChat.first {
                        SettingRow(title: "Missing",
                                   detail: "\(coverage.combined.missing.formatted()) files · most in \(top.chat) (\(top.count.formatted()))") {
                            Text("Show…").font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Accent.text)
                        }
                        .onTapGesture { sheet = .missing }
                        RowDivider()
                    }
                    SettingRow(title: "Found",
                               detail: "\(coverage.combined.present.formatted()) of \(coverage.combined.total.formatted()) indexed photos, videos and documents (\(Int((coverage.combined.fraction * 100).rounded()))%)") {
                        EmptyView()
                    }
                } else {
                    SettingRow(title: "Files found", detail: "Checking the folders…") { EmptyView() }
                }
            }

            // Discoverable without waiting a day: what the last check found, a manual check, and
            // the switch that turns the whole feature off.
            GlassGroup(title: "Updates",
                       footer: "Saga asks GitHub for the latest release once a day. The request carries nothing but itself — no identifier, no archive, no usage — and the answer is a version number and a link. Turn it off here and no request is made.") {
                SettingRow(title: "Saga \(AppModel.appVersion ?? "development build")",
                           detail: model.updateStatus.text) {
                    Button(model.updateChecking ? "Checking…" : "Check now") {
                        Task { await model.checkForUpdates(manual: true) }
                    }
                    .disabled(model.updateChecking || !model.updateChecksEnabled)
                }
                RowDivider()
                SettingRow(title: "Check for updates automatically",
                           detail: "Once a day · sends nothing but the request") {
                    Toggle("", isOn: Binding(get: { model.updateChecksEnabled },
                                             set: { model.updateChecksEnabled = $0 }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if let release = model.updateStatus.release {
                    RowDivider()
                    SettingRow(title: "Download \(release.versionText)", detail: "Opens the download in your browser",
                               isAction: true) { EmptyView() }
                        .onTapGesture { model.openUpdate(release) }
                }
            }
        }
        .task {
            if let vault = model.prepareVault() { profiles = ProfilesStore.load(in: vault) }
            let path = model.indexURL.path
            var locations = (try? MediaSources.loadLocations(in: AppModel.vaultURL)) ?? []
            if AppModel.demoRoot == nil, let drive = AppModel.driveRoot {
                locations.append(MediaLocation(path: drive.path, label: "Google Drive", kind: .cloud))
            }
            guard !locations.isEmpty else { return }
            let report: MediaCoverage.Detailed? = await Task.detached {
                guard let store = try? VaultStore(path: path) else { return nil }
                return try? MediaCoverage.checkDetailed(store: store, locations: locations)
            }.value
            coverage = report
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .foldIn: FoldInView().environment(model)
            case .mediaSources: MediaSourcesView().environment(model)
            case .missing:
                if let coverage {
                    MissingMediaView(rows: coverage.missingByChat, total: coverage.combined.missing).environment(model)
                }
            }
        }
    }

    private func changeFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Use this folder"
        p.message = "Choose where Saga keeps your archive."
        if p.runModal() == .OK, let u = p.url { model.moveVault(to: u) }
    }
}

// MARK: - People & chats

/// The housekeeping that used to live in the Go menu, grouped by what the owner is trying
/// to do — not by which component implements it.
private struct PeopleSettingsPane: View {
    @Environment(AppModel.self) private var model

    private var unnamedDetail: String {
        guard let n = model.unnamedTotal else { return "Chats the archive could not name" }
        guard n > 0 else { return "Every chat has a saved name" }
        return "\(n.formatted()) chats · name the ones that are people"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            GlassGroup(title: "People and names",
                       footer: "Names come from your phone's contacts, then WhatsApp profiles, then the number. Two numbers that are one person are shown with the evidence before anything changes.") {
                SettingRow(title: "Merge contacts…", detail: "Numbers that are one person, with the evidence", isAction: true) { EmptyView() }
                    .onTapGesture { model.openMergeContacts() }
                RowDivider()
                SettingRow(title: "Chats without a name…", detail: unnamedDetail, isAction: true) { EmptyView() }
                    .onTapGesture { model.openUnnamedChats() }
            }

            GlassGroup(title: "Conversations",
                       footer: "Hiding is reversible: the messages stay in the archive folder, and removing a rule brings them back.") {
                SettingRow(title: "Clean up spam…", detail: "Spam, repeats and media, hidden reversibly", isAction: true) { EmptyView() }
                    .onTapGesture { model.openCleanUp() }
                RowDivider()
                SettingRow(title: "Might need your reply…", detail: model.replyWaitingCount.map {
                    $0 == 1 ? "1 question waiting · found without a model" : "\($0.formatted()) questions waiting · found without a model"
                } ?? "Quiet questions, found without a model", isAction: true) { EmptyView() }
                    .onTapGesture { model.openReplyReview() }
            }
        }
        .task { model.reloadPeople() }
    }
}

// MARK: - Home

private struct HomeSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            GlassGroup(title: "On this day",
                       footer: "A card on Home with the messages, photos and songs from today's date across every year. Hide it here and the card leaves Home; open it any time without changing that.") {
                SettingRow(title: "Show “On this day” on Home") {
                    Toggle("", isOn: $m.showOnThisDayOnHome)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                RowDivider()
                SettingRow(title: "Open today's page…", detail: "Or pick another day inside", isAction: true) { EmptyView() }
                    .onTapGesture { model.openOnThisDay() }
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacySettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var protection: VaultProtection?
    /// Encrypt and change-passphrase were two stacked `.sheet` modifiers; one item hosts both.
    private enum PrivacySheet: String, Identifiable { case encryption, changePassphrase; var id: String { rawValue } }
    private var sheet: Binding<PrivacySheet?> {
        Binding(get: { model.showChangePassphrase ? .changePassphrase : (model.showEncryption ? .encryption : nil) },
                set: { if $0 == nil { model.showEncryption = false; model.showChangePassphrase = false } })
    }

    private var isEncrypted: Bool { protection == .encrypted }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            GlassGroup(title: "Protection",
                       footer: isEncrypted
                       ? "Segments and configuration are sealed with your passphrase. The search index stays readable, because it can be rebuilt from the archive."
                       : "Encryption is optional and off by default, so nothing can lock you out of your own history. Turning it on asks for a passphrase and gives you a recovery kit.") {
                SettingRow(title: "Archive") {
                    Label(isEncrypted ? "Encrypted" : "Not encrypted",
                          systemImage: isEncrypted ? "lock.fill" : "lock.open")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(isEncrypted ? AppTheme.Accent.text : AppTheme.Surface.textSecondary)
                }
            }

            GlassGroup(title: isEncrypted ? "Manage encryption" : "Turn on encryption",
                       footer: "A forgotten passphrase can only be recovered with the recovery code you printed when you turned encryption on. Store it somewhere that is not this Mac.") {
                if isEncrypted {
                    SettingRow(title: "Change passphrase…", isAction: true) { EmptyView() }
                        .onTapGesture { model.showChangePassphrase = true }
                    RowDivider()
                    SettingRow(title: "Show recovery kit…", isAction: true) { EmptyView() }
                        .onTapGesture { model.showChangePassphrase = true }
                    RowDivider()
                    SettingRow(title: "Decrypt archive", isAction: true) { EmptyView() }
                        .onTapGesture { model.startDecrypt() }
                } else {
                    SettingRow(title: "Encrypt archive…", isAction: true) { EmptyView() }
                        .onTapGesture { model.startEncrypt() }
                }
            }

            GlassGroup(title: "What leaves this Mac",
                       footer: "Search, summaries and embeddings run locally. Opening a player, a link preview or a download contacts that service; so does the once-a-day update check. Nothing else does.") {
                SettingRow(title: "Cloud AI", detail: "Off, and not offered") { EmptyView() }
                RowDivider()
                SettingRow(title: "Link previews", detail: "Only the URL you open") { EmptyView() }
                RowDivider()
                SettingRow(title: "Search and summaries", detail: "Run on this Mac") { EmptyView() }
                RowDivider()
                SettingRow(title: "Update check", detail: model.updateChecksEnabled
                           ? "One request a day to GitHub · sends nothing but the request"
                           : "Off · no request is made") { EmptyView() }
            }

            GlassGroup(title: "Other apps",
                       footer: "Saga answers Claude Code and other MCP clients with read-only archive tools. The command points at the copy inside this app; paste it in Terminal once.") {
                SettingRow(title: "Copy Claude Code connect command", isAction: true) { EmptyView() }
                    .onTapGesture { model.copyClaudeCodeCommand() }
            }
        }
        .task { protection = try? VaultEncryption.protection(at: AppModel.vaultURL) }
        .onChange(of: model.showEncryption) { _, _ in
            protection = try? VaultEncryption.protection(at: AppModel.vaultURL)
        }
        .sheet(item: sheet) { which in
            switch which {
            case .encryption: VaultEncryptionView().environment(model)
            case .changePassphrase: ChangePassphraseView().environment(model)
            }
        }
    }
}

/// Which conversations are missing files, biggest gap first. Clicking one opens it so the
/// owner can see what is missing rather than reading a number.
struct MissingMediaView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let rows: [(chat: String, count: Int)]
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Missing files").font(.title3.bold())
                Spacer()
                Text("\(total.formatted()) not in any folder").font(.caption).foregroundStyle(.secondary)
            }
            Text("These conversations reference photos, videos or documents that none of your media folders contain. The messages are here; the files are not.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        HStack {
                            Text(row.chat).lineLimit(1)
                            Spacer()
                            Text(row.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                            Button("Open") {
                                if let chat = model.chats.first(where: { $0.name == row.chat }) {
                                    model.openChat(chat); dismiss()
                                }
                            }
                            .buttonStyle(.link)
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 480, height: 460)
    }
}
