import SwiftUI
import SagaCore
import AppKit

enum WizStep: Int, CaseIterable { case start, connect, encrypted, backup, key, names, location, build }

@MainActor @Observable
final class WizardModel {
    var step: WizStep = .start
    var androidMode = true
    // phone / adb
    var adb: AdbState = .noDevice
    var toolMessage = ""
    var downloading = false
    var info: BackupInfo?
    var pulling = false
    var pulledBackup: URL?
    var pollTask: Task<Void, Never>?
    // manual
    var fileBackup: URL?
    // key & names
    var keyText = Keychain.load() ?? ""
    var remember = true
    var names: AppModel.NameSource = .phone
    var vcfURL: URL?
    var vaultChoice: VaultChoice = .thisMac
    var vaultFolder: URL?
    enum VaultChoice { case thisMac, folder }

    var cleanKey: String { keyText.filter { $0.isHexDigit } }
    var keyValid: Bool { cleanKey.count == 64 }
    var backupURL: URL? { androidMode ? pulledBackup : fileBackup }
    var adbReady: Bool { if case .ready = adb { return true }; return false }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            if Adb.locate() == nil && !downloading {
                downloading = true; toolMessage = "Getting the Android connection tool (one time, ~15 MB)…"
                do { try await Adb.downloadTools(); toolMessage = "" } catch { toolMessage = "Couldn't download it: \(error). Check your internet connection." }
                downloading = false
            }
            while !Task.isCancelled {
                adb = await Adb.state()
                if case .ready = adb { info = await Adb.backupInfo() } else { info = nil }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func stopPolling() { pollTask?.cancel() }

    func pull() {
        guard let info else { return }
        pulling = true
        Task {
            let dest = AppModel.supportDir.appendingPathComponent("phone-pull")
            if await Adb.pullDatabases(from: info, to: dest) {
                pulledBackup = dest.appendingPathComponent("msgstore.db.crypt15"); step = .key; stopPolling()
            } else { toolMessage = "Copying from the phone failed. Keep it unlocked and plugged in, then try again." }
            pulling = false
        }
    }
    func pasteKey() {
        if let s = NSPasteboard.general.string(forType: .string) { keyText = s.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

struct WizardView: View {
    @Environment(AppModel.self) var model
    @State private var w: WizardModel
    @State private var art = ArtTimeline()

    init(startAt: WizStep = .start) {
        let m = WizardModel()
        m.step = startAt
        _w = State(initialValue: m)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    header
                    HStack(alignment: .top, spacing: 36) {
                        if w.step == .connect || w.step == .encrypted || w.step == .backup || w.step == .key {
                            illustration
                                .frame(width: 300)
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                            stepCopy
                        }
                        .frame(maxWidth: 520, alignment: .leading)
                    }
                }
                .padding(AppTheme.Spacing.xl)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer.padding(AppTheme.Spacing.m)
        }
        .onDisappear { w.stopPolling(); art.stop() }
        .onChange(of: w.step) { _, step in play(step) }
        .onAppear {
            play(w.step)
            if (w.step == .connect || w.step == .backup) && w.androidMode { w.startPolling() }
        }
        .onChange(of: w.adbReady) { _, ready in
            // The illustration should end where the app actually is: a real phone wins over the scripted beats.
            if ready { art.jump(to: 4) }
        }
        .sheet(isPresented: Binding(get: { model.showFoldIn }, set: { model.showFoldIn = $0 })) { FoldInView().environment(model) }
    }

    // MARK: - Illustration

    @ViewBuilder private var illustration: some View {
        switch w.step {
        case .connect: DevSettingsArt(phase: art.phase)
        case .encrypted: KeySetupArt(phase: art.phase)
        // Without a backup on the phone, the illustration stops at "backing up" rather than
        // promising a copy that cannot happen yet.
        case .backup: BackupCopyArt(phase: w.info == nil ? min(art.phase, 1) : art.phase)
        default: KeyArt(filledBlocks: min(8, w.cleanKey.count / 8))
        }
    }

    /// Beats, not a video: each one is a point where the person has to act.
    private func play(_ step: WizStep) {
        switch step {
        case .connect: art.run(beats: [0.9, 1.1, 0.9, 1.3], restingPhase: 4)
        case .encrypted: art.run(beats: [0.8, 0.9, 1.0], restingPhase: 3)
        case .backup: art.run(beats: [1.1, 0.9, 1.2, 1.0], restingPhase: 4)
        default: art.stop()
        }
    }

    // MARK: - Header and copy

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.s) {
                Text("Saga").font(.system(size: 30, weight: .bold))
                if w.step != .start {
                    Text(stepLabel)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                }
            }
            if w.step != .start {
                HStack(spacing: 5) {
                    ForEach(1...7, id: \.self) { i in
                        Capsule()
                            .fill(i <= max(1, w.step.rawValue) ? AppTheme.Accent.primary : AppTheme.Surface.hairline)
                            .frame(height: 4)
                    }
                }
                .frame(maxWidth: 320)
            }
        }
    }

    private var stepLabel: String {
        switch w.step {
        case .connect: "Step 1 of 7 · The phone"
        case .encrypted: "Step 2 of 7 · The key, if you don't have one"
        case .backup: "Step 3 of 7 · The backup"
        case .key: "Step 4 of 7 · The key"
        case .names: "Step 5 of 7 · Names"
        case .location: "Step 6 of 7 · The archive"
        case .build: "Step 7 of 7 · Building"
        case .start: ""
        }
    }

    @ViewBuilder private var stepCopy: some View {
        switch w.step {
        case .start: start
        case .connect: connect
        case .encrypted: encrypted
        case .backup: backup
        case .key: key
        case .names: names
        case .location: location
        case .build: build
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Your WhatsApp history, kept private on this Mac.")
                .font(.title3.weight(.semibold))
            Text("Saga turns your chat backup into something you can search and browse. Nothing is uploaded anywhere.")
                .foregroundStyle(AppTheme.Surface.textSecondary)

            Text("Where is your chat history?").font(.headline).padding(.top, AppTheme.Spacing.s)
            bigButton("📱  My Android phone", "Plug it in with a cable. Saga walks you through the one setting it needs.") {
                w.androidMode = true; w.names = .phone; w.step = .connect; w.startPolling()
            }
            bigButton("📁  I already have a backup file", "A msgstore.db.crypt15 file saved on this Mac.") {
                w.androidMode = false; w.names = .mac; w.step = .key
            }
            Text("iPhone support is coming later.").font(.caption).foregroundStyle(AppTheme.Surface.textSecondary)

            Menu("Advanced") {
                Button("Add old backups from a folder…") { model.showFoldIn = true }
                Button("Import an already-decrypted msgstore.db…") { if let d = pick(["db"]) { model.importDB(db: d, vcf: nil) } }
                Button("Open an existing index…") { if let i = pick(["db"]) { model.open(path: i.path) } }
            }
            .fixedSize()
            .padding(.top, AppTheme.Spacing.s)

            Text(model.status).font(.callout).foregroundStyle(AppTheme.Surface.textSecondary)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Turn on one setting").font(.title2.bold())
            Text("Android lets a computer read a phone's files only when you say so. That switch is called USB debugging, and it is buried. We'll walk you to it, tap by tap.")
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            artCaption

            callout("What this allows",
                    "While the cable is plugged in, this Mac can read your phone's files. Turn it off afterwards and the permission is gone. Nothing is uploaded.")

            statusRow
            if w.downloading { ProgressView().controlSize(.small) }
            if !w.toolMessage.isEmpty { Text(w.toolMessage).foregroundStyle(AppTheme.Feedback.warning) }

            Text("You can turn it off again as soon as the import finishes.")
                .font(.caption).foregroundStyle(AppTheme.Surface.textSecondary)
        }
    }

    private var artCaption: some View {
        let text: String
        switch art.phase {
        case 0: text = "Open Settings → About phone → Software information."
        case 1: text = "Tap Build number seven times. That unlocks Developer options."
        case 2: text = "Turn on USB debugging."
        case 3: text = "Tap Allow on the phone."
        default: text = "Phone connected. That was the hard part."
        }
        return Text(text)
            .font(AppTheme.Typography.callout)
            .foregroundStyle(AppTheme.Surface.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: art.phase)
    }

    private var statusRow: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            switch w.adb {
            case .ready(let m):
                VStack(alignment: .leading, spacing: 0) {
                    Label("Phone connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Feedback.success)
                    Text(m).font(.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                }
            case .unauthorized:
                Label("Waiting for you to allow it on the phone…", systemImage: "hand.tap").foregroundStyle(AppTheme.Feedback.warning)
            default:
                Label("Looking for your phone…", systemImage: "cable.connector").foregroundStyle(AppTheme.Surface.textSecondary)
                ProgressView().controlSize(.small)
            }
        }
        .font(.headline)
    }

    private var encrypted: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Turn on encrypted backup, and keep the key").font(.title2.bold())
            Text("This is the step people skip, and it is the one that decides whether your archive can be opened at all.")
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            numbered([
                "In WhatsApp: Settings → Chats → Chat backup.",
                "Tap End-to-end encrypted backup → Turn on.",
                "Choose Use 64-digit key, not a password. Saga cannot open a password-protected backup.",
                "Tap Create, then copy the 64 characters it shows and keep them somewhere safe.",
                "Back on Chat backup, tap Back up now, and leave the phone plugged in."
            ], highlight: [2])

            callout("No key on the phone?",
                    "If the setting only offers a password, your emergency option is to turn encryption off, which deletes the encrypted copy, then set it up again with a key. Saga says a file cannot be opened rather than guessing.")

            Text("This uploads an encrypted copy to Google Drive. Use Wi-Fi if your plan is metered; the copy is useless without the key.")
                .font(.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func numbered(_ items: [String], highlight: Set<Int> = []) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: AppTheme.Spacing.s) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.Accent.text)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(AppTheme.Accent.tint))
                    Text(items[index])
                        .font(AppTheme.Typography.callout)
                        .fontWeight(highlight.contains(index) ? .semibold : .regular)
                        .foregroundStyle(highlight.contains(index) ? AppTheme.Accent.text : AppTheme.Surface.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var backup: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Make a fresh one").font(.title2.bold())
            Text("Open WhatsApp → Settings → Chats → Chat backup and tap Back up now. That creates the file on the phone; Saga copies it the moment it appears.")
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            callout("Why a fresh one",
                    "Your last backup might be days old. The newest messages are the ones worth keeping.")

            if let i = w.info {
                Label("Latest backup on the phone: \(i.lastBackup ?? "unknown")", systemImage: "clock")
                    .font(.headline)
                if w.pulling {
                    HStack(spacing: AppTheme.Spacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Copying from the phone…")
                    }
                }
            } else {
                Label("No WhatsApp backup found yet. Finish the steps on the phone.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.Feedback.warning)
            }

            if !w.toolMessage.isEmpty { Text(w.toolMessage).foregroundStyle(AppTheme.Feedback.warning) }
            Text("Saga copies the file itself. No folders, no dragging, no terminal.")
                .font(.caption).foregroundStyle(AppTheme.Surface.textSecondary)
        }
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Paste your 64-digit key").font(.title2.bold())
            Text("Copy it from the screen WhatsApp showed you when you turned on the encrypted backup. It never leaves this Mac.")
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !w.androidMode {
                HStack(spacing: AppTheme.Spacing.s) {
                    Button("Choose msgstore.db.crypt15…") { w.fileBackup = pick(["crypt15"]) }
                    Text(w.fileBackup?.lastPathComponent ?? "no file chosen")
                        .foregroundStyle(AppTheme.Surface.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            HStack(spacing: AppTheme.Spacing.s) {
                SecureField("Paste the 64-digit key", text: $w.keyText).textFieldStyle(.roundedBorder)
                Button("Paste") { w.pasteKey() }
            }
            Text(w.keyValid ? "Looks right: 64 characters." : (w.keyText.isEmpty ? " " : "Needs 64 letters and digits (\(w.cleanKey.count) so far)."))
                .font(.caption)
                .foregroundStyle(w.keyValid ? AppTheme.Feedback.success : AppTheme.Feedback.warning)

            Toggle("Remember it securely in this Mac's Keychain", isOn: $w.remember)

            callout("Lost it?",
                    "WhatsApp shows the key again under Chats → Chat backup → End-to-end encrypted backup, if the backup was made with a key rather than a password.")
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Show real names").font(.title2.bold())
            Text("WhatsApp stores phone numbers. Saga can match them to your contacts so chats show names.")
                .foregroundStyle(AppTheme.Surface.textSecondary)
            Picker("", selection: $w.names) {
                if w.androidMode { Text("From my phone's contacts (recommended)").tag(AppModel.NameSource.phone) }
                Text("From this Mac's Contacts app").tag(AppModel.NameSource.mac)
                Text("From a .vcf contacts file").tag(AppModel.NameSource.file)
                Text("Skip (show phone numbers)").tag(AppModel.NameSource.none)
            }.pickerStyle(.radioGroup).labelsHidden()
            if w.names == .file {
                HStack {
                    Button("Choose .vcf…") { w.vcfURL = pick(["vcf"]) }
                    Text(w.vcfURL?.lastPathComponent ?? "").foregroundStyle(AppTheme.Surface.textSecondary)
                }
            }
        }
    }

    private var location: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Where should your archive live?").font(.title2.bold())
            Text("Saga keeps your messages as plain, open files in one folder, so you can back it up, copy it, or open it with other tools.")
                .foregroundStyle(AppTheme.Surface.textSecondary)
            Picker("", selection: $w.vaultChoice) {
                Text("On this Mac (simplest)").tag(WizardModel.VaultChoice.thisMac)
                Text("In a folder I choose: NAS, external drive, Google Drive, iCloud…").tag(WizardModel.VaultChoice.folder)
            }.pickerStyle(.radioGroup).labelsHidden()
            if w.vaultChoice == .folder {
                HStack {
                    Button("Choose folder…") { w.vaultFolder = pickFolder() }
                    Text(w.vaultFolder?.path ?? "none chosen")
                        .foregroundStyle(AppTheme.Surface.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
            callout("Good to know",
                    "Cloud folders work: Saga only adds small files and never edits old ones. The messages are stored unencrypted so other tools can read them, so pick a folder on an encrypted drive if that matters.")
        }
    }

    private var build: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Building your archive").font(.title2.bold())
            HStack(spacing: AppTheme.Spacing.s) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.headline)
            }
            Text("This usually takes under a minute.").foregroundStyle(AppTheme.Surface.textSecondary)
        }
    }

    // MARK: - Navigation

    private var footer: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            if w.step != .start && w.step != .build {
                Button("Back") { back() }
            }
            Spacer()
            switch w.step {
            case .start, .build:
                EmptyView()
            case .connect:
                Button("I already have the backup file") {
                    w.androidMode = false; w.names = .mac; w.step = .key; w.stopPolling()
                }
                .buttonStyle(.bordered)
                Button("Continue") { w.step = .encrypted }
                    .buttonStyle(.borderedProminent)
                    .disabled(!w.adbReady)
            case .encrypted:
                Button("I already have my key") { w.step = .backup }
                    .buttonStyle(.bordered)
                Button("I have a key now") { w.step = .backup }
                    .buttonStyle(.borderedProminent)
            case .backup:
                Button("Check again") { Task { w.info = await Adb.backupInfo() } }
                Button("Copy it to my Mac") { w.pull() }
                    .buttonStyle(.borderedProminent)
                    .disabled(w.info == nil || w.pulling)
            case .key:
                Button("Continue") { w.step = .names }
                    .buttonStyle(.borderedProminent)
                    .disabled(!w.keyValid || w.backupURL == nil)
            case .names:
                Button("Continue") { w.step = .location }
                    .buttonStyle(.borderedProminent)
                    .disabled(w.names == .file && w.vcfURL == nil)
            case .location:
                Button("Build my archive") {
                    w.step = .build
                    if let b = w.backupURL {
                        model.runSetup(backup: b, key: w.keyText, remember: w.remember, names: w.names, vcf: w.vcfURL,
                                       vaultFolder: w.vaultChoice == .folder ? w.vaultFolder : nil)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(w.vaultChoice == .folder && w.vaultFolder == nil)
            }
        }
    }

    private func back() {
        switch w.step {
        case .connect: w.stopPolling(); w.step = .start
        case .encrypted: w.step = .connect; w.startPolling()
        case .backup: w.step = .encrypted
        case .key: if w.androidMode { w.step = .backup; w.startPolling() } else { w.step = .start }
        case .names: w.step = .key
        case .location: w.step = .names
        default: break
        }
    }

    // MARK: - Helpers

    private func bigButton(_ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(sub).font(.caption).foregroundStyle(AppTheme.Surface.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.m)
            .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.Surface.field))
        }
        .buttonStyle(.plain)
    }

    private func callout(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(AppTheme.Surface.textPrimary)
            Text(body).font(.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.Surface.field))
    }

    private func pickFolder() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true
        p.prompt = "Use this folder"
        return p.runModal() == .OK ? p.url : nil
    }

    private func pick(_ types: [String]) -> URL? {
        let p = NSOpenPanel()
        p.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        p.canChooseFiles = true; p.canChooseDirectories = false
        return p.runModal() == .OK ? p.url : nil
    }
}
