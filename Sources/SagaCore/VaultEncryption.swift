import Foundation
import CryptoKit
import CommonCrypto
import Security

// Optional vault encryption (vault format 2). Frozen format: docs/tasks/02-encryption-contract.md §8.
// A random 256-bit data key (DEK) seals protected files with AES-256-GCM (CryptoKit). The DEK is stored only
// wrapped: once under a PBKDF2-HMAC-SHA256 passphrase key, once under an HKDF key derived from an independent
// random recovery credential. No secret material is ever logged or put in an error message.

public enum VaultProtection: Sendable { case plaintext, encrypted }

public enum VaultEncryptionError: Error, Sendable, Equatable {
    case locked, invalidCredential, invalidRecoveryCode, recoveryNotConfirmed, unsupportedFormat, invalidMetadata
    case wrongVault, authenticationFailed, sourceChanged, conversionInProgress, ioFailure, keychainUnavailable, cancelled
    case weakPassphrase
}

extension VaultEncryptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .locked: return "This archive is encrypted and locked. Unlock it with your passphrase or Recovery Kit."
        case .invalidCredential: return "That passphrase did not unlock this archive. Try again or use your Recovery Kit."
        case .invalidRecoveryCode: return "That recovery code isn't in the right format. Check it against your Recovery Kit and try again."
        case .recoveryNotConfirmed: return "Confirm your Recovery Kit before encrypting. Type back the full code from your saved kit."
        case .unsupportedFormat: return "This archive was written by a newer version of Saga. Update Saga to open it."
        case .invalidMetadata: return "This archive's settings file is damaged or inconsistent. Nothing was changed; restore vault.json from a backup."
        case .wrongVault: return "That key belongs to a different archive."
        case .authenticationFailed: return "An archive file failed its integrity check, so it was not used. Restore it from a backup or retry."
        case .sourceChanged: return "The archive changed while it was being converted. Nothing was replaced; start the conversion again."
        case .conversionInProgress: return "The archive is being converted or recovered. Wait for that to finish."
        case .ioFailure: return "Saga couldn't read or write the archive files. Your original archive is untouched."
        case .keychainUnavailable: return "The macOS Keychain isn't available. Use your passphrase or Recovery Kit instead."
        case .cancelled: return "Cancelled. Your original archive is untouched."
        case .weakPassphrase: return "Use a passphrase of at least \(VaultEncryption.minimumPassphraseLength) characters."
        }
    }
}

/// Scoped data-key capability. Never Codable; description is redacted.
public struct VaultUnlockContext: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let vaultID: String
    let key: SymmetricKey
    init(vaultID: String, key: SymmetricKey) { self.vaultID = vaultID; self.key = key }
    public var description: String { "VaultUnlockContext(<redacted>)" }
    public var debugDescription: String { description }
    func sameKey(as other: VaultUnlockContext) -> Bool {
        key.withUnsafeBytes { a in other.key.withUnsafeBytes { b in a.count == b.count && a.elementsEqual(b) } }
    }
}

final class SetupState: @unchecked Sendable {
    private let lock = NSLock(); private var _confirmed = false
    var confirmed: Bool { lock.lock(); defer { lock.unlock() }; return _confirmed }
    func confirm() { lock.lock(); _confirmed = true; lock.unlock() }
}

public struct VaultEncryptionSetup: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let vaultID: String
    /// Sensitive and transient: display once, never persist. Grouped, with check character.
    public let recoveryCode: String
    let context: VaultUnlockContext
    let metadata: EncryptionMetadata
    let state: SetupState
    public var isConfirmed: Bool { state.confirmed }
    public var description: String { "VaultEncryptionSetup(<redacted>)" }
    public var debugDescription: String { description }
}

// MARK: - Metadata (format 2)

struct EncryptionMetadata: Codable, Equatable, Sendable {
    struct Passphrase: Codable, Equatable, Sendable { var kdf: String; var iterations: Int; var salt: String; var keyBytes: Int; var wrapped: String }
    struct Recovery: Codable, Equatable, Sendable { var kdf: String; var encoding: String; var wrapped: String }
    var version: Int
    var cipher: String
    var passphrase: Passphrase
    var recovery: Recovery

    static let wrappedLength = 12 + 32 + 16     // nonce + key + tag

    func validate() throws {
        guard version == 1, cipher == "AES-256-GCM" else { throw VaultEncryptionError.unsupportedFormat }
        guard passphrase.kdf == "PBKDF2-HMAC-SHA256", VaultEncryption.iterationBounds.contains(passphrase.iterations),
              passphrase.keyBytes == 32, Data(base64Encoded: passphrase.salt)?.count == 16,
              Data(base64Encoded: passphrase.wrapped)?.count == Self.wrappedLength,
              recovery.kdf == "HKDF-SHA256", recovery.encoding == RecoveryCode.encodingID,
              Data(base64Encoded: recovery.wrapped)?.count == Self.wrappedLength
        else { throw VaultEncryptionError.invalidMetadata }
    }
}

struct VaultMeta {
    var raw: [String: Any]
    var format: Int
    var id: String
    var encryption: EncryptionMetadata?
    var protection: VaultProtection { encryption == nil ? .plaintext : .encrypted }

    static func read(at vaultURL: URL) throws -> VaultMeta {
        let file = vaultURL.appendingPathComponent("vault.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw SQLiteError.open("not a Saga vault: \(vaultURL.path)") }
        guard let data = try? Data(contentsOf: file) else { throw VaultEncryptionError.ioFailure }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = (o["format"] as? NSNumber)?.intValue, let id = o["id"] as? String, UUID(uuidString: id) != nil
        else { throw VaultEncryptionError.invalidMetadata }
        switch format {
        case 1:
            guard o["encryption"] == nil else { throw VaultEncryptionError.invalidMetadata }
            return VaultMeta(raw: o, format: 1, id: id, encryption: nil)
        case 2:
            guard let e = o["encryption"], JSONSerialization.isValidJSONObject(e),
                  let ed = try? JSONSerialization.data(withJSONObject: e),
                  let enc = try? JSONDecoder().decode(EncryptionMetadata.self, from: ed)
            else { throw VaultEncryptionError.invalidMetadata }
            try enc.validate()
            return VaultMeta(raw: o, format: 2, id: id, encryption: enc)
        default:
            throw VaultEncryptionError.unsupportedFormat
        }
    }

    /// vault.json bytes for this metadata with `encryption` replaced (nil → plaintext format 1). Unknown keys are preserved.
    static func serialize(base raw: [String: Any], encryption: EncryptionMetadata?) throws -> Data {
        var o = raw
        if let e = encryption {
            o["format"] = 2
            let d = try JSONEncoder().encode(e)
            o["encryption"] = try JSONSerialization.jsonObject(with: d)
        } else {
            o["format"] = 1; o.removeValue(forKey: "encryption")
        }
        return try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Crypto primitives

enum VaultCrypto {
    enum Purpose: String { case passphraseWrap = "passphrase-wrap", recoveryWrap = "recovery-wrap", file = "file" }

    /// format version || vault id || purpose || relative path, each length-prefixed (UInt32 big-endian) UTF-8.
    static func aad(vaultID: String, purpose: Purpose, path: String = "") -> Data {
        var d = Data()
        for field in ["2", vaultID, purpose.rawValue, path] {
            let b = Data(field.utf8)
            var n = UInt32(b.count).bigEndian
            d.append(Data(bytes: &n, count: 4)); d.append(b)
        }
        return d
    }

    static func seal(_ plain: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(), authenticating: aad), let c = box.combined
        else { throw VaultEncryptionError.ioFailure }
        return c
    }

    static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: combined), let p = try? AES.GCM.open(box, using: key, authenticating: aad)
        else { throw VaultEncryptionError.authenticationFailed }
        return p
    }

    static func pbkdf2(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard VaultEncryption.iterationBounds.contains(iterations) else { throw VaultEncryptionError.invalidMetadata }
        let pw = Array(VaultEncryption.normalise(passphrase).utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = pw.withUnsafeBufferPointer { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
            }
        }
        guard status == kCCSuccess else { throw VaultEncryptionError.ioFailure }
        defer { for i in out.indices { out[i] = 0 } }
        return SymmetricKey(data: out)
    }

    static func recoveryWrapKey(credential: Data, vaultID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: credential), salt: Data(vaultID.utf8),
                               info: Data("saga.vault.recovery-wrap.v1".utf8), outputByteCount: 32)
    }

    static func randomBytes(_ n: Int) throws -> Data {
        var b = [UInt8](repeating: 0, count: n)
        guard SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess else { throw VaultEncryptionError.ioFailure }
        return Data(b)
    }

    static func keyData(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }
}

// MARK: - Recovery code (Crockford Base32, 160 bits, group-of-5 display, one check character)

enum RecoveryCode {
    static let encodingID = "crockford-base32-v1"
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func checkIndex(_ values: [Int]) -> Int { values.enumerated().reduce(0) { ($0 + (2 * $1.offset + 1) * $1.element) % 32 } }

    static func encode(_ bytes: Data) -> String {
        precondition(bytes.count == 20)
        var values: [Int] = []; var buf = 0, bits = 0
        for b in bytes { buf = (buf << 8) | Int(b); bits += 8; while bits >= 5 { bits -= 5; values.append((buf >> bits) & 31) }; buf &= (1 << bits) - 1 }
        let all = values + [checkIndex(values)]
        let chars = all.map { String(alphabet[$0]) }
        return stride(from: 0, to: chars.count, by: 5).map { chars[$0..<min($0 + 5, chars.count)].joined() }.joined(separator: "-")
    }

    /// Normalises case/spaces/dashes (and Crockford look-alikes O→0, I/L→1) and validates length and check character.
    static func decode(_ typed: String) -> Data? {
        var values: [Int] = []
        for ch in typed.uppercased() where ch != " " && ch != "-" && ch != "\t" && ch != "\n" {
            let c: Character = ch == "O" ? "0" : (ch == "I" || ch == "L") ? "1" : ch
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            values.append(i)
        }
        guard values.count == 33, checkIndex(Array(values[0..<32])) == values[32] else { return nil }
        var out = Data(); var buf = 0, bits = 0
        for v in values[0..<32] { buf = (buf << 5) | v; bits += 5; if bits >= 8 { bits -= 8; out.append(UInt8((buf >> bits) & 255)); buf &= (1 << bits) - 1 } }
        return out.count == 20 ? out : nil
    }
}

// MARK: - Public API

public enum VaultEncryption {
    public static let minimumPassphraseLength = 10
    public static let defaultIterations = 600_000
    static let iterationBounds = 100_000...5_000_000

    /// Unicode NFC, no trimming.
    static func normalise(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// Parses and validates metadata without unlocking or modifying files.
    public static func protection(at url: URL) throws -> VaultProtection { try VaultMeta.read(at: url).protection }

    /// The vault's stable UUID (plaintext in vault.json).
    public static func vaultID(at url: URL) throws -> String { try VaultMeta.read(at: url).id }

    public static func prepare(vault: Vault, passphrase: String) throws -> VaultEncryptionSetup {
        let meta = try VaultMeta.read(at: vault.url)
        guard meta.protection == .plaintext else { throw VaultEncryptionError.unsupportedFormat }
        guard normalise(passphrase).count >= minimumPassphraseLength else { throw VaultEncryptionError.weakPassphrase }
        let key = SymmetricKey(size: .bits256)
        let dek = VaultCrypto.keyData(key)
        let salt = try VaultCrypto.randomBytes(16)
        let pk = try VaultCrypto.pbkdf2(passphrase: passphrase, salt: salt, iterations: defaultIterations)
        let pWrapped = try VaultCrypto.seal(dek, key: pk, aad: VaultCrypto.aad(vaultID: meta.id, purpose: .passphraseWrap))
        let credential = try VaultCrypto.randomBytes(20)
        let rk = VaultCrypto.recoveryWrapKey(credential: credential, vaultID: meta.id)
        let rWrapped = try VaultCrypto.seal(dek, key: rk, aad: VaultCrypto.aad(vaultID: meta.id, purpose: .recoveryWrap))
        let md = EncryptionMetadata(version: 1, cipher: "AES-256-GCM",
            passphrase: .init(kdf: "PBKDF2-HMAC-SHA256", iterations: defaultIterations, salt: salt.base64EncodedString(), keyBytes: 32, wrapped: pWrapped.base64EncodedString()),
            recovery: .init(kdf: "HKDF-SHA256", encoding: RecoveryCode.encodingID, wrapped: rWrapped.base64EncodedString()))
        // The wrappers must really open to this key before we ever hand them out.
        guard try unwrap(md.passphrase.wrapped, with: pk, vaultID: meta.id, purpose: .passphraseWrap) == dek,
              try unwrap(md.recovery.wrapped, with: rk, vaultID: meta.id, purpose: .recoveryWrap) == dek
        else { throw VaultEncryptionError.ioFailure }
        return VaultEncryptionSetup(vaultID: meta.id, recoveryCode: RecoveryCode.encode(credential),
                                    context: VaultUnlockContext(vaultID: meta.id, key: key), metadata: md, state: SetupState())
    }

    /// Validates the complete typed code; marks this exact setup confirmed. The typed secret is not retained.
    public static func confirmRecovery(_ typedCode: String, for setup: VaultEncryptionSetup) throws {
        guard let typed = RecoveryCode.decode(typedCode), let real = RecoveryCode.decode(setup.recoveryCode), typed == real
        else { throw VaultEncryptionError.recoveryNotConfirmed }
        setup.state.confirm()
    }

    public static func unlock(at url: URL, passphrase: String) throws -> VaultUnlockContext {
        let meta = try VaultMeta.read(at: url)
        guard let e = meta.encryption else { throw VaultEncryptionError.unsupportedFormat }
        guard let salt = Data(base64Encoded: e.passphrase.salt) else { throw VaultEncryptionError.invalidMetadata }
        let k = try VaultCrypto.pbkdf2(passphrase: passphrase, salt: salt, iterations: e.passphrase.iterations)
        do {
            let dek = try unwrap(e.passphrase.wrapped, with: k, vaultID: meta.id, purpose: .passphraseWrap)
            return VaultUnlockContext(vaultID: meta.id, key: SymmetricKey(data: dek))
        } catch { throw VaultEncryptionError.invalidCredential }
    }

    public static func recover(at url: URL, recoveryCode: String) throws -> VaultUnlockContext {
        let meta = try VaultMeta.read(at: url)
        guard let e = meta.encryption else { throw VaultEncryptionError.unsupportedFormat }
        guard let cred = RecoveryCode.decode(recoveryCode) else { throw VaultEncryptionError.invalidRecoveryCode }
        let k = VaultCrypto.recoveryWrapKey(credential: cred, vaultID: meta.id)
        do {
            let dek = try unwrap(e.recovery.wrapped, with: k, vaultID: meta.id, purpose: .recoveryWrap)
            return VaultUnlockContext(vaultID: meta.id, key: SymmetricKey(data: dek))
        } catch { throw VaultEncryptionError.invalidCredential }
    }

    /// Replaces only the passphrase wrapper (new salt and nonce). Segments, config and the recovery wrapper are untouched.
    public static func changePassphrase(at url: URL, context: VaultUnlockContext, newPassphrase: String) throws {
        let meta = try VaultMeta.read(at: url)
        guard var e = meta.encryption else { throw VaultEncryptionError.unsupportedFormat }
        guard context.vaultID == meta.id else { throw VaultEncryptionError.wrongVault }
        guard normalise(newPassphrase).count >= minimumPassphraseLength else { throw VaultEncryptionError.weakPassphrase }
        try ensureIdle(url)
        let salt = try VaultCrypto.randomBytes(16)
        let k = try VaultCrypto.pbkdf2(passphrase: newPassphrase, salt: salt, iterations: defaultIterations)
        let dek = VaultCrypto.keyData(context.key)
        let wrapped = try VaultCrypto.seal(dek, key: k, aad: VaultCrypto.aad(vaultID: meta.id, purpose: .passphraseWrap))
        guard try unwrap(wrapped.base64EncodedString(), with: k, vaultID: meta.id, purpose: .passphraseWrap) == dek else { throw VaultEncryptionError.ioFailure }
        e.passphrase = .init(kdf: "PBKDF2-HMAC-SHA256", iterations: defaultIterations, salt: salt.base64EncodedString(), keyBytes: 32, wrapped: wrapped.base64EncodedString())
        try writeMetadata(e, base: meta.raw, at: url)
    }

    /// Generates a new recovery code and replaces the recovery wrapper; the old code stops working. Returns the new code (sensitive).
    public static func rotateRecoveryCode(at url: URL, context: VaultUnlockContext) throws -> String {
        let meta = try VaultMeta.read(at: url)
        guard var e = meta.encryption else { throw VaultEncryptionError.unsupportedFormat }
        guard context.vaultID == meta.id else { throw VaultEncryptionError.wrongVault }
        try ensureIdle(url)
        let cred = try VaultCrypto.randomBytes(20)
        let rk = VaultCrypto.recoveryWrapKey(credential: cred, vaultID: meta.id)
        let wrapped = try VaultCrypto.seal(VaultCrypto.keyData(context.key), key: rk, aad: VaultCrypto.aad(vaultID: meta.id, purpose: .recoveryWrap))
        e.recovery.wrapped = wrapped.base64EncodedString()
        try writeMetadata(e, base: meta.raw, at: url)
        return RecoveryCode.encode(cred)
    }

    // MARK: internals

    static func unwrap(_ b64: String, with key: SymmetricKey, vaultID: String, purpose: VaultCrypto.Purpose) throws -> Data {
        guard let d = Data(base64Encoded: b64) else { throw VaultEncryptionError.invalidMetadata }
        return try VaultCrypto.open(d, key: key, aad: VaultCrypto.aad(vaultID: vaultID, purpose: purpose))
    }

    static func ensureIdle(_ url: URL) throws {
        if ConversionRegistry.isActive(url) || ConversionJournal.pending(for: url) { throw VaultEncryptionError.conversionInProgress }
    }

    static func writeMetadata(_ e: EncryptionMetadata, base: [String: Any], at url: URL) throws {
        let data = try VaultMeta.serialize(base: base, encryption: e)
        do { try data.write(to: url.appendingPathComponent("vault.json"), options: .atomic) } catch { throw VaultEncryptionError.ioFailure }
    }
}
