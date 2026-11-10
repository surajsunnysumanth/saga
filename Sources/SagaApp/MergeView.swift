import SwiftUI
import SagaCore

@MainActor @Observable
final class MergeModel {
    var suggestions: [MergeSuggestion] = []
    var ignored: [IgnoredMergeSuggestion] = []
    var merges: [PersonMerge] = []
    var loading = false
    var applying = false
    var searchA = ""
    var searchB = ""
    var a: PersonRow?
    var b: PersonRow?

    func load(model: AppModel, preselect: PersonRow?) {
        guard let vault = model.prepareVault(), model.store != nil else { return }
        merges = MergeConfig.load(vault)
        if let preselect { a = preselect }
        reloadSuggestions(model: model, vault: vault)
    }

    /// Suggestions are read-only evidence: loading them never changes the archive, so ignoring or restoring one only
    /// needs a reload, not a library rebuild.
    func reloadSuggestions(model: AppModel, vault: Vault) {
        let path = model.indexURL.path
        loading = true
        Task {
            let report = await Task.detached { () -> MergeSuggestionReport in
                guard let store = try? VaultStore(path: path) else { return MergeSuggestionReport() }
                return (try? store.mergeSuggestionReport(vault: vault)) ?? MergeSuggestionReport()
            }.value
            suggestions = report.suggestions
            ignored = report.ignored
            loading = false
        }
    }

    func search(_ q: String, model: AppModel) -> [PersonRow] {
        guard q.count >= 2, let st = model.store else { return [] }
        return (try? st.people(matching: q, sort: .mostMessages, namedOnly: false, limit: 8)) ?? []
    }

    func ignore(_ s: MergeSuggestion, model: AppModel) {
        guard let vault = model.prepareVault() else { return }
        do { try MergeSuggestionIgnores.add(s.people.map(\.key), to: vault) }
        catch { model.toast = "Couldn't save: \(error.localizedDescription)"; return }
        reloadSuggestions(model: model, vault: vault)
    }

    func restore(_ i: IgnoredMergeSuggestion, model: AppModel) {
        guard let vault = model.prepareVault() else { return }
        do { try MergeSuggestionIgnores.remove(i.keys, from: vault) }
        catch { model.toast = "Couldn't save: \(error.localizedDescription)"; return }
        reloadSuggestions(model: model, vault: vault)
    }

    func apply(keys: [String], name: String, model: AppModel, done: @escaping () -> Void) {
        guard let vault = model.prepareVault() else { return }
        do { try MergeConfig.add(keys: keys, name: name, to: vault) } catch { model.toast = "Couldn't save: \(error)"; return }
        rebuild(model: model, vault: vault, done: done)
    }

    func unmerge(_ m: PersonMerge, model: AppModel) {
        guard let vault = model.prepareVault() else { return }
        do { try MergeConfig.remove(m, from: vault) } catch { model.toast = "Couldn't unmerge: \(error)"; return }
        rebuild(model: model, vault: vault) { }
    }

    func rebuild(model: AppModel, vault: Vault, done: @escaping () -> Void) {
        applying = true
        model.rebuildLibrary { [self] _ in
            applying = false; merges = MergeConfig.load(vault); a = nil; b = nil; searchA = ""; searchB = ""
            model.reloadPeople(); load(model: model, preselect: nil); done()
        }
    }
}

struct MergeView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var preselect: PersonRow? = nil
    @State private var m = MergeModel()
    @State private var nameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Merge contacts", systemImage: "person.2.badge.gearshape").font(.title2.bold())
            Text("For one person with several numbers. Their chats join into one conversation and their messages in groups count as one person. Nothing is deleted: Unmerge brings the old numbers back.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    manual
                    suggestions
                    ignoredSuggestions
                    existing
                }
            }
            if m.applying { HStack { ProgressView().controlSize(.small); Text("Rebuilding your library…") } }
            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding(22).frame(width: 620, height: 680)
        .task { m.load(model: model, preselect: preselect) }
    }

    func picker(_ title: String, text: Binding<String>, chosen: Binding<PersonRow?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let c = chosen.wrappedValue {
                HStack { Text(c.name).lineLimit(1); Text("\(c.received.formatted()) msgs").font(.caption).foregroundStyle(.secondary); Spacer()
                    Button { chosen.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            } else {
                TextField("Search by name or number", text: text).textFieldStyle(.roundedBorder)
                ForEach(m.search(text.wrappedValue, model: model)) { p in
                    Button { chosen.wrappedValue = p; text.wrappedValue = "" } label: {
                        HStack { Text(p.name).lineLimit(1); if !p.resolved { Text("(no name)").font(.caption).foregroundStyle(AppTheme.Feedback.warning) }; Spacer()
                            Text("\(p.received.formatted()) msgs · \(p.last.formatted(.dateTime.month(.abbreviated).year()))").font(.caption).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    var manual: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge two contacts yourself").font(.headline)
            Text("An old number you deleted shows up by its number. Search for the digits you remember.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                picker("Keep this person", text: $m.searchA, chosen: $m.a)
                picker("Merge this one into them", text: $m.searchB, chosen: $m.b)
            }
            if let a = m.a, let b = m.b, a.key != b.key {
                HStack {
                    Text("Show as").font(.caption)
                    TextField(a.resolved ? a.name : b.name, text: $nameText).textFieldStyle(.roundedBorder).frame(width: 220)
                    Spacer()
                    Button("Merge") {
                        let name = nameText.isEmpty ? (a.resolved ? a.name : (b.resolved ? b.name : a.name)) : nameText
                        m.apply(keys: [a.key, b.key], name: name, model: model) { nameText = "" }
                    }.buttonStyle(.borderedProminent).disabled(m.applying)
                }
            }
        }
    }

    var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested: possibly the same person").font(.headline)
            Text("Same saved name, the same WhatsApp profile name, numbers that end alike, or one chat going quiet as another starts. Nothing changes until you choose Merge.")
                .font(.caption).foregroundStyle(.secondary)
            if m.loading { ProgressView().controlSize(.small) }
            else if m.suggestions.isEmpty { Text("None found.").foregroundStyle(.secondary) }
            ForEach(m.suggestions.prefix(40)) { s in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(s.name).lineLimit(1)
                            confidenceBadge(s.confidence)
                        }
                        Text(s.people.map { "\($0.received.formatted()) msgs (\($0.first.formatted(.dateTime.year()))–\($0.last.formatted(.dateTime.year())))" }.joined(separator: "  ·  "))
                            .font(.caption).foregroundStyle(.secondary)
                        // A name alone is not enough to tell two accounts apart: two chats can both be
                        // "Amma" and be two different people. The number underneath is the tie-breaker.
                        ForEach(Array(s.people.enumerated()), id: \.offset) { _, person in
                            if let number = Self.phoneHint(person.key) {
                                Text(number)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .help("The number behind this entry")
                            }
                        }
                        ForEach(s.reasons, id: \.self) { reason in
                            Text(reason.explanation).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Merge") { m.apply(keys: s.people.map(\.key), name: s.name, model: model) { } }
                        .disabled(m.applying)
                    Button("Ignore") { m.ignore(s, model: model) }
                        .disabled(m.applying)
                }
            }
        }
    }


    /// Turns a stored person key into something a human can compare at a glance. Keys are JIDs, saved
    /// names or raw numbers depending on how the chat arrived, so anything that is not a phone number
    /// returns nil rather than printing an internal identifier at the user.
    static func phoneHint(_ key: String) -> String? {
        // Only a real number, never a name that happens to contain digits. A key is a JID, a saved
        // name or a raw number depending on how the chat arrived; guessing produced wrong numbers,
        // which is worse than showing none.
        let bare = key.split(separator: "@").first.map(String.init) ?? ""
        guard !bare.isEmpty, bare.allSatisfy(\.isNumber) else { return nil }
        let suffix = key.contains("@") ? key.split(separator: "@").last.map(String.init) ?? "" : ""
        guard suffix.isEmpty || suffix == "s.whatsapp.net" || suffix == "lid" else { return nil }
        guard bare.count >= 10, bare.count <= 15 else { return nil }
        if bare.count == 12, bare.hasPrefix("91") {
            let rest = bare.dropFirst(2)
            return "+91 \(rest.prefix(5)) \(rest.dropFirst(5))"
        }
        return "+" + bare
    }

    func confidenceBadge(_ c: MergeConfidence) -> some View {
        Text(c.label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(c == .high ? Color.green.opacity(0.2) : c == .medium ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15)))
    }

    @ViewBuilder var ignoredSuggestions: some View {
        if !m.ignored.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ignored suggestions").font(.headline)
                Text("Hidden here only. Nothing was merged or deleted.").font(.caption).foregroundStyle(.secondary)
                ForEach(m.ignored) { i in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.people.isEmpty ? "\(i.keys.count) numbers no longer in the library" : i.people.map(\.name).joined(separator: " · "))
                                .lineLimit(1)
                            if i.isNowMerged {
                                Text("These numbers are now merged into one person").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Show again") { m.restore(i, model: model) }.disabled(m.applying)
                    }
                }
            }
        }
    }

    var existing: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !m.merges.isEmpty { Text("Your merges").font(.headline) }
            ForEach(m.merges) { g in
                HStack {
                    VStack(alignment: .leading) { Text(g.name); Text("\(g.keys.count) numbers").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Unmerge") { m.unmerge(g, model: model) }.disabled(m.applying)
                }
            }
        }
    }
}
