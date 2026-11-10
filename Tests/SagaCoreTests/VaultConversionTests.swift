import XCTest
@testable import SagaCore

final class FaultBox: @unchecked Sendable {
    let phase: String; private(set) var hit = false
    init(_ p: String) { phase = p }
    func check(_ p: String) throws { if p == phase || (phase.hasSuffix("*") && p.hasPrefix(phase.dropLast())) { hit = true; throw VaultEncryptionError.ioFailure } }
}

final class VaultConversionTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try EncFixtures.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func siblings(_ name: String = "vault") throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != name }.sorted()
    }

    func confirmedSetup(_ v: Vault) throws -> VaultEncryptionSetup {
        let s = try VaultEncryption.prepare(vault: v, passphrase: "correct horse battery")
        try VaultEncryption.confirmRecovery(s.recoveryCode, for: s); return s
    }

    func testEncryptThenDecryptRoundTripKeepsOriginalsAndBytes() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let original = try EncFixtures.files(v.url)
        let setup = try confirmedSetup(v)

        let r = try VaultConversion.commit(try VaultConversion.stageEncryption(vault: v, setup: setup))
        XCTAssertEqual(r.protection, .encrypted)
        // retained original is byte-identical and still plaintext
        XCTAssertEqual(try EncFixtures.files(r.retainedOriginalURL), original)
        XCTAssertEqual(try VaultEncryption.protection(at: r.retainedOriginalURL), .plaintext)
        // ciphertext contains no sentinel; unprotected files are preserved verbatim
        let enc = try EncFixtures.files(r.activeURL)
        for (k, d) in enc where k != "config/overrides.csv" && k != "media/a.jpg" { XCTAssertNil(d.range(of: Data(EncFixtures.sentinel.utf8)), k) }
        XCTAssertEqual(enc["media/a.jpg"], original["media/a.jpg"]); XCTAssertEqual(enc["config/overrides.csv"], original["config/overrides.csv"])
        XCTAssertTrue(enc.keys.contains("config/future-thing.json.enc"))          // unknown JSON is protected too
        XCTAssertFalse(enc.keys.contains("config/contacts.json"))
        XCTAssertFalse(try siblings().contains { $0.contains("saga-converting") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConversionJournal.url(for: v.url).path))

        // unlock → same data → decrypt
        let ctx = try VaultEncryption.unlock(at: r.activeURL, passphrase: "correct horse battery")
        let ev = try Vault(url: r.activeURL, create: false, unlockContext: ctx)
        XCTAssertEqual(try ev.knownUIDs().keys.sorted(), ["u1", "u2"])
        let back = try VaultConversion.commit(try VaultConversion.stageDecryption(vault: ev))
        XCTAssertEqual(back.protection, .plaintext)
        let restored = try EncFixtures.files(back.activeURL)
        for (k, d) in original where k != "vault.json" { XCTAssertEqual(restored[k], d, k) }     // gzip segments + config JSON byte-identical
        XCTAssertEqual(try EncFixtures.files(back.retainedOriginalURL).keys.filter { $0.hasSuffix(".enc") }.count, 3)   // encrypted copy retained
        XCTAssertEqual(try VaultEncryption.protection(at: back.activeURL), .plaintext)
        // vault id preserved through both conversions
        XCTAssertEqual(try VaultEncryption.vaultID(at: back.activeURL), v.id)
    }

    func testDecryptionRequiresUnlockedEncryptedVault() throws {
        let v = try EncFixtures.plainVault(in: dir)
        XCTAssertThrowsError(try VaultConversion.stageDecryption(vault: v))
        let (_, _, r) = try EncFixtures.encrypted(in: try EncFixtures.tempDir())
        defer { try? FileManager.default.removeItem(at: r.activeURL.deletingLastPathComponent()) }
        let locked = try Vault(url: r.activeURL, create: false)
        XCTAssertThrowsError(try VaultConversion.stageDecryption(vault: locked)) { XCTAssertEqual($0 as? VaultEncryptionError, .locked) }
        XCTAssertThrowsError(try VaultConversion.stageEncryption(vault: locked, setup: try confirmedSetup(v)))
    }

    func testStagingFailureLeavesOriginalIntactAndCleansUp() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let before = try EncFixtures.files(v.url)
        let setup = try confirmedSetup(v)
        for phase in ["staged:*", "metadata-written", "verified"] {
            let box = FaultBox(phase)
            XCTAssertThrowsError(try VaultConversion.stageEncryption(vault: v, setup: setup, hook: { try box.check($0) }))
            XCTAssertTrue(box.hit, phase)
            XCTAssertEqual(try EncFixtures.files(v.url), before)
            XCTAssertEqual(try siblings(), [], phase)                                   // staging removed
            XCTAssertFalse(ConversionRegistry.isActive(v.url))
        }
        XCTAssertNoThrow(try v.ingestNothingCheck())
    }

    func testEveryCommitFaultPointKeepsUsableOriginal() throws {
        for phase in ["journal-written", "source-moved", "activated", "reopened"] {
            let d = try EncFixtures.tempDir(); defer { try? FileManager.default.removeItem(at: d) }
            let v = try EncFixtures.plainVault(in: d)
            let before = try EncFixtures.files(v.url)
            let setup = try confirmedSetup(v)
            let t = try VaultConversion.stageEncryption(vault: v, setup: setup)
            let box = FaultBox(phase)
            XCTAssertThrowsError(try VaultConversion.commit(t, hook: { try box.check($0) }), phase)
            XCTAssertTrue(box.hit)
            XCTAssertEqual(try EncFixtures.files(v.url), before, phase)               // original restored exactly, plaintext, usable
            XCTAssertEqual(try Vault(url: v.url, create: false).knownUIDs().count, 2, phase)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ConversionJournal.url(for: v.url).path), phase)
            XCTAssertFalse(ConversionRegistry.isActive(v.url), phase)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: d.path).contains { $0.contains(".original-") }, phase)
        }
    }

    func testSourceChangedBeforeCommitIsRefused() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let setup = try confirmedSetup(v)
        let t = try VaultConversion.stageEncryption(vault: v, setup: setup)
        XCTAssertThrowsError(try v.writeConfig(Data("{}".utf8), name: "contacts.json")) { XCTAssertEqual($0 as? VaultEncryptionError, .conversionInProgress) }   // app writes are blocked
        try Data("changed externally".utf8).write(to: v.url.appendingPathComponent("config/overrides.csv"))             // external/cloud change
        XCTAssertThrowsError(try VaultConversion.commit(t)) { XCTAssertEqual($0 as? VaultEncryptionError, .sourceChanged) }
        XCTAssertEqual(try VaultEncryption.protection(at: v.url), .plaintext)
        try VaultConversion.cancel(t)
        XCTAssertEqual(try siblings(), [])
        XCTAssertNoThrow(try v.writeConfig(Data("{}".utf8), name: "contacts.json"))   // exclusivity released
    }

    func testCancelRemovesOnlyStaging() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let before = try EncFixtures.files(v.url)
        let t = try VaultConversion.stageEncryption(vault: v, setup: try confirmedSetup(v))
        XCTAssertEqual(try siblings().count, 1)
        try VaultConversion.cancel(t)
        XCTAssertEqual(try siblings(), [])
        XCTAssertEqual(try EncFixtures.files(v.url), before)
    }

    func testSymlinkInVaultIsRefused() throws {
        let v = try EncFixtures.plainVault(in: dir)
        try FileManager.default.createSymbolicLink(at: v.url.appendingPathComponent("media/link"), withDestinationURL: dir)
        XCTAssertThrowsError(try VaultConversion.stageEncryption(vault: v, setup: try confirmedSetup(v))) { XCTAssertEqual($0 as? VaultEncryptionError, .ioFailure) }
        XCTAssertEqual(try siblings(), [])
        XCTAssertFalse(ConversionRegistry.isActive(v.url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: v.url.appendingPathComponent("segments/seg-a.ndjson.gz").path))
    }

    func testDamagedSourceSegmentFailsStagingWithoutChanges() throws {
        let (v, _, r) = try EncFixtures.encrypted(in: dir)
        var seg = try Data(contentsOf: v.segmentFiles()[0]); seg[30] ^= 1
        try seg.write(to: v.segmentFiles()[0])
        let before = try EncFixtures.files(r.activeURL)
        XCTAssertThrowsError(try VaultConversion.stageDecryption(vault: v)) { XCTAssertEqual($0 as? VaultEncryptionError, .authenticationFailed) }
        XCTAssertEqual(try EncFixtures.files(r.activeURL), before)
        XCTAssertEqual(try siblings(), [r.retainedOriginalURL.lastPathComponent])   // only the retained plaintext copy
    }

    func testPendingJournalBlocksOpeningAndReconcileCompletesInterruptedSwap() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let setup = try confirmedSetup(v)
        let t = try VaultConversion.stageEncryption(vault: v, setup: setup)
        // Simulate a crash after the source was moved aside but before staging was activated.
        let retained = dir.appendingPathComponent("vault.original-plaintext-crash")
        try FileManager.default.moveItem(at: v.url, to: retained)
        try ConversionJournal.write(.init(phase: "source-moved", source: v.url.path, staging: t.staging.path, retained: retained.path,
                                          kind: "encrypt", vaultID: v.id), for: v.url)
        XCTAssertThrowsError(try Vault(url: v.url, create: true)) { XCTAssertEqual($0 as? VaultEncryptionError, .conversionInProgress) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.url.path), "must not create an empty vault while a swap is pending")
        XCTAssertEqual(try VaultConversion.reconcile(at: v.url), .completed)
        XCTAssertEqual(try VaultEncryption.protection(at: v.url), .encrypted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertNoThrow(try VaultEncryption.unlock(at: v.url, passphrase: "correct horse battery"))
        ConversionRegistry.end(v.url, id: t.id)
    }

    func testReconcileAmbiguousChangesNothing() throws {
        let v = try EncFixtures.plainVault(in: dir)
        try ConversionJournal.write(.init(phase: "source-moved", source: v.url.path, staging: dir.appendingPathComponent("nope").path,
                                          retained: dir.appendingPathComponent("nope2").path, kind: "encrypt", vaultID: v.id), for: v.url)
        XCTAssertEqual(try VaultConversion.reconcile(at: v.url), .ambiguous)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ConversionJournal.url(for: v.url).path))
        XCTAssertEqual(try VaultConversion.reconcile(at: dir.appendingPathComponent("other")), .none)
    }
}

extension Vault {
    /// Test convenience: the vault is still writable/readable.
    func ingestNothingCheck() throws { try ensureWritable(); _ = try knownUIDs() }
}
