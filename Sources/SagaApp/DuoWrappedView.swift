import SwiftUI
import WebKit
import UniformTypeIdentifiers
import SagaCore

@MainActor @Observable
final class DuoModel {
    var wrapped: DuoWrapped?
    var loading = false
    var error = ""
    var task: Task<Void, Never>?

    /// Built stories survive closing and reopening the sheet. The key is the chat plus its
    /// newest message key, so the expensive pass (distinctive-phrase scan, link lookups) runs
    /// once per import and a fresh message invalidates it.
    static var cache: [String: DuoWrapped] = [:]

    func build(chat: ChatRow, me: String, titles: Bool, model: AppModel) {
        guard model.store != nil else { return }
        let path = model.indexURL.path
        loading = true; error = ""; wrapped = nil
        task = Task {
            do {
                let store = try VaultStore(path: path)
                let key = DuoWrappedBuilder.cacheKey(store: store, chatID: chat.id) + (titles ? "-titles" : "-plain")
                if let hit = Self.cache[key] { wrapped = hit; loading = false; return }
                let w = try await DuoWrappedBuilder.build(store: store, chatID: chat.id, me: me, fetchTitles: titles)
                if w.total < 2 { error = "Not enough messages in this chat for a Heartbeat." }
                else { Self.cache[key] = w; wrapped = w }
            } catch { self.error = "Couldn't build it: \(error.localizedDescription)" }
            loading = false
        }
    }
}

struct DuoWrappedView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let chat: ChatRow
    @AppStorage("myDisplayName") private var myName = ""
    @AppStorage("wrappedTitles") private var titles = false
    /// Rendered inside the chat pane instead of a sheet: no Close button, builds on arrival.
    var embedded = false
    @State private var d = DuoModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let w = d.wrapped {
                DuoWrappedStory(w: w, onJump: { id in
                    // Leaving the story for the message: the jump takes the pane back to Messages
                    // (a sheet also closes), and it remembers the Heartbeat pane so the return
                    // bar can offer it back.
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
            if embedded && d.wrapped == nil && !d.loading {
                d.build(chat: chat, me: myName.isEmpty ? defaultName : myName, titles: titles, model: model)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The chat header above already names the conversation and the hero names it
            // again, so this row is a control strip, not a second title.
            if !embedded { Label("Heartbeat", systemImage: "gift").font(.headline).lineLimit(1) }
            Spacer()
            if d.wrapped != nil {
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
                    Image(systemName: "gift.fill").font(.system(size: 24)).foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .clipShape(AppTheme.Radius.iconShape)
                VStack(alignment: .leading, spacing: 3) {
                    Text("A look back at \(chat.name)").font(AppTheme.Typography.title)
                        .foregroundStyle(AppTheme.Surface.textPrimary)
                    Text("Who carries the conversation, what made you laugh, the songs you swapped, and the phrases only the two of you use.")
                        .font(AppTheme.Typography.body).foregroundStyle(AppTheme.Surface.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                HStack {
                    Text("Your name in it").font(AppTheme.Typography.body).foregroundStyle(AppTheme.Surface.textPrimary)
                    TextField("e.g. Alex", text: $myName).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                Toggle("Look up song and video titles (asks Spotify/YouTube for ~12 links)", isOn: $titles)
                    .toggleStyle(.checkbox).font(AppTheme.Typography.callout)
                Text("Real titles and artwork make the soundtrack cards worth reading. Nothing is sent unless you turn this on.")
                    .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
            }
            HStack(spacing: 10) {
                Button(d.loading ? "Building…" : "Build our Heartbeat") {
                    d.build(chat: chat, me: myName.isEmpty ? defaultName : myName, titles: titles, model: model)
                }
                .buttonStyle(.borderedProminent).disabled(d.loading)
                if d.loading { ProgressView().controlSize(.small) }
            }
            if !d.error.isEmpty { StatusBanner(level: .warning, message: d.error) }
            Text("The story quotes short bits of your chat, and the exported page will too. Only share it with \(chat.name) or someone you are happy to show them to.")
                .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textTertiary)
            Spacer()
        }
        .padding(AppTheme.Spacing.xxl)
        .frame(maxWidth: 640, alignment: .leading)
    }

    var defaultName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me" }

    private func shareHTML() -> String? {
        d.wrapped.map { DuoWrappedHTML.render($0, interactive: false) }
    }

    func save() {
        guard let html = shareHTML() else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.html]; p.nameFieldStringValue = "\(myName) and \(chat.name) - Heartbeat.html"
        if p.runModal() == .OK, let u = p.url {
            try? html.write(to: u, atomically: true, encoding: .utf8)
            model.toast = "Saved. Open it in any browser."
            Task { try? await Task.sleep(for: .seconds(5)); model.toast = nil }
        }
    }

    func savePDF() {
        guard let html = shareHTML() else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = "\(myName) and \(chat.name) - Heartbeat.pdf"
        guard p.runModal() == .OK, let u = p.url else { return }
        PDFMaker.make(html: html, to: u) { ok in
            model.toast = ok ? "PDF saved." : "Couldn't make the PDF."
            Task { try? await Task.sleep(for: .seconds(5)); model.toast = nil }
        }
    }
}

/// Renders the exported page offscreen and writes one tall PDF page.
@MainActor
final class PDFMaker: NSObject, WKNavigationDelegate {
    static var live: [PDFMaker] = []
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 1000))
    var url: URL!, done: ((Bool) -> Void)!
    static func make(html: String, to url: URL, done: @escaping (Bool) -> Void) {
        let m = PDFMaker(); m.url = url; m.done = done; live.append(m)
        m.web.navigationDelegate = m
        m.web.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        w.evaluateJavaScript("document.querySelectorAll('.reveal').forEach(e=>e.classList.add('in')); document.body.scrollHeight") { h, _ in
            let height = (h as? Double) ?? 1000
            w.frame = NSRect(x: 0, y: 0, width: 720, height: height)
            let cfg = WKPDFConfiguration(); cfg.rect = NSRect(x: 0, y: 0, width: 720, height: height)
            w.createPDF(configuration: cfg) { r in
                var ok = false
                if case .success(let data) = r { ok = (try? data.write(to: self.url)) != nil }
                self.done(ok); PDFMaker.live.removeAll { $0 === self }
            }
        }
    }
}
