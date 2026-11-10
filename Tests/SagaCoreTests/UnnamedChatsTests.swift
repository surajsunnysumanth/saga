import Foundation
import Testing
@testable import SagaCore

/// The Unnamed list: every chat the resolver could not name, ordered by how much was said, with a kind that
/// separates a stranger from a newsletter and a group. Every number, id and name here is invented; nothing
/// comes from a real archive or a real phone book.
@Suite struct UnnamedChatsTests {
    // Made-up identities. Person keys are their last ten digits.
    let strangerJID = "919800000201@s.whatsapp.net"       // 4 messages, not in the address book
    let quietJID = "919800000202@s.whatsapp.net"          // 1 message, not in the address book
    let lidJID = "445566@lid"                             // a person with no phone number at all
    let newsletterJID = "120363000000000001@newsletter"
    let namedGroupJID = "120363000000000002@g.us"         // has a subject, so it is already named
    let unnamedGroupJID = "120363000000000003@g.us"      // never had a subject
    let savedJID = "919800000203@s.whatsapp.net"          // saved in the address book, so not unnamed
    let emptyJID = "919800000205@s.whatsapp.net"          // an unnamed chat with no messages at all

    /// One chat per identity, with distinct message counts and timestamps so ordering is decidable.
    func makeVault() throws -> (vault: Vault, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unnamed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER, display_name TEXT, username TEXT);
        INSERT INTO jid VALUES
          (1,'919800000201','s.whatsapp.net',0,0,0,'\(strangerJID)'),
          (2,'919800000202','s.whatsapp.net',0,0,0,'\(quietJID)'),
          (3,'445566','lid',0,0,0,'\(lidJID)'),
          (4,'120363000000000001','newsletter',0,0,0,'\(newsletterJID)'),
          (5,'120363000000000002','g.us',0,0,0,'\(namedGroupJID)'),
          (6,'120363000000000003','g.us',0,0,0,'\(unnamedGroupJID)'),
          (7,'919800000203','s.whatsapp.net',0,0,0,'\(savedJID)'),
          (9,'919800000205','s.whatsapp.net',0,0,0,'\(emptyJID)');
        INSERT INTO chat VALUES (10,1,NULL),(11,2,NULL),(12,3,NULL),(13,4,NULL),(14,5,'Team'),(15,6,NULL),(16,7,NULL),(17,9,NULL);
        INSERT INTO message VALUES
          (1,10,0,NULL,1000,0,'hi','k10a'),(2,10,0,NULL,2000,0,'there','k10b'),
          (3,10,1,NULL,3000,0,'hello','k10c'),(4,10,0,NULL,4000,0,'again','k10d'),
          (5,12,0,NULL,5000,0,'lid one','k12a'),(6,12,0,NULL,6000,0,'lid two','k12b'),(7,12,0,NULL,7000,0,'lid three','k12c'),
          (8,13,0,NULL,8000,0,'news one','k13a'),(9,13,0,NULL,9000,0,'news two','k13b'),
          (10,15,0,NULL,11000,0,'group one','k15a'),
          (11,11,0,NULL,12000,0,'quiet one','k11a'),
          (12,14,0,NULL,13000,0,'team one','k14a'),(13,14,0,NULL,14000,0,'team two','k14b'),
          (14,16,0,NULL,15000,0,'saved one','k16a'),(15,16,0,NULL,16000,0,'saved two','k16b');
        """)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: dir.appendingPathComponent("m.db").path, label: "t")
        // A name the archive already had: this chat must never be offered as unnamed.
        try vault.writeConfig(Data(#"{"9800000203":"Saved Person"}"#.utf8), name: "contacts.json")
        return (vault, dir)
    }

    func build(_ vault: Vault, _ dir: URL, name: String = "i.db") throws -> String {
        let idx = dir.appendingPathComponent(name).path
        _ = try VaultIndexer.build(vault: vault, out: idx)
        return idx
    }

    /// jid -> (display name, resolved flag) straight out of the index the app reads.
    func chatNames(_ idx: String) throws -> [String: (name: String, resolved: Int64)] {
        var out: [String: (String, Int64)] = [:]
        try SQLiteDB(path: idx, readOnly: true).query("SELECT jid, name, resolved FROM chats") {
            out[$0.text(0) ?? ""] = ($0.text(1) ?? "", $0.int(2))
        }
        return out
    }

    /// The query returns whole rows; these helpers compare by JID, because chat ids are assigned by the
    /// indexer (sorted JID order) and say nothing about the fixture.
    func rows(_ idx: String, q: String = "", kind: UnnamedKind? = nil,
              excluding: Set<String> = [], limit: Int = 100, offset: Int = 0) throws -> [UnnamedChat] {
        try VaultStore(path: idx).unnamedChats(matching: q, kind: kind, excluding: excluding, limit: limit, offset: offset)
    }

    func jids(_ idx: String, q: String = "", kind: UnnamedKind? = nil,
              excluding: Set<String> = [], limit: Int = 100, offset: Int = 0) throws -> [String] {
        try rows(idx, q: q, kind: kind, excluding: excluding, limit: limit, offset: offset).map(\.jid)
    }

    // MARK: membership

    @Test func onlyChatsTheResolverCouldNotNameAreListed() throws {
        let (v, dir) = try makeVault()
        let idx = try build(v, dir)
        // Ordered by message count, then last activity.
        #expect(try jids(idx) == [strangerJID, lidJID, newsletterJID, quietJID, unnamedGroupJID, emptyJID])
        // The named group (subject "Team") and the address-book contact are not here.
        #expect(!(try jids(idx)).contains(namedGroupJID))
        #expect(!(try jids(idx)).contains(savedJID))
    }

    @Test func everyKindIsLabelledSoABusinessIsNotOfferedAsAPerson() throws {
        let (v, dir) = try makeVault()
        let found = try rows(try build(v, dir))
        let kinds = Dictionary(uniqueKeysWithValues: found.map { ($0.jid, $0.kind) })
        #expect(kinds[strangerJID] == .person)
        #expect(kinds[lidJID] == .person)              // a lid is a person, not a business
        #expect(kinds[newsletterJID] == .newsletter)
        #expect(kinds[unnamedGroupJID] == .group)
        // The filter is the same classification the row shows.
        #expect(try jids(try build(v, dir, name: "b.db"), kind: .person) == [strangerJID, lidJID, quietJID, emptyJID])
        #expect(try jids(try build(v, dir, name: "c.db"), kind: .newsletter) == [newsletterJID])
        #expect(try jids(try build(v, dir, name: "d.db"), kind: .group) == [unnamedGroupJID])
    }

    @Test func countsPerKindAndPagingCoverTheWholeList() throws {
        let (v, dir) = try makeVault()
        let idx = try build(v, dir)
        let store = try VaultStore(path: idx)
        let counts = try store.unnamedChatCounts()
        #expect(counts[.person] == 4)
        #expect(counts[.newsletter] == 1)
        #expect(counts[.group] == 1)
        #expect(try store.unnamedChatCount() == 6)
        // A chat with no messages is still unnamed, and it is listed last rather than dropped.
        #expect(try rows(idx).last?.jid == emptyJID)
        #expect(try rows(idx).last?.count == 0)

        // A page is a window over the same ordering, never a different one.
        #expect(try jids(idx, limit: 2, offset: 0) == [strangerJID, lidJID])
        #expect(try jids(idx, limit: 2, offset: 2) == [newsletterJID, quietJID])
        #expect(try jids(idx, limit: 2, offset: 4) == [unnamedGroupJID, emptyJID])
        #expect(try jids(idx, limit: 2, offset: 8).isEmpty)
    }

    @Test func searchFindsANumberOrAnIdentifier() throws {
        let (v, dir) = try makeVault()
        let idx = try build(v, dir)
        #expect(try jids(idx, q: "000202") == [quietJID])       // part of the phone number
        #expect(try jids(idx, q: "lid:4455") == [lidJID])       // the id the row prints
        #expect(try jids(idx, q: "newsletter") == [newsletterJID])
        #expect(try jids(idx, q: "Team").isEmpty)               // a named group is not unnamed
        #expect(try jids(idx, q: "zzzz").isEmpty)
    }

    @Test func aRowShowsSomethingTheOwnerCanActuallyRecognise() throws {
        let (v, dir) = try makeVault()
        let found = try rows(try build(v, dir))
        let byJID = Dictionary(uniqueKeysWithValues: found.map { ($0.jid, $0) })
        let stranger = try #require(byJID[strangerJID])
        #expect(stranger.identifier == "+91 98000 00201")   // full number, never a masked label
        #expect(stranger.subtitle == nil)                   // the index's "+919800000201" is not a name
        #expect(stranger.count == 4)
        #expect(try #require(byJID[lidJID]).identifier == "lid:445566")
        #expect(try #require(byJID[newsletterJID]).identifier == "newsletter:120363000000000001")
        #expect(try #require(byJID[unnamedGroupJID]).identifier == "group:120363000000000003")
        #expect(try #require(byJID[unnamedGroupJID]).subtitle == nil)   // "(unnamed group)" is not a name
    }

    @Test func anIgnoredChatStopsAppearingAndTheRestNeverChange() throws {
        let (v, dir) = try makeVault()
        let idx = try build(v, dir)
        try UnnamedIgnores.add(strangerJID, to: v)
        #expect(UnnamedIgnores.load(v) == [strangerJID])
        let store = try VaultStore(path: idx)
        let excluded = Set(UnnamedIgnores.load(v))
        #expect(!(try store.unnamedChats(excluding: excluded).map(\.jid)).contains(strangerJID))
        #expect(try store.unnamedChats(excluding: excluded).count == 5)
        #expect(try store.unnamedChatCounts(excluding: excluded)[.person] == 3)
        // Restoring puts it back; nothing was deleted from the archive.
        try UnnamedIgnores.remove(strangerJID, from: v)
        #expect(try store.unnamedChats(excluding: Set(UnnamedIgnores.load(v))).count == 6)
    }

    // MARK: naming

    /// The whole point: a name typed here is written into the vault's override file, survives the rebuild
    /// the app runs, and the chat stops being unnamed everywhere.
    @Test func namingAStrangerWritesAnOverrideThatSurvivesTheRebuild() throws {
        let (v, dir) = try makeVault()
        _ = try build(v, dir)
        try NameOverrides.set("Ravi Kumar", for: strangerJID, in: v)

        #expect(NameOverrides.load(in: v)[strangerJID] == "Ravi Kumar")
        #expect(ContactSources.loadOverrides(path: NameOverrides.fileURL(in: v).path)[strangerJID] == "Ravi Kumar")

        let rebuilt = try build(v, dir, name: "rebuilt.db")
        let named = try chatNames(rebuilt)
        #expect(named[strangerJID]?.name == "Ravi Kumar")
        #expect(named[strangerJID]?.resolved == 1)
        #expect(!(try jids(rebuilt)).contains(strangerJID))
        #expect(try rows(rebuilt).count == 5)
    }

    /// A lid chat has no phone number to join on, so a typed override is the only way to name one.
    @Test func namingALidChatSticksThroughTheRebuildToo() throws {
        let (v, dir) = try makeVault()
        _ = try build(v, dir)
        try NameOverrides.set("Office Landline", for: lidJID, in: v)
        let named = try chatNames(try build(v, dir, name: "rebuilt.db"))
        #expect(named[lidJID]?.name == "Office Landline")
        #expect(named[lidJID]?.resolved == 1)
        #expect(!(try jids(try build(v, dir, name: "again.db"))).contains(lidJID))
    }

    /// The file is a spreadsheet the owner may have edited: a name write must not flatten its other columns,
    /// duplicate a row, or lose a row that has no name yet.
    @Test func theOverrideFileKeepsItsOtherColumnsAndRows() throws {
        let (v, dir) = try makeVault()
        let original = """
        chat_jid,name,phone
        \(quietJID),,98888 80000
        \(savedJID),Already Named,98888 80001
        """
        let url = NameOverrides.fileURL(in: v)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(original.utf8).write(to: url)
        try NameOverrides.set("Rao, Asha", for: strangerJID, in: v)
        try NameOverrides.set("Quiet One", for: quietJID, in: v)

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.first == "chat_jid,name,phone")            // header, extra column and all
        #expect(lines.filter { $0.hasPrefix(quietJID) }.count == 1)
        #expect(text.contains(",98888 80000"))                    // the phone column survived
        #expect(text.contains("Already Named,98888 80001"))       // an untouched row is untouched
        // A comma inside a name is quoted, so the next read still sees one name.
        #expect(NameOverrides.load(in: v)[strangerJID] == "Rao, Asha")
        #expect(NameOverrides.load(in: v)[savedJID] == "Already Named")
    }

    /// A `lid` chat that WhatsApp does *not* map to a phone is covered above. This is the harder one: a LID chat
    /// that maps through a phone JID the address book does not know. The chat JID (the LID) is what the list shows
    /// and what a typed name is saved under, so the name has to win even though the resolver looked up the phone.
    func makeMappedLidVault() throws -> (vault: Vault, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unnamed-lid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE jid_map(lid_row_id INTEGER PRIMARY KEY, jid_row_id INT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER, display_name TEXT, username TEXT);
        INSERT INTO jid VALUES
          (3,'445566','lid',0,0,0,'445566@lid'),
          (8,'919800000204','s.whatsapp.net',0,0,0,'919800000204@s.whatsapp.net');
        INSERT INTO jid_map VALUES (3,8);
        INSERT INTO chat VALUES (12,3,NULL);
        INSERT INTO message VALUES (1,12,0,3,5000,0,'one','m1'),(2,12,0,3,6000,0,'two','m2');
        """)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: dir.appendingPathComponent("m.db").path, label: "t")
        return (vault, dir)
    }

    @Test func aLidChatThatMapsToAPhoneStillTakesATypedName() throws {
        let (v, dir) = try makeMappedLidVault()
        let before = try rows(try build(v, dir))
        #expect(before.map(\.jid) == [lidJID])                  // listed by its LID, as a person
        #expect(before.first?.kind == .person)

        try NameOverrides.set("Chemist", for: lidJID, in: v)
        let rebuilt = try build(v, dir, name: "rebuilt.db")
        let named = try chatNames(rebuilt)
        #expect(named[lidJID]?.name == "Chemist")
        #expect(named[lidJID]?.resolved == 1)
        #expect(try rows(rebuilt).isEmpty)
        // The messages in that chat are from them, so the sender label moves with the chat.
        var senders: [String] = []
        try SQLiteDB(path: rebuilt, readOnly: true).query("SELECT DISTINCT sender FROM messages WHERE chat_id=(SELECT chat_id FROM chats WHERE jid='\(lidJID)')") {
            senders.append($0.text(0) ?? "")
        }
        #expect(senders == ["Chemist"])
    }

    // MARK: merging into a person the owner already knows

    /// The obsolete-number case the owner reported: a number they already have under a contact must fold
    /// into that person's history, take that person's name, and stop appearing here after the rebuild.
    @Test func mergingAnUnnamedChatIntoAKnownPersonFoldsItsHistory() throws {
        let (v, dir) = try makeVault()
        _ = try build(v, dir)
        let strangerKey = try #require(VaultStore.personKey(forJID: strangerJID))
        let savedKey = try #require(VaultStore.personKey(forJID: savedJID))
        #expect(strangerKey == "9800000201")     // the key the merge is written under
        #expect(savedKey == "9800000203")

        // What the row's "Merge into…" writes: the known person's key first, so their name and identity
        // stay primary, and the dead number joins as a member.
        try MergeConfig.add(keys: [savedKey, strangerKey], name: "Saved Person", to: v)

        let rebuilt = try build(v, dir, name: "merged.db")
        // Gone from the unnamed list — and from the archive's "unnamed" count, not just this page.
        #expect(!(try jids(rebuilt)).contains(strangerJID))
        #expect(try rows(rebuilt).count == 5)
        #expect(try VaultStore(path: rebuilt).unnamedChatCount() == 5)

        // The chat carries the existing person's name and is resolved: never the number.
        let named = try chatNames(rebuilt)
        #expect(named[strangerJID]?.name == "Saved Person")
        #expect(named[strangerJID]?.resolved == 1)

        // The merged person owns both numbers' history: 3 received on the dead number + 2 on the saved one.
        let store = try VaultStore(path: rebuilt)
        let person = try #require(try store.people(matching: "Saved Person", sort: .mostMessages, namedOnly: true, limit: 10)
            .first { $0.key == savedKey })
        #expect(person.received == 5)
        var senders: [String] = []
        try SQLiteDB(path: rebuilt, readOnly: true)
            .query("SELECT DISTINCT sender FROM messages WHERE chat_id=(SELECT chat_id FROM chats WHERE jid='\(strangerJID)')") {
                senders.append($0.text(0) ?? "")
            }
        // One of the four was the owner's own message; the rest now read as the person they were merged into.
        #expect(Set(senders) == ["Saved Person", "me"])

        // An ordinary merge group, so Merge contacts can unmerge it: both keys, the person's name.
        let group = try #require(MergeConfig.loadChecked(v).first)
        #expect(Set(group.keys) == [savedKey, strangerKey])
        #expect(group.name == "Saved Person")
    }

    /// A chat named here first, then merged into someone else: the merge's name wins, the row stays gone,
    /// and unmerging puts the typed name back because nothing was rewritten.
    @Test func aNamedChatMergedIntoAPersonKeepsThatPersonAndCanBeUnmerged() throws {
        let (v, dir) = try makeVault()
        _ = try build(v, dir)
        try NameOverrides.set("Old Chemist", for: quietJID, in: v)
        let quietKey = try #require(VaultStore.personKey(forJID: quietJID))
        let savedKey = try #require(VaultStore.personKey(forJID: savedJID))
        try MergeConfig.add(keys: [savedKey, quietKey], name: "Saved Person", to: v)

        let rebuilt = try build(v, dir, name: "named-merged.db")
        let named = try chatNames(rebuilt)
        #expect(named[quietJID]?.name == "Saved Person")    // the merge's name, not the typed one
        #expect(named[quietJID]?.resolved == 1)
        #expect(!(try jids(rebuilt)).contains(quietJID))

        let group = try #require(MergeConfig.loadChecked(v).first)
        try MergeConfig.remove(group, from: v)
        let undone = try build(v, dir, name: "unmerged.db")
        #expect(try chatNames(undone)[quietJID]?.name == "Old Chemist")
    }

    @Test func anEmptyNameIsNotWrittenAndClearRemovesOnlyThatRow() throws {
        let (v, dir) = try makeVault()
        try NameOverrides.set("Someone", for: strangerJID, in: v)
        try NameOverrides.set("   ", for: quietJID, in: v)
        #expect(NameOverrides.load(in: v)[quietJID] == nil)
        try NameOverrides.clear(for: strangerJID, in: v)
        #expect(NameOverrides.load(in: v).isEmpty)
        _ = dir
    }
}
