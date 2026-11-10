import XCTest
@testable import SagaCore

/// Voice notes are the one media kind a thumbnail cannot explain: the interesting part is who
/// spoke and where. These fixtures use invented names and reserved 555-01xx numbers only.
final class VoiceNoteTests: XCTestCase {
    private var root: URL!
    private var index: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        index = root.appendingPathComponent("index.db").path
        let db = try SQLiteDB(path: index, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec("""
            INSERT INTO chats VALUES
              (1,'15550001111@s.whatsapp.net',0,'Test Chat A',1,'5550001111'),
              (2,'120363000000000000@g.us',1,'Test Group',1,NULL),
              (3,'15550003333@s.whatsapp.net',0,'',0,'5550003333');
            INSERT INTO messages VALUES
              (1,1,1,'me','me',1717200000000,2,NULL,'uid-1'),
              (2,1,0,'Synthetic Sender','5550001111',1717286400000,2,NULL,'uid-2'),
              (3,2,0,'','5550002222',1748908800000,2,NULL,'uid-3'),
              (4,2,0,'Unknown','lid:123456789012345',1748995200000,2,NULL,'uid-4'),
              (5,3,0,'+15550003333','5550003333',1717372800000,2,NULL,'uid-5'),
              (6,1,0,'Synthetic Sender','5550001111',1717459200000,1,NULL,'uid-6');
            INSERT INTO media VALUES
              (1,1,1717200000000,'audio/ogg','audio','Media/WhatsApp Voice Notes/A/PTT-1.opus',100,NULL,NULL,NULL),
              (2,1,1717286400000,'audio/ogg','audio','Media/WhatsApp Voice Notes/A/PTT-2.opus',200,NULL,NULL,NULL),
              (3,2,1748908800000,'audio/ogg','audio','Media/WhatsApp Voice Notes/B/PTT-3.opus',300,NULL,'caption',NULL),
              (4,2,1748995200000,'audio/ogg','audio','Media/WhatsApp Voice Notes/B/PTT-4.opus',400,NULL,NULL,NULL),
              (5,3,1717372800000,'audio/ogg','audio','Media/WhatsApp Voice Notes/C/PTT-5.opus',500,NULL,NULL,NULL),
              (6,1,1717459200000,'image/jpeg','image','Media/WhatsApp Images/IMG-6.jpg',600,NULL,NULL,NULL),
              (77,2,1686000000000,'audio/ogg','audio','Media/WhatsApp Voice Notes/B/PTT-77.opus',700,NULL,NULL,NULL);
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() throws -> VaultStore { try VaultStore(path: index) }

    func testJoinsSenderChatGroupAndFromMe() throws {
        let notes = try store().voiceNotes()
        XCTAssertEqual(notes.map(\.id), [4, 3, 5, 2, 1, 77], "newest first, including a media row with no message")

        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        XCTAssertEqual(byID[1]?.senderName, "You")
        XCTAssertEqual(byID[1]?.chatName, "Test Chat A")
        XCTAssertEqual(byID[1]?.isGroup, false)
        XCTAssertEqual(byID[1]?.path, "Media/WhatsApp Voice Notes/A/PTT-1.opus")
        XCTAssertEqual(byID[1]?.size, 100)

        XCTAssertEqual(byID[2]?.senderName, "Synthetic Sender")
        XCTAssertEqual(byID[3]?.senderName, "+5550002222", "no stored name falls back to the person's number")
        XCTAssertEqual(byID[4]?.senderName, "Number ending 2345", "a LID is never labelled Unknown")
        XCTAssertEqual(byID[4]?.chatName, "Test Group")
        XCTAssertEqual(byID[4]?.isGroup, true)
        XCTAssertEqual(byID[5]?.senderName, "+15550003333")
        XCTAssertEqual(byID[5]?.chatName, "+15550003333", "an unnamed DM shows the JID number")
        XCTAssertEqual(byID[77]?.senderName, "Unnamed sender")
        XCTAssertEqual(byID[77]?.chatName, "Test Group")
        XCTAssertEqual(byID[77]?.fromMe, false)
        XCTAssertEqual(byID[3]?.caption, "caption")
    }

    func testChatYearAndSortFilters() throws {
        let store = try store()
        XCTAssertEqual(try store.voiceNotes(chatID: 2).map(\.id), [4, 3, 77])
        XCTAssertEqual(try store.voiceNotes(year: 2025).map(\.id), [4, 3])
        XCTAssertEqual(try store.voiceNotes(year: 2024).map(\.id), [5, 2, 1])
        XCTAssertEqual(try store.voiceNotes(sort: .oldest).map(\.id), [77, 1, 2, 5, 3, 4])
        XCTAssertEqual(try store.voiceNotes(limit: 2).map(\.id), [4, 3])
        XCTAssertTrue(try store.voiceNotes(chatID: 999).isEmpty)
    }

    func testCountsIncludeAudioAndNonAudioIsExcluded() throws {
        let store = try store()
        XCTAssertEqual(try store.mediaCounts()["audio"], 6)
        XCTAssertEqual(try store.media(kind: "audio").count, 6)
        XCTAssertFalse(try store.voiceNotes().contains { $0.id == 6 }, "images are not voice notes")
    }

    /// A chat's Media tab counts only what that chat holds. The per-chat numbers must add up
    /// to the archive-wide ones; otherwise a tab claims 40 photos and draws 5.
    func testCountsAndYearsAreScopedToAChat() throws {
        let store = try store()
        XCTAssertEqual(try store.mediaCounts(chatID: 1)["audio"], 2)
        XCTAssertEqual(try store.mediaCounts(chatID: 1)["image"], 1)
        XCTAssertEqual(try store.mediaCounts(chatID: 2)["audio"], 3)
        XCTAssertNil(try store.mediaCounts(chatID: 3)["image"])
        XCTAssertEqual(try store.mediaCounts(chatID: 999), [:])

        let summed = try [1, 2, 3, 999].reduce(0) { total, id in
            total + (try store.mediaCounts(chatID: id)["audio"] ?? 0)
        }
        XCTAssertEqual(summed, try store.mediaCounts()["audio"])

        XCTAssertEqual(try store.mediaYears(chatID: 1), [2024])
        XCTAssertEqual(try store.mediaYears(chatID: 2), [2025, 2023])
        XCTAssertEqual(try store.mediaYears(chatID: 999), [])
    }

    func testSenderFallbacksNeverSayUnknown() {
        XCTAssertEqual(VoiceNote.senderLabel(fromMe: true, sender: "Synthetic Sender", person: "5550001111"), "You")
        XCTAssertEqual(VoiceNote.senderLabel(fromMe: false, sender: "Saved Name", person: "5550001111"), "Saved Name")
        XCTAssertEqual(VoiceNote.senderLabel(fromMe: false, sender: "Unknown", person: "5550002222"), "+5550002222")
        XCTAssertEqual(VoiceNote.senderLabel(fromMe: false, sender: "unknown (6789)", person: "lid:111111116789"), "Number ending 6789")
        XCTAssertEqual(VoiceNote.senderLabel(fromMe: false, sender: "", person: "lid:111111116789"), "Number ending 6789")
        XCTAssertEqual(VoiceNote.senderLabel(fromMe: false, sender: "", person: ""), "Unnamed sender")
        XCTAssertEqual(VoiceNote.chatLabel(name: "", jid: "", isGroup: true), "Unnamed group")
        XCTAssertEqual(VoiceNote.chatLabel(name: "", jid: "", isGroup: false), "One conversation")
    }
}
