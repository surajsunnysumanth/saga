import Foundation
import CryptoKit

// Convert a vault to/from format 2 by building and verifying a NEW sibling folder, then swapping.
// The original is always kept (no delete-original API). See docs/tasks/02-encryption-contract.md §3 and §8.

public struct VaultConversionTicket: Sendable {
    enum Kind: String, Sendable { case encrypt, decrypt }
    let id: UUID
    let kind: Kind
    let source: URL
    let staging: URL
    let vaultID: String
    let inventory: [String: VaultConversion.Fingerprint]
}

public struct VaultConversionResult: Sendable {
    public let activeURL: URL
    public let retainedOriginalURL: URL
    public let protection: VaultProtection
}

public enum VaultConversionReconcile: Sendable, Equatable { case none, completed, rolledBack, ambiguous }

/// In-process exclusivity: while a conversion is staged, imports/config writes to that vault fail.
enum ConversionRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: [String: UUID] = [:]
    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    static func isActive(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return active[key(url)] != nil }
    static func begin(_ url: URL, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard active[key(url)] == nil else { throw VaultEncryptionError.conversionInProgress }
        active[key(url)] = id
    }
    static func holds(_ url: URL, id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return active[key(url)] == id }
    static func end(_ url: URL, id: UUID) { lock.lock(); if active[key(url)] == id { active[key(url)] = nil }; lock.unlock() }
}

/// On-disk journal next to the vault (never holds secrets): `.saga-conversion-<name>.json` in the parent folder.
enum ConversionJournal {
    struct Entry: Codable { var phase: String; var source: String; var staging: String; var retained: String; var kind: String; var vaultID: String }
    static func url(for source: URL) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(".saga-conversion-\(source.lastPathComponent).json")
    }
    static func read(for source: URL) -> Entry? {
        guard let d = try? Data(contentsOf: url(for: source)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }
    /// An unreadable journal counts as pending (fail closed); a "done" journal does not.
    static func pending(for source: URL) -> Bool {
        let f = url(for: source)
        guard FileManager.default.fileExists(atPath: f.path) else { return false }
        return read(for: source)?.phase != "done"
    }
    static func write(_ e: Entry, for source: URL) throws {
        do { try JSONEncoder().encode(e).write(to: url(for: source), options: .atomic) } catch { throw VaultEncryptionError.ioFailure }
    }
    static func remove(for source: URL) { try? FileManager.default.removeItem(at: url(for: source)) }
}

public enum VaultConversion {
    struct Fingerprint: Equatable, Sendable { var isDir: Bool; var size: Int64; var mtime: Double; var hash: String? }
    typealias Hook = @Sendable (String) throws -> Void

    public static func stageEncryption(vault: Vault, setup: VaultEncryptionSetup) throws -> VaultConversionTicket {
        try stageEncryption(vault: vault, setup: setup, hook: nil)
    }
    public static func stageDecryption(vault: Vault) throws -> VaultConversionTicket { try stageDecryption(vault: vault, hook: nil) }
    public static func commit(_ ticket: VaultConversionTicket) throws -> VaultConversionResult { try commit(ticket, hook: nil) }

    // MARK: inventory

    static func isProtected(_ rel: String, encrypted: Bool) -> Bool {
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[1].hasPrefix(".") else { return false }
        let n = parts[1]
        switch (parts[0], encrypted) {
        case ("segments", false): return n.hasSuffix(".ndjson.gz")
        case ("config", false): return n.hasSuffix(".json")
        case ("segments", true): return n.hasSuffix(".ndjson.gz.enc")
        case ("config", true): return n.hasSuffix(".json.enc")
        default: return false
        }
    }

    static func inventory(of root: URL, hashProtected encrypted: Bool) throws -> [String: Fingerprint] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { throw VaultEncryptionError.ioFailure }
        var out: [String: Fingerprint] = [:]
        let base = root.standardizedFileURL.path
        for case let u as URL in en {
            try checkCancelled()
            let v = try u.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { throw VaultEncryptionError.ioFailure }       // unsafe: refuse rather than follow
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            let isDir = v.isDirectory == true
            var hash: String?
            if !isDir, isProtected(rel, encrypted: encrypted) || rel == "vault.json" {
                guard let d = try? Data(contentsOf: u, options: .mappedIfSafe) else { throw VaultEncryptionError.ioFailure }
                hash = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            }
            out[rel] = Fingerprint(isDir: isDir, size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0, hash: hash)
        }
        return out
    }

    static func checkCancelled() throws { if Task.isCancelled { throw VaultEncryptionError.cancelled } }

    static func stagingURL(for source: URL) -> URL {
        source.deletingLastPathComponent().appendingPathComponent("\(source.lastPathComponent).saga-converting-\(UUID().uuidString.prefix(8).lowercased())")
    }

    // MARK: staging

    static func stageEncryption(vault: Vault, setup: VaultEncryptionSetup, hook: Hook?) throws -> VaultConversionTicket {
        guard vault.protection == .plaintext else { throw VaultEncryptionError.unsupportedFormat }
        guard setup.vaultID == vault.id else { throw VaultEncryptionError.wrongVault }
        guard setup.state.confirmed else { throw VaultEncryptionError.recoveryNotConfirmed }
        return try stage(vault: vault, kind: .encrypt, setup: setup, hook: hook)
    }

    static func stageDecryption(vault: Vault, hook: Hook?) throws -> VaultConversionTicket {
        guard vault.protection == .encrypted else { throw VaultEncryptionError.unsupportedFormat }
        _ = try vault.key()                                    // must already be unlocked
        return try stage(vault: vault, kind: .decrypt, setup: nil, hook: hook)
    }

    private static func stage(vault: Vault, kind: VaultConversionTicket.Kind, setup: VaultEncryptionSetup?, hook: Hook?) throws -> VaultConversionTicket {
        let fm = FileManager.default
        let source = vault.url
        let ticketID = UUID()
        try ConversionRegistry.begin(source, id: ticketID)
        if ConversionJournal.pending(for: source) { ConversionRegistry.end(source, id: ticketID); throw VaultEncryptionError.conversionInProgress }
        let staging = stagingURL(for: source)
        var created = false
        do {
            try vault.checkRepresentation()
            let inv = try inventory(of: source, hashProtected: kind == .decrypt)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            created = true
            let toEncrypted = kind == .encrypt
            for rel in inv.keys.sorted() {
                try checkCancelled()
                let src = source.appendingPathComponent(rel), dst = staging.appendingPathComponent(rel)
                if inv[rel]!.isDir { try fm.createDirectory(at: dst, withIntermediateDirectories: true); continue }
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if rel == "vault.json" { continue }
                if isProtected(rel, encrypted: !toEncrypted) {
                    let plain = try vault.read(protected: src, logicalPath: toEncrypted ? rel : String(rel.dropLast(4)))
                    if toEncrypted {
                        try vault.sealForConversion(plain, setup: setup!, logicalPath: rel).write(to: URL(fileURLWithPath: dst.path + ".enc"))
                    } else {
                        try plain.write(to: dst.deletingPathExtension())
                    }
                } else {
                    try fm.copyItem(at: src, to: dst)
                }
                try hook?("staged:\(rel)")
            }
            let newMeta = try VaultMeta.serialize(base: vault.meta.raw, encryption: toEncrypted ? setup!.metadata : nil)
            try newMeta.write(to: staging.appendingPathComponent("vault.json"))
            try hook?("metadata-written")

            try verify(source: vault, staging: staging, kind: kind, setup: setup, inventory: inv)
            try hook?("verified")
            return VaultConversionTicket(id: ticketID, kind: kind, source: source, staging: staging, vaultID: vault.id, inventory: inv)
        } catch {
            if created { try? fm.removeItem(at: staging) }
            ConversionRegistry.end(source, id: ticketID)
            throw map(error)
        }
    }

    static func map(_ e: Error) -> Error {
        if e is VaultEncryptionError { return e }
        if e is CancellationError { return VaultEncryptionError.cancelled }
        return VaultEncryptionError.ioFailure
    }

    /// A real dry run: reopen the staged vault from its on-disk wrappers, authenticate/decrypt every protected file,
    /// compare to the source bytes, and build a scratch index.
    private static func verify(source: Vault, staging: URL, kind: VaultConversionTicket.Kind, setup: VaultEncryptionSetup?,
                               inventory inv: [String: Fingerprint]) throws {
        let ctx: VaultUnlockContext?
        if kind == .encrypt {
            ctx = try VaultEncryption.recover(at: staging, recoveryCode: setup!.recoveryCode)     // opens the recovery wrapper from disk
            guard ctx!.sameKey(as: setup!.context) else { throw VaultEncryptionError.authenticationFailed }
        } else { ctx = nil }
        let target = try Vault(url: staging, create: false, unlockContext: ctx, ignoreJournal: true)
        guard target.protection == (kind == .encrypt ? .encrypted : .plaintext), target.id == source.id else { throw VaultEncryptionError.invalidMetadata }
        let toEncrypted = kind == .encrypt
        var expected = Set<String>()
        for rel in inv.keys.sorted() where !(inv[rel]!.isDir) && rel != "vault.json" {
            try checkCancelled()
            if isProtected(rel, encrypted: !toEncrypted) {
                let tRel = toEncrypted ? rel + ".enc" : String(rel.dropLast(4))
                expected.insert(tRel)
                let t = staging.appendingPathComponent(tRel)
                let original = try source.read(protected: source.url.appendingPathComponent(rel), logicalPath: toEncrypted ? rel : String(rel.dropLast(4)))
                let roundTrip = try target.read(protected: t, logicalPath: toEncrypted ? rel : tRel)
                guard original == roundTrip else { throw VaultEncryptionError.authenticationFailed }
                if toEncrypted, original.count >= 16, let raw = try? Data(contentsOf: t), raw.range(of: original.prefix(16)) != nil { throw VaultEncryptionError.authenticationFailed }
            } else {
                expected.insert(rel)
                guard FileManager.default.fileExists(atPath: staging.appendingPathComponent(rel).path) else { throw VaultEncryptionError.ioFailure }
            }
        }
        // no extra/missing files besides vault.json and directories
        let actual = try Self.inventory(of: staging, hashProtected: false)
        let actualFiles = Set(actual.filter { !$0.value.isDir && $0.key != "vault.json" }.keys)
        guard actualFiles == expected else { throw VaultEncryptionError.invalidMetadata }
        // semantics: same message set; a scratch index builds from the staged vault
        let a = try source.knownUIDs(), b = try target.knownUIDs()
        guard a == b else { throw VaultEncryptionError.authenticationFailed }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("saga-verify-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try VaultIndexer.build(vault: target, out: scratch.path)
    }

    // MARK: commit / cancel / reconcile

    static func commit(_ ticket: VaultConversionTicket, hook: Hook?) throws -> VaultConversionResult {
        let fm = FileManager.default
        guard ConversionRegistry.holds(ticket.source, id: ticket.id), fm.fileExists(atPath: ticket.staging.path) else { throw VaultEncryptionError.conversionInProgress }
        // source must be exactly what was verified
        let now = try inventory(of: ticket.source, hashProtected: ticket.kind == .decrypt)
        guard now == ticket.inventory else { throw VaultEncryptionError.sourceChanged }
        try checkCancelled()

        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"; df.timeZone = TimeZone(identifier: "UTC")
        let label = ticket.kind == .encrypt ? "plaintext" : "encrypted"
        let retained = ticket.source.deletingLastPathComponent().appendingPathComponent(
            "\(ticket.source.lastPathComponent).original-\(label)-\(df.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased())")
        var entry = ConversionJournal.Entry(phase: "prepared", source: ticket.source.path, staging: ticket.staging.path,
                                            retained: retained.path, kind: ticket.kind.rawValue, vaultID: ticket.vaultID)
        try ConversionJournal.write(entry, for: ticket.source)
        func rollback() {
            if fm.fileExists(atPath: retained.path) {          // the source was moved aside: put everything back
                if fm.fileExists(atPath: ticket.source.path) { try? fm.moveItem(at: ticket.source, to: ticket.staging) }
                try? fm.moveItem(at: retained, to: ticket.source)
            }
            ConversionJournal.remove(for: ticket.source)
        }
        do {
            try hook?("journal-written")
            try fm.moveItem(at: ticket.source, to: retained)
            entry.phase = "source-moved"; try ConversionJournal.write(entry, for: ticket.source)
            try hook?("source-moved")
            try fm.moveItem(at: ticket.staging, to: ticket.source)
            entry.phase = "activated"; try ConversionJournal.write(entry, for: ticket.source)
            try hook?("activated")
            // reopen the active target
            let active = try Vault(url: ticket.source, create: false, unlockContext: nil, ignoreJournal: true)
            guard active.protection == (ticket.kind == .encrypt ? .encrypted : .plaintext), active.id == ticket.vaultID else { throw VaultEncryptionError.invalidMetadata }
            try hook?("reopened")
        } catch {
            rollback()
            ConversionRegistry.end(ticket.source, id: ticket.id)
            throw map(error)
        }
        entry.phase = "done"
        if (try? ConversionJournal.write(entry, for: ticket.source)) != nil { ConversionJournal.remove(for: ticket.source) }
        ConversionRegistry.end(ticket.source, id: ticket.id)
        return VaultConversionResult(activeURL: ticket.source, retainedOriginalURL: retained,
                                     protection: ticket.kind == .encrypt ? .encrypted : .plaintext)
    }

    /// Removes only this operation's own staging folder; never the source, retained original or active vault.
    public static func cancel(_ ticket: VaultConversionTicket) throws {
        defer { ConversionRegistry.end(ticket.source, id: ticket.id) }
        let st = ticket.staging.standardizedFileURL
        guard st.deletingLastPathComponent() == ticket.source.deletingLastPathComponent().standardizedFileURL,
              st.lastPathComponent.contains(".saga-converting-"), st.path != ticket.source.standardizedFileURL.path else { throw VaultEncryptionError.ioFailure }
        if FileManager.default.fileExists(atPath: st.path) {
            do { try FileManager.default.removeItem(at: st) } catch { throw VaultEncryptionError.ioFailure }
        }
    }

    /// Call before opening/creating a vault at `url` after a crash. Completes or rolls back an interrupted swap;
    /// when the state is ambiguous it changes nothing.
    public static func reconcile(at url: URL) throws -> VaultConversionReconcile {
        let fm = FileManager.default
        guard let e = ConversionJournal.read(for: url) else {
            return fm.fileExists(atPath: ConversionJournal.url(for: url).path) ? .ambiguous : .none
        }
        let staging = URL(fileURLWithPath: e.staging), retained = URL(fileURLWithPath: e.retained)
        let hasSource = fm.fileExists(atPath: url.path), hasStaging = fm.fileExists(atPath: staging.path), hasRetained = fm.fileExists(atPath: retained.path)
        func finish(_ r: VaultConversionReconcile) -> VaultConversionReconcile { ConversionJournal.remove(for: url); return r }
        switch (hasSource, hasStaging, hasRetained) {
        case (true, false, true):
            guard (try? Vault(url: url, create: false, unlockContext: nil, ignoreJournal: true)) != nil else { return .ambiguous }
            return finish(.completed)
        case (false, true, true):
            do { try fm.moveItem(at: staging, to: url) } catch { throw VaultEncryptionError.ioFailure }
            return finish(.completed)
        case (true, true, false):
            return finish(.rolledBack)         // source never moved; staging left for the user/cancel
        case (true, false, false) where e.phase == "done":
            return finish(.completed)
        default:
            return .ambiguous
        }
    }
}

extension Vault {
    func sealForConversion(_ plain: Data, setup: VaultEncryptionSetup, logicalPath: String) throws -> Data {
        try VaultCrypto.seal(plain, key: setup.context.key, aad: VaultCrypto.aad(vaultID: setup.vaultID, purpose: .file, path: logicalPath))
    }
}
