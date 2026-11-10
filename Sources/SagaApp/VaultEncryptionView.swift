import SwiftUI
import SagaCore

// MARK: - Shared explanation copy

/// Plain-language disclosure of exactly what vault encryption does and does not protect.
/// Requirements: brief scope 4–5; contract §5 "user-visible truth" and S4 (CSV stays plaintext).
enum EncryptionCopy {
    static let protects = """
    Encrypting protects your message records (the `segments` folder) and your settings (`config` JSON — contact overrides, \
    prune and merge rules, media-source paths) with a passphrase and a separate recovery code. The original plaintext copy \
    is kept after conversion; it is never deleted automatically.
    """

    static let doesNotProtect = """
    It does not protect: file and folder names, message counts and sizes, the archive settings file itself, your contact-name \
    spreadsheet (`config/overrides.csv`), media files, exports, your original phone backups, or the local search index, AI \
    cache and link cache on this Mac. Anyone with access to those can still read them.
    """

    static let whatIfIForget = """
    What if I forget my passphrase? Your Recovery Kit holds a separate recovery code that can always reopen the archive. \
    Save or print the kit and keep it private and apart from the archive. If your passphrase, kit and the “remember this Mac” \
    unlock are all unavailable, Saga cannot recover the encrypted contents. This encryption protects selected files at rest; \
    it is not an app lock. For whole-disk protection, use FileVault or an encrypted disk/NAS instead.
    """
}

// MARK: - Encrypt / Decrypt wizard

struct VaultEncryptionView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var wizard = model.encryption
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            switch wizard.phase {
            case .explain: explainView
            case .passphrase: passphraseView
            case .recoveryKit: recoveryKitView
            case .decryptUnlock: decryptUnlockView
            case .working: workingView
            case .done: doneView
            case .failed: failedView
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560)
        .onDisappear { wizard.passphrase = ""; wizard.newPassphrase = ""; wizard.recoveryCodeInput = "" }
    }

    private var header: some View {
        @Bindable var wizard = model.encryption
        return HStack {
            Text(wizard.mode == .encrypt ? "Encrypt archive" : "Decrypt archive").font(.title2.bold())
            Spacer()
            Button("Close") { dismiss() }
        }
    }

    private var explainView: some View {
        @Bindable var wizard = model.encryption
        return VStack(alignment: .leading, spacing: 14) {
            Text(wizard.mode == .encrypt ? EncryptionCopy.protects : "This archive is encrypted. Decrypting returns it to a plain folder (segments and settings are no longer sealed). The encrypted original is kept and never deleted automatically.")
                .fixedSize(horizontal: false, vertical: true)
            if wizard.mode == .encrypt {
                Text(EncryptionCopy.doesNotProtect).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(EncryptionCopy.whatIfIForget).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(wizard.mode == .encrypt ? "Continue" : "Decrypt…") {
                    if wizard.mode == .encrypt { wizard.phase = .passphrase } else { wizard.phase = .decryptUnlock }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
    }

    private var passphraseView: some View {
        @Bindable var wizard = model.encryption
        return VStack(alignment: .leading, spacing: 12) {
            Text("Choose a passphrase").font(.headline)
            Text("At least \(VaultEncryption.minimumPassphraseLength) characters. It protects your archive; your recovery code is separate.").foregroundStyle(.secondary)
            SecureField("Passphrase", text: $wizard.passphrase).textFieldStyle(.roundedBorder)
            Toggle("Remember the unlock on this Mac", isOn: $wizard.remember)
            if let e = wizard.error { Text(e).font(.callout).foregroundStyle(AppTheme.Feedback.error).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Back") { wizard.error = nil; wizard.phase = .explain }
                Button("Continue") { model.wizardCollectPassphrase() }
                    .buttonStyle(.borderedProminent)
                    .disabled(wizard.passphrase.count < VaultEncryption.minimumPassphraseLength || wizard.status != nil)
            }
        }
    }

    private var recoveryKitView: some View {
        @Bindable var wizard = model.encryption
        return Group {
            if let setup = wizard.setup {
                RecoveryKitView(
                    material: RecoveryKitMaterial(vaultID: setup.vaultID, recoveryCode: setup.recoveryCode),
                    onConfirm: { typed in
                        try VaultEncryption.confirmRecovery(typed, for: setup)
                        Task { @MainActor in model.wizardStartEncrypt() }
                    },
                    onCancel: { wizard.setup = nil; wizard.phase = .passphrase }
                )
            } else {
                ErrorStateView(
                    title: "The Recovery Kit didn't finish",
                    message: "Saga couldn't prepare your Recovery Kit, so nothing has been encrypted yet. Your archive is unchanged.",
                    detail: wizard.error,
                    retryTitle: "Try again",
                    retry: { model.wizardCollectPassphrase() })
            }
        }
    }

    private var decryptUnlockView: some View {
        @Bindable var wizard = model.encryption
        return VStack(alignment: .leading, spacing: 12) {
            Text("Unlock to decrypt").font(.headline)
            Picker("", selection: $wizard.unlockMode) {
                Text("Passphrase").tag(EncryptionWizard.UnlockMode.passphrase)
                Text("Recovery code").tag(EncryptionWizard.UnlockMode.recovery)
            }.pickerStyle(.segmented).labelsHidden()
            if wizard.unlockMode == .passphrase {
                SecureField("Passphrase", text: $wizard.passphrase).textFieldStyle(.roundedBorder)
            } else {
                TextField("Recovery code", text: $wizard.recoveryCodeInput).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
            if let e = wizard.unlockError { Text(e).font(.callout).foregroundStyle(AppTheme.Feedback.error).fixedSize(horizontal: false, vertical: true) }
            if let s = wizard.status { ProgressView().controlSize(.small); Text(s).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Unlock") { model.wizardStartDecrypt() }.buttonStyle(.borderedProminent)
                    .disabled(wizard.status != nil || (wizard.unlockMode == .passphrase ? wizard.passphrase.isEmpty : wizard.recoveryCodeInput.isEmpty))
            }
        }
    }

    private var workingView: some View {
        @Bindable var wizard = model.encryption
        return VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(wizard.status ?? "Working…").font(.callout).foregroundStyle(.secondary)
            Text("Saga builds and verifies a full copy before swapping anything. Your original archive stays untouched.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneView: some View {
        @Bindable var wizard = model.encryption
        return VStack(alignment: .leading, spacing: 12) {
            Label(wizard.mode == .encrypt ? "Archive encrypted" : "Archive decrypted", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(AppTheme.Feedback.success)
            if let r = wizard.retainedURL {
                Text("Your previous copy was kept at:\n\(r.path)").font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("You can delete it yourself once you're satisfied; Saga won't delete it automatically.").font(.caption).foregroundStyle(.secondary)
            }
            if wizard.mode == .encrypt {
                Text("Note: files outside segments and config JSON — including contact-name CSV, media, exports, and the local index and AI caches — remain unencrypted.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }
    }

    private var failedView: some View {
        @Bindable var wizard = model.encryption
        return ErrorStateView(
            title: "Couldn't finish",
            message: "Nothing was changed: your original archive is intact. Try again, or close this and carry on as before.",
            detail: wizard.error,
            retryTitle: "Try again",
            retry: { wizard.reset(wizard.mode) })
            .frame(height: 340)
    }
}

// MARK: - Unlock / recover sheet

struct VaultUnlockView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var wizard = model.encryption
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlock your archive").font(.title3.bold())
            Text("Enter your passphrase, or use your Recovery Kit code.").foregroundStyle(.secondary)
            Picker("", selection: $wizard.unlockMode) {
                Text("Passphrase").tag(EncryptionWizard.UnlockMode.passphrase)
                Text("Recovery code").tag(EncryptionWizard.UnlockMode.recovery)
            }.pickerStyle(.segmented).labelsHidden()
            if wizard.unlockMode == .passphrase {
                SecureField("Passphrase", text: $wizard.passphrase).textFieldStyle(.roundedBorder).frame(width: 380)
            } else {
                TextField("Recovery code", text: $wizard.recoveryCodeInput).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 380)
            }
            Toggle("Remember the unlock on this Mac", isOn: $wizard.remember)
            if let e = wizard.unlockError { Text(e).font(.callout).foregroundStyle(AppTheme.Feedback.error).fixedSize(horizontal: false, vertical: true) }
            if let s = wizard.status { HStack { ProgressView().controlSize(.small); Text(s).font(.callout).foregroundStyle(.secondary) } }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Unlock") { model.unlockVault() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(wizard.status != nil || (wizard.unlockMode == .passphrase ? wizard.passphrase.isEmpty : wizard.recoveryCodeInput.isEmpty))
            }
        }
        .padding(22).frame(width: 480)
    }
}

// MARK: - Change passphrase sheet

struct ChangePassphraseView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var wizard = model.encryption
        VStack(alignment: .leading, spacing: 12) {
            Text("Change passphrase").font(.title3.bold())
            Text("This only re-wraps the encryption key; your messages and recovery code stay the same. At least \(VaultEncryption.minimumPassphraseLength) characters.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("New passphrase", text: $wizard.newPassphrase).textFieldStyle(.roundedBorder).frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change") { model.changePassphrase() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(wizard.newPassphrase.count < VaultEncryption.minimumPassphraseLength)
            }
        }
        .padding(22).frame(width: 480)
    }
}
