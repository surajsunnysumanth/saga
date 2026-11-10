import SwiftUI
import AVKit
import SagaCore

/// Media inside a chat bubble. Nothing is read until the bubble appears (thumbnails) or the user taps (open/play).
struct BubbleMedia: View {
    @Environment(AppModel.self) var model
    let msg: MessageRow
    let kind: String
    @State private var state: ChatMediaLoadState = .idle
    @State private var thumb: NSImage?
    @State private var viewing: URL?
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var opening = false

    private var presentation: ChatMediaPresentation { ChatMediaPresentation(msg.media) }

    var body: some View {
        Group {
            switch presentation {
            case .thumbnail: thumbnailView
            case .audio: chip(playing ? "Pause" : "Play \(kind)", playing ? "pause.circle" : "play.circle") { toggleAudio() }
            case .file: chip(opening ? "Opening…" : "Open \(kind == "doc" ? "document" : kind)", "doc") { openExternally() }
            case .labelOnly: chip("\(kind.capitalized) not available", "exclamationmark.triangle", action: nil)
                .help("This message has no file recorded to open. Add the folder your media lives in from Settings › Archive › Media folders…")
            }
        }
        .sheet(item: Binding(get: { viewing.map(Item.init) }, set: { viewing = $0?.url })) { item in
            MediaViewer(url: item.url, isVideo: kind == "video")
        }
        .onDisappear { player?.pause(); playing = false }
    }

    private struct Item: Identifiable { let url: URL; var id: URL { url } }

    @ViewBuilder private var thumbnailView: some View {
        Group {
            if let thumb {
                Image(nsImage: thumb).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 260)
                    .overlay { if kind == "video" { Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 3) } }
                    .clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                    .onTapGesture { Task { await openViewer() } }
            } else if state == .missing {
                chip("\(kind.capitalized) not available", "exclamationmark.triangle", action: nil)
                    .help("The file isn't in any media folder. Add one from Settings › Archive › Media folders…")
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.1)).frame(width: 160, height: 110)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: model.mediaGeneration) { await loadThumbnail() }   // cancelled automatically when scrolled off
    }

    private func loadThumbnail() async {
        guard let media = msg.media else { return }
        state = .loading
        let url = try? await model.mediaLoader()?.thumbnail(for: media)
        if Task.isCancelled { state = .idle; return }
        if let url, let img = NSImage(contentsOf: url) { thumb = img; state = .loaded(url) } else { thumb = nil; state = .missing }
    }

    private func openViewer() async {
        guard let media = msg.media else { return }
        if let url = try? await model.mediaLoader()?.file(for: media) { viewing = url } else { state = .missing; thumb = nil }
    }

    private func toggleAudio() {
        if playing { player?.pause(); playing = false; return }
        if let player { player.play(); playing = true; return }
        Task {
            guard let media = msg.media, let url = try? await model.mediaLoader()?.file(for: media) else {
                model.flash("That \(kind) isn't available. Add its folder from Settings › Archive › Media folders…"); return
            }
            let p = AVPlayer(url: url); player = p
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                Task { @MainActor in playing = false; await p.seek(to: .zero) }
            }
            p.play(); playing = true
        }
    }

    private func openExternally() {
        guard let media = msg.media, !opening else { return }
        opening = true
        Task {
            defer { opening = false }
            if let url = try? await model.mediaLoader()?.file(for: media) { NSWorkspace.shared.open(url) }
            else { model.flash("That file isn't available. Add its folder from Settings › Archive › Media folders…") }
        }
    }

    private func chip(_ title: String, _ symbol: String, action: (() -> Void)?) -> some View {
        let label = Label(title, systemImage: symbol).font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill((msg.fromMe ? Color.white : Color.primary).opacity(0.12)))
        return Group { if let action { Button(action: action) { label }.buttonStyle(.plain) } else { label } }
    }
}

struct MediaViewer: View {
    let url: URL; let isVideo: Bool
    @Environment(\.dismiss) var dismiss
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(10)
            Divider()
            if isVideo, let player { VideoPlayer(player: player) }
            else if let image { Image(nsImage: image).resizable().scaledToFit().padding(8) }
            else { ProgressView().frame(maxHeight: .infinity) }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            if isVideo { player = AVPlayer(url: url) }
            else {   // bytes off the main actor, NSImage built here: NSImage is not Sendable on the stricter CI toolchain
                let data = await Task.detached { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
                image = data.flatMap { NSImage(data: $0) }
            }
        }
        .onDisappear { player?.pause() }
    }
}

/// Settings › Archive › Media folders… : where attachments are looked up. Per-vault sources plus an optional Google Drive folder.
struct MediaSourcesView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var locations: [MediaLocation] = []
    @State private var drive: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media folders").font(.title3.bold())
            Text("Photos, videos and files are looked up here only when you scroll to them. Nothing is copied into your archive.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox("Folders, in priority order") {
                VStack(alignment: .leading, spacing: 6) {
                    if locations.isEmpty { Text("None added.").foregroundStyle(.secondary) }
                    ForEach(Array(locations.enumerated()), id: \.element.id) { i, _ in
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: locations[i]))
                            TextField("Name", text: Binding(
                                get: { locations[i].label },
                                set: { locations[i].label = $0; save() }))
                                .textFieldStyle(.roundedBorder).frame(width: 150)
                            Text(locations[i].path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(locations[i].kindLabel).font(.caption2).foregroundStyle(.tertiary)
                            Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.plain).disabled(i == 0)
                            Button { move(i, 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.plain).disabled(i == locations.count - 1)
                            Button { locations.remove(at: i); save() } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                    Button("Add folder…") { if let u = pick() {
                        locations.append(MediaLocation(path: u.path))
                        save()
                    } }
                    Text("The first folder with a file wins, so put the phone export above a cloud archive.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Google Drive folder") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Online-only files download when you open them or view their thumbnail.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(drive?.path ?? "Not set").lineLimit(1).truncationMode(.middle).foregroundStyle(drive == nil ? .secondary : .primary)
                        Spacer()
                        Button(drive == nil ? "Choose…" : "Change…") { if let u = pick() { drive = u; saveDrive() } }
                        if drive != nil { Button("Remove") { drive = nil; saveDrive() } }
                    }
                }.padding(4)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 520)
        .onAppear {
            if let v = model.prepareVault() { locations = (try? MediaSources.loadLocations(in: v)) ?? [] }
            drive = AppModel.driveRoot
        }
    }
    private func icon(for l: MediaLocation) -> String {
        switch l.kind { case .cloud: return "cloud"; case .network: return "externaldrive.connected.to.line.below"; case .local: return "folder" }
    }

    private func move(_ i: Int, _ by: Int) {
        let j = i + by
        guard locations.indices.contains(i), locations.indices.contains(j) else { return }
        locations.swapAt(i, j); save()
    }

    private func pick() -> URL? {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.prompt = "Use this folder"
        return p.runModal() == .OK ? p.url : nil
    }
    private func save() { if let v = model.prepareVault() { try? MediaSources.save(locations, in: v) }; model.mediaSettingsChanged() }
    private func saveDrive() { AppModel.driveRoot = drive; model.mediaSettingsChanged() }
}
