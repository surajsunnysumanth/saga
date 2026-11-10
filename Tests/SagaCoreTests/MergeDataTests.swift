import XCTest
@testable import SagaCore

/// Merge-data behaviour: rules, saved summaries, numbers and identities must survive a merge and come back
/// unchanged after an unmerge. All fixtures are synthetic and temporary.
final class MergeDataTests: XCTestCase {
    let aJID = "919833052771@s.whatsapp.net"      // old number, person key 9833052771
    let bJID = "971501234567@s.whatsapp.net"      // new number, person key 1501234567
    let lidJID = "445566@lid"                     // unmapped LID, person key lid:445566
    let groupJID = "1203630000@g.us"

    /// Two numbers of one person (different country codes), one group where the new number posts, one unrelated
    /// person and one unmapped LID. The old number's JID sorts before the new one, so a merge can be primary on
    /// the key whose JID is not the surviving chat row.
    func vault() throws -> (Vault, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-mergedata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try db.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER, display_name TEXT, username TEXT);
        INSERT INTO jid VALUES
          (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net'),
          (2,'971501234567','s.whatsapp.net',0,0,0,'971501234567@s.whatsapp.net'),
          (3,'1203630000','g.us',0,0,0,'1203630000@g.us'),
          (4,'919800000009','s.whatsapp.net',0,0,0,'919800000009@s.whatsapp.net'),
          (5,'445566','lid',0,0,0,'445566@lid');
        INSERT INTO lid_display_name VALUES (5,'Ghost',NULL);
        INSERT INTO chat VALUES (10,1,NULL),(11,2,NULL),(12,3,'Club'),(13,4,NULL),(14,5,NULL);
        INSERT INTO message VALUES
          (1,10,0,NULL,1000,0,'old number hi','a1'),
          (2,10,0,NULL,2000,0,'https://old.example/a','a2'),
          (3,10,0,NULL,3000,0,'same long repeated line here','a3'),
          (4,10,0,NULL,4000,0,'same long repeated line here','a4'),
          (5,11,0,NULL,5000,0,'new number hi','b1'),
          (6,11,0,NULL,6000,0,'https://new.example/b','b2'),
          (7,12,0,2,7000,0,'group message from B','g1'),
          (8,13,0,NULL,8000,0,'other person hi','o1'),
          (9,14,0,NULL,9000,0,'from the lid','l1');
        """)
        let v = try Vault(url: dir.appendingPathComponent("v"))
        _ = try v.ingest(msgstore: dir.appendingPathComponent("m.db").path, label: "t")
        return (v, dir)
    }

    func build(_ v: Vault, _ dir: URL, _ name: String = "i.db") throws -> String {
        let idx = dir.appendingPathComponent(name).path
        _ = try VaultIndexer.build(vault: v, out: idx, extraContacts: ["9833052771": "Asha", "1501234567": "Asha", "9800000009": "Ravi"])
        return idx
    }

    func count(_ idx: String, _ sql: String) throws -> Int {
        Int(try SQLiteDB(path: idx, readOnly: true).scalarInt(sql))
    }

    func textCount(_ idx: String, _ text: String) throws -> Int {
        try count(idx, "SELECT count(*) FROM messages WHERE text='\(text)'")
    }

    // MARK: Rules across merges

    func testRulesFromBothNumbersApplyToTheMergedConversationAndUnmergeRestores() throws {
        let (v, dir) = try vault()
        var link = PruneRule(chat: aJID, label: "Asha"); link.dropLinkOnly = true
        var dups = PruneRule(chat: bJID, label: "Asha"); dups.dropDuplicates = true
        try PruneConfig.save([link, dups], to: v)
        var idx = try build(v, dir)

        // Before the merge each rule only affects its own chat.
        XCTAssertEqual(try textCount(idx, "https://old.example/a"), 0)
        XCTAssertEqual(try textCount(idx, "https://new.example/b"), 1)
        XCTAssertEqual(try textCount(idx, "same long repeated line here"), 2)            // the duplicate rule is on the other number

        try MergeConfig.add(keys: ["1501234567", "9833052771"], name: "Asha", to: v)   // primary key's JID sorts last
        idx = try build(v, dir)
        let q = try SQLiteDB(path: idx, readOnly: true)
        // The merged conversation accepts rules saved for either number.
        XCTAssertEqual(try textCount(idx, "https://old.example/a"), 0)
        XCTAssertEqual(try textCount(idx, "https://new.example/b"), 0)                  // link rule from the old number
        XCTAssertEqual(try textCount(idx, "same long repeated line here"), 1)           // duplicate rule from the new number
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM messages m JOIN chats c USING(chat_id) WHERE c.name='Asha'"), 3)
        let survivor = try q.scalarInt("SELECT count(*) FROM chats c WHERE c.name='Asha' AND c.person='1501234567'")
        XCTAssertEqual(survivor, 1)                                                     // shown as keys[0], not the surviving JID

        // The persisted rules are untouched: still one per original number.
        XCTAssertEqual(PruneConfig.load(v).map(\.chat).sorted(), [aJID, bJID].sorted())

        try MergeConfig.remove(MergeConfig.load(v)[0], from: v)
        idx = try build(v, dir)
        XCTAssertEqual(try textCount(idx, "https://old.example/a"), 0)
        XCTAssertEqual(try textCount(idx, "https://new.example/b"), 1)                  // back to the original effect
        XCTAssertEqual(try textCount(idx, "same long repeated line here"), 2)
    }

    func testRulesSurviveEitherPrimaryOrder() throws {
        for order in [["1501234567", "9833052771"], ["9833052771", "1501234567"]] {
            let (v, dir) = try vault()
            var link = PruneRule(chat: aJID, label: "Asha"); link.dropLinkOnly = true
            var dups = PruneRule(chat: bJID, label: "Asha"); dups.dropDuplicates = true
            try PruneConfig.save([link, dups], to: v)
            try MergeConfig.add(keys: order, name: "Asha", to: v)
            let idx = try build(v, dir)
            XCTAssertEqual(try textCount(idx, "https://new.example/b"), 0, "order \(order)")
            XCTAssertEqual(try textCount(idx, "same long repeated line here"), 1, "order \(order)")
            let st = try VaultStore(path: idx)
            XCTAssertEqual(try st.detail(for: order[0]).numbers.count, 2, "order \(order)")
            // The surviving chat row is the lexically first JID even when it is not keys[0].
            XCTAssertEqual(try VaultStore(path: idx).mergedJIDs(chatJID: aJID), [aJID, bJID].sorted(), "order \(order)")
        }
    }

    func testHiddenMemberHidesTheMergedConversationAndUnmergeRestores() throws {
        let (v, dir) = try vault()
        var hideB = PruneRule(chat: bJID, label: "Asha"); hideB.hideChat = true
        try PruneConfig.save([hideB], to: v)
        var idx = try build(v, dir)
        XCTAssertEqual(try textCount(idx, "old number hi"), 1)                     // old number still visible
        XCTAssertEqual(try textCount(idx, "new number hi"), 0)

        try MergeConfig.add(keys: ["1501234567", "9833052771"], name: "Asha", to: v)
        idx = try build(v, dir)
        XCTAssertEqual(try count(idx, "SELECT count(*) FROM messages m JOIN chats c USING(chat_id) WHERE c.name='Asha'"), 0)

        try MergeConfig.remove(MergeConfig.load(v)[0], from: v)
        idx = try build(v, dir)
        XCTAssertEqual(try textCount(idx, "old number hi"), 1)
        XCTAssertEqual(try textCount(idx, "new number hi"), 0)
    }

    func testSenderExclusionFollowsThePersonAcrossAMerge() throws {
        let (v, dir) = try vault()
        var spam = PruneRule(chat: groupJID, label: "Club"); spam.dropSenders = ["1501234567"]   // the old key
        try PruneConfig.save([spam], to: v)
        var idx = try build(v, dir)
        XCTAssertEqual(try textCount(idx, "group message from B"), 0)

        // keys[0] is the other number, so indexing rewrites the group message to that person key. The exclusion
        // must be resolved through merge membership or it would silently stop working.
        try MergeConfig.add(keys: ["9833052771", "1501234567"], name: "Asha", to: v)
        idx = try build(v, dir)
        XCTAssertEqual(try textCount(idx, "group message from B"), 0)

        try MergeConfig.remove(MergeConfig.load(v)[0], from: v)
        idx = try build(v, dir)
        XCTAssertEqual(try textCount(idx, "group message from B"), 0)
    }

    func testEffectiveRulesAreUnionedForTheConversationOnly() {
        let group = "1203630000@g.us"
        var groupRule = PruneRule(chat: group, label: "Club"); groupRule.dropMedia = true
        var link = PruneRule(chat: aJID, label: "Asha"); link.dropLinkOnly = true
        var dups = PruneRule(chat: bJID, label: "Asha"); dups.dropDuplicates = true; dups.dropSenders = ["9999"]
        let merge = PersonMerge(keys: ["1501234567", "9833052771"], name: "Asha")

        let effective = MergeIdentity.effectiveRules([groupRule, link, dups], merges: [merge],
                                                     conversationMembers: ["1501234567": [aJID, bJID]])
        let byJID = Dictionary(effective.map { ($0.chat, $0) }, uniquingKeysWith: { _, l in l })
        XCTAssertEqual(byJID.count, 3)
        XCTAssertTrue(byJID[aJID]?.dropLinkOnly == true)
        XCTAssertTrue(byJID[aJID]?.dropDuplicates == true)
        XCTAssertTrue(byJID[bJID]?.dropLinkOnly == true)
        XCTAssertTrue(byJID[bJID]?.dropDuplicates == true)
        XCTAssertEqual(byJID[bJID]?.dropSenders, ["9999"])
        // A group rule stays scoped to that group and never leaks into the merged DM.
        XCTAssertTrue(byJID[group]?.dropMedia == true)
        XCTAssertFalse(byJID[group]?.dropLinkOnly == true)
        XCTAssertFalse(byJID[aJID]?.dropMedia == true)
        XCTAssertNil(MergeIdentity.unionRule(jids: [aJID, bJID], rules: [:]))
    }

    // MARK: Saved summaries

    func testSavedSummariesForBothNumbersStayReachableAndMergedWritesUseSeparateKey() throws {
        let (v, dir) = try vault()
        let idx = try build(v, dir)
        let cache = try AICache(path: dir.appendingPathComponent("ai.db").path)
        let suffix = "|30|m1|quick"
        let aKey = aJID + suffix, bKey = bJID + suffix
        try save(cache, aKey, created: 100, text: "old number summary")
        try save(cache, bKey, created: 200, text: "new number summary")
        try save(cache, bJID + "|7|m1|quick", created: 900, text: "different period")   // must not be considered

        var store = try VaultStore(path: idx)
        let before = SummaryCacheKeys.make(chatJIDs: store.mergedJIDs(chatJID: aJID), days: 30, modelID: "m1", detail: "quick")
        XCTAssertEqual(before?.readKeys, [aKey])
        XCTAssertEqual(cache.latestSummary(keys: before!.readKeys)?.key, aKey)

        try MergeConfig.add(keys: ["1501234567", "9833052771"], name: "Asha", to: v)
        _ = try build(v, dir)
        store = try VaultStore(path: idx)
        let members = store.mergedJIDs(chatJID: aJID)
        XCTAssertEqual(members, [aJID, bJID].sorted())
        let keys = try XCTUnwrap(SummaryCacheKeys.make(chatJIDs: members, days: 30, modelID: "m1", detail: "quick"))
        XCTAssertEqual(keys.readKeys, [aKey, bKey, "person:\(members.joined(separator: ","))" + suffix])
        XCTAssertEqual(keys.writeKey, "person:\(members.joined(separator: ","))" + suffix)
        XCTAssertEqual(cache.latestSummary(keys: keys.readKeys)?.key, bKey)             // newest of the originals
        XCTAssertEqual(cache.latestSummary(keys: keys.readKeys)?.summary.points.first?.text, "new number summary")

        // A summary generated while merged must not overwrite either original.
        cache.saveSummary(key: keys.writeKey, lastTS: 0, messageCount: 2, points: [.init(text: "merged summary", uids: [])])
        XCTAssertEqual(cache.summary(key: aKey)?.points.first?.text, "old number summary")
        XCTAssertEqual(cache.summary(key: bKey)?.points.first?.text, "new number summary")
        XCTAssertTrue(keys.isMergedSummary(keys.writeKey))
        XCTAssertTrue(keys.isOwnSummary(aKey, chatJID: aJID))

        try MergeConfig.remove(MergeConfig.load(v)[0], from: v)
        _ = try build(v, dir)
        store = try VaultStore(path: idx)
        let after = try XCTUnwrap(SummaryCacheKeys.make(chatJIDs: store.mergedJIDs(chatJID: aJID), days: 30, modelID: "m1", detail: "quick"))
        XCTAssertEqual(after.readKeys, [aKey])                                          // merged namespace ignored again
        XCTAssertEqual(cache.latestSummary(keys: after.readKeys)?.key, aKey)
        XCTAssertNotNil(cache.summary(key: keys.writeKey))                              // nothing was deleted
        XCTAssertNil(SummaryCacheKeys.make(chatJIDs: [""], days: 30, modelID: "m1", detail: "quick"))
    }

    func testSummaryCacheTieBreakIsStable() throws {
        let cache = try AICache(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("saga-mergedata-cache-\(UUID().uuidString).db").path)
        try save(cache, bJID, created: 500, text: "b")
        try save(cache, aJID, created: 500, text: "a")
        XCTAssertEqual(cache.latestSummary(keys: [bJID, aJID])?.key, [aJID, bJID].sorted()[0])
    }

    // MARK: Person page and identities

    func testPersonPageShowsEveryOriginalNumberAndDMChatCarriesAJID() throws {
        let (v, dir) = try vault()
        try MergeConfig.add(keys: ["1501234567", "9833052771", "lid:445566"], name: "Asha", to: v)
        let idx = try build(v, dir)
        let store = try VaultStore(path: idx)
        let detail = try store.detail(for: "1501234567")

        XCTAssertEqual(detail.numbers.count, 3)
        XCTAssertTrue(detail.numbers.contains { $0.display == "+919833052771" })       // full international digits
        XCTAssertTrue(detail.numbers.contains { $0.display == "+971501234567" })
        let lid = detail.numbers.first { $0.isUnresolvedLID }
        XCTAssertEqual(lid?.display, "LID 445566")
        XCTAssertEqual(lid?.isPhone, false)                                           // a LID is never a phone number
        XCTAssertFalse(detail.numbers.contains { $0.display == "+9833052771" })        // not the truncated key

        let dm = try XCTUnwrap(detail.dmChat)
        XCTAssertFalse(dm.jid.isEmpty)                                                // detail(for:) used to drop this
        XCTAssertEqual(Set(store.mergedJIDs(chatJID: dm.jid)), Set([aJID, bJID, lidJID]))
        XCTAssertEqual(store.mergeMembers(chatJID: aJID).count, 3)
        XCTAssertEqual(Set(store.mergeMembers(person: "1501234567").map(\.member)), ["1501234567", "9833052771", "lid:445566"])
    }

    func testUnmergeRestoresSingleIdentity() throws {
        let (v, dir) = try vault()
        try MergeConfig.add(keys: ["1501234567", "9833052771"], name: "Asha", to: v)
        var idx = try build(v, dir)
        XCTAssertEqual(try VaultStore(path: idx).mergeMembers(person: "1501234567").count, 2)

        try MergeConfig.remove(MergeConfig.load(v)[0], from: v)
        idx = try build(v, dir)
        let store = try VaultStore(path: idx)
        XCTAssertEqual(store.mergedJIDs(chatJID: aJID), [aJID])
        XCTAssertEqual(try store.detail(for: "9833052771").numbers.count, 1)
        XCTAssertEqual(try store.detail(for: "1501234567").numbers.count, 1)
    }

    func testIndexWithoutMembershipTableFallsBackToSingletons() throws {
        let (v, dir) = try vault()
        let idx = try build(v, dir)
        let q = try SQLiteDB(path: idx, readOnly: false)
        try q.exec("DROP TABLE merge_members")                                        // as an older index would look
        let store = try VaultStore(path: idx)
        XCTAssertFalse(store.hasMergeMembers)
        XCTAssertEqual(store.mergedJIDs(chatJID: aJID), [aJID])
        XCTAssertEqual(try store.detail(for: "9833052771").numbers.count, 1)
        XCTAssertEqual(try store.detail(for: "9833052771").numbers.first?.display, "+919833052771")
    }

    // MARK: helpers

    func save(_ cache: AICache, _ key: String, created: Int64, text: String) throws {
        let points = AICache.encode([.init(text: text, uids: [])])
        try cache.db.prepare("INSERT OR REPLACE INTO summaries VALUES(?,?,?,?,?)")
            .run([.text(key), .int(created), .int(0), .int(1), .text(points)])
    }
}
