import SwiftUI
import SagaCore

/// Which model to use, shared by Catch me up and Ask. Detects Apple Intelligence, Ollama and LM Studio on this Mac.
@MainActor @Observable
final class AIChoice {
    var models: [AIModel] = []
    var hints: [String] = []
    var selectedID: String { didSet { UserDefaults.standard.set(selectedID, forKey: "aiModel") } }
    var detecting = false
    init() { selectedID = UserDefaults.standard.string(forKey: "aiModel") ?? "apple" }
    var selected: AIModel? { models.first { $0.id == selectedID } ?? models.first }

    func refresh() {
        detecting = true
        Task {
            let d = await LocalAI.detect()
            models = d.models; hints = d.hints
            if !models.contains(where: { $0.id == selectedID }), let f = models.first { selectedID = f.id }
            detecting = false
        }
    }
}

struct ModelPicker: View {
    @Bindable var ai: AIChoice
    var body: some View {
        HStack(spacing: 8) {
            if ai.models.isEmpty {
                if ai.detecting { ProgressView().controlSize(.small); Text("Looking for AI models…").foregroundStyle(.secondary) }
            } else {
                Picker("Model", selection: $ai.selectedID) {
                    ForEach(ai.models) { m in Text("\(m.name) · \(m.detail)").tag(m.id) }
                }.labelsHidden().fixedSize()
            }
            Button { ai.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Look for models again")
        }
    }
}

/// Inline notice for a panel that has no model to talk to. Stays text-only so it
/// can sit mid-panel (Topics); the full "nothing works yet" surface is the
/// illustrated state in `AIPanelView`.
struct NoModelNotice: View {
    let ai: AIChoice
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("No AI model found on this Mac.")
                .font(AppTheme.Typography.section)
                .foregroundStyle(AppTheme.Surface.textPrimary)
            ForEach(ai.hints, id: \.self) { hint in
                Text("• \(hint)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Saga works with Apple Intelligence (macOS 26+), Ollama and LM Studio. Everything stays on this Mac.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Points with an arrow that jumps to the messages behind each one.
struct PointsList: View {
    @Environment(AppModel.self) var model
    let points: [SummaryPoint]
    var onJump: () -> Void = {}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(points) { p in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                        Text(p.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if !p.sources.isEmpty {
                            Menu {
                                ForEach(Array(p.sources.enumerated()), id: \.offset) { i, r in
                                    Button("Message \(i + 1)") { model.jump(toMessage: r.messageID, in: r.chatID); onJump() }
                                }
                            } label: { Image(systemName: "arrow.turn.down.right") }
                            .menuStyle(.borderlessButton).fixedSize().help("Jump to the messages behind this point")
                        }
                    }
                }
            }
        }
    }
}


// MARK: - The AI side panel (stays open while you jump around the chat)

@MainActor @Observable
final class AIPanel {
    enum Mode: String, CaseIterable { case summary = "Catch me up", ask = "Ask", media = "Music & video" }
    var open = false
    var mode: Mode = .summary
    let choice = AIChoice()
    var cache: AICache?

    // meaning search: Ask's optional second retriever, off until the person turns it on
    var semanticOn: Bool { didSet { UserDefaults.standard.set(semanticOn, forKey: "semanticSearchOn") } }
    var semanticDetecting = false
    var semanticProviders: [SemanticProvider] = []
    var semanticChoiceTag: String { didSet { UserDefaults.standard.set(semanticChoiceTag, forKey: "semanticEmbeddingChoice") } }
    var semanticCoverage: SemanticCoverage?
    var semanticBuilding = false
    var semanticBuildProgress: SemanticIndexProgress?
    var semanticMessage = ""
    @ObservationIgnored var semanticStore: SemanticStore?
    @ObservationIgnored var semanticTask: Task<Void, Never>?
    @ObservationIgnored var semanticRun = UUID()

    init() {
        let d = UserDefaults.standard
        semanticOn = d.bool(forKey: "semanticSearchOn")
        semanticChoiceTag = d.string(forKey: "semanticEmbeddingChoice") ?? SemanticEmbeddingChoice.apple.tag
    }

    // summary
    var chat: ChatRow?
    var days = 30
    var detail: LocalAI.Detail = .quick
    var running = false
    var points: [SummaryPoint] = []
    var isPartial = false
    var message = ""
    var savedNote = ""
    var planNote = ""
    var done = 0
    var total = 0
    var fromCache = 0
    var merging = false
    var startedAt: Date?
    var task: Task<Void, Never>?
    var hasSaved = false

    // ask
    var question = ""
    var thisChatOnly = false
    var askRunning = false
    var askPoints: [SummaryPoint] = []
    var searched = 0
    var askMessage = ""
    var askProgress = ""
    var askRetrieval: LocalAI.AskRetrieval?
    var askTask: Task<Void, Never>?

    nonisolated static let maxMessages = 12000

    func ensureCache(_ model: AppModel) -> AICache? {
        if cache == nil { cache = try? AICache(path: AppModel.supportDir.appendingPathComponent("ai_cache.db").path) }
        return cache
    }
    func openSummary(chat c: ChatRow, model: AppModel) {
        open = true; mode = .summary; choice.refresh()
        if chat?.id != c.id || chat?.jid != c.jid { chat = c; points = []; message = ""; isPartial = false; if !running { loadSaved(model) } }
        else if points.isEmpty { loadSaved(model) }
    }
    func openMedia(chat: ChatRow?, model: AppModel) { open = true; mode = .media; model.media.open(chat: chat, model: model) }
    func openAsk(model: AppModel) {
        open = true; mode = .ask; choice.refresh()
        // One door: the pill asks the conversation you are reading, and the panel's scope chip
        // is how you widen it. Nothing else in the app opens a second, differently-scoped Ask.
        thisChatOnly = model.selected != nil
        if semanticOn { refreshSemantic(model: model) }
    }

    // MARK: meaning search (local, opt-in)

    var semanticProvider: SemanticProvider? {
        semanticProviders.first { $0.choice.tag == semanticChoiceTag } ?? semanticProviders.first
    }
    private func semanticScope(_ model: AppModel) -> String {
        VaultStore.archiveScope(vaultURL: AppModel.vaultURL, indexPath: model.indexURL.path)
    }
    private func ensureSemanticStore() -> SemanticStore? {
        if let semanticStore { return semanticStore }
        semanticStore = try? SemanticStore(path: AppModel.supportDir.appendingPathComponent("semantic_cache.db").path)
        return semanticStore
    }

    /// Finds the embedding models installed on this Mac and how much of the archive the chosen one already covers.
    func refreshSemantic(model: AppModel) {
        guard semanticOn, !semanticBuilding else { return }
        semanticDetecting = true; semanticMessage = ""
        let path = model.indexURL.path, scope = semanticScope(model)
        guard let store = ensureSemanticStore() else {
            semanticDetecting = false
            semanticMessage = "Couldn't open the local index. Check that your Saga folder is writable, then try again."
            return
        }
        Task {
            let providers = await SemanticSearch.providers()
            semanticProviders = providers
            semanticDetecting = false
            guard semanticOn else { return }
            guard !providers.isEmpty else { semanticCoverage = nil; return }
            if !providers.contains(where: { $0.choice.tag == semanticChoiceTag }), let first = providers.first {
                semanticChoiceTag = first.choice.tag
            }
            guard let provider = semanticProvider else { return }
            let coverage = await Task.detached { () -> SemanticCoverage? in
                try? SemanticSearch(indexPath: path, archiveScope: scope, store: store, provider: provider).coverage()
            }.value
            guard semanticOn, !semanticBuilding, provider.choice.tag == semanticChoiceTag else { return }
            semanticCoverage = coverage
            if coverage == nil { semanticMessage = "Couldn't read the local index. Rebuild your library, then try again." }
        }
    }

    /// Recomputes coverage only (no provider probe), after a build or an embedding-model change.
    func refreshSemanticCoverage(_ model: AppModel) {
        guard semanticOn, !semanticBuilding, let store = ensureSemanticStore(), let provider = semanticProvider else { return }
        let path = model.indexURL.path, scope = semanticScope(model)
        Task {
            let coverage = await Task.detached { () -> SemanticCoverage? in
                try? SemanticSearch(indexPath: path, archiveScope: scope, store: store, provider: provider).coverage()
            }.value
            guard semanticOn, !semanticBuilding, provider.choice.tag == semanticChoiceTag else { return }
            semanticCoverage = coverage
        }
    }

    func semanticToggled(_ on: Bool, model: AppModel) {
        if on { refreshSemantic(model: model) }
        else { stopSemanticBuild(); semanticCoverage = nil; semanticMessage = "" }
    }

    func semanticProviderChanged(model: AppModel) {
        semanticCoverage = nil
        refreshSemanticCoverage(model)
    }

    /// The search object Ask may use: only when the person opted in and the index matches the current archive.
    func semanticSearch(model: AppModel) -> SemanticSearch? {
        guard semanticOn, let coverage = semanticCoverage, case .current = coverage,
              let store = ensureSemanticStore(), let provider = semanticProvider else { return nil }
        return SemanticSearch(indexPath: model.indexURL.path, archiveScope: semanticScope(model), store: store, provider: provider)
    }

    func buildSemanticIndex(model: AppModel) {
        guard !semanticBuilding, let provider = semanticProvider else { return }
        guard let store = ensureSemanticStore() else {
            semanticMessage = "Couldn't open the local index. Check that your Saga folder is writable, then try again."
            return
        }
        let path = model.indexURL.path, scope = semanticScope(model)
        let search = SemanticSearch(indexPath: path, archiveScope: scope, store: store, provider: provider)
        let stamp = SemanticSearch.indexStamp(path)
        let run = UUID(); semanticRun = run
        semanticBuilding = true; semanticBuildProgress = nil; semanticMessage = ""; semanticCoverage = nil
        semanticTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let summary = try await search.build(progress: { p in
                    Task { @MainActor in
                        guard let self, self.semanticRun == run else { return }
                        self.semanticBuildProgress = p
                    }
                })
                await MainActor.run { self?.finishSemanticBuild(run: run, outcome: .success(summary), stamp: stamp, path: path, model: model) }
            } catch {
                await MainActor.run { self?.finishSemanticBuild(run: run, outcome: .failure(error), stamp: stamp, path: path, model: model) }
            }
        }
    }

    func stopSemanticBuild() {
        semanticTask?.cancel()
    }

    private func finishSemanticBuild(run: UUID, outcome: Result<SemanticIndexSummary, Error>, stamp: String?, path: String, model: AppModel) {
        guard semanticRun == run else { return }
        semanticBuilding = false
        switch outcome {
        case .success(let s):
            if SemanticSearch.indexStamp(path) != stamp {
                semanticMessage = "Your library was rebuilt while the index was being built, so this run was discarded. Press Build index to run it again on the new data."
            } else if s.total == 0 {
                semanticMessage = "There are no text messages to index yet."
            } else if s.skipped > 0 {
                semanticMessage = "Indexed \(s.embedded.formatted()) messages. \(s.skipped.formatted()) couldn't be embedded and were skipped."
            } else if s.embedded == 0 {
                semanticMessage = "Already up to date · \(s.reused.formatted()) messages indexed."
            } else {
                semanticMessage = "Indexed \(s.total.formatted()) messages."
            }
        case .failure(let e):
            if e is CancellationError {
                semanticMessage = "Stopped. Finished messages are kept; press Continue to resume."
            } else {
                semanticMessage = "Couldn't build the meaning index: \(e.localizedDescription)"
            }
        }
        refreshSemanticCoverage(model)
    }

    func ask(model: AppModel) {
        guard let store = model.store, let m = choice.selected, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        askRunning = true; askPoints = []; askMessage = ""; askProgress = "Searching…"; askRetrieval = nil
        let q = question, scope = thisChatOnly ? model.selected?.id : nil
        let semantic = semanticSearch(model: model)
        askTask = Task {
            do {
                let r = try await LocalAI.askResult(q, store: store, chat: scope, model: m, semantic: semantic, progress: { s in Task { @MainActor in self.askProgress = s } })
                askPoints = r.points; searched = r.searched; askRetrieval = r.retrieval
                if r.searched == 0 {
                    askMessage = semantic == nil
                        ? "No messages matched those words. Try different or fewer keywords."
                        : "Nothing in your archive matched those words or that meaning. Try different words."
                }
            } catch is CancellationError { askMessage = "Stopped." } catch { askMessage = "Couldn't answer: \(error.localizedDescription)" }
            askRunning = false
        }
    }
    func cacheKeys(_ model: AppModel) -> SummaryCacheKeys? {
        guard let c = chat, let m = choice.selected else { return nil }
        let jids = model.store?.mergedJIDs(chatJID: c.jid) ?? (c.jid.isEmpty ? [] : [c.jid])
        return SummaryCacheKeys.make(chatJIDs: jids, days: days, modelID: m.id, detail: detail.rawValue)
    }

    /// Shows a previously finished summary for this chat/period/model, if there is one, and estimates a fresh run.
    func loadSaved(_ model: AppModel) {
        guard !running, let c = chat, let store = model.store, let keys = cacheKeys(model), let cache = ensureCache(model) else { return }
        points = []; message = ""; savedNote = ""; hasSaved = false; isPartial = false
        if let hit = cache.latestSummary(keys: keys.readKeys) {
            let s = hit.summary
            let map = store.resolve(uids: s.points.flatMap(\.uids))
            points = s.points.map { sp in SummaryPoint(text: sp.text, sources: sp.uids.compactMap { u in map[u].map { MessageRef(messageID: $0.id, chatID: $0.chatID, uid: u) } }) }
            let newer = store.countMessages(chat: c.id, after: s.lastTS)
            let when = s.created.formatted(.relative(presentation: .named))
            let origin = keys.isMergedSummary(hit.key) ? "Saved summary for this merged conversation from \(when)"
                : keys.isOwnSummary(hit.key, chatJID: c.jid) ? "Saved summary from \(when)"
                : "Saved summary for one of their earlier numbers from \(when)"
            savedNote = origin + (newer > 0 ? " · \(newer.formatted()) newer messages since" : " · up to date")
            hasSaved = true
        }
        planNote = ""
        guard let m = choice.selected else { return }
        let path = model.indexURL.path, chatCopy = c, days = days, detail = detail
        Task {
            let info = await Task.detached { () -> (Int, Int, Int)? in
                guard let st = try? VaultStore(path: path) else { return nil }
                let from = chatCopy.last.addingTimeInterval(-Double(days) * 86400)
                guard let rows = try? st.messages(chat: chatCopy.id, from: from, filter: .all, limit: AIPanel.maxMessages) else { return nil }
                let p = LocalAI.plan(rows, chatID: chatCopy.id, chatName: chatCopy.name, isGroup: chatCopy.isGroup, model: m, detail: detail, cache: cache)
                return (p.parts, p.cached, rows.count)
            }.value
            guard let (parts, cached, n) = info, !running, chat?.id == chatCopy.id, self.days == days, self.detail == detail else { return }
            let per = UserDefaults.standard.double(forKey: "aiPartSeconds.\(m.id)")
            let remaining = parts - cached
            var t = "\(n.formatted()) messages · \(parts) part\(parts == 1 ? "" : "s")" + (cached > 0 ? " (\(cached) already saved)" : "")
            if remaining > 0, per > 0 { t += " · about \(Self.duration(Double(remaining) * per))" }
            else if remaining > 0 { t += " · speed unknown until the first run" }
            if n >= AIPanel.maxMessages { t += " · using the most recent \(AIPanel.maxMessages.formatted())" }
            planNote = t
        }
    }
    static func duration(_ s: Double) -> String { s < 90 ? "\(Int(s.rounded())) seconds" : "\(Int((s / 60).rounded())) minutes" }

    func summarize(model: AppModel) {
        guard let store = model.store, let c = chat, let m = choice.selected, let cache = ensureCache(model),
              let keys = cacheKeys(model) else { return }
        running = true; points = []; message = ""; savedNote = ""; isPartial = true; hasSaved = false
        done = 0; total = 0; fromCache = 0; merging = false; startedAt = Date()
        let days = days, key = keys.writeKey, detail = detail
        task = Task {
            do {
                let from = c.last.addingTimeInterval(-Double(days) * 86400)
                let rows = try store.messages(chat: c.id, from: from, filter: .all, limit: Self.maxMessages)
                let t0 = Date()
                let pts = try await LocalAI.summarize(rows, chatID: c.id, chatName: c.name, isGroup: c.isGroup, model: m, detail: detail, cache: cache, cacheKey: key,
                    onPartial: { p in Task { @MainActor in self.points = p } },
                    progress: { pr in Task { @MainActor in self.done = pr.done; self.total = pr.total; self.fromCache = pr.fromCache; self.merging = pr.merging } })
                points = pts; isPartial = false
                if pts.isEmpty { message = "No text messages in this period." }
                let fresh = max(1, total - fromCache)
                if fromCache < total { UserDefaults.standard.set(Date().timeIntervalSince(t0) / Double(fresh), forKey: "aiPartSeconds.\(m.id)") }
                hasSaved = !pts.isEmpty; savedNote = pts.isEmpty ? "" : "Saved just now"
            } catch is CancellationError {
                message = points.isEmpty ? "Stopped." : "Stopped early: this covers the \(done) newest of \(total) parts. Press Continue to pick up where it left off."
            } catch { message = "Couldn't summarize: \(error.localizedDescription)" }
            running = false
        }
    }
    func stop() { task?.cancel(); askTask?.cancel() }

    var eta: String? {
        guard running, !merging, let t0 = startedAt, total > 0 else { return nil }
        let fresh = done - fromCache
        guard fresh >= 1 else { return nil }
        let per = Date().timeIntervalSince(t0) / Double(fresh + 0)
        let left = Double(total - done) * per
        return left > 5 ? "about \(Self.duration(left)) left" : nil
    }

}

struct AIPanelView: View {
    @Environment(AppModel.self) var model
    /// In the inspector the panel can be closed; inside a chat tab it is the pane itself.
    var showsClose = true
    var body: some View {
        @Bindable var p = model.aiPanel
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Inline in a chat, the Media tab owns music and video, so the panel keeps the two AI modes.
                Picker("", selection: $p.mode) {
                    ForEach(showsClose ? AIPanel.Mode.allCases : AIPanel.Mode.allCases.filter { $0 != .media }, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                if showsClose {
                    Button { p.open = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close (your results are kept)")
                }
            }
            if p.mode == .media { MediaPanelView() }
            else if p.choice.models.isEmpty && !p.choice.detecting {
                EmptyStateView(
                    symbol: "sparkles",
                    title: "No AI model on this Mac yet",
                    message: p.choice.hints.isEmpty
                        ? "Saga uses Apple Intelligence, Ollama or LM Studio, and runs whichever you have here. Nothing is sent anywhere."
                        : p.choice.hints.joined(separator: " ") + " Everything stays on this Mac.",
                    colors: AppTheme.Module.chats.colors,
                    actionTitle: "Check again",
                    action: { p.choice.refresh() })
            }
            else {
                ModelPicker(ai: p.choice).disabled(p.running || p.askRunning)
                    .onChange(of: p.choice.selectedID) { _, _ in if p.mode == .summary { p.loadSaved(model) } }
                if p.mode == .summary { summary(p) } else { ask(p) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        // Ask is one door now, so someone who opens it to ask and switches to Catch me up
        // should not be told to open a chat they already have open.
        .onChange(of: p.mode) { _, mode in
            if mode == .summary, p.chat == nil, let sel = model.selected { p.openSummary(chat: sel, model: model) }
        }
    }

    @ViewBuilder func summary(_ p: AIPanel) -> some View {
        @Bindable var p = p
        if let c = p.chat {
            Text(c.name).font(.headline).lineLimit(1)
            if let sel = model.selected, sel.id != c.id {
                Button("Summarize \"\(sel.name)\" instead") { p.openSummary(chat: sel, model: model) }.buttonStyle(.link)
            }
            HStack {
                Picker("Period", selection: $p.days) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                }.labelsHidden().fixedSize().disabled(p.running)
                    .onChange(of: p.days) { _, _ in p.loadSaved(model) }
                Picker("Detail", selection: $p.detail) { ForEach(LocalAI.Detail.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize().disabled(p.running).help("Quick samples long periods so it finishes sooner")
                    .onChange(of: p.detail) { _, _ in p.loadSaved(model) }
                Spacer()
                if p.running { Button("Stop") { p.stop() } }
                else { Button(p.hasSaved ? "Regenerate" : (p.isPartial && !p.points.isEmpty ? "Continue" : "Summarize")) { p.summarize(model: model) }.buttonStyle(.borderedProminent).disabled(p.choice.selected == nil) }
            }
            if !p.savedNote.isEmpty { Text(p.savedNote).font(.caption).foregroundStyle(.secondary) }
            if !p.running, !p.planNote.isEmpty { Text(p.planNote).font(.caption).foregroundStyle(.secondary) }
            if p.running {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Text(p.merging ? "Combining notes…" : "Part \(p.done) of \(max(p.total, 1))" + (p.fromCache > 0 ? " (\(p.fromCache) from saved)" : "") + (p.eta.map { " · \($0)" } ?? "") + " · newest first")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !p.message.isEmpty { StatusBanner(level: p.message.hasPrefix("Couldn't") ? .error : .warning, message: p.message) }
            if !p.points.isEmpty {
                PointsList(points: p.points)
                if p.points.contains(where: \.unstructured) {
                    Text("Part of this came back as plain text, so citations may be missing. Run it again for sources.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Jump arrows keep this panel open. Summaries can miss things; check the sources.").font(.caption2).foregroundStyle(.secondary)
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.points.map { "• " + $0.text }.joined(separator: "\n"), forType: .string) }.buttonStyle(.link)
            }
        } else {
            EmptyStateView(
                symbol: "bubble.left.and.bubble.right",
                title: "Open a chat first",
                message: "Pick a conversation, then choose Catch me up here to summarize it.",
                colors: AppTheme.Module.chats.colors,
                compact: true)
        }
    }

    @ViewBuilder func ask(_ p: AIPanel) -> some View {
        @Bindable var p = p
        TextField("e.g. When did we plan the Goa trip?", text: $p.question).textFieldStyle(.roundedBorder).onSubmit { p.ask(model: model) }
        HStack(spacing: AppTheme.Spacing.xs) {
            scopeChip(p)
            Spacer(minLength: AppTheme.Spacing.xxs)
            if p.askRunning { Button("Stop") { p.stop() } }
            else { Button("Ask") { p.ask(model: model) }.buttonStyle(.borderedProminent)
                .disabled(p.question.trimmingCharacters(in: .whitespaces).isEmpty || p.choice.selected == nil)
                .fixedSize() }
        }
        SemanticSearchControls(panel: p)
        Text(p.semanticOn
             ? "Answers from messages found by keyword and, when the local index is ready, by meaning. Everything stays on this Mac."
             : "Finds messages with your keywords, then the model answers from them. Use words people would have typed.").font(.caption).foregroundStyle(.secondary)
        if p.askRunning { HStack { ProgressView().controlSize(.small); Text(p.askProgress).font(.caption) } }
        if !p.askMessage.isEmpty { StatusBanner(level: p.askMessage.hasPrefix("Couldn't") ? .error : .warning, message: p.askMessage) }
        if !p.askPoints.isEmpty {
            PointsList(points: p.askPoints)
            if p.askPoints.contains(where: \.unstructured) {
                Text("The model answered as plain text, so these points may not cite the messages they came from.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if case .keywordFallback(let message)? = p.askRetrieval {
                StatusBanner(level: .warning, message: message)
            }
            Text(foundLine(p)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// One visible scope, in the row the question is typed in. It reads what Ask will search,
    /// and it is the only way to change it — the old checkbox said the same thing in words
    /// that looked like a filter for the search above it.
    @ViewBuilder private func scopeChip(_ p: AIPanel) -> some View {
        if let c = model.selected {
            let scoped = p.thisChatOnly
            Button { p.thisChatOnly.toggle() } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: scoped ? "bubble.left" : "square.stack.3d.up")
                        .font(.system(size: 10, weight: .semibold))
                    Text(scoped ? "Only in \(c.name)" : "Every conversation")
                        .lineLimit(1).truncationMode(.middle)
                    if scoped { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, AppTheme.Spacing.s)
                .padding(.vertical, 3)
                .foregroundStyle(scoped ? AppTheme.Accent.text : AppTheme.Surface.textSecondary)
                .background(Capsule().fill(scoped ? AppTheme.Accent.tint.opacity(0.55) : Color.clear))
                .overlay(Capsule().strokeBorder(scoped ? AppTheme.Accent.text.opacity(0.22) : AppTheme.Surface.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(scoped ? "Ask across every conversation instead" : "Ask only in \(c.name)")
        } else {
            Text("Every conversation")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Surface.textSecondary)
        }
    }

    private func foundLine(_ p: AIPanel) -> String {
        if case .hybrid? = p.askRetrieval {
            return "Based on \(p.searched) messages, found by keyword and meaning. Check sources with the arrows."
        }
        return "Based on \(p.searched) messages found by keyword. Check sources with the arrows."
    }
}
