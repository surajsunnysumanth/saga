import XCTest
import CryptoKit
@testable import SagaCore

final class IOSTests: XCTestCase {
    /// A fake unencrypted iPhone backup: Manifest.db + Info/Manifest plists + ChatStorage.sqlite stored under its hashed name.
    func fakeBackup(encrypted: Bool = false) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("saga-ios-\(UUID().uuidString)")
        let dev = root.appendingPathComponent("00008020-TEST")
        try fm.createDirectory(at: dev, withIntermediateDirectories: true)
        try (["Device Name": "Test iPhone", "Product Version": "18.7", "Last Backup Date": Date()] as NSDictionary).write(to: dev.appendingPathComponent("Info.plist"))
        try (["IsEncrypted": encrypted] as NSDictionary).write(to: dev.appendingPathComponent("Manifest.plist"))

        let domain = IOSBackup.domain, rel = "ChatStorage.sqlite"
        let id = Insecure.SHA1.hash(data: Data("\(domain)-\(rel)".utf8)).map { String(format: "%02x", $0) }.joined()
        let sub = dev.appendingPathComponent(String(id.prefix(2))); try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let cs = try SQLiteDB(path: sub.appendingPathComponent(id).path, readOnly: false)
        let t0 = 700_000_000.0           // seconds since 2001
        try cs.exec("""
        CREATE TABLE ZWACHATSESSION(Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZSESSIONTYPE INT);
        CREATE TABLE ZWAMESSAGE(Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INT, ZISFROMME INT, ZMESSAGEDATE REAL, ZTEXT TEXT, ZMESSAGETYPE INT, ZSTANZAID TEXT, ZGROUPMEMBER INT, ZFROMJID TEXT);
        CREATE TABLE ZWAMEDIAITEM(Z_PK INTEGER PRIMARY KEY, ZMESSAGE INT, ZMEDIALOCALPATH TEXT, ZTITLE TEXT, ZFILESIZE INT);
        CREATE TABLE ZWAGROUPMEMBER(Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INT, ZMEMBERJID TEXT, ZCONTACTNAME TEXT);
        CREATE TABLE ZWAPROFILEPUSHNAME(Z_PK INTEGER PRIMARY KEY, ZJID TEXT, ZPUSHNAME TEXT);
        INSERT INTO ZWACHATSESSION VALUES (1,'919833052771@s.whatsapp.net','Asha',0),(2,'1203630000@g.us','Quiz Team',1),(3,'status@broadcast','',3);
        INSERT INTO ZWAGROUPMEMBER VALUES (1,2,'919900011122@s.whatsapp.net','Ben');
        INSERT INTO ZWAPROFILEPUSHNAME VALUES (1,'919833052771@s.whatsapp.net','Asha R');
        INSERT INTO ZWAMESSAGE VALUES
          (1,1,0,\(t0),'hello from iphone',0,'STANZA1',NULL,NULL),
          (2,1,1,\(t0 + 60),'reply',0,'STANZA2',NULL,NULL),
          (3,1,0,\(t0 + 120),NULL,1,'STANZA3',NULL,NULL),
          (4,2,0,\(t0 + 180),'group hi',0,'STANZA4',1,NULL),
          (5,2,0,\(t0 + 240),'You joined',6,'STANZA5',NULL,NULL),
          (6,3,0,\(t0 + 300),'status update',0,'STANZA6',NULL,NULL);
        INSERT INTO ZWAMEDIAITEM VALUES (1,3,'Media/919833052771@s.whatsapp.net/a/b/photo.jpg','nice pic',2048);
        """)

        let man = try SQLiteDB(path: dev.appendingPathComponent("Manifest.db").path, readOnly: false)
        try man.exec("CREATE TABLE Files(fileID TEXT, domain TEXT, relativePath TEXT, flags INT, file BLOB); INSERT INTO Files VALUES ('\(id)','\(domain)','\(rel)',1,NULL);")
        return root
    }

    func testLocateFindsBackupAndEncryptedIsRefused() throws {
        let root = try fakeBackup()
        let b = try IOSBackup.locate(root)
        XCTAssertEqual(b.deviceName, "Test iPhone"); XCTAssertEqual(b.iosVersion, "18.7"); XCTAssertFalse(b.encrypted)
        XCTAssertNotNil(try IOSBackup.file(b, relativePath: "ChatStorage.sqlite"))
        XCTAssertNil(try IOSBackup.file(b, relativePath: "Nope.sqlite"))
        XCTAssertThrowsError(try IOSBackup.locate(FileManager.default.temporaryDirectory.appendingPathComponent("nothing-here-\(UUID().uuidString)")))
        let enc = try IOSBackup.locate(try fakeBackup(encrypted: true))
        XCTAssertThrowsError(try IOSBackup.file(enc, relativePath: "ChatStorage.sqlite"))
    }

    func testConvertThenVaultThenIndexMatchesAndroidMerge() throws {
        let root = try fakeBackup(); let b = try IOSBackup.locate(root)
        let cs = try IOSBackup.chatStorage(b)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString).db").path
        let r = try IOSBackup.convert(chatStorage: cs.path, to: out)
        XCTAssertEqual(r.chats, 2)                                   // the Status "chat" is skipped
        XCTAssertEqual(r.messages, 5); XCTAssertEqual(r.media, 1); XCTAssertEqual(r.pushNames, 1)

        let vault = try Vault(url: root.appendingPathComponent("vault"))
        let first = try vault.ingest(msgstore: out, label: "ios", source: "ios-backup", fullSnapshot: false)
        XCTAssertEqual(first.added, 5)
        XCTAssertEqual(try vault.ingest(msgstore: out, label: "ios", source: "ios-backup", fullSnapshot: false).added, 0)   // idempotent

        // an Android database holding the SAME WhatsApp message ids merges without duplicates
        let and = try SQLiteDB(path: root.appendingPathComponent("android.db").path, readOnly: false)
        try and.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL);
        INSERT INTO message VALUES (1,10,0,NULL,1700000000000,0,'hello from iphone','STANZA1'),(2,10,0,NULL,1700000999000,0,'only on android','ANDROID9');
        """)
        let merged = try vault.ingest(msgstore: root.appendingPathComponent("android.db").path, label: "android", fullSnapshot: false)
        XCTAssertEqual(merged.added, 1); XCTAssertEqual(merged.skipped, 1)

        let idx = root.appendingPathComponent("i.db").path
        _ = try VaultIndexer.build(vault: vault, out: idx)
        let st = try SQLiteDB(path: idx, readOnly: true)
        XCTAssertEqual(try st.scalarInt("SELECT count(*) FROM messages WHERE text='hello from iphone'"), 1)
        XCTAssertEqual(try st.scalarInt("SELECT count(*) FROM chats WHERE is_group=1 AND name='Quiz Team'"), 1)
        XCTAssertEqual(try st.scalarInt("SELECT count(*) FROM messages WHERE sender='Ben'"), 1)               // group member name carried over
        XCTAssertEqual(try st.scalarInt("SELECT count(*) FROM media m JOIN messages x ON x.id=m.msg_id WHERE m.kind='image'"), 1)
        XCTAssertEqual(try st.scalarInt("SELECT count(*) FROM messages WHERE type=7"), 1)                    // system notice mapped
    }
}
