import SwiftUI
import SagaCore

@MainActor @Observable
final class FoldInModel {
    enum Phase { case choose, scanning, report, dryRunning, dryDone, running, done }
    var phase: Phase = .choose
    var folder: URL?
    var report: ScanReport?
    var scanned = 0
    var keyText = Keychain.load() ?? ""
    var outcomes: [FoldIn.Outcome] = []
    var note = ""
    var cleanKey: String { keyText.filter { $0.isHexDigit } }
    var needsKey: Bool { report?.databases.contains { $0.format == .crypt15 } ?? false }
    var keyOK: Bool { !needsKey || cleanKey.count == 64 }

    func scan(_ url: URL) {
        folder = url; phase = .scanning; scanned = 0; outcomes = []
        Task {
            let rep = await Task.detached { FoldIn.scan(root: url) }.value
            report = rep; phase = .report
        }
    }
    func run(model: AppModel, dry: Bool) {
        guard let report, let vault = model.prepareVault() else { note = "The archive folder isn't available."; return }
        phase = dry ? .dryRunning : .running; note = ""
        let key = cleanKey.count == 64 ? cleanKey : nil
        if !dry, let k = key { Keychain.save(k) }
        Task {
            let res = await FoldIn.run(report: report, vault: vault, keyHex: key, dryRun: dry, label: AppModel.deviceLabel, progress: { m in Task { @MainActor in self.note = m } })
            outcomes = res; note = ""
            if dry { phase = .dryDone } else {
                FoldIn.recordMediaSource(report.root, in: vault)
                phase = .done
                if res.contains(where: { $0.added > 0 }) { model.rebuildLibrary { _ in } }
            }
        }
    }
}

struct FoldInView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State private var f = FoldInModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add old backups").font(.title2.bold())
            switch f.phase {
            case .choose:
                Text("Point Saga at a folder where you've copied WhatsApp data over the years (for example a Google Drive or NAS folder). Saga only reads it: nothing is moved, changed or deleted.")
                    .foregroundStyle(.secondary)
                HStack { Button("Choose folder…") { if let u = pickFolder() { f.scan(u) } }.buttonStyle(.borderedProminent); Spacer() }
            case .scanning:
                HStack { ProgressView().controlSize(.small); Text("Looking through \(f.folder?.lastPathComponent ?? "folder")…") }
            case .report, .dryRunning, .dryDone, .running, .done:
                if let r = f.report { reportView(r) }
            }
            Spacer(minLength: 0)
            HStack {
                if f.phase != .choose && f.phase != .scanning && f.phase != .running && f.phase != .dryRunning {
                    Button("Start over") { f.phase = .choose; f.report = nil; f.outcomes = [] }
                }
                Spacer()
                Button(f.phase == .done ? "Close" : "Cancel") { dismiss() }
                if f.phase == .report || f.phase == .dryDone {
                    Button(f.phase == .report ? "Preview (nothing is changed)" : "Fold in") {
                        f.run(model: model, dry: f.phase == .report)
                    }.buttonStyle(.borderedProminent).disabled(!f.keyOK || !(f.report?.databases.contains { $0.usable } ?? false))
                }
            }
        }
        .padding(24).frame(width: 640, height: 600)
    }

    @ViewBuilder func reportView(_ r: ScanReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let usable = r.databases.filter(\.usable).count
                Label("\(r.databases.count) chat databases found, \(usable) readable", systemImage: "externaldrive").font(.headline)
                ForEach(r.databases.prefix(40)) { d in
                    HStack {
                        Image(systemName: d.usable ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(d.usable ? .green : .secondary)
                        Text(d.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(d.format == .plain ? "Unencrypted" : d.format == .crypt15 ? "crypt15" : d.format == .crypt14 ? "crypt14: needs key file" : d.format == .crypt12 ? "crypt12: needs key file" : "not supported")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout)
                }
                if r.databases.count > 40 { Text("…and \(r.databases.count - 40) more").font(.caption).foregroundStyle(.secondary) }
                if !r.media.isEmpty {
                    Divider()
                    Label("Media: \(r.media.reduce(0) { $0 + $1.files }.formatted()) files", systemImage: "photo.on.rectangle").font(.headline)
                    ForEach(r.media) { c in
                        HStack { Text(c.name.replacingOccurrences(of: "WhatsApp ", with: "")); Spacer()
                            Text("\(c.files.formatted()) · \(ByteCountFormatter.string(fromByteCount: c.bytes, countStyle: .file))").foregroundStyle(.secondary) }.font(.callout)
                    }
                    Text("Media isn't copied. Saga remembers where it is and loads files only when you open them.").font(.caption).foregroundStyle(.secondary)
                }
                if !r.quirks.isEmpty {
                    Divider()
                    ForEach(r.quirks, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(.secondary) }
                }
                if f.needsKey && (f.phase == .report || f.phase == .dryDone) {
                    Divider()
                    Text("Your 64-digit backup key unlocks the crypt15 files").font(.headline)
                    SecureField("Paste the key", text: $f.keyText).textFieldStyle(.roundedBorder)
                    Text(f.keyOK ? "✓ Looks right" : "Needs 64 letters/digits").font(.caption).foregroundStyle(f.keyOK ? .green : .orange)
                }
                if !f.outcomes.isEmpty {
                    Divider()
                    Label(f.phase == .done ? "Result" : "Preview: what would happen", systemImage: "list.bullet").font(.headline)
                    ForEach(Array(f.outcomes.enumerated()), id: \.offset) { _, o in
                        HStack(alignment: .top) { Text(o.file).lineLimit(1).truncationMode(.middle); Spacer(); Text(o.status).foregroundStyle(o.added > 0 ? .green : .secondary) }.font(.callout)
                    }
                }
                if f.phase == .dryRunning || f.phase == .running { HStack { ProgressView().controlSize(.small); Text(f.note.isEmpty ? "Working…" : f.note) } }
                if !usableHint(r).isEmpty { Text(usableHint(r)).font(.callout).foregroundStyle(AppTheme.Feedback.warning) }
            }
        }
    }
    func usableHint(_ r: ScanReport) -> String { r.databases.contains { $0.usable } ? "" : "None of these databases can be opened yet. Older encrypted backups need the old key file from the phone they were made on." }
    func pickFolder() -> URL? {
        let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.prompt = "Scan this folder"
        return p.runModal() == .OK ? p.url : nil
    }
}
