import SwiftUI
import SagaCore

@MainActor @Observable
final class PruneModel {
    var rules: [PruneRule] = []
    var suggestions: [ChatSpamStats] = []
    var chosen = Set<String>()                 // jids of suggestions ticked
    var scanning = false
    var applying = false
    var editor: PruneRule?                     // rule being edited for a single chat
    var editorStats: ChatSpamStats?
    var editorMembers: [String] = []           // every original JID of the (possibly merged) conversation
    var ruleRows: [PruneRule] = []             // one row per conversation for the list (a merged person appears once)
    var note = ""

    func load(model: AppModel, chat: ChatRow?) {
        guard let vault = model.prepareVault(), model.store != nil else { return }
        let path = model.indexURL.path
        rules = PruneConfig.load(vault)
        refreshRuleRows(model: model)
        scanning = true
        let id = chat?.id
        Task {
            let all = await Task.detached { (try? VaultStore(path: path)).flatMap { try? PruneScan.scan(store: $0) } ?? [] }.value
            let known = Set(rules.map(\.chat))
            suggestions = all.filter { $0.suggestion != nil && !known.contains($0.jid) }
            chosen = Set(suggestions.map(\.jid))
            if let id, let st = await Task.detached(operation: { (try? VaultStore(path: path)).flatMap { try? PruneScan.scan(store: $0, onlyChat: id).first } }).value {
                editorStats = st
                editorMembers = memberJIDs(st.jid, model: model)
                let byJID = Dictionary(rules.map { ($0.chat, $0) }, uniquingKeysWith: { _, last in last })
                editor = MergeIdentity.unionRule(jids: editorMembers, rules: byJID, label: st.name)
                    ?? PruneRule(chat: st.jid, label: st.name)
            }
            scanning = false
        }
    }

    /// A merged person is stored as one rule per original number. Every lookup/update below goes through all of
    /// them, so editing or restoring the merged conversation never leaves a stale secondary rule active.
    func memberJIDs(_ jid: String, model: AppModel) -> [String] {
        let jids = model.store?.mergedJIDs(chatJID: jid) ?? []
        return jids.isEmpty ? [jid] : jids
    }

    /// The list shows one row per conversation, with the rule the library actually applies. Without this a merged
    /// person's rule appears once per old number and Restore on one row silently removes the others too.
    func refreshRuleRows(model: AppModel) {
        guard !rules.isEmpty else { ruleRows = []; return }
        var members: [String: [String]] = [:]
        for r in rules { members[r.chat] = memberJIDs(r.chat, model: model) }
        ruleRows = MergeIdentity.effectiveRuleRows(rules, members: members)
    }

    func apply(model: AppModel, newRules: [PruneRule], done: @escaping () -> Void) {
        guard let vault = model.prepareVault() else { return }
        let expanded = newRules.flatMap { r in
            memberJIDs(r.chat, model: model).map { jid in var copy = r; copy.chat = jid; return copy }
        }
        let touched = Set(expanded.map(\.chat))
        applying = true; note = "Saving and rebuilding your library…"
        var merged = rules.filter { !touched.contains($0.chat) } + expanded
        merged = merged.filter { !$0.isEmpty }
        do { try PruneConfig.save(merged, to: vault) } catch { note = "Couldn't save: \(error)"; applying = false; return }
        rules = merged
        refreshRuleRows(model: model)
        model.rebuildLibrary { [self] s in
            applying = false
            refreshRuleRows(model: model)
            model.toast = s.map { "Done. \($0.prunedMessages.formatted()) messages hidden from view." } ?? "Couldn't rebuild"
            Task { try? await Task.sleep(for: .seconds(6)); model.toast = nil }
            done()
        }
    }
    func remove(_ r: PruneRule, model: AppModel, done: @escaping () -> Void) {
        guard let vault = model.prepareVault() else { return }
        let gone = Set(memberJIDs(r.chat, model: model))
        rules.removeAll { gone.contains($0.chat) }
        do { try PruneConfig.save(rules, to: vault) } catch { note = "Couldn't save: \(error)"; return }
        refreshRuleRows(model: model)
        applying = true; note = "Restoring those messages…"
        model.rebuildLibrary { [self] _ in applying = false; done() }
    }
}

struct PruneView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var chat: ChatRow? = nil
    @State private var p = PruneModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Clean up spam", systemImage: "wand.and.sparkles").font(.title2.bold())
            Text("Hide noisy messages without deleting them. Your rules are saved with your archive, so spam stays hidden after future updates. Remove a rule any time to bring the messages back.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let ed = p.editor, let st = p.editorStats { editor(ed, st) }
                    suggestionsSection
                    rulesSection
                }
            }
            if p.applying { HStack { ProgressView().controlSize(.small); Text(p.note) } }
            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding(22).frame(width: 640, height: 640)
        .task { p.load(model: model, chat: chat) }
    }

    func editor(_ ed: PruneRule, _ st: ChatSpamStats) -> some View {
        @Bindable var pm = p
        let r = Binding(get: { p.editor ?? ed }, set: { p.editor = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            Text("This chat: \(st.name)").font(.headline)
            Text("\(st.messages.formatted()) messages · you wrote \(st.mine.formatted()) · \(st.mediaPct)% media-only · \(st.linkPct)% link-only · \(st.repeatPct)% repeats")
                .font(.caption).foregroundStyle(.secondary)
            if p.editorMembers.count > 1 {
                Text("These \(p.editorMembers.count) numbers are merged into one person. The rule is saved for each of them, and Restore removes it from all of them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Hide the whole chat", isOn: r.hideChat)
            Toggle("Hide photos, videos and files (captions stay)", isOn: r.dropMedia).disabled(r.wrappedValue.hideChat)
            Toggle("Hide repeats of the same text or file", isOn: r.dropDuplicates).disabled(r.wrappedValue.hideChat)
            Toggle("Hide messages that are only a link", isOn: r.dropLinkOnly).disabled(r.wrappedValue.hideChat)
            HStack {
                Text("About \(st.estimate(r.wrappedValue).formatted()) messages would be hidden").foregroundStyle(.secondary)
                Spacer()
                Button("Save and hide") { p.apply(model: model, newRules: [r.wrappedValue]) { dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(r.wrappedValue.isEmpty || p.applying)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggestions").font(.headline)
            if p.scanning { HStack { ProgressView().controlSize(.small); Text("Looking at your groups…") } }
            else if p.suggestions.isEmpty { Text("No spam-like groups found. Groups you write in regularly are left alone.").foregroundStyle(.secondary) }
            ForEach(p.suggestions.prefix(30)) { c in
                if let r = c.suggestion {
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(get: { p.chosen.contains(c.jid) }, set: { on in if on { p.chosen.insert(c.jid) } else { p.chosen.remove(c.jid) } })).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).lineLimit(1)
                            Text("\(r.summary) · about \(c.estimate(r).formatted()) of \(c.messages.formatted()) messages · you wrote \(c.mine)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !p.suggestions.isEmpty {
                Button("Hide selected (\(p.chosen.count))") {
                    p.apply(model: model, newRules: p.suggestions.filter { p.chosen.contains($0.jid) }.compactMap(\.suggestion)) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(p.chosen.isEmpty || p.applying)
            }
        }
    }

    var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !p.ruleRows.isEmpty { Text("Your cleanup rules").font(.headline) }
            ForEach(p.ruleRows) { r in
                HStack {
                    VStack(alignment: .leading) { Text(r.label).lineLimit(1); Text(r.summary).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Restore") { p.remove(r, model: model) { } }.disabled(p.applying)
                }
            }
        }
    }
}
