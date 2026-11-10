import SwiftUI
import SagaCore

@MainActor @Observable
final class TopicsModel {
    let choice = AIChoice()
    var days = 30 { didSet { if days != oldValue { reload() } } }
    var points: [SummaryPoint] = []
    var stale = false
    var savedNote = ""
    var coverage = ""
    var running = false
    var partial = false
    var message = ""
    var done = 0
    var total = 0
    var merging = false
    var eligibleEmpty = false
    var cacheReady = false

    private var task: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var run = UUID()
    private var cache: AICache?
    private var chat: ChatRow?
    private weak var app: AppModel?

    var canGenerate: Bool { choice.selected != nil && !running && cacheReady }

    func attach(chat: ChatRow, app: AppModel) {
        guard self.chat == nil else { return }
        self.chat = chat; self.app = app
        cache = try? AICache(path: AppModel.supportDir.appendingPathComponent("ai_cache.db").path)
        cacheReady = cache != nil
        if !cacheReady { message = "Couldn't open the local AI cache. Check that your Saga folder is writable, then close and reopen this window." }
        choice.refresh()
        reload()
    }

    private struct Context: Sendable { let chat: ChatRow; let days: Int; let scope: String; let modelID: String; let indexPath: String; let indexStamp: String? }
    nonisolated private static func indexStamp(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let ino = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(ino)|\(size)|\(mtime)"
    }
    private func context() -> Context? {
        guard let chat, let app else { return nil }
        let path = app.indexURL.path
        return Context(chat: chat, days: days, scope: VaultStore.archiveScope(vaultURL: AppModel.vaultURL, indexPath: path), modelID: choice.selected?.id ?? choice.selectedID, indexPath: path, indexStamp: Self.indexStamp(path))
    }
    nonisolated private static func stampMatches(_ c: Context) -> Bool { indexStamp(c.indexPath) == c.indexStamp }
    nonisolated private static func period(_ c: Context) -> (Date, Date) { (c.chat.last.addingTimeInterval(-Double(c.days) * 86400), c.chat.last) }

    private func describe(_ r: TopicsRead) -> String {
        let n = r.readCount.formatted()
        return r.capped ? "Read the most recent \(n) of \(r.inPeriod.formatted()) messages in this period (the rest is skipped)." : "\(n) messages in this period."
    }

    /// Shows what is already saved for this chat/period/model. Never starts the model.
    func reload() {
        guard !running, let c = context() else { return }
        loadTask?.cancel()
        points = []; stale = false; savedNote = ""; message = ""; partial = false; eligibleEmpty = false
        let cache = cache
        loadTask = Task {
            let out = await Task.detached { () -> (TopicsRead, LocalAI.SavedTopics?)? in
                guard let st = try? VaultStore(path: c.indexPath) else { return nil }
                let (s, e) = Self.period(c)
                guard let read = try? st.topicsRead(chat: c.chat.id, start: s, end: e) else { return nil }
                let saved = LocalAI.savedTopics(rows: read.rows, chatID: c.chat.id, chatJID: c.chat.jid, archiveScope: c.scope, days: c.days, periodStart: s, periodEnd: e, modelID: c.modelID, cache: cache, store: st)
                return (read, saved)
            }.value
            guard !Task.isCancelled, !running, c.days == days, c.chat.id == chat?.id else { return }
            guard let (read, saved) = out else { message = "Couldn't read this chat. Rebuild your library and try again."; return }
            coverage = describe(read)
            eligibleEmpty = read.rows.isEmpty
            if let saved {
                points = saved.points; stale = !saved.isCurrent
                let when = saved.created.formatted(.relative(presentation: .named))
                savedNote = saved.isCurrent ? "Saved \(when) · up to date" : "Saved \(when) · this chat has changed since. Press Refresh to update."
            }
        }
    }

    func generate() {
        guard !running, let c = context(), let m = choice.selected else { return }
        guard let cache else { message = "Couldn't open the local AI cache. Check that your Saga folder is writable, then reopen this window."; return }
        running = true; points = []; message = ""; savedNote = ""; partial = true; stale = false; done = 0; total = 0; merging = false
        let id = UUID(); run = id
        task = Task {
            do {
                let result = try await Task.detached { () -> (TopicsRead, [SummaryPoint], Int)? in
                    guard let st = try? VaultStore(path: c.indexPath) else { return nil }
                    let (s, e) = Self.period(c)                         // period end is fixed by the chat's last message, captured now
                    let read = try st.topicsRead(chat: c.chat.id, start: s, end: e)
                    let skip = SkipBox()
                    let pts = try await LocalAI.topics(read.rows, chatID: c.chat.id, chatJID: c.chat.jid, chatName: c.chat.name, isGroup: c.chat.isGroup, archiveScope: c.scope,
                        days: c.days, periodStart: s, periodEnd: e, model: m, cache: cache,
                        onPartial: { p in Task { @MainActor in if self.run == id { self.points = p } } },
                        progress: { pr in skip.set(pr.skipped); Task { @MainActor in if self.run == id { self.done = pr.done; self.total = pr.total; self.merging = pr.merging } } })
                    let fresh = st.resolve(uids: pts.flatMap { $0.sources.map(\.uid) })
                    let resolved = pts.compactMap { p -> SummaryPoint? in
                        let src = p.sources.compactMap { r in fresh[r.uid].map { MessageRef(messageID: $0.id, chatID: $0.chatID, uid: r.uid) } }
                        return src.isEmpty ? nil : SummaryPoint(text: p.text, sources: src)
                    }
                    return (read, resolved, skip.value)
                }.value
                guard run == id else { return }
                guard Self.stampMatches(c) else { message = "Your library was rebuilt while this ran, so the result was discarded. Press Generate to run it again."; points = []; running = false; partial = false; return }
                guard let (read, pts, skipped) = result else { message = "Couldn't read this chat. Rebuild your library and try again."; running = false; partial = false; return }
                coverage = describe(read)
                points = pts; partial = skipped > 0
                if pts.isEmpty {
                    if read.rows.isEmpty { message = "No messages in this period." }
                    else if skipped > 0 { message = "No topics found, and \(skipped) part\(skipped == 1 ? "" : "s") couldn't be read. Press Generate to try again." }
                    else { message = "No clear topics found in this period." }
                } else if skipped > 0 { message = "\(skipped) part\(skipped == 1 ? "" : "s") couldn't be read, so this list is partial and wasn't saved. Press Generate to retry." }
                else { savedNote = "Saved just now" }
            } catch is CancellationError {
                guard run == id else { return }
                message = points.isEmpty ? "Stopped." : "Stopped early: this covers only part of the period and wasn't saved."
                partial = !points.isEmpty
            } catch {
                guard run == id else { return }
                message = "Couldn't find topics: \(error.localizedDescription) Try again or choose another model."
                partial = false
            }
            if run == id { running = false }
        }
    }

    func stop() { task?.cancel() }
    func close() { run = UUID(); task?.cancel(); loadTask?.cancel() }
}

private final class SkipBox: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    func set(_ n: Int) { lock.lock(); v = n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
}

/// Topics for one chat: pick a period, see a saved list at once, generate or refresh with a model on this Mac.
struct TopicsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let chat: ChatRow
    @State private var topics = TopicsModel()

    var body: some View {
        @Bindable var t = topics
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Topics in \(chat.name)").font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("Close") { topics.close(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Runs on this Mac. Nothing is sent anywhere.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Picker("Period", selection: $t.days) {
                    ForEach(LocalAI.topicsPeriods, id: \.self) { Text($0 == 365 ? "Last year" : "Last \($0) days").tag($0) }
                }.fixedSize().disabled(t.running)
                ModelPicker(ai: t.choice).disabled(t.running)
                Spacer()
                if t.running { Button("Stop") { topics.stop() } }
                else { Button(t.points.isEmpty || t.stale ? "Generate" : "Refresh") { topics.generate() }.buttonStyle(.borderedProminent).disabled(!t.canGenerate || t.eligibleEmpty) }
            }
            Text("Periods end at this chat's last archived message.").font(.caption).foregroundStyle(.secondary)
            if !t.coverage.isEmpty { Text(t.coverage).font(.caption).foregroundStyle(.secondary) }
            if t.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t.merging ? "Combining topics…" : t.total > 0 ? "Reading part \(t.done) of \(t.total)…" : "Starting…").foregroundStyle(.secondary)
                }
            }
            if t.partial && !t.points.isEmpty { Label("Partial: topics so far", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppTheme.Feedback.warning) }
            if !t.savedNote.isEmpty { Text(t.savedNote).font(.caption).foregroundStyle(t.stale ? AppTheme.Feedback.warning : AppTheme.Surface.textSecondary) }
            if t.choice.selected == nil && !t.choice.detecting {
                NoModelNotice(ai: t.choice)
                if !t.points.isEmpty { Text("Showing what was saved earlier.").font(.caption).foregroundStyle(.secondary) }
            }
            if !t.message.isEmpty { Text(t.message).foregroundStyle(.secondary) }
            if t.points.isEmpty, !t.running, t.message.isEmpty {
                Text(t.eligibleEmpty ? "No messages in this period." : "No topics saved for this period yet. Press Generate.").foregroundStyle(.secondary)
            }
            PointsList(points: t.points, onJump: { topics.close(); dismiss() })
            Spacer(minLength: 0)
        }
        .padding(20).frame(minWidth: 520, minHeight: 420)
        .onAppear { topics.attach(chat: chat, app: model) }
        .onChange(of: topics.choice.selectedID) { _, _ in topics.reload() }
    }
}
