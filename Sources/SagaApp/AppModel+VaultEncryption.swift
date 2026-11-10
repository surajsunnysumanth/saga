import Foundation
import Observation
import SagaCore

/// Observable state for the Encrypt / Decrypt wizards and the unlock/recover sheet.
/// Holds only UI state; every action that touches the vault lives on `AppModel`.
@MainActor @Observable
final class EncryptionWizard {
    enum Mode { case encrypt, decrypt }
    enum Phase { case explain, passphrase, recoveryKit, decryptUnlock, working, done, failed }
    enum UnlockMode { case passphrase, recovery }

    // Encrypt / Decrypt wizard
    var mode: Mode = .encrypt
    var phase: Phase = .explain
    var passphrase = ""
    var newPassphrase = ""
    var remember = true
    var recoveryCodeInput = ""
    var setup: VaultEncryptionSetup?
    var error: String?
    var status: String?
    var retainedURL: URL?

    // Unlock / recover sheet (opening an already-encrypted vault)
    var unlockMode: UnlockMode = .passphrase
    var unlockError: String?

    func reset(_ mode: Mode) {
        self.mode = mode
        phase = .explain
        passphrase = ""
        newPassphrase = ""
        remember = true
        recoveryCodeInput = ""
        setup = nil
        error = nil
        status = nil
        retainedURL = nil
        unlockError = nil
    }
}

extension AppModel {
    // MARK: - Settings › Privacy entries

    /// Settings › Privacy › "Encrypt archive…". Only offered for a plaintext archive; checks protection without unlocking.
    func startEncrypt() {
        do {
            guard try VaultEncryption.protection(at: Self.vaultURL) == .plaintext else {
                toast = "This archive is already encrypted."
                return
            }
            encryption.reset(.encrypt)
            showEncryption = true
        } catch { toast = friendly(error) }
    }

    /// Settings › Privacy › "Decrypt archive". Only offered for an encrypted archive; the wizard collects the unlock.
    func startDecrypt() {
        do {
            guard try VaultEncryption.protection(at: Self.vaultURL) == .encrypted else {
                toast = "This archive is not encrypted."
                return
            }
            encryption.reset(.decrypt)
            showEncryption = true
        } catch { toast = friendly(error) }
    }

    // MARK: - Encrypt wizard

    /// Collects a passphrase and generates the Recovery Kit setup (no on-disk changes).
    func wizardCollectPassphrase() {
        encryption.error = nil
        guard let vault = prepareVault(), vault.protection == .plaintext else {
            encryption.error = "This archive can't be encrypted right now."
            return
        }
        encryption.status = "Preparing your Recovery Kit…"
        let passphrase = encryption.passphrase
        Task {
            do {
                let setup = try await Task.detached { try VaultEncryption.prepare(vault: vault, passphrase: passphrase) }.value
                encryption.setup = setup
                encryption.status = nil
                encryption.phase = .recoveryKit
            } catch {
                encryption.status = nil
                encryption.error = friendly(error)
            }
        }
    }

    /// Runs the verified encrypt conversion, then rebuilds the library from the encrypted vault.
    func wizardStartEncrypt() {
        guard let setup = encryption.setup, encryption.phase == .recoveryKit else { return }
        encryption.phase = .working
        encryption.status = "Encrypting your archive…"
        let url = Self.vaultURL
        let recoveryCode = setup.recoveryCode
        Task {
            do {
                let result = try await Task.detached {
                    let vault = try Vault(url: url, create: false)
                    let ticket = try VaultConversion.stageEncryption(vault: vault, setup: setup)
                    return try VaultConversion.commit(ticket)
                }.value
                // Re-derive the unlock context from the kit code (the setup's raw context is internal).
                let ctx = try VaultEncryption.recover(at: result.activeURL, recoveryCode: recoveryCode)
                rememberIfNeeded(ctx)
                encryption.retainedURL = result.retainedOriginalURL
                encryption.status = nil
                encryption.phase = .done
                rebuildLibrary(vault: try Vault(url: result.activeURL, create: false, unlockContext: ctx))
                toast = "Archive encrypted. Your previous plaintext copy is kept at \(result.retainedOriginalURL.lastPathComponent)."
            } catch {
                encryption.status = nil
                encryption.phase = .failed
                encryption.error = friendly(error)
            }
        }
    }

    // MARK: - Decrypt wizard

    /// Unlocks with the supplied credential, then runs the verified decrypt conversion and rebuilds.
    func wizardStartDecrypt() {
        encryption.phase = .working
        encryption.status = "Decrypting your archive…"
        let url = Self.vaultURL
        let mode = encryption.unlockMode
        let passphrase = encryption.passphrase
        let code = encryption.recoveryCodeInput
        Task {
            do {
                let result = try await Task.detached {
                    let ctx: VaultUnlockContext = try {
                        switch mode {
                        case .passphrase: return try VaultEncryption.unlock(at: url, passphrase: passphrase)
                        case .recovery: return try VaultEncryption.recover(at: url, recoveryCode: code)
                        }
                    }()
                    let unlocked = try Vault(url: url, create: false, unlockContext: ctx)
                    let ticket = try VaultConversion.stageDecryption(vault: unlocked)
                    return try VaultConversion.commit(ticket)
                }.value
                encryption.retainedURL = result.retainedOriginalURL
                encryption.status = nil
                encryption.phase = .done
                rebuildLibrary(vault: try Vault(url: result.activeURL, create: false))
                toast = "Archive decrypted. Your previous encrypted copy is kept at \(result.retainedOriginalURL.lastPathComponent)."
            } catch {
                encryption.status = nil
                encryption.phase = .failed
                encryption.error = friendly(error)
            }
        }
    }

    /// Change the passphrase of the open encrypted vault (re-wrap only; needs the Keychain-unlocked context).
    func changePassphrase() {
        guard let v = prepareVault(), let ctx = v.unlockContext else { return }
        let url = Self.vaultURL
        let new = encryption.newPassphrase
        Task {
            do {
                try await Task.detached { try VaultEncryption.changePassphrase(at: url, context: ctx, newPassphrase: new) }.value
                toast = "Passphrase changed."
                encryption.newPassphrase = ""
            } catch { toast = friendly(error) }
        }
    }

    // MARK: - Unlock / recover (open an already-encrypted vault)

    /// From the unlock sheet: derive a context, optionally remember it, rebuild.
    func unlockVault() {
        encryption.unlockError = nil
        encryption.status = "Unlocking…"
        let url = Self.vaultURL
        let mode = encryption.unlockMode
        let passphrase = encryption.passphrase
        let code = encryption.recoveryCodeInput
        Task {
            do {
                let ctx: VaultUnlockContext = try await Task.detached {
                    switch mode {
                    case .passphrase: return try VaultEncryption.unlock(at: url, passphrase: passphrase)
                    case .recovery: return try VaultEncryption.recover(at: url, recoveryCode: code)
                    }
                }.value
                rememberIfNeeded(ctx)
                encryption.status = nil
                if appSheet == .unlock { appSheet = nil }
                encryption.passphrase = ""
                encryption.recoveryCodeInput = ""
                vaultOK = true
                rebuildLibrary(vault: try Vault(url: url, create: false, unlockContext: ctx))
            } catch {
                encryption.status = nil
                encryption.unlockError = friendly(error)
            }
        }
    }

    // MARK: - helpers

    private func rememberIfNeeded(_ ctx: VaultUnlockContext) {
        guard encryption.remember else { return }
        do { try VaultKeychain.save(ctx) } catch { /* fail-save: still usable with passphrase/code */ }
    }

    /// A safe, plain-language message for the user; never echoes secrets.
    func friendly(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return "Something went wrong. Your archive is unchanged."
    }

    /// Rebuilds the local library from a specific (already-open) vault.
    func rebuildLibrary(vault: Vault, then done: @escaping @MainActor (ImportSummary?) -> Void = { _ in }) {
        let out = indexURL
        Task {
            do {
                let s = try await Task.detached { try VaultIndexer.build(vault: vault, out: out.path) }.value
                open(path: out.path); done(s)
            } catch { status = "Could not build the library: \(error)"; done(nil) }
        }
    }
}
