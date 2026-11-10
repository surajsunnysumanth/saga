import XCTest
@testable import SagaCore

/// End-to-end integration of the encryption feature with the recovery workflow and the index:
/// encrypt → reopen → rebuild → decrypt → byte-compare, plus recovery on a fresh (empty Keychain) profile.
/// Synthetic fixtures only; no real Keychain, vault or user data is touched.
final class VaultEncryptionIntegrationTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try EncFixtures.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func indexCounts(_ v: Vault, out: String) throws -> Int {
        let s = try VaultIndexer.build(vault: v, out: out)
        return s.messages
    }

    /// E03 + I01: the full round trip rebuilds the disposable index at each protection level and
    /// returns the vault to byte-identical segments/config, with UID semantics unchanged.
    func testEncryptRebuildDecryptRoundTrip() throws {
        let plain = try EncFixtures.plainVault(in: dir)
        let originalFiles = try EncFixtures.files(plain.url)
        let originalUIDs = try plain.knownUIDs()

        // encrypt
        let setup = try VaultEncryption.prepare(vault: plain, passphrase: "correct horse battery")
        try VaultEncryption.confirmRecovery(setup.recoveryCode, for: setup)
        let encResult = try VaultConversion.commit(try VaultConversion.stageEncryption(vault: plain, setup: setup))
        XCTAssertEqual(encResult.protection, .encrypted)

        // reopen unlocked and rebuild the index (the app does this after commit)
        let ctx = try VaultEncryption.unlock(at: encResult.activeURL, passphrase: "correct horse battery")
        let encrypted = try Vault(url: encResult.activeURL, create: false, unlockContext: ctx)
        XCTAssertEqual(try encrypted.knownUIDs(), originalUIDs)
        XCTAssertEqual(try indexCounts(encrypted, out: dir.appendingPathComponent("enc.db").path), 2)

        // decrypt into a new folder and rebuild again
        let decResult = try VaultConversion.commit(try VaultConversion.stageDecryption(vault: encrypted))
        XCTAssertEqual(decResult.protection, .plaintext)
        let decrypted = try Vault(url: decResult.activeURL, create: false)
        XCTAssertEqual(try decrypted.knownUIDs(), originalUIDs)
        XCTAssertEqual(try indexCounts(decrypted, out: dir.appendingPathComponent("dec.db").path), 2)

        // byte-compare original segments + config (vault.json legitimately differs in format/id)
        let restored = try EncFixtures.files(decResult.activeURL)
        for (k, d) in originalFiles where k != "vault.json" { XCTAssertEqual(restored[k], d, k) }
        // both retained copies still exist — nothing was auto-deleted
        XCTAssertTrue(FileManager.default.fileExists(atPath: encResult.retainedOriginalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: decResult.retainedOriginalURL.path))
        XCTAssertEqual(try VaultEncryption.vaultID(at: decResult.activeURL), plain.id)
    }

    /// R03: recovery works on a fresh Mac (empty Keychain and no local index), and the passphrase can
    /// be reset afterwards without invalidating the recovery code.
    func testRecoveryOnFreshProfileThenResetPassphrase() throws {
        let plain = try EncFixtures.plainVault(in: dir)
        let setup = try VaultEncryption.prepare(vault: plain, passphrase: "correct horse battery")
        try VaultEncryption.confirmRecovery(setup.recoveryCode, for: setup)
        let r = try VaultConversion.commit(try VaultConversion.stageEncryption(vault: plain, setup: setup))

        // fresh profile: empty Keychain store → the remembered-open path fails closed
        let freshStore = InMemoryKeyStore()
        XCTAssertThrowsError(try Vault.open(url: r.activeURL, store: freshStore)) { XCTAssertEqual($0 as? VaultEncryptionError, .locked) }

        // recover with the kit code alone (no Keychain, no local index, no defaults)
        let ctx = try VaultEncryption.recover(at: r.activeURL, recoveryCode: setup.recoveryCode.lowercased())
        let unlocked = try Vault(url: r.activeURL, create: false, unlockContext: ctx)
        XCTAssertEqual(try unlocked.knownUIDs().count, 2)
        XCTAssertEqual(try indexCounts(unlocked, out: dir.appendingPathComponent("recovered.db").path), 2)

        // reset the passphrase, then reopen with the new one; the old one stops working and recovery stays valid
        try VaultEncryption.changePassphrase(at: r.activeURL, context: ctx, newPassphrase: "a completely new passphrase")
        XCTAssertNoThrow(try VaultEncryption.unlock(at: r.activeURL, passphrase: "a completely new passphrase"))
        XCTAssertThrowsError(try VaultEncryption.unlock(at: r.activeURL, passphrase: "correct horse battery")) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidCredential) }
        XCTAssertNoThrow(try VaultEncryption.recover(at: r.activeURL, recoveryCode: setup.recoveryCode))
    }

    /// R03 failure cases: malformed and wrong codes fail without mutating anything.
    func testInvalidRecoveryCodesLeaveVaultUntouched() throws {
        let (_, _, r) = try EncFixtures.encrypted(in: dir)
        let before = try EncFixtures.files(r.activeURL)

        XCTAssertThrowsError(try VaultEncryption.recover(at: r.activeURL, recoveryCode: "not-a-code")) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidRecoveryCode) }
        let wrongValid = RecoveryCode.encode(try VaultCrypto.randomBytes(20))
        XCTAssertThrowsError(try VaultEncryption.recover(at: r.activeURL, recoveryCode: wrongValid)) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidCredential) }

        XCTAssertEqual(try EncFixtures.files(r.activeURL), before)   // no on-disk change
    }

    /// E01: an existing plaintext (format 1) vault opens, ingests and rebuilds with no upgrade,
    /// no encryption metadata and no password prompt.
    func testPlaintextVaultBehaviourIsUnchanged() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let meta = try Data(contentsOf: v.url.appendingPathComponent("vault.json"))
        XCTAssertEqual(v.protection, .plaintext)
        XCTAssertEqual(try VaultEncryption.protection(at: v.url), .plaintext)
        XCTAssertEqual(try indexCounts(v, out: dir.appendingPathComponent("plain.db").path), 2)
        XCTAssertEqual(try Data(contentsOf: v.url.appendingPathComponent("vault.json")), meta)   // untouched
        XCTAssertTrue(try EncFixtures.files(v.url).keys.allSatisfy { !$0.hasSuffix(".enc") })
        // the remembered-open path also works unchanged for plaintext
        XCTAssertEqual(try Vault.open(url: v.url).knownUIDs().count, 2)
    }

    /// I01: the conversion keeps the original copy and the active vault is the only thing that changed identity.
    func testConversionKeepsOriginalAndJournalCleansUp() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let setup = try VaultEncryption.prepare(vault: v, passphrase: "correct horse battery")
        try VaultEncryption.confirmRecovery(setup.recoveryCode, for: setup)
        let r = try VaultConversion.commit(try VaultConversion.stageEncryption(vault: v, setup: setup))
        XCTAssertEqual(try VaultEncryption.protection(at: r.activeURL), .encrypted)
        XCTAssertEqual(try VaultEncryption.protection(at: r.retainedOriginalURL), .plaintext)
        XCTAssertEqual(try EncFixtures.files(r.retainedOriginalURL).keys.filter { $0.hasSuffix(".enc") }.count, 0)
        // no journal or staging folder remains after a clean commit
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConversionJournal.url(for: v.url).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(leftovers.contains { $0.contains("saga-converting") }, "\(leftovers)")
        XCTAssertEqual(try VaultConversion.reconcile(at: r.activeURL), .none)
    }
}
