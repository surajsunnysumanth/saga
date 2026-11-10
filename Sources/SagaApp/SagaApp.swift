import SwiftUI
import SagaCore

@main
struct SagaApp: App {
    @State private var model = AppModel.shared
    init() {
        // Screenshot runs must never take over the owner's screen: no Dock icon, no focus stealing.
        if CommandLine.arguments.contains("--snapshot") {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async {   // don't depend on the window appearing
            if AppModel.demoRoot != nil { AppModel.shared.openDemo(); return }   // isolated synthetic run: no restore, migration or phone hints
            AppModel.shared.restore(); AppModel.shared.refreshPhoneHint()
            AppModel.shared.startPhoneWatch()
            AppModel.shared.applyStartPlaceFromEnvironment()
            // Quiet guest: one request a day at most, off the launch path, silent if it fails.
            Task { await AppModel.shared.checkForUpdates() }
        }
    }
    var body: some Scene {
        WindowGroup("Saga") {
            ContentView().environment(model).frame(minWidth: 900, minHeight: 640)
                .sheet(isPresented: Binding(get: { model.showReplies }, set: { model.showReplies = $0 })) {
                    ReplyResponsibilityView().environment(model)
                }
                .task { await Snapshot.runIfRequested(model) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if AppModel.demoRoot == nil { model.refreshPhoneHint() } }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Settings is a place in this window, not a second window with a second copy of
            // the same view: ⌘, navigates the place and leaves the duplicate scene out.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.go(to: .settings) }
                    .keyboardShortcut(",")
            }
            // Find is contextual: inside a conversation ⌘F searches that chat, everywhere else it
            // puts the cursor in the archive search. ⌘G / ⇧⌘G step through matches.
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find in Conversation") { model.beginFind() }
                    .keyboardShortcut("f")
                Button("Find Next") { model.stepFind(1) }
                    .keyboardShortcut("g")
                    .disabled(!model.findOpen || model.findHits.isEmpty)
                Button("Find Previous") { model.stepFind(-1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!model.findOpen || model.findHits.isEmpty)
                Button("Search Everything") { model.searchFocusTick += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.store == nil)
                // ⌘K belongs to the Ask pill in the top bar; it is listed next to Find because
                // both are ways of looking something up, and the Edit menu is where a Mac
                // user reaches for those. The pill is the visible door.
                Button("Ask Your Archive…") { model.aiPanel.openAsk(model: model) }
                    .keyboardShortcut("k")
                    .disabled(model.store == nil)
            }
            // Go is a place switcher and nothing else. Every tool that used to live here has a
            // visible home in the window — Settings, the Home cards, the Gallery tabs — and a
            // menu-only action is, to this owner, a hidden feature.
            CommandMenu("Go") {
                Button("Home") { model.go(to: .home) }.keyboardShortcut("0")
                Button("Chats") { model.go(to: .chats) }.keyboardShortcut("1")
                Button("People") { model.go(to: .chats); model.section = .people }.keyboardShortcut("2")
                Button("Gallery") { model.go(to: .gallery) }.keyboardShortcut("3")
                Button("Insights") { model.go(to: .insights) }.keyboardShortcut("4")
                Button("Settings") { model.go(to: .settings) }.keyboardShortcut("5")
            }
        }
    }
}

/// The sheets a `Go` menu item, the phone importer or the vault can open from anywhere.
/// They are presented by one `.sheet(item:)` at the window root, never by stacked modifiers.
enum AppSheet: String, Identifiable, CaseIterable {
    case merge, prune, onThisDay, unlock, needsKey
    var id: String { rawValue }
}

enum Pane { case dashboard, chat, search, person, wrapped, gallery, settings }

/// `ChatMode` itself lives in `SagaCore` (`ChatNavigation`), next to the rule that says a
/// different conversation always opens on Messages. One definition, one rule, tested there.
enum NavSection: String, CaseIterable { case chats = "Chats", people = "People", wrapped = "Wrapped" }

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    var store: VaultStore?
    var stats: VaultStats?
    var busy = false
    var status = ""
    /// Live USB state, so the window can say whether pulling from the phone is even possible.
    var phone: PhoneStatus = .absent
    var pane: Pane = .dashboard

    /// The conversation pane's navigation: which chat is open, which mode it shows, and where a
    /// jump took the reader from. `ChatNavigation` owns both rules (a new chat opens on Messages;
    /// a jump remembers its origin), so `swift test` can pin them instead of the view.
    var nav = ChatNavigation()

    /// What the open conversation is showing. Reading and writing it goes through `nav`, so a
    /// chat switch resets it deterministically and the segmented control keeps its binding.
    var chatMode: ChatMode {
        get { nav.mode }
        set { nav.setMode(newValue) }
    }

    /// Where the reader was before the last jump, or nil when there is nothing to go back to.
    var jumpOrigin: ChatOrigin? { nav.origin }

    /// What the return bar says happened: "Back to Priya Menon · Heartbeat" in words.
    var jumpOriginSentence: String {
        guard let o = nav.origin else { return "" }
        switch o.place {
        case .search:
            return "You jumped here from your search results"
        case .insights:
            return "You jumped here from Wrapped"
        case .conversation:
            let name = o.chatID.flatMap { id in chats.first(where: { $0.id == id })?.name } ?? "that conversation"
            let pane = o.mode == .messages ? "" : " · \(o.mode.rawValue)"
            return "You jumped here from \(name)\(pane)"
        }
    }

    /// The × on the return bar. The origin is gone for good; nothing can resurrect it later.
    func dismissJumpOrigin() { nav.dismissOrigin() }

    /// Bumped when a reveal is wanted but `focusMessage` may already hold the same id — a return
    /// to the message you were last shown is otherwise an unchanged value and scrolls nothing.
    var revealTick = 0

    /// The place is derived, never stored: a chat lives inside Chats, a person too.
    var place: Place {
        switch pane {
        case .dashboard: return .home
        case .gallery: return .gallery
        case .settings: return .settings
        case .wrapped: return .insights
        default: return section == .wrapped ? .insights : .chats
        }
    }

    /// Lets a run open straight into a place, which the snapshot harness and a quick manual
    /// check both need.
    func applyStartPlaceFromEnvironment() {
        guard let raw = ProcessInfo.processInfo.environment["SAGA_START_PLACE"],
              let place = Place(rawValue: raw) else { return }
        go(to: place)
    }

    func go(to place: Place) {
        switch place {
        case .home: pane = .dashboard
        case .chats: section = .chats; pane = .chat
        case .gallery: pane = .gallery
        case .insights: section = .wrapped; pane = .wrapped
        case .settings: pane = .settings
        }
    }

    /// Which Gallery tab a place change should land on (`Music` from the Home tile).
    /// The Gallery owns the tab, so it reads this once on arrival and clears it.
    var galleryTab: String?

    /// Where a Home module tile goes.
    ///
    /// The tiles used to set `section` and nothing else, so `sectionChanged` decided the pane
    /// and left it on Home whenever no conversation was selected — a card that swallows the
    /// click. Every destination now names its place, which is also what the Go menu does.
    func openModule(_ id: String) {
        switch id {
        case "chats":
            go(to: .chats)
        case "people":
            section = .people
            pane = .person
        case "wrapped":
            go(to: .insights)
        case "music":
            galleryTab = "Music"
            go(to: .gallery)
        default:
            break
        }
    }

    // update from phone
    var updating = false
    var phoneHint: String?          // e.g. "New backup on your phone (6 Nov 02:56)"
    var keyEntry = ""
    var toast: String?

    var section: NavSection = .chats { didSet { sectionChanged() } }

    // people
    var people: [PersonRow] = []
    var peopleQuery = "" { didSet { reloadPeople() } }
    var peopleSort: PersonSort = .mostMessages { didSet { reloadPeople() } }
    var peopleNamedOnly = true { didSet { reloadPeople() } }
    var selectedPerson: PersonRow? { didSet { if let p = selectedPerson { personDetail = try? store?.detail(for: p.key); pane = .person } } }
    var personDetail: PersonDetail?

    // wrapped: the year story is built off the main thread and cached by content, so
    // switching years, toggling titles or reopening the tab does not rebuild the same year.
    var wrappedYear = String(Calendar.current.component(.year, from: Date())) { didSet { loadWrapped() } }
    var yearWrapped: YearWrapped?
    var wrappedLoading = false
    var wrappedError: String?
    /// Set by the snapshot harness: a capture may show real titles and artwork without
    /// reading (or writing) the user's preferences, which demo mode never touches.
    var demoTitles = false
    /// Opt-in: ask Spotify/YouTube for the real title of the songs in the story.
    /// Demo mode starts off and never persists it; the snapshot flag can force it.
    var wrappedTitles: Bool = (AppModel.demoRoot == nil)
        ? ((UserDefaults.standard.object(forKey: "wrappedTitles") as? Bool) ?? false) : false
    private var wrappedRequest = 0
    private static var yearCache: [String: YearWrapped] = [:]
    /// Titles and artwork fetched once are remembered here, so a second year costs no network.
    nonisolated static let linkMeta: LinkMetaCache? = try? LinkMetaCache(path: supportDir.appendingPathComponent("link_meta.db").path)

    // on this day: a compact Home card that opens a dated sheet. The build runs off the
    // main thread against a read-only connection; the sheet reuses it for the same date.
    // The open flag is `showOnThisDay` above, a view onto `appSheet`.
    var onThisDayDate = Date()
    var onThisDay: OnThisDay?
    var onThisDayLoading = false
    var onThisDayError: String?
    var showOnThisDayOnHome: Bool = (UserDefaults.standard.object(forKey: "onThisDayHome") as? Bool) ?? true {
        didSet { if Self.demoRoot == nil { UserDefaults.standard.set(showOnThisDayOnHome, forKey: "onThisDayHome") } }
    }
    private var onThisDayRequest = 0
    private var onThisDayLoadingKey = ""

    // Update check: one request a day to GitHub's release API, nothing else. It never blocks a
    // launch, never shows an error and never runs in a demo/snapshot session. The banner on Home
    // and the row in Settings both read `updateOutcome`; the skip and the on/off switch live in
    // `UserDefaults` (see `UpdatePreferenceKey`).
    var updateOutcome: UpdateOutcome?
    var updateChecking = false
    var updateChecksEnabled: Bool = (UserDefaults.standard.object(forKey: UpdatePreferenceKey.enabled) as? Bool) ?? true {
        didSet {
            guard Self.demoRoot == nil else { return }
            UserDefaults.standard.set(updateChecksEnabled, forKey: UpdatePreferenceKey.enabled)
            if updateChecksEnabled {
                if updateOutcome == nil || updateOutcome == .disabled { Task { await checkForUpdates() } }
            } else {
                updateOutcome = .disabled
            }
        }
    }

    /// The build's own version, written into the bundle by `scripts/make_app.sh`. A binary with
    /// no bundle (the CLI, `swift test`) has no version, and then no check happens at all —
    /// better than treating every release as newer than a development build.
    nonisolated static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Ask GitHub once. Silent by design: the only outcomes a person sees are a banner and the
    /// status line in Settings.
    func checkForUpdates(manual: Bool = false) async {
        guard Self.demoRoot == nil, !updateChecking,
              let text = Self.appVersion, let current = SemanticVersion(text) else { return }
        guard updateChecksEnabled else { updateOutcome = .disabled; return }
        updateChecking = true
        let outcome = await UpdateChecker(currentVersion: current, store: UserDefaultsUpdateStore())
            .check(manual ? .manual : .automatic)
        updateOutcome = outcome
        updateChecking = false
    }

    /// The release the Home banner shows: only an undismissed newer version.
    var announcedUpdate: UpdateRelease? { updateOutcome?.shouldAnnounce == true ? updateOutcome?.release : nil }

    /// The × on the banner. Skips this version only; a later release announces again.
    func skipUpdate(_ release: UpdateRelease) {
        if Self.demoRoot == nil { UserDefaultsUpdateStore().skippedVersion = release.versionText }
        updateOutcome = .skipped(release)
    }

    /// Download opens the DMG; the version number opens the release notes.
    func openUpdate(_ release: UpdateRelease) { NSWorkspace.shared.open(release.downloadURL) }
    func openUpdatePage(_ release: UpdateRelease) { NSWorkspace.shared.open(release.pageURL) }

    /// What Settings says above "Check now", and the release to download if there is one. A
    /// launch inside the 24-hour window still answers, from the version remembered last time.
    var updateStatus: (text: String, release: UpdateRelease?) {
        switch updateOutcome {
        case .available(let r): return ("\(r.versionText) is available", r)
        case .skipped(let r): return ("\(r.versionText) available · dismissed", r)
        case .disabled: return ("Off", nil)
        case .failed: return ("Couldn't reach GitHub", nil)
        case .upToDate: return ("Up to date", nil)
        case .throttled, .none:
            if let seen = UserDefaultsUpdateStore().lastSeenVersion, let v = SemanticVersion(seen),
               let current = Self.appVersion.flatMap(SemanticVersion.init), v > current {
                return ("\(v) is available",
                        UpdateRelease(version: v, tag: "v\(v)", pageURL: UpdateSource.releasePage, downloadURL: UpdateSource.download))
            }
            return updateOutcome == nil ? ("Not checked yet", nil) : ("Checked recently", nil)
        }
    }

    /// Snapshot only: a synthetic release, so a capture of the banner or the Settings row never
    /// touches the network and never writes to the real preferences.
    func previewUpdate(version: String) {
        guard let v = SemanticVersion(version) else { return }
        updateOutcome = .available(UpdateRelease(version: v, tag: "v\(v)",
                                                 pageURL: UpdateSource.releasePage, downloadURL: UpdateSource.download))
    }

    // chat list
    var chats: [ChatRow] = []
    var chatQuery = "" { didSet { reloadChats() } }
    var chatKind: ChatKind = .all { didSet { reloadChats() } }
    var chatSort: ChatSort = .recent { didSet { reloadChats() } }
    var hideTinyChats = true { didSet { reloadChats() } }
    var selected: ChatRow? {
        didSet {
            guard selected != oldValue else { return }
            // The mode belongs to the conversation it was chosen in: a different chat opens on
            // Messages, the same chat keeps whatever pane it was showing.
            nav.select(selected?.id)
            loadSelected()
        }
    }

    // conversation
    var messages: [MessageRow] = [] { didSet { syncReactions() } }
    var messageFilter: MessageFilter = .all { didSet { loadSelected() } }
    var focusMessage: Int64?
    var canLoadOlder = true

    // Reaction chips, keyed by message id. Filled one page at a time (see `syncReactions`),
    // never per bubble: the conversation can hold thousands of rows.
    var reactionSummaries: [Int64: MessageReactionSummary] = [:]
    /// Ids already asked about, including the ones that came back with nothing. It is what
    /// keeps a message with no reactions from being queried again on the next body pass.
    @ObservationIgnored private var reactionChecked: Set<Int64> = []

    // find in the open conversation: a search scoped to the chat on screen. It marks every
    // match in the loaded window and steps between them, loading the messages around a hit
    // that sits outside it, so it never leaves the conversation the way the archive search does.
    var findOpen = false
    var findQuery = "" { didSet { if findQuery != oldValue { scheduleFind() } } }
    var findHits: [SearchHit] = []          // oldest first: a hit's number is its place in the transcript
    var findIndex = 0
    var findFocusTick = 0                   // ⌘F asks the field to take focus
    var searchFocusTick = 0                 // ⇧⌘F asks the top-bar field to take focus
    @ObservationIgnored private var findTask: Task<Void, Never>?
    @ObservationIgnored private static let findLimit = 500

    /// Every match in the conversation, for the bubbles to ring as you type.
    var findMatchIDs: Set<Int64> { findOpen ? Set(findHits.map(\.id)) : [] }
    /// "3 of 17", "No matches", or empty while the field is.
    var findCountLabel: String {
        guard !findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        guard !findHits.isEmpty else { return "No matches" }
        let total = findHits.count >= Self.findLimit ? "\(findHits.count)+" : "\(findHits.count)"
        return "\(findIndex + 1) of \(total)"
    }

    /// ⌘F. With a conversation open it finds inside it; anywhere else it puts the cursor in
    /// the archive search. One key, two levels — it never pretends the chat is the archive.
    func beginFind() {
        guard pane == .chat, selected != nil else { searchFocusTick += 1; return }
        chatMode = .messages
        findOpen = true
        findFocusTick += 1
        if findQuery.trimmingCharacters(in: .whitespaces).isEmpty { findHits = []; findIndex = 0 }
        else { scheduleFind() }
    }

    func closeFind() {
        findTask?.cancel()
        dropFindFocus()
        findOpen = false
        findHits = []; findIndex = 0
    }

    func stepFind(_ delta: Int) {
        guard !findHits.isEmpty else { return }
        findIndex = (findIndex + delta + findHits.count) % findHits.count
        revealFind()
    }

    /// Typing is rapid; wait for a pause so a long chat is queried once, not per letter.
    private func scheduleFind() {
        findTask?.cancel()
        guard findOpen, let chat = selected else { findHits = []; findIndex = 0; return }
        let text = findQuery
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            dropFindFocus()
            findHits = []; findIndex = 0
            return
        }
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self, self.findOpen,
                  self.findQuery == text, self.selected?.id == chat.id else { return }
            guard let store = self.store, let hits = try? store.find(text, in: chat.id, limit: Self.findLimit) else { return }
            self.findHits = hits
            // Start at the newest match: the reader is at the bottom of the conversation.
            self.findIndex = max(0, hits.count - 1)
            self.revealFind()
        }
    }

    /// Removes the ring find put on a bubble, without disturbing a jump from the archive search.
    private func dropFindFocus() {
        if let f = focusMessage, findHits.contains(where: { $0.id == f }) { focusMessage = nil }
    }

    private func revealFind() {
        guard findHits.indices.contains(findIndex) else { return }
        let hit = findHits[findIndex]
        if messages.contains(where: { $0.id == hit.id }) { focusMessage = hit.id }
        else { jump(toMessage: hit.id, in: hit.chatID) }
    }

    // search
    var query = ""
    var searchSender: SenderFilter = .any { didSet { runSearch() } }
    var searchSort: SearchSort = .newest { didSet { runSearch() } }
    var searchFrom: Date? { didSet { runSearch() } }
    var searchTo: Date? { didSet { runSearch() } }
    var hits: [SearchHit] = []

    /// Set by `--demo <folder>` (a folder made by `saga demo`): support, cache and vault all live there.
    nonisolated static let demoRoot: URL? = {
        do { return try DemoVault.launchDirectory(arguments: CommandLine.arguments) }
        catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(2) }
    }()
    func openDemo() {
        guard let root = Self.demoRoot else { return }
        open(path: root.appendingPathComponent("vault_index.db").path)
    }
    nonisolated static var supportDir: URL {
        if let demoRoot { return demoRoot }
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Saga")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    var indexURL: URL { Self.supportDir.appendingPathComponent("vault_index.db") }
    /// The vault: a plain folder holding the archive (segments of messages, open formats). Default is local; the user can pick a NAS / cloud folder.
    nonisolated static var vaultURL: URL {
        if let demoRoot { return demoRoot.appendingPathComponent("vault") }
        if let p = UserDefaults.standard.string(forKey: "vaultPath") { return URL(fileURLWithPath: p) }
        return supportDir.appendingPathComponent("vault")
    }
    nonisolated static var legacyArchiveDir: URL { supportDir.appendingPathComponent("archive") }
    nonisolated static var deviceLabel: String { (Host.current().localizedName ?? "mac").filter { $0.isLetter || $0.isNumber } }

    /// Opens (creating if needed) the vault. Reconciles an interrupted conversion first; encrypted vaults
    /// open with the Keychain-remembered key and otherwise prompt for unlock.
    func prepareVault() -> Vault? {
        do {
            _ = try VaultConversion.reconcile(at: Self.vaultURL)
        } catch {
            vaultOK = false
            toast = "A previous archive conversion needs attention."
            return nil
        }
        do {
            let v = try Vault.open(url: Self.vaultURL)
            vaultOK = true; return v
        } catch VaultEncryptionError.locked {
            vaultOK = false
            appSheet = .unlock
            return nil
        } catch {
            vaultOK = false
            toast = "Your archive folder isn't available. Showing the last saved library."
            return nil
        }
    }
    var vaultOK = true
    var showFoldIn = false
    var showUnnamed = false
    /// How many chats the archive could not name; the People sidebar's entry row carries it.
    var unnamedTotal: Int?
    var showEncryption = false
    var showChangePassphrase = false

    /// Which window-wide sheet is open. `Go` menu items and the vault code set these flags from
    /// anywhere, so they need one host at the window root. Seven `.sheet(isPresented:)` modifiers
    /// stacked on one view present only one of them: the rest are built and thrown away, and the
    /// menu item looks dead. Each flag below is a view onto this single item instead.
    var appSheet: AppSheet?

    var showMerge: Bool { get { appSheet == .merge } set { setSheet(newValue, .merge) } }
    var showPrune: Bool { get { appSheet == .prune } set { setSheet(newValue, .prune) } }
    var showOnThisDay: Bool { get { appSheet == .onThisDay } set { setSheet(newValue, .onThisDay) } }
    var needsKey: Bool { get { appSheet == .needsKey } set { setSheet(newValue, .needsKey) } }

    private func setSheet(_ on: Bool, _ sheet: AppSheet) {
        if on { appSheet = sheet } else if appSheet == sheet { appSheet = nil }
    }
    /// One entry point per housekeeping tool, so Settings, the menu and the surface that
    /// actually needs the tool all call the same thing instead of each inventing its state.
    var showReplies = false
    func openMergeContacts() { showMerge = true }
    func openCleanUp() { showPrune = true }
    func openReplyReview() { showReplies = true }
    func openUnnamedChats() {
        section = .people
        pane = .person
        showUnnamed = true
    }
    /// The MCP command is a visible Settings › Privacy row; the menu only mirrors it.
    func copyClaudeCodeCommand() {
        let exe = Bundle.main.bundlePath + "/Contents/MacOS/saga-mcp"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude mcp add saga -- \"\(exe)\"", forType: .string)
        flash("Copied. Paste it in Terminal to let Claude Code read your archive.")
    }
    var encryption = EncryptionWizard()
    // On-demand chat media: one loader per vault; created lazily, does no IO until a bubble asks.
    var mediaGeneration = 0
    private var loader: ChatMediaLoader?
    private var loaderVault: URL?
    nonisolated static var driveRoot: URL? {
        get { UserDefaults.standard.string(forKey: "driveMediaRoot").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "driveMediaRoot") }
    }
    func mediaLoader() -> ChatMediaLoader? {
        let url = Self.vaultURL
        if loader == nil || loaderVault != url {
            loader = ChatMediaLoader(vaultURL: url, cacheDirectory: Self.supportDir.appendingPathComponent("media-thumbnails"),
                                     maxConcurrentLoads: 4, driveRoots: Self.driveRoot.map { [$0] } ?? [])
            loaderVault = url
        }
        return loader
    }
    func mediaSettingsChanged() { loader = nil; mediaGeneration += 1 }

    /// Polls ADB while the app is open. Cheap (one process every eight seconds) and it is the
    /// only honest way to know whether a cable offers a backup and the phone's photos.
    func startPhoneWatch() {
        Task { @MainActor in
            while !Task.isCancelled {
                let status = await Task.detached { PhoneLink.detect() }.value
                let changed = status != phone
                if changed { phone = status }
                PhoneLink.mediaFallbackEnabled = status.isConnected
                // A tile that failed while the cable was out must be given another chance.
                if changed, status.isConnected { mediaGeneration += 1 }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    /// Copies the phone's media tree into the support folder and registers it as a source, so
    /// the resolver can show photos that exist only on the device.
    func copyPhoneMedia() {
        guard phone.isConnected else { flash("Connect the phone with USB debugging to copy its media."); return }
        let dest = Self.supportDir.appendingPathComponent("phone-media")
        flash("Copying media from the phone…")
        Task {
            do {
                let n = try await Task.detached { try PhoneLink.copyMedia(to: dest) { msg in
                    Task { @MainActor in self.toast = msg }
                } }.value
                if let vault = prepareVault() {
                    var sources = (try? MediaSources.load(in: vault)) ?? []
                    if !sources.contains(where: { $0.standardizedFileURL == dest.standardizedFileURL }) {
                        sources.append(dest)
                        try? MediaSources.save(sources, in: vault)
                    }
                }
                mediaSettingsChanged()
                flash(n > 0 ? "\(n.formatted()) new files copied from the phone." : "Phone media is already here.")
            } catch {
                flash(error.localizedDescription)
            }
        }
    }
    func flash(_ text: String) {
        toast = text
        // A token, not the text: two identical messages in a row used to let the first
        // message's timer clear the second one almost immediately.
        flashToken += 1
        let token = flashToken
        Task { try? await Task.sleep(for: .seconds(5)); if flashToken == token { toast = nil } }
    }
    @ObservationIgnored private var flashToken = 0
    var showAsk = false
    let aiPanel = AIPanel()
    let media = MediaBrowser()

    // Home tile: how many distinct music/video links the archive holds. Counted once
    // per opened library, off the main thread (`nil` until it lands, so the tile shows "—").
    var sharedLinkCount: Int?
    private var loadingSharedLinkCount = false
    func loadSharedLinkCount() {
        guard store != nil, sharedLinkCount == nil, !loadingSharedLinkCount else { return }
        loadingSharedLinkCount = true
        let path = indexURL.path
        Task {
            let n = await Task.detached { () -> Int? in
                guard let store = try? VaultStore(path: path) else { return nil }
                return try? store.sharedLinks(chat: nil).count
            }.value
            sharedLinkCount = n
            loadingSharedLinkCount = false
        }
    }

    /// Home card: how many one-to-one chats end on their unanswered question. The same
    /// rule the sheet uses, counted once per opened library off the main thread, so Home
    /// can offer the review without opening a sheet to find out whether there is anything
    /// in it. `nil` until it lands (or when there is nothing), so no card is drawn.
    var replyWaitingCount: Int?
    private var loadingReplyWaitingCount = false
    func loadReplyWaitingCount() {
        guard store != nil, replyWaitingCount == nil, !loadingReplyWaitingCount else { return }
        loadingReplyWaitingCount = true
        let path = indexURL.path
        Task {
            let n = await Task.detached { () -> Int? in
                guard let s = try? VaultStore(path: path) else { return nil }
                return try? ReplyResponsibility.find(store: s).candidates.count
            }.value
            replyWaitingCount = n
            loadingReplyWaitingCount = false
        }
    }

    /// Rebuilds the local library (index cache) from the vault.
    func rebuildLibrary(extraContacts: [String: String] = [:], vcf: String? = nil, then done: @escaping @MainActor (ImportSummary?) -> Void) {
        guard let vault = prepareVault() else { done(nil); return }
        let out = indexURL
        Task {
            do {
                let s = try await Task.detached { try VaultIndexer.build(vault: vault, out: out.path, vcfPath: vcf, extraContacts: extraContacts) }.value
                open(path: out.path); done(s)
            } catch { status = "Could not build the library: \(error)"; done(nil) }
        }
    }

    func restore() {
        if store == nil, let p = UserDefaults.standard.string(forKey: "indexPath"), FileManager.default.fileExists(atPath: p) { open(path: p) }
        // library built by an older version (no "content" column): rebuild once so blank chats get filtered
        if let st = store, !st.hasContentCol, !updating, UserDefaults.standard.bool(forKey: "libraryRebuiltForContent") == false {
            UserDefaults.standard.set(true, forKey: "libraryRebuiltForContent")
            updating = true
            rebuildLibrary { [self] _ in updating = false; reloadChats() }
        }
        // library built before "last_real_ts" existed (system notices bumped chats): rebuild once
        if let st = store, !st.hasLastRealCol, !updating, UserDefaults.standard.bool(forKey: "libraryRebuiltForRealActivity") == false {
            UserDefaults.standard.set(true, forKey: "libraryRebuiltForRealActivity")
            updating = true
            rebuildLibrary { [self] _ in updating = false; reloadChats() }
        }
        // legacy decrypted archive present: move it into the vault in the background, then rebuild
        let legacy = Self.legacyArchiveDir
        let legacyHasDBs = ((try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == "db" }
        if legacyHasDBs, !updating, let vault = prepareVault() {
            updating = true; toast = "Moving your archive into the new vault format…"
            let label = Self.deviceLabel, support = Self.supportDir
            Task {
                do {
                    _ = try await Task.detached { try Updater.migrateLegacyArchive(legacy, into: vault, label: label) }.value
                    try? FileManager.default.moveItem(at: legacy, to: support.appendingPathComponent("archive-migrated"))
                    rebuildLibrary { [self] s in
                        updating = false
                        toast = s.map { "Archive moved to the new vault: \($0.messages.formatted()) messages" }
                        Task { try? await Task.sleep(for: .seconds(6)); toast = nil }
                    }
                } catch { updating = false; toast = "Couldn't move the old archive: \(error)" }
            }
        }
    }
    /// Quietly checks whether the connected phone has a newer backup than the one already in the archive.
    func refreshPhoneHint() {
        Task {
            guard Adb.locate() != nil, case .ready = await Adb.state(), let info = await Adb.backupInfo(), let t = info.lastBackup else { phoneHint = nil; return }
            phoneHint = t == Updater.lastPulledBackup(support: Self.supportDir) ? nil : "New backup on your phone (\(t))"
        }
    }

    func updateFromPhone(force: Bool = false) {
        guard !updating else { return }
        guard let key = Keychain.load() ?? (keyEntry.filter { $0.isHexDigit }.count == 64 ? keyEntry : nil) else { needsKey = true; return }
        if keyEntry.filter({ $0.isHexDigit }).count == 64 { Keychain.save(keyEntry.filter { $0.isHexDigit }) }
        updating = true; needsKey = false; toast = "Updating from your phone…"
        let support = Self.supportDir, out = indexURL
        guard let vault = prepareVault() else { updating = false; return }
        Task {
            do {
                let s = try await Updater.run(support: support, vault: vault, indexOut: out, keyHex: key, force: force, label: Self.deviceLabel, progress: { msg in Task { @MainActor in self.toast = msg } })
                let keep = selected?.id
                open(path: out.path)
                if let keep, let c = chats.first(where: { $0.id == keep }) { openChat(c) }
                toast = "Updated: \(s.messages.formatted()) messages" + (s.mergedMessages > 0 ? " · \(s.mergedMessages.formatted()) kept from older backups" : "")
                phoneHint = nil
            } catch { toast = "\(error)" }
            updating = false
            try? await Task.sleep(for: .seconds(8)); if !updating { toast = nil }
        }
    }

    func updateFromIPhone() {
        guard !updating else { return }
        updating = true; toast = "Updating from your iPhone…"
        let support = Self.supportDir, out = indexURL
        guard let vault = prepareVault() else { updating = false; return }
        Task {
            do {
                let s = try await IOSUpdater.run(support: support, vault: vault, indexOut: out, label: Self.deviceLabel + "-iphone", progress: { msg in Task { @MainActor in self.toast = msg } })
                let keep = selected?.id
                open(path: out.path)
                if let keep, let c = chats.first(where: { $0.id == keep }) { openChat(c) }
                toast = "Updated from iPhone: \(s.messages.formatted()) messages in your archive"
            } catch { toast = error.localizedDescription }
            updating = false
            try? await Task.sleep(for: .seconds(10)); if !updating { toast = nil }
        }
    }

    func export(chat: ChatRow, format: ExportFormat) {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = chat.name.replacingOccurrences(of: "/", with: "-") + (format == .html ? ".html" : ".txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let n = try ChatExporter.export(store: store, chat: chat, format: format, to: url); toast = "Exported \(n.formatted()) messages to \(url.lastPathComponent)" }
        catch { toast = "Export failed: \(error)" }
        Task { try? await Task.sleep(for: .seconds(6)); toast = nil }
    }

    func open(path: String) {
        do {
            store = try VaultStore(path: path); stats = try store?.stats()
            sharedLinkCount = nil
            replyWaitingCount = nil
            yearWrapped = nil; wrappedError = nil      // the library just changed; rebuild the year story
            onThisDay = nil; onThisDayError = nil; onThisDayLoadingKey = ""; onThisDayRequest += 1
            // A rebuilt index can carry reactions the previous one did not (an update from the
            // phone lands them after the messages). Re-ask before anything draws, so no chip is
            // left showing the old count.
            reloadReactions()
            if Self.demoRoot == nil { UserDefaults.standard.set(path, forKey: "indexPath") }   // demo never touches saved preferences
            reloadChats(); status = ""; pane = .dashboard
        } catch { status = "Could not open index: \(error)" }
    }
    func sectionChanged() {
        switch section {
        case .chats: pane = selected == nil ? .dashboard : .chat
        case .people: reloadPeople(); pane = .person
        case .wrapped:
            if let y = stats?.yearly.last?.year, !(stats?.yearly.contains { $0.year == wrappedYear } ?? false) { wrappedYear = y }
            loadWrapped(); pane = .wrapped
        }
    }
    func reloadPeople() {
        people = (try? store?.people(matching: peopleQuery, sort: peopleSort, namedOnly: peopleNamedOnly)) ?? []
        // One small aggregate over chat_stats; cheap enough to keep in step with the list beside it.
        if let store, let n = try? store.unnamedChatCount() { unnamedTotal = n } else { unnamedTotal = nil }
    }
    func loadWrapped(force: Bool = false) {
        guard store != nil else { yearWrapped = nil; wrappedLoading = false; return }
        if !force, let have = yearWrapped, have.year == wrappedYear { return }
        let year = wrappedYear, path = indexURL.path
        let titles = demoTitles || wrappedTitles
        let wanted = !force
        wrappedRequest += 1
        let request = wrappedRequest
        wrappedLoading = true; wrappedError = nil; yearWrapped = nil
        // A year of a real library is a lot of rows: build on a background task with its
        // own read-only connection so the window never stops responding.
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> (String, YearWrapped) in
                    let store = try VaultStore(path: path)
                    let key = YearWrappedBuilder.cacheKey(store: store, year: year) + (titles ? "-titles" : "")
                    if wanted, let hit = await Self.cachedYear(key) { return (key, hit) }
                    let built = try await YearWrappedBuilder.build(store: store, year: year,
                                                                   fetchTitles: titles, cache: Self.linkMeta)
                    return (key, built)
                }.value
                Self.yearCache[result.0] = result.1
                if wrappedRequest == request { yearWrapped = result.1; wrappedLoading = false }
            } catch {
                if wrappedRequest == request {
                    wrappedError = "Couldn't build \(year): \(error.localizedDescription)"
                    wrappedLoading = false
                }
            }
        }
    }

    private nonisolated static func cachedYear(_ key: String) async -> YearWrapped? {
        await MainActor.run { yearCache[key] }
    }

    /// Postpone a capture until the year story has actually arrived.
    func waitForWrapped() async {
        for _ in 0..<80 where wrappedLoading { try? await Task.sleep(for: .milliseconds(250)) }
    }

    func setWrappedTitles(_ on: Bool) {
        wrappedTitles = on
        if Self.demoRoot == nil { UserDefaults.standard.set(on, forKey: "wrappedTitles") }
        loadWrapped(force: true)
    }

    // MARK: On this day

    /// Opens the sheet for `date` (today by default) and starts loading it.
    func openOnThisDay(for date: Date = Date()) {
        guard store != nil else { return }
        onThisDayDate = date
        showOnThisDay = true
        Task { await loadOnThisDay(date: date) }
    }

    /// Builds a date off the main thread. Reuses the loaded day when the month/day match,
    /// unless `force` says the library just changed.
    func loadOnThisDay(date: Date = Date(), force: Bool = false) async {
        guard store != nil else { return }
        let cal = Calendar.current
        let month = cal.component(.month, from: date), day = cal.component(.day, from: date)
        let key = String(format: "%02d-%02d", month, day)
        onThisDayDate = date
        if !force, let have = onThisDay, have.month == month, have.day == day { return }
        if onThisDayLoading, onThisDayLoadingKey == key { return }
        onThisDayRequest += 1
        let request = onThisDayRequest
        onThisDayLoading = true; onThisDayLoadingKey = key; onThisDayError = nil
        let path = indexURL.path
        let outcome = await Task.detached { () -> (day: OnThisDay?, error: String?) in
            do { return (try OnThisDayBuilder.build(store: try VaultStore(path: path), month: month, day: day), nil) }
            catch { return (nil, "\(error)") }
        }.value
        guard request == onThisDayRequest else { return }
        if let day = outcome.day { onThisDay = day; onThisDayError = nil }
        else { onThisDayError = outcome.error ?? "The archive could not be read." }
        onThisDayLoading = false; onThisDayLoadingKey = ""
    }

    /// Picks one of the archive's busiest calendar days, so "Surprise me" lands on a day
    /// with something to see. Returns the date the sheet should show.
    func surpriseOnThisDay() async -> Date? {
        guard store != nil else { return nil }
        let path = indexURL.path
        let cal = Calendar.current
        let cur = onThisDay.map { ($0.month, $0.day) }
        let pick = await Task.detached { () -> (month: Int, day: Int)? in
            guard let store = try? VaultStore(path: path) else { return nil }
            var rng: any RandomNumberGenerator = SystemRandomNumberGenerator()
            return try? OnThisDayBuilder.surpriseDate(store: store, excluding: cur?.0, day: cur?.1, random: &rng)
        }.value
        guard let pick else { return nil }
        var comps = DateComponents()
        comps.year = cal.component(.year, from: Date()); comps.month = pick.month; comps.day = pick.day
        guard let date = cal.date(from: comps) else { return nil }
        onThisDayDate = date
        await loadOnThisDay(date: date, force: true)
        return date
    }

    func openPerson(key: String) {
        section = .people
        if let p = (try? store?.people(matching: "", sort: .mostMessages, namedOnly: false, limit: 100000))?.first(where: { $0.key == key }) { selectedPerson = p }
    }

    func reloadChats() {
        chats = (try? store?.chats(matching: chatQuery, kind: chatKind, sort: chatSort, minMessages: hideTinyChats ? 10 : 1)) ?? []
    }

    func openChat(_ c: ChatRow) {
        // A deliberate move: whatever jump the reader was offered is behind them now, so the
        // return bar goes with it rather than following them into the next conversation.
        nav.dismissOrigin()
        selected = c; pane = .chat
    }
    /// Returns false when the conversation is not in the archive (a merged or pruned chat).
    @discardableResult
    func openChat(id: Int64) -> Bool {
        if let r = chats.first(where: { $0.id == id }) ?? (try? store?.chats(limit: 100000))?.first(where: { $0.id == id }) {
            openChat(r)
            return true
        }
        return false
    }
    /// Where the reader is right now, as a place a jump can come back to.
    ///
    /// The anchor is the message on screen — a jump's own highlight when there is one, otherwise
    /// the newest message the loaded window ends on — together with its date, which is what a
    /// pruned anchor falls back to. A place with no conversation to restore (Home, a person) is
    /// not an origin: there would be nothing to come back to.
    private func currentOrigin() -> ChatOrigin? {
        switch pane {
        case .search:
            // The results are still in `hits`; coming back re-shows the list the reader left.
            return ChatOrigin(place: .search, chatID: selected?.id,
                              messageID: focusMessage, date: messages.last?.ts ?? Date(), mode: chatMode)
        case .wrapped:
            // A jump out of the year's story: the story is the place, not a chat.
            return ChatOrigin(place: .insights, date: messages.last?.ts ?? Date(), mode: .messages)
        case .chat:
            guard let c = selected else { return nil }
            let anchor = messages.first(where: { $0.id == focusMessage }) ?? messages.last
            return ChatOrigin(place: .conversation, chatID: c.id,
                              messageID: focusMessage ?? anchor?.id,
                              date: anchor?.ts ?? c.last, mode: chatMode)
        default:
            return nil
        }
    }
    /// The jump's origin, kept only when the reader lands somewhere else.
    private func rememberJump(_ origin: ChatOrigin?, to chatID: Int64) {
        guard let origin else { nav.dismissOrigin(); return }
        nav.remember(origin, jumpingTo: chatID)
    }
    func loadSelected() {
        guard let c = selected, let store else { return }
        if findOpen { closeFind() }             // the bar belongs to the chat that was on screen
        focusMessage = nil
        messages = (try? store.messages(chat: c.id, filter: messageFilter)) ?? []
        canLoadOlder = messages.count >= 200
    }
    func loadOlder() {
        guard let c = selected, let store, let first = messages.first else { return }
        // Paging back is a long scroll away from the message that was jumped to: the offer to
        // return stops being about where the reader is, so it goes.
        nav.dismissOrigin()
        let older = (try? store.messages(chat: c.id, before: first.ts, filter: messageFilter)) ?? []
        canLoadOlder = older.count >= 200
        messages = older + messages
    }

    // MARK: Reactions on the messages on screen

    /// One batched query per page of messages, never one per bubble.
    ///
    /// `messages` is replaced when a chat opens and grows a page at a time as older messages are
    /// loaded; this keeps the chips in step by asking only about the ids it has not seen. So
    /// opening a chat costs one extra query, each "load earlier" costs one, and scrolling costs
    /// none — a per-bubble query would have been 900 round trips on a long conversation.
    private func syncReactions() {
        guard let store else {
            if !reactionSummaries.isEmpty { reactionSummaries = [:] }
            reactionChecked.removeAll()
            return
        }
        let live = Set(messages.map(\.id))
        // A different chat (or a jump) replaces the rows: drop what can no longer be drawn so
        // the cache stays the size of the conversation, not the size of the session.
        if reactionSummaries.contains(where: { !live.contains($0.key) }) {
            reactionSummaries = reactionSummaries.filter { live.contains($0.key) }
        }
        reactionChecked.formIntersection(live)
        let wanted = live.filter { !reactionChecked.contains($0) }
        guard !wanted.isEmpty else { return }
        let found = store.reactions(for: Array(wanted))
        if !found.isEmpty { reactionSummaries.merge(found) { _, new in new } }
        reactionChecked.formUnion(wanted)
    }

    /// The library was rebuilt: nothing on screen may keep a count from the old index.
    func reloadReactions() {
        reactionSummaries = [:]
        reactionChecked.removeAll()
        syncReactions()
    }

    func jump(toDate d: Date) {
        guard let c = selected, let store else { return }
        nav.dismissOrigin()
        messages = (try? store.messages(chat: c.id, from: d, filter: messageFilter)) ?? []
        focusMessage = messages.first?.id; canLoadOlder = true
        revealTick += 1
    }
    /// Opens the conversation around one message and highlights it.
    ///
    /// The id came from a story, a search hit or a citation, so it may be stale: rebuilding the
    /// index renumbers rows and a prune deletes them. The id is resolved first, and every
    /// outcome lands the reader somewhere honest instead of a chat with a highlight that
    /// points at nothing (or, worse, at a stranger's message).
    ///
    /// Where the reader was is remembered first, so the pane can offer the way back — the whole
    /// point of a jump from Wrapped is that you return to what you were reading.
    ///
    /// - Parameter origin: the place to come back to, when the caller knows better than the
    ///   current pane does. A jump out of the year story passes `.insights`, because the story is
    ///   the place the reader is leaving even though the window has already switched sections.
    func jump(toMessage id: Int64, in chatID: Int64, origin override: ChatOrigin? = nil) {
        guard let store else { return }
        let origin = override ?? currentOrigin()
        switch store.jumpTarget(messageID: id, chatID: chatID) {
        case .message(let mid, let cid, _):
            guard openChat(id: cid) else {
                flash("That conversation isn't in the archive any more.")
                return
            }
            chatMode = .messages               // the destination is the message, not the pane you left
            let page = (try? store.messages(chat: cid, around: mid)) ?? (rows: [], found: false)
            messages = page.rows
            focusMessage = page.found ? mid : nil
            canLoadOlder = page.rows.count >= 200
            revealTick += 1
            rememberJump(origin, to: cid)
            if !page.found {
                flash("That message isn't in the archive any more — showing the conversation.")
            }
        case .chat(let cid):
            guard openChat(id: cid) else {
                flash("That conversation isn't in the archive any more.")
                return
            }
            chatMode = .messages
            messages = (try? store.messages(chat: cid, filter: .all)) ?? []
            focusMessage = nil
            canLoadOlder = messages.count >= 200
            rememberJump(origin, to: cid)
            flash("That message is no longer in the archive — showing the conversation.")
        case .gone:
            flash("That message is no longer in the archive.")
        }
    }

    /// "Back to where you were": the chat, the pane and the message the reader left, resolved
    /// against what the archive still holds. A pruned anchor reopens the conversation at the same
    /// date; a vanished conversation says so instead of pretending the bar worked.
    func returnToOrigin() {
        guard let origin = nav.origin, let store else { return }
        let originChat = origin.chatID
        let chatExists = originChat.map { store.chatExists($0) } ?? false
        let anchorExists: Bool = {
            guard origin.place == .conversation, let originChat, let mid = origin.messageID else { return false }
            if case .message = store.jumpTarget(messageID: mid, chatID: originChat) { return true }
            return false
        }()
        switch nav.takeReturnPlan(chatExists: chatExists, anchorExists: anchorExists) {
        case .message(let cid, let mid, let mode):
            guard openChat(id: cid) else { flash("That conversation isn't in the archive any more."); return }
            chatMode = mode
            if mode == .messages {
                let page = (try? store.messages(chat: cid, around: mid)) ?? (rows: [], found: false)
                messages = page.rows
                focusMessage = page.found ? mid : nil
                canLoadOlder = page.rows.count >= 200
                revealTick += 1
            }
        case .date(let cid, let date, let mode):
            guard openChat(id: cid) else { flash("That conversation isn't in the archive any more."); return }
            chatMode = mode
            if mode == .messages { jump(toDate: date) }
            flash("That message is gone from the archive — you're back at the same point in the conversation.")
        case .search:
            pane = .search
        case .insights:
            section = .wrapped
            pane = .wrapped
        case .gone:
            flash("The conversation you came from isn't in the archive any more.")
        case .none:
            break
        }
    }
    func runSearch() {
        guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { if pane == .search { hits = [] }; return }
        do {
            hits = try store.search(query, chat: nil, sender: searchSender,
                                    from: searchFrom, to: searchTo, sort: searchSort)
            pane = .search; status = ""
        } catch { hits = []; status = "Search error: \(error)" }
    }
    func jump(to h: SearchHit) {
        guard let store else { return }
        if let row = chats.first(where: { $0.id == h.chatID }) ?? (try? store.chats(limit: 100000))?.first(where: { $0.id == h.chatID }) {
            let origin = currentOrigin()
            selected = row; pane = .chat
            chatMode = .messages
            messages = (try? store.messages(chat: h.chatID, from: h.ts.addingTimeInterval(-6 * 3600))) ?? []
            focusMessage = h.id; canLoadOlder = true
            revealTick += 1
            rememberJump(origin, to: h.chatID)
        }
    }

    enum NameSource: String, CaseIterable { case phone, mac, file, none }

    /// First-run: decrypt the backup, add it to the vault, gather contact names and build the library.
    func runSetup(backup: URL, key rawKey: String, remember: Bool, names: NameSource, vcf: URL?, vaultFolder: URL?) {
        let key = rawKey.filter { $0.isHexDigit }
        guard key.count == 64 else { status = "That key doesn't look right (needs 64 hex digits)."; return }
        if let vaultFolder { UserDefaults.standard.set(vaultFolder.path, forKey: "vaultPath") }
        busy = true; status = "Unlocking your backup…"
        if remember { Keychain.save(key) }
        guard let vault = prepareVault() else { busy = false; status = "Couldn't use that folder."; return }
        Task {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saga-setup-\(UUID().uuidString).db")
            defer { try? FileManager.default.removeItem(at: tmp) }       // the decrypted temp copy never stays on disk
            do {
                try await Task.detached {
                    let data = try Data(contentsOf: backup, options: .mappedIfSafe)
                    try Crypt15.decrypt(file: data, rootKeyHex: key).write(to: tmp)
                }.value
                status = "Adding your messages to the archive…"
                let label = Self.deviceLabel
                _ = try await Task.detached { try vault.ingest(msgstore: tmp.path, label: label) }.value
                var extra: [String: String] = [:]
                var vcfPath: String? = nil
                switch names {
                case .phone: status = "Reading names from your phone…"; extra = await Adb.phoneContacts()
                case .mac: status = "Reading your Mac contacts…"; extra = await MacContacts.load()
                case .file: vcfPath = vcf?.path
                case .none: break
                }
                status = "Building your library…"
                let out = indexURL
                let s = try await Task.detached { try VaultIndexer.build(vault: vault, out: out.path, vcfPath: vcfPath, extraContacts: extra) }.value
                status = "Done: \(s.messages.formatted()) messages from \(s.chats.formatted()) chats"
                open(path: out.path)
            } catch let e as Crypt15.Failure {
                status = "\(e)".contains("wrong key") ? "That key didn't unlock this backup. Double-check the 64 digits." : "Couldn't read the backup: \(e)"
            } catch { status = "Something went wrong: \(error)" }
            busy = false
        }
    }

    /// Add an already-decrypted msgstore.db (e.g. an older backup) to the vault and rebuild.
    func importDB(db: URL, vcf: URL?) {
        busy = true; status = "Importing…"
        guard let vault = prepareVault() else { busy = false; return }
        let label = Self.deviceLabel
        Task {
            do {
                let r = try await Task.detached { try vault.ingest(msgstore: db.path, label: label, fullSnapshot: false) }.value
                status = "Added \(r.added.formatted()) messages"
                rebuildLibrary(vcf: vcf?.path) { _ in }
            } catch { status = "Import failed: \(error)" }
            busy = false
        }
    }

    /// Switch to another archive folder. An existing vault there is opened; an empty folder receives a copy of the current vault.
    func moveVault(to folder: URL) {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: folder.appendingPathComponent("vault.json").path) {
                let current = Self.vaultURL
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for item in ["vault.json", "segments", "media", "config"] where fm.fileExists(atPath: current.appendingPathComponent(item).path) {
                    try fm.copyItem(at: current.appendingPathComponent(item), to: folder.appendingPathComponent(item))
                }
            }
            UserDefaults.standard.set(folder.path, forKey: "vaultPath")
            toast = "Archive location changed. Rebuilding…"
            rebuildLibrary { [self] s in toast = s.map { "Using \(folder.lastPathComponent): \($0.messages.formatted()) messages" }
                Task { try? await Task.sleep(for: .seconds(6)); toast = nil } }
        } catch { toast = "Couldn't use that folder: \(error)" }
    }
}
