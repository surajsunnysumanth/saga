import Foundation
import Testing
@testable import SagaCore

/// The address book as a first-class name source. Every fixture here is invented: no number or name comes
/// from a real archive or a real phone book.
@Suite struct SavedContactNameTests {
    // Made-up numbers. Person keys are their last ten digits.
    let savedJID = "919800000101@s.whatsapp.net"        // saved in the phone book, also has a profile name
    let bareJID = "919800000102@s.whatsapp.net"         // not in the phone book, no profile name
    let lidJID = "445566@lid"                           // a LID has no number, so nothing can match it

    let savedBook = """
    {"contacts":[
      {"id":"1","name":"Asha Rao","numbers":["919800000101"]}
    ]}
    """

    /// One chat per identity, plus the jid/profile tables the indexer reads.
    func makeVault() throws -> (vault: Vault, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saved-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER, display_name TEXT, username TEXT);
        INSERT INTO jid VALUES
          (1,'919800000101','s.whatsapp.net',0,0,0,'\(savedJID)'),
          (2,'919800000102','s.whatsapp.net',0,0,0,'\(bareJID)'),
          (3,'445566','lid',0,0,0,'\(lidJID)');
        INSERT INTO lid_display_name VALUES (1,'Wp Nick',NULL),(3,'Girl Friday',NULL);
        INSERT INTO chat VALUES (10,1,NULL),(11,2,NULL),(12,3,NULL);
        INSERT INTO message VALUES
          (1,10,0,NULL,1000,0,'hi from the saved contact','k1'),
          (2,11,0,NULL,2000,0,'hi from a stranger','k2'),
          (3,12,0,NULL,3000,0,'hi from a lid','k3');
        """)
        let v = try Vault(url: dir.appendingPathComponent("v"))
        _ = try v.ingest(msgstore: dir.appendingPathComponent("m.db").path, label: "t")
        return (v, dir)
    }

    func build(_ vault: Vault, _ dir: URL, book: String? = nil, overrides: String? = nil, name: String = "i.db") throws -> String {
        if let book { try vault.writeConfig(Data(book.utf8), name: PhoneContacts.fileName) }
        if let overrides { try Data(overrides.utf8).write(to: vault.url.appendingPathComponent("config/overrides.csv")) }
        let idx = dir.appendingPathComponent(name).path
        _ = try VaultIndexer.build(vault: vault, out: idx)
        return idx
    }

    /// jid -> (display name, resolved flag, person key) straight out of the index the app reads.
    func chats(_ idx: String) throws -> [String: (name: String, resolved: Int64, person: String)] {
        var out: [String: (String, Int64, String)] = [:]
        try SQLiteDB(path: idx, readOnly: true).query("SELECT jid, name, resolved, person FROM chats") {
            out[$0.text(0) ?? ""] = ($0.text(1) ?? "", $0.int(2), $0.text(3) ?? "")
        }
        return out
    }

    // MARK: the preference order

    @Test func aSavedContactNameBecomesTheChatName() throws {
        let (v, dir) = try makeVault()
        let rows = try chats(try build(v, dir, book: savedBook))
        let saved = try #require(rows[savedJID])
        #expect(saved.name == "Asha Rao")            // not the WhatsApp profile name ("Wp Nick")
        #expect(saved.resolved == 1)
        #expect(saved.person == "9800000101")
    }

    @Test func aManualOverrideStillWins() throws {
        let (v, dir) = try makeVault()
        let csv = "chat_jid,name\n\(savedJID),The Name I Chose\n"
        let rows = try chats(try build(v, dir, book: savedBook, overrides: csv))
        #expect(rows[savedJID]?.name == "The Name I Chose")
    }

    @Test func aNumberWithNoSavedContactStillShowsTheNumber() throws {
        let (v, dir) = try makeVault()
        let rows = try chats(try build(v, dir, book: savedBook))
        let bare = try #require(rows[bareJID])
        #expect(bare.name == "+919800000102")
        #expect(bare.resolved == 0)
        #expect(bare.person == "9800000102")
    }

    @Test func aLidChatIsLeftAlone() throws {
        let (v, dir) = try makeVault()
        // A saved contact must not be able to hijack a LID: it carries no number, so nothing can match it.
        let book = """
        {"contacts":[{"id":"1","name":"Asha Rao","numbers":["919800000101"]},
                     {"id":"2","name":"Not The Lid","numbers":["91980000445566"]}]}
        """
        let rows = try chats(try build(v, dir, book: book))
        let lid = try #require(rows[lidJID])
        #expect(lid.name == "Girl Friday")
        #expect(lid.person == "lid:445566")
    }

    @Test func theSameInputGivesTheSameNameAcrossReads() throws {
        let (v, dir) = try makeVault()
        let first = try chats(try build(v, dir, book: savedBook, name: "a.db"))
        let second = try chats(try build(v, dir, book: savedBook, name: "b.db"))
        #expect(first.count == second.count)
        for (jid, row) in first {
            #expect(second[jid]?.name == row.name, "\(jid)")
            #expect(second[jid]?.person == row.person, "\(jid)")
            #expect(second[jid]?.resolved == row.resolved, "\(jid)")
        }
        // Reading the book twice in a row is also stable.
        #expect(PhoneContacts.names(in: v) == PhoneContacts.names(in: v))
    }

    // MARK: the key reduction

    /// The address book's key rule and the chat JID's key rule must be the same rule, or a saved number
    /// silently never matches its chat. Every written form of one invented number reduces to one key.
    @Test func everyWrittenFormOfANumberReducesToTheSameKey() {
        let forms = ["919800000101", "+91 98000 00101", "+91-98000-00101", "098000 00101",
                     "09800000101", "9800000101"]
        for form in forms {
            #expect(normalizePhone(form) == "9800000101", "\(form)")
            #expect(PhoneContact(id: "1", name: "X", numbers: [form]).keys == ["9800000101"], "\(form)")
        }
        // The JID side of the join, computed the way `Resolver.resolve` computes it.
        let jidNode = "919800000101@s.whatsapp.net".split(separator: "@")[0]
        #expect(normalizePhone(String(jidNode)) == PhoneContact(id: "1", name: "X", numbers: ["098000 00101"]).keys.first)
    }

    /// A saved number written the way a person types it — with a trunk `0` and spaces — still names the chat,
    /// whose JID carries the country code instead. This is the join that matters.
    @Test func aNationalFormatSavedNumberStillNamesTheChat() throws {
        let (v, dir) = try makeVault()
        let book = """
        {"contacts":[{"id":"1","name":"Asha Rao","numbers":["098000 00101"]}]}
        """
        let rows = try chats(try build(v, dir, book: book))
        let saved = try #require(rows[savedJID])
        #expect(saved.name == "Asha Rao")
        #expect(saved.resolved == 1)
        #expect(saved.person == "9800000101")
    }

    /// A number too short to be a person key is dropped instead of becoming a key that can never match.
    @Test func tooShortANumberIsNotAKey() {
        #expect(PhoneContact(id: "1", name: "X", numbers: ["12345"]).keys.isEmpty)
        #expect(PhoneContact(id: "1", name: "X", numbers: ["+1 (415) 555-0101"]).keys == ["4155550101"])
    }
}
