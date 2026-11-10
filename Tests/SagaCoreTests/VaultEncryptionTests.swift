import XCTest
import CommonCrypto
@testable import SagaCore

/// Shared synthetic-vault helpers for the encryption suites.
enum EncFixtures {
    static let sentinel = "SENTINEL-secret-message-text"

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("saga-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Plaintext vault with one segment, config files and an unprotected media file.
    static func plainVault(in dir: URL, name: String = "vault") throws -> Vault {
        let v = try Vault(url: dir.appendingPathComponent(name))
        let ndjson = """
        {"k":"seg","fmt":1}
        {"k":"chat","jid":"1@s.whatsapp.net","g":0,"j":"1@s.whatsapp.net"}
        {"k":"m","u":"u1","c":"1@s.whatsapp.net","fm":0,"ts":1000,"ty":0,"tx":"\(sentinel)","kid":"k1"}
        {"k":"m","u":"u2","c":"1@s.whatsapp.net","fm":1,"ts":2000,"ty":0,"tx":"second","kid":"k2"}

        """
        try Gzip.compress(Data(ndjson.utf8)).write(to: v.segmentsDir.appendingPathComponent("seg-a.ndjson.gz"))
        try v.writeConfig(Data(#"{"1":"\#(sentinel)-contact"}"#.utf8), name: "contacts.json")
        try v.writeConfig(Data(#"{"future":true}"#.utf8), name: "future-thing.json")
        try Data("a,b\n".utf8).write(to: v.url.appendingPathComponent("config/overrides.csv"))
        try Data("media-bytes".utf8).write(to: v.url.appendingPathComponent("media/a.jpg"))
        return v
    }

    static func files(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let base = root.standardizedFileURL.path
        for case let u as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])! {
            if (try u.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { continue }
            out[String(u.standardizedFileURL.path.dropFirst(base.count + 1))] = try Data(contentsOf: u)
        }
        return out
    }

    static func encrypted(in dir: URL, passphrase: String = "correct horse battery") throws -> (Vault, VaultEncryptionSetup, VaultConversionResult) {
        let v = try plainVault(in: dir)
        let setup = try VaultEncryption.prepare(vault: v, passphrase: passphrase)
        try VaultEncryption.confirmRecovery(setup.recoveryCode, for: setup)
        let t = try VaultConversion.stageEncryption(vault: v, setup: setup)
        let r = try VaultConversion.commit(t)
        return (try Vault(url: r.activeURL, create: false, unlockContext: setup.context), setup, r)
    }
}

final class InMemoryKeyStore: VaultKeyStore, @unchecked Sendable {
    var items: [String: Data] = [:]; var failing = false
    func read(account: String) throws -> Data? { if failing { throw VaultEncryptionError.keychainUnavailable }; return items[account] }
    func write(_ data: Data, account: String) throws { if failing { throw VaultEncryptionError.keychainUnavailable }; items[account] = data }
    func remove(account: String) throws { if failing { throw VaultEncryptionError.keychainUnavailable }; items[account] = nil }
}

final class VaultEncryptionTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try EncFixtures.tempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPBKDF2KnownVector() throws {      // RFC 7914 §11: PBKDF2-HMAC-SHA256, c=1, dkLen=32
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array("passwd".utf8), salt = Array("salt".utf8)
        XCTAssertEqual(CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count, salt, salt.count,
                                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 1, &out, 32), Int32(kCCSuccess))
        XCTAssertEqual(out.map { String(format: "%02x", $0) }.joined(), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    func testPBKDF2RejectsOutOfBoundsIterations() {
        XCTAssertThrowsError(try VaultCrypto.pbkdf2(passphrase: "x", salt: Data(count: 16), iterations: 99_999))
        XCTAssertThrowsError(try VaultCrypto.pbkdf2(passphrase: "x", salt: Data(count: 16), iterations: 5_000_001))
    }

    func testRecoveryCodeFormatAndNormalisation() throws {
        let bytes = try VaultCrypto.randomBytes(20)
        let code = RecoveryCode.encode(bytes)
        XCTAssertEqual(code.split(separator: "-").map(\.count), [5, 5, 5, 5, 5, 5, 3])
        XCTAssertEqual(RecoveryCode.decode(code), bytes)
        XCTAssertEqual(RecoveryCode.decode(code.lowercased().replacingOccurrences(of: "-", with: " ")), bytes)
        var chars = Array(code); let i = chars.firstIndex { $0 != "-" }!
        chars[i] = chars[i] == "A" ? "B" : "A"                                    // single-character typo is caught by the check character
        XCTAssertNil(RecoveryCode.decode(String(chars)))
        XCTAssertNil(RecoveryCode.decode("short"))
        XCTAssertNil(RecoveryCode.decode(code + "0"))
        XCTAssertNotEqual(RecoveryCode.encode(try VaultCrypto.randomBytes(20)), code)     // fresh randomness
    }

    func testPrepareUnlockRecoverAndFailures() throws {
        let (v, setup, r) = try EncFixtures.encrypted(in: dir)
        XCTAssertEqual(try VaultEncryption.protection(at: r.activeURL), .encrypted)
        XCTAssertEqual(v.protection, .encrypted)
        let a = try VaultEncryption.unlock(at: r.activeURL, passphrase: "correct horse battery")
        let b = try VaultEncryption.recover(at: r.activeURL, recoveryCode: setup.recoveryCode.lowercased())
        XCTAssertTrue(a.sameKey(as: b)); XCTAssertTrue(a.sameKey(as: setup.context))
        XCTAssertThrowsError(try VaultEncryption.unlock(at: r.activeURL, passphrase: "wrong passphrase!")) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidCredential) }
        XCTAssertThrowsError(try VaultEncryption.recover(at: r.activeURL, recoveryCode: "nope")) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidRecoveryCode) }
        let other = RecoveryCode.encode(try VaultCrypto.randomBytes(20))
        XCTAssertThrowsError(try VaultEncryption.recover(at: r.activeURL, recoveryCode: other)) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidCredential) }
        XCTAssertFalse(String(describing: a).contains("key"), "context description must be redacted")
        XCTAssertFalse(String(reflecting: setup).contains(setup.recoveryCode))
    }

    func testWeakPassphraseAndUnconfirmedSetupAreRejected() throws {
        let v = try EncFixtures.plainVault(in: dir)
        XCTAssertThrowsError(try VaultEncryption.prepare(vault: v, passphrase: "short")) { XCTAssertEqual($0 as? VaultEncryptionError, .weakPassphrase) }
        let setup = try VaultEncryption.prepare(vault: v, passphrase: "long enough passphrase")
        XCTAssertThrowsError(try VaultEncryption.confirmRecovery("AAAAA-AAAAA", for: setup))
        XCTAssertThrowsError(try VaultConversion.stageEncryption(vault: v, setup: setup)) { XCTAssertEqual($0 as? VaultEncryptionError, .recoveryNotConfirmed) }
        XCTAssertEqual(try EncFixtures.files(v.url).keys.filter { $0.hasSuffix(".enc") }.count, 0)      // prepare/stage failure touched nothing
    }

    func testPassphraseNormalisationNFC() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let decomposed = "cafe\u{301} passphrase", composed = "caf\u{e9} passphrase"
        let setup = try VaultEncryption.prepare(vault: v, passphrase: decomposed)
        try VaultEncryption.confirmRecovery(setup.recoveryCode, for: setup)
        let r = try VaultConversion.commit(try VaultConversion.stageEncryption(vault: v, setup: setup))
        XCTAssertNoThrow(try VaultEncryption.unlock(at: r.activeURL, passphrase: composed))
    }

    func testChangePassphraseOnlyRewritesMetadata() throws {
        let (v, setup, r) = try EncFixtures.encrypted(in: dir)
        let before = try EncFixtures.files(r.activeURL)
        try VaultEncryption.changePassphrase(at: r.activeURL, context: v.unlockContext!, newPassphrase: "a brand new passphrase")
        let after = try EncFixtures.files(r.activeURL)
        for (k, d) in before where k != "vault.json" { XCTAssertEqual(after[k], d, k) }     // ciphertext byte-identical
        XCTAssertNotEqual(before["vault.json"], after["vault.json"])
        XCTAssertNoThrow(try VaultEncryption.unlock(at: r.activeURL, passphrase: "a brand new passphrase"))
        XCTAssertThrowsError(try VaultEncryption.unlock(at: r.activeURL, passphrase: "correct horse battery"))
        XCTAssertNoThrow(try VaultEncryption.recover(at: r.activeURL, recoveryCode: setup.recoveryCode))
        XCTAssertThrowsError(try VaultEncryption.changePassphrase(at: r.activeURL, context: v.unlockContext!, newPassphrase: "tiny"))
        let foreign = VaultUnlockContext(vaultID: UUID().uuidString, key: v.unlockContext!.key)
        XCTAssertThrowsError(try VaultEncryption.changePassphrase(at: r.activeURL, context: foreign, newPassphrase: "another long passphrase")) { XCTAssertEqual($0 as? VaultEncryptionError, .wrongVault) }
    }

    func testRotateRecoveryCodeInvalidatesOldCode() throws {
        let (v, setup, r) = try EncFixtures.encrypted(in: dir)
        let newCode = try VaultEncryption.rotateRecoveryCode(at: r.activeURL, context: v.unlockContext!)
        XCTAssertNotEqual(newCode, setup.recoveryCode)
        XCTAssertNoThrow(try VaultEncryption.recover(at: r.activeURL, recoveryCode: newCode))
        XCTAssertThrowsError(try VaultEncryption.recover(at: r.activeURL, recoveryCode: setup.recoveryCode))
        XCTAssertNoThrow(try VaultEncryption.unlock(at: r.activeURL, passphrase: "correct horse battery"))
    }

    func testLockedVaultFailsClosed() throws {
        let (_, _, r) = try EncFixtures.encrypted(in: dir)
        let locked = try Vault(url: r.activeURL, create: false)
        XCTAssertEqual(locked.protection, .encrypted)
        XCTAssertThrowsError(try locked.readAll { _ in }) { XCTAssertEqual($0 as? VaultEncryptionError, .locked) }
        XCTAssertThrowsError(try locked.readConfig("contacts.json")) { XCTAssertEqual($0 as? VaultEncryptionError, .locked) }
        XCTAssertThrowsError(try locked.writeConfig(Data("{}".utf8), name: "contacts.json")) { XCTAssertEqual($0 as? VaultEncryptionError, .locked) }
        XCTAssertThrowsError(try PruneConfig.save([], to: locked))
        XCTAssertThrowsError(try MergeConfig.add(keys: ["a", "b"], name: "x", to: locked))
        let db = dir.appendingPathComponent("m.db")
        XCTAssertThrowsError(try locked.ingest(msgstore: db.path, label: "x")) { XCTAssertEqual($0 as? VaultEncryptionError, .locked) }
    }

    func testWrongVaultContextRejected() throws {
        let (_, _, r) = try EncFixtures.encrypted(in: dir)
        let foreign = VaultUnlockContext(vaultID: UUID().uuidString, key: .init(size: .bits256))
        XCTAssertThrowsError(try Vault(url: r.activeURL, create: false, unlockContext: foreign)) { XCTAssertEqual($0 as? VaultEncryptionError, .wrongVault) }
    }

    func testWrongKeyCannotReadAndCannotOverwriteConfig() throws {
        let (v, _, r) = try EncFixtures.encrypted(in: dir)
        let wrong = VaultUnlockContext(vaultID: v.id, key: .init(size: .bits256))
        let bad = try Vault(url: r.activeURL, create: false, unlockContext: wrong)
        XCTAssertThrowsError(try bad.readConfig("contacts.json")) { XCTAssertEqual($0 as? VaultEncryptionError, .authenticationFailed) }
        let before = try EncFixtures.files(r.activeURL)
        XCTAssertThrowsError(try bad.writeConfig(Data("{}".utf8), name: "contacts.json"))
        XCTAssertEqual(try EncFixtures.files(r.activeURL), before)            // nothing replaced with empty config
    }

    func testTamperedFilesFailClosed() throws {
        let (v, _, r) = try EncFixtures.encrypted(in: dir)
        let seg = v.segmentFiles()[0]
        let original = try Data(contentsOf: seg)
        for mutate in [{ (d: inout Data) in d[0] ^= 1 },                      // nonce
                       { (d: inout Data) in d[d.count / 2] ^= 1 },            // ciphertext
                       { (d: inout Data) in d[d.count - 1] ^= 1 },            // tag
                       { (d: inout Data) in d = d.prefix(d.count - 5) }] as [(inout Data) -> Void] {   // truncated
            var t = original; mutate(&t); try t.write(to: seg)
            XCTAssertThrowsError(try v.readAll { _ in }) { XCTAssertEqual($0 as? VaultEncryptionError, .authenticationFailed) }
        }
        try original.write(to: seg)
        XCTAssertNoThrow(try v.readAll { _ in })
        // a file moved to a different logical path fails its AAD
        let moved = seg.deletingLastPathComponent().appendingPathComponent("seg-b.ndjson.gz.enc")
        try FileManager.default.copyItem(at: seg, to: moved)
        XCTAssertThrowsError(try v.readAll { _ in }) { XCTAssertEqual($0 as? VaultEncryptionError, .authenticationFailed) }
        // tampered config
        try FileManager.default.removeItem(at: moved)
        let cfg = r.activeURL.appendingPathComponent("config/contacts.json.enc")
        var c = try Data(contentsOf: cfg); c[20] ^= 1; try c.write(to: cfg)
        XCTAssertThrowsError(try v.readConfig("contacts.json")) { XCTAssertEqual($0 as? VaultEncryptionError, .authenticationFailed) }
        XCTAssertThrowsError(try VaultIndexer.build(vault: v, out: dir.appendingPathComponent("i.db").path))
    }

    func testMetadataValidation() throws {
        let (_, _, r) = try EncFixtures.encrypted(in: dir)
        let meta = r.activeURL.appendingPathComponent("vault.json")
        let good = try Data(contentsOf: meta)
        func edit(_ f: (inout [String: Any]) -> Void) throws {
            var o = try JSONSerialization.jsonObject(with: good) as! [String: Any]; f(&o)
            try JSONSerialization.data(withJSONObject: o).write(to: meta)
        }
        try edit { $0["format"] = 3 }
        XCTAssertThrowsError(try VaultEncryption.protection(at: r.activeURL)) { XCTAssertEqual($0 as? VaultEncryptionError, .unsupportedFormat) }
        try edit { $0.removeValue(forKey: "encryption") }
        XCTAssertThrowsError(try VaultEncryption.protection(at: r.activeURL)) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidMetadata) }
        try edit { var e = $0["encryption"] as! [String: Any]; var p = e["passphrase"] as! [String: Any]; p["iterations"] = 10; e["passphrase"] = p; $0["encryption"] = e }
        XCTAssertThrowsError(try Vault(url: r.activeURL, create: true)) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidMetadata) }
        try edit { var e = $0["encryption"] as! [String: Any]; e["cipher"] = "ROT13"; $0["encryption"] = e }
        XCTAssertThrowsError(try VaultEncryption.protection(at: r.activeURL))
        try Data("not json".utf8).write(to: meta)
        XCTAssertThrowsError(try VaultEncryption.protection(at: r.activeURL)) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidMetadata) }
        try good.write(to: meta)
        XCTAssertEqual(try VaultEncryption.protection(at: r.activeURL), .encrypted)
        // no raw key or passphrase material in vault.json
        let text = String(decoding: good, as: UTF8.self)
        XCTAssertFalse(text.contains("correct horse"))
    }

    func testMixedRepresentationRejected() throws {
        let (v, _, r) = try EncFixtures.encrypted(in: dir)
        try Data("x".utf8).write(to: r.activeURL.appendingPathComponent("config/stray.json"))
        XCTAssertThrowsError(try v.readAll { _ in }) { XCTAssertEqual($0 as? VaultEncryptionError, .invalidMetadata) }
        XCTAssertThrowsError(try v.writeConfig(Data("{}".utf8), name: "contacts.json"))
    }

    func testConfigNamesAreConfined() throws {
        let v = try EncFixtures.plainVault(in: dir)
        for bad in ["../vault.json", "a/b.json", "x.txt", ".hidden.json", ""] {
            XCTAssertThrowsError(try v.readConfig(bad), bad)
            XCTAssertThrowsError(try v.writeConfig(Data(), name: bad), bad)
        }
    }

    func testEncryptedIngestAndIndexRoundTrip() throws {
        let (v, _, r) = try EncFixtures.encrypted(in: dir)
        let src = dir.appendingPathComponent("m.db")
        let db = try SQLiteDB(path: src.path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL);
        INSERT INTO message VALUES (1,10,0,NULL,5000,0,'ingested later','zz');
        """)
        let res = try v.ingest(msgstore: src.path, label: "t", fullSnapshot: false)
        XCTAssertEqual(res.added, 1)
        XCTAssertTrue(res.segment!.hasSuffix(".ndjson.gz.enc"))
        XCTAssertEqual(v.segmentFiles().count, 2)
        XCTAssertEqual(try v.knownUIDs().count, 3)
        let again = try v.ingest(msgstore: src.path, label: "t", fullSnapshot: false)
        XCTAssertEqual(again.added, 0)                                           // idempotent
        let sum = try VaultIndexer.build(vault: v, out: dir.appendingPathComponent("i.db").path)
        _ = sum
        // contact edit goes through the encrypted gateway
        try MergeConfig.add(keys: ["a", "b"], name: "Asha", to: v)
        XCTAssertEqual(try MergeConfig.loadChecked(v).count, 1)
        XCTAssertNil(try? Data(contentsOf: r.activeURL.appendingPathComponent("config/merges.json")))   // no plaintext copy
        XCTAssertNotNil(try? Data(contentsOf: r.activeURL.appendingPathComponent("config/merges.json.enc")))
    }

    func testPlaintextVaultBehaviourUnchanged() throws {
        let v = try EncFixtures.plainVault(in: dir)
        let meta = try Data(contentsOf: v.url.appendingPathComponent("vault.json"))
        XCTAssertEqual(v.protection, .plaintext)
        XCTAssertEqual(try v.knownUIDs().count, 2)
        _ = try VaultIndexer.build(vault: v, out: dir.appendingPathComponent("i.db").path)
        XCTAssertEqual(try Data(contentsOf: v.url.appendingPathComponent("vault.json")), meta)
        XCTAssertTrue(v.segmentFiles().allSatisfy { $0.lastPathComponent.hasSuffix(".ndjson.gz") })
        XCTAssertEqual(String(decoding: try v.readConfig("future-thing.json")!, as: UTF8.self), #"{"future":true}"#)
        XCTAssertNil(try v.readConfig("missing.json"))
    }

    func testKeychainStoreRoundTripAndFailures() throws {
        let store = InMemoryKeyStore()
        let ctx = VaultUnlockContext(vaultID: UUID().uuidString, key: .init(size: .bits256))
        XCTAssertNil(try VaultKeychain.load(vaultID: ctx.vaultID, store: store))               // missing != error
        try VaultKeychain.save(ctx, store: store)
        XCTAssertTrue(try VaultKeychain.load(vaultID: ctx.vaultID, store: store)!.sameKey(as: ctx))
        // identity mismatch (item copied under another account)
        store.items["other"] = store.items[ctx.vaultID]
        XCTAssertThrowsError(try VaultKeychain.load(vaultID: "other", store: store)) { XCTAssertEqual($0 as? VaultEncryptionError, .wrongVault) }
        store.items["junk"] = Data([1, 2, 3])
        XCTAssertThrowsError(try VaultKeychain.load(vaultID: "junk", store: store)) { XCTAssertEqual($0 as? VaultEncryptionError, .keychainUnavailable) }
        try VaultKeychain.delete(vaultID: ctx.vaultID, store: store)
        XCTAssertNil(try VaultKeychain.load(vaultID: ctx.vaultID, store: store))
        XCTAssertNotNil(store.items["other"])                                                 // only the selected item removed
        store.failing = true
        XCTAssertThrowsError(try VaultKeychain.save(ctx, store: store)) { XCTAssertEqual($0 as? VaultEncryptionError, .keychainUnavailable) }
        XCTAssertThrowsError(try VaultKeychain.load(vaultID: "x", store: store))
        XCTAssertNotEqual(SystemVaultKeyStore.service, "app.saga.backup-key")
    }

    func testVaultOpenUsesKeychainOrFailsLocked() throws {
        let (v, _, r) = try EncFixtures.encrypted(in: dir)
        let store = InMemoryKeyStore()
        XCTAssertThrowsError(try Vault.open(url: r.activeURL, store: store)) { XCTAssertEqual($0 as? VaultEncryptionError, .locked) }
        try VaultKeychain.save(v.unlockContext!, store: store)
        let opened = try Vault.open(url: r.activeURL, store: store)
        XCTAssertEqual(try opened.knownUIDs().count, 2)
        store.failing = true
        XCTAssertThrowsError(try Vault.open(url: r.activeURL, store: store)) { XCTAssertEqual($0 as? VaultEncryptionError, .keychainUnavailable) }
    }
}
