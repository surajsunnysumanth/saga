import SwiftUI
import UniformTypeIdentifiers
import SagaCore

@MainActor @Observable
final class GroupModel {
    var wrapped: GroupWrapped?
    var loading = false
    var error = ""
    var task: Task<Void, Never>?

    /// Same idea as `DuoModel`: one build per chat state, reused when the sheet reopens.
    static var cache: [String: GroupWrapped] = [:]

    func build(chat: ChatRow, me: String, titles: Bool, model: AppModel) {
        guard model.store != nil else { return }
        let path = model.indexURL.path
        loading = true; error = ""; wrapped = nil
        task = Task {
            do {
                let store = try VaultStore(path: path)
                let key = DuoWrappedBuilder.cacheKey(store: store, chatID: chat.id) + (titles ? "-titles" : "-plain")
                if let hit = Self.cache[key] { wrapped = hit; loading = false; return }
                let w = try await GroupWrappedBuilder.build(store: store, chatID: chat.id, me: me, fetchTitles: titles)
                if w.total < 2 { error = "Not enough messages in this group for a Wrapped." }
                else { Self.cache[key] = w; wrapped = w }
            } catch { self.error = "Couldn't build it: \(error.localizedDescription)" }
            loading = false
        }
    }
}

struct GroupWrappedView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let chat: ChatRow
    @AppStorage("myDisplayName") private var myName = ""
    @AppStorage("wrappedTitles") private var titles = false
    /// Rendered inside the chat pane instead of a sheet: no Close button, builds on arrival.
    var embedded = false
    @State private var g = GroupModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let w = g.wrapped {
                GroupWrappedStory(w: w, onJump: { id in
                    // The jump leaves the story for the message and remembers the pane it left,
                    // so the return bar can offer the group's Heartbeat back; a sheet closes.
                    model.jump(toMessage: id, in: chat.id)
                    if !embedded { dismiss() }
                }, onExport: save, onSavePDF: savePDF)
            } else {
                setup
            }
        }
        .frame(minWidth: 560, idealWidth: 760, minHeight: 560, idealHeight: 900)
        .background(AppTheme.Surface.page)
        .onAppear {
            if myName.isEmpty { myName = defaultName }
            if embedded && g.wrapped == nil && !g.loading {
                g.build(chat: chat, me: myName.isEmpty ? defaultName : myName, titles: titles, model: model)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The chat header directly above this pane already names the conversation and the
            // hero beneath names it again. "Group Wrapped: <name>" was the third time.
            if !embedded {
                Label("Heartbeat", systemImage: "gift").font(.headline).lineLimit(1)
            }
            Spacer()
            if g.wrapped != nil {
                Menu {
                    Button { save() } label: { Label("Save as web page", systemImage: "square.and.arrow.down") }
                    Button { savePDF() } label: { Label("Save as PDF", systemImage: "doc.richtext") }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("The story lives in the app. Export a copy only when you want to share it.")
            }
            if !embedded { Button("Close") { dismiss() } }
        }
        .padding(12)
        .background(AppTheme.Surface.bar)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            HStack(spacing: AppTheme.Spacing.l) {
                ZStack {
                    AppTheme.Module.wrapped.gradient
                    Image(systemName: "person.3.fill").font(.system(size: 22)).foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .clipShape(AppTheme.Radius.iconShape)
                VStack(alignment: .leading, spacing: 3) {
                    Text("A look back at \(chat.name)").font(AppTheme.Typography.title)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                    Text("Who talks most, who gets the laughs, the jokes the group invented, and what everyone was sharing.")
                        .font(AppTheme.Typography.body).foregroundStyle(AppTheme.Surface.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                HStack {
                    Text("Your name in it").font(AppTheme.Typography.body).foregroundStyle(AppTheme.Surface.textPrimary)
                    TextField("e.g. Alex", text: $myName).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                Toggle("Look up song and video titles (asks Spotify/YouTube for a few links)", isOn: $titles)
                    .toggleStyle(.checkbox).font(AppTheme.Typography.callout)
            }
            HStack(spacing: 10) {
                Button(g.loading ? "Building…" : "Build group Wrapped") {
                    g.build(chat: chat, me: myName.isEmpty ? defaultName : myName, titles: titles, model: model)
                }
                .buttonStyle(.borderedProminent).disabled(g.loading)
                if g.loading { ProgressView().controlSize(.small) }
            }
            if !g.error.isEmpty { StatusBanner(level: .warning, message: g.error) }
            Text("The story quotes short messages from the group, and the exported page will too. Only share it with people who are in it.")
                .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textTertiary)
            Spacer()
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: 640, alignment: .leading)
    }

    var defaultName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me" }

    private func shareHTML() -> String? {
        g.wrapped.map { GroupWrappedHTML.render($0, interactive: false) }
    }

    func save() {
        guard let html = shareHTML() else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.html]; p.nameFieldStringValue = "\(chat.name) - Heartbeat.html"
        if p.runModal() == .OK, let u = p.url {
            try? html.write(to: u, atomically: true, encoding: .utf8)
            model.toast = "Saved. Open it in any browser."
            Task { try? await Task.sleep(for: .seconds(5)); model.toast = nil }
        }
    }

    func savePDF() {
        guard let html = shareHTML() else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = "\(chat.name) - Heartbeat.pdf"
        guard p.runModal() == .OK, let u = p.url else { return }
        PDFMaker.make(html: html, to: u) { ok in
            model.toast = ok ? "PDF saved." : "Couldn't make the PDF."
            Task { try? await Task.sleep(for: .seconds(5)); model.toast = nil }
        }
    }
}
