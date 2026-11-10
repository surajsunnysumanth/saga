import XCTest
@testable import SagaCore

/// A sticker is a picture with an identity: its file's SHA-256. Two sends of the same file are
/// one sticker used twice, and the archive files it as a sticker — not a photo, not a document.
final class StickerStatsTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-stickers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func index(_ dir: URL) throws -> (SQLiteDB, String) {
        let path = dir.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec(Importer.finish)
        return (db, path)
    }

    // MARK: - Import classification

    func testImporterFilesWhatsAppStickersAsStickersWithoutTouchingPhotos() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("msgstore.db").path
        let src = try SQLiteDB(path: source, readOnly: false)
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'1203630000','g.us',0,0,0,'1203630000@g.us'),(2,'5550000001','s.whatsapp.net',0,0,0,'5550000001@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,'Quiz club');
        INSERT INTO message VALUES
          (100,10,0,2,1700000000000,20,NULL,'k1'),
          (101,10,1,NULL,1700000001000,20,NULL,'k2'),
          (102,10,0,2,1700000002000,0,NULL,'k3'),
          (103,10,0,2,1700000003000,1,NULL,'k4');
        INSERT INTO message_media VALUES
          (100,10,'image/webp','Media/WhatsApp Stickers/STK-20240101-WA0000.webp',900,'hash-a',''),
          (101,10,'image/webp','Media/WhatsApp Stickers/STK-20240101-WA0001.webp',901,'hash-b',''),
          -- An older export with no message type: the folder is the only evidence.
          (102,10,'image/webp','Media/WhatsApp Stickers/STK-20240101-WA0002.webp',902,'hash-c',''),
          -- A real photo, even though it is also image/webp.
          (103,10,'image/webp','Media/WhatsApp Images/IMG-20240101-WA0000.webp',903,'hash-d','');
        """)
        let out = dir.appendingPathComponent("out.db").path
        let summary = try Importer.run(ImportOptions(sourceDB: source, outputDB: out,
                                                     extraContacts: ["5550000001": "Asha"]))
        XCTAssertEqual(summary.media, 4)
        let db = try SQLiteDB(path: out, readOnly: true)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM media WHERE kind='sticker'"), 3)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM media WHERE kind='image'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT count(*) FROM media WHERE kind='sticker' AND file_hash='hash-b'"), 1)
    }

    // MARK: - Dedupe and counts

    private func stickerIndex(_ dir: URL) throws -> VaultStore {
        let (db, path) = try index(dir)
        try db.exec("""
        INSERT INTO chats VALUES
          (1,'a',0,'Asha',1,'asha'),
          (2,'b',1,'Quiz club',1,NULL);
        INSERT INTO people VALUES('asha','Asha',1),('ben','Ben',1),('me','me',0);
        INSERT INTO messages VALUES
          (1,1,0,'Asha','asha',1735689600000,20,NULL,'s1'),
          (2,1,0,'Asha','asha',1735689601000,20,NULL,'s2'),
          (3,1,0,'Asha','asha',1735689602000,20,NULL,'s3'),
          (4,1,0,'Asha','asha',1735689603000,20,NULL,'s4'),
          (5,1,1,'me','me',1735689604000,20,NULL,'s5'),
          (6,2,0,'Ben','ben',1735689605000,20,NULL,'s6'),
          (7,2,0,'Ben','ben',1735689606000,20,NULL,'s7'),
          (8,1,0,'Asha','asha',1735689607000,20,NULL,'s8'),
          (9,2,0,'Ben','ben',1735689608000,20,NULL,'s9');
        INSERT INTO media VALUES
          (1,1,1735689600000,'image/webp','sticker','Media/WhatsApp Stickers/STK-1.webp',900,'H1','',NULL),
          (2,1,1735689601000,'image/webp','sticker','Media/WhatsApp Stickers/STK-1.webp',900,'H1','',NULL),
          (3,1,1735689602000,'image/webp','sticker','Media/WhatsApp Stickers/STK-1.webp',900,'H1','',NULL),
          (4,1,1735689603000,'image/webp','sticker','Media/WhatsApp Stickers/STK-1.webp',900,'H1','',NULL),
          (5,1,1735689604000,'image/webp','sticker','Media/WhatsApp Stickers/STK-2.webp',910,'H2','',NULL),
          (6,2,1735689605000,'image/webp','sticker','Media/WhatsApp Stickers/STK-1.webp',900,'H1','',NULL),
          (7,2,1735689606000,'image/webp','sticker','Media/WhatsApp Stickers/STK-1.webp',900,'H1','',NULL),
          (8,1,1735689607000,'image/webp','sticker','Media/WhatsApp Stickers/STK-3.webp',920,NULL,'',NULL),
          (9,2,1735689608000,'image/webp','sticker','Media/WhatsApp Stickers/STK-2.webp',910,'H2','',NULL);
        """)
        return try VaultStore(path: path)
    }

    func testSameStickerUsedManyTimesIsOneSticker() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try stickerIndex(dir)

        let chat = try Stickers.summary(store: store, chatID: 1)
        XCTAssertEqual(chat.total, 6)
        XCTAssertEqual(chat.distinct, 2)
        XCTAssertEqual(chat.unhashed, 1)
        XCTAssertEqual(chat.mine, 1)
        XCTAssertEqual(chat.theirs, 5)
        XCTAssertEqual(chat.top.first?.hash, "H1")
        XCTAssertEqual(chat.top.first?.count, 4, "four sends of the same file are four sends of one sticker")
        XCTAssertEqual(chat.top.first?.sender, "Asha")

        let all = try Stickers.summary(store: store)
        XCTAssertEqual(all.total, 9)
        XCTAssertEqual(all.distinct, 2)
        XCTAssertEqual(all.top.first?.hash, "H1")
        XCTAssertEqual(all.top.first?.count, 6, "the same file across two chats is still one sticker")

        let dmScope = try Stickers.summary(store: store, chatID: 1, person: "me")
        XCTAssertEqual(dmScope.total, 1)
        XCTAssertEqual(dmScope.top.first?.hash, "H2")
    }

    func testPerPersonPickUsesTheSameHashIdentity() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try stickerIndex(dir)
        let people = try Stickers.byPerson(store: store, chatID: 1)
        XCTAssertEqual(people.first?.name, "Asha")
        XCTAssertEqual(people.first?.total, 5)
        XCTAssertEqual(people.first?.top?.hash, "H1")
        XCTAssertEqual(people.first?.top?.count, 4)
        XCTAssertEqual(people.first?.distinct, 1, "Asha's hashed stickers are all one file; the unhashed send has no identity")
    }

    // MARK: - It is not a photo

    func testStickersDoNotInflatePhotosOrDocuments() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try stickerIndex(dir)
        let year = try await YearWrappedBuilder.build(store: store, year: "2025")
        XCTAssertEqual(year.media.photos, 0)
        XCTAssertEqual(year.media.docs, 0, "a sticker used to fall through to the document default")
        XCTAssertEqual(year.stickers.total, 9)
        // The Images tab and its count still show stickers: they are pictures.
        XCTAssertEqual(try store.mediaCounts()["image"], 9)
        XCTAssertEqual(try store.media(kind: "image").count, 9)
        XCTAssertEqual(try store.media(kind: "sticker").count, 9)
    }

    func testStickerCopyIsCountLedBecauseAStickerHasNoWords() {
        XCTAssertNil(WrappedCopy.stickers(total: 0, distinct: 0, topCount: 0))
        XCTAssertEqual(WrappedCopy.stickers(total: 1, distinct: 1, topCount: 1), "One sticker went round.")
        XCTAssertEqual(WrappedCopy.stickers(total: 41, distinct: 12, topCount: 27),
                       "41 stickers went round, 12 of them different. One did a lot of the work: sent 27 times.")
        XCTAssertEqual(WrappedCopy.stickers(total: 12, distinct: 1, topCount: 12),
                       "12 stickers went round, 1 of them different. It was the same one every time.")
    }
}
