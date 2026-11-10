import XCTest
import CryptoKit
@testable import SagaCore

/// End-to-end contact workflow: a suggestion is applied exactly as the merge sheet does it, the archive is rebuilt,
/// and every piece of data that predated the merge (cleanup rules, saved summaries, both numbers) must still be
/// reachable — then unmerging must put everything back. All identities, names and text are synthetic and temporary.
final class MergeWorkflowTests: XCTestCase {
    let day: Int64 = 86_400_000
    let aJID = "919833052771@s.whatsapp.net"     // person key 9833052771, the busier number
    let bJID = "971501234567@s.whatsapp.net"     // person key 1501234567
    let groupJID = "1203630000@g.us"
    let otherJID = "919800000009@s.whatsapp.net"
    let aKey = "9833052771"
    let bKey = "1501234567"

    struct Msg { var ts: Int64; var text: String; var sender: String? = nil; var fromMe = false }
    struct ChatSpec { var jid: String; var group = false; var subject: String? = nil; var messages: [Msg] = [] }

    struct Fixture {
        let vault: Vault
        let dir: URL
        let index: String
        let names: [String: String]
        func rebuild() throws { _ = try VaultIndexer.build(vault: vault, out: index, extraContacts: names) }
        func store() throws -> VaultStore { try VaultStore(path: index) }
        func report() throws -> MergeSuggestionReport { try store().mergeSuggestionReport(vault: vault) }
        func count(_ sql: String) throws -> Int { Int(try SQLiteDB(path: index, readOnly: true).scalarInt(sql)) }
        func textCount(_ text: String) throws -> Int { try count("SELECT count(*) FROM messages WHERE text='\(text)'") }
        /// Hash of every segment file: merges must never rewrite the archive itself.
        func segmentsDigest() throws -> String {
            let segments = vault.url.appendingPathComponent("segments")
            let files = try FileManager.default.contentsOfDirectory(at: segments, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent).sorted()
            var hash = SHA256()
            for name in files {
                hash.update(data: Data(name.utf8))
                hash.update(data: try Data(contentsOf: segments.appendingPathComponent(name)))
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    func fixture(_ chats: [ChatSpec], push: [String: String] = [:], names: [String: String] = [:]) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var jids: [String] = []
        func jidRow(_ raw: String) -> Int {
            if let i = jids.firstIndex(of: raw) { return i + 1 }
            jids.append(raw); return jids.count
        }
        for chat in chats { _ = jidRow(chat.jid) }
        for chat in chats { for msg in chat.messages { if let sender = msg.sender { _ = jidRow(sender) } } }

        var sql = """
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        CREATE TABLE lid_display_name(lid_row_id INTEGER PRIMARY KEY, display_name TEXT, username TEXT);
        """
        for (i, raw) in jids.enumerated() {
            let at = raw.lastIndex(of: "@")
            let user = at.map { String(raw[..<$0]) } ?? raw
            let server = at.map { String(raw[raw.index(after: $0)...]) } ?? ""
            sql += "\nINSERT INTO jid VALUES (\(i + 1),'\(user)','\(server)',0,0,0,'\(raw)');"
        }
        for (i, chat) in chats.enumerated() {
            let subject = chat.subject.map { "'\($0)'" } ?? "NULL"
            sql += "\nINSERT INTO chat VALUES (\(10 + i),\(jidRow(chat.jid)),\(subject));"
        }
        for (raw, name) in push {
            guard let row = jids.firstIndex(of: raw) else { continue }
            sql += "\nINSERT INTO lid_display_name VALUES (\(row + 1),'\(name)',NULL);"
        }
        for (ci, chat) in chats.enumerated() {
            for (mi, msg) in chat.messages.enumerated() {
                let sender = msg.sender.map { String(jidRow($0)) } ?? "NULL"
                sql += "\nINSERT INTO message VALUES (\(ci * 1000 + mi + 1),\(10 + ci),\(msg.fromMe ? 1 : 0),\(sender),\(msg.ts),0,'\(msg.text)','k\(ci)-\(mi)');"
            }
        }
        let dbPath = dir.appendingPathComponent("m.db").path
        try SQLiteDB(path: dbPath, readOnly: false).exec(sql)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: dbPath, label: "t")
        let index = dir.appendingPathComponent("i.db").path
        _ = try VaultIndexer.build(vault: vault, out: index, extraContacts: names)
        return Fixture(vault: vault, dir: dir, index: index, names: names)
    }

    /// Two numbers saved under one name, the same WhatsApp profile name on both, and the old DM going quiet before
    /// the new one starts — every suggestion signal at once. The old number is busier, and the shared group makes
    /// the new number post under the merged person key.
    func mainFixture() throws -> Fixture {
        let group: [Msg] = [
            Msg(ts: 7 * day, text: "group one from A", sender: aJID),
            Msg(ts: 7 * day + 1, text: "group two from A", sender: aJID),
            Msg(ts: 7 * day + 2, text: "group three from A", sender: aJID),
            Msg(ts: 7 * day + 3, text: "group four from A", sender: aJID),
            Msg(ts: 7 * day + 4, text: "group five from A", sender: aJID),
            Msg(ts: 7 * day + 5, text: "group six from A", sender: aJID),
            Msg(ts: 8 * day, text: "group from B", sender: bJID),
        ]
        return try fixture([
            ChatSpec(jid: aJID, messages: [
                Msg(ts: day + 1_000, text: "old number hi"),
                Msg(ts: day + 2_000, text: "https://old.example/a"),
                Msg(ts: day + 3_000, text: "same long repeated line here"),
                Msg(ts: day + 4_000, text: "same long repeated line here"),
            ]),
            ChatSpec(jid: bJID, messages: [
                Msg(ts: 6 * day, text: "new number hi"),
                Msg(ts: 6 * day + 1_000, text: "https://new.example/b"),
                Msg(ts: 6 * day + 2_000, text: "line from the new number"),
                Msg(ts: 6 * day + 3_000, text: "line from the new number"),
            ]),
            ChatSpec(jid: groupJID, group: true, subject: "Club", messages: group),
            ChatSpec(jid: otherJID, messages: [Msg(ts: 9 * day, text: "other person hi")]),
        ], push: [aJID: "Asha Rao", bJID: "Asha Rao"],
           names: [aKey: "Asha", bKey: "Asha", "9800000009": "Ravi"])
    }

    func fullNumber(_ jid: String) -> String { "+" + String(jid[..<(jid.firstIndex(of: "@") ?? jid.endIndex)]) }

    func summary(_ cache: AICache, _ key: String, created: Int64, text: String) throws {
        let points = AICache.encode([AICache.StoredPoint(text: text, uids: [])])
        try cache.db.prepare("INSERT OR REPLACE INTO summaries VALUES(?,?,?,?,?)")
            .run([.text(key), .int(created), .int(0), .int(1), .text(points)])
    }

    // MARK: suggestion -> merge -> persisted state -> unmerge

    func testSuggestionMergeCarriesRulesSummariesAndNumbersThenUnmergeRestoresEverything() throws {
        let f = try mainFixture()
        let digestBefore = try f.segmentsDigest()

        // The archive suggests exactly this pair, with all three signals and no automatic merge.
        let report = try f.report()
        XCTAssertEqual(report.suggestions.count, 1)
        let suggestion = try XCTUnwrap(report.suggestions.first)
        XCTAssertEqual(Set(suggestion.people.map(\.key)), [aKey, bKey])
        XCTAssertEqual(suggestion.people.map(\.key), [aKey, bKey])          // busiest first: the merged primary
        XCTAssertEqual(suggestion.name, "Asha")
        XCTAssertEqual(suggestion.reasons.first?.weight, 3)                 // strongest evidence listed first
        XCTAssertEqual(Set(suggestion.reasons), [
            .sameName, .sameUpstreamName,
            .dmHandoff(gapDays: Int((6 * day - (day + 4_000)) / day), sharedGroups: 1),
        ])
        XCTAssertEqual(suggestion.confidence, .high)
        // The no-vault entry point keeps working and finds the same pair.
        XCTAssertEqual(try f.store().mergeSuggestions().map(\.id), [suggestion.id])

        // Data the user had before merging: one cleanup rule per number, one saved summary per number.
        var link = PruneRule(chat: aJID, label: "Asha"); link.dropLinkOnly = true
        var dups = PruneRule(chat: bJID, label: "Asha"); dups.dropDuplicates = true
        try PruneConfig.save([link, dups], to: f.vault)
        try f.rebuild()
        let cache = try AICache(path: f.dir.appendingPathComponent("ai.db").path)
        let suffix = "|30|m1|quick"
        try summary(cache, aJID + suffix, created: 100, text: "summary for the old number")
        try summary(cache, bJID + suffix, created: 200, text: "summary for the new number")
        try summary(cache, bJID + "|7|m1|quick", created: 999, text: "different period, must be ignored")

        // Pre-merge sanity: each rule only affects its own chat.
        XCTAssertEqual(try f.textCount("https://old.example/a"), 0)
        XCTAssertEqual(try f.textCount("https://new.example/b"), 1)
        XCTAssertEqual(try f.textCount("same long repeated line here"), 2)
        XCTAssertEqual(try f.textCount("line from the new number"), 1)

        // Apply exactly what the merge sheet does: the suggestion's people and name.
        try MergeConfig.add(keys: suggestion.people.map(\.key), name: suggestion.name, to: f.vault)
        try f.rebuild()

        let store = try f.store()
        XCTAssertTrue(try f.report().suggestions.isEmpty)                    // the same pair is never suggested again

        // One person with both original numbers, shown in full.
        XCTAssertEqual(store.mergeMembers(person: aKey).count, 2)
        let detail = try store.detail(for: aKey)
        XCTAssertEqual(detail.numbers.count, 2)
        XCTAssertEqual(Set(detail.numbers.map(\.display)), [fullNumber(aJID), fullNumber(bJID)])
        XCTAssertTrue(detail.numbers.allSatisfy(\.isPhone))

        // The merged conversation is one chat with every member's messages, and the person page points at it.
        let dm = try XCTUnwrap(detail.dmChat)
        XCTAssertFalse(dm.isGroup)
        XCTAssertEqual(dm.jid, aJID)                                        // lexically first JID survives
        XCTAssertEqual(store.mergedJIDs(chatJID: aJID), [aJID, bJID].sorted())
        XCTAssertEqual(store.mergedJIDs(chatJID: bJID), [aJID, bJID].sorted())
        XCTAssertEqual(detail.dmChat?.count, 4)
        XCTAssertEqual(try f.count("SELECT count(*) FROM messages m JOIN chats c USING(chat_id) WHERE c.person='\(aKey)' AND c.is_group=0"), 4)

        // Cleanup rules saved for either number now apply to the merged conversation...
        XCTAssertEqual(try f.textCount("https://old.example/a"), 0)
        XCTAssertEqual(try f.textCount("https://new.example/b"), 0)
        XCTAssertEqual(try f.textCount("same long repeated line here"), 1)
        XCTAssertEqual(try f.textCount("line from the new number"), 1)
        XCTAssertEqual(try f.textCount("old number hi"), 1)
        XCTAssertEqual(try f.textCount("new number hi"), 1)
        // ...the stored rules are untouched (one per original number), so unmerge is lossless...
        let stored = PruneConfig.load(f.vault)
        XCTAssertEqual(stored.map(\.chat).sorted(), [aJID, bJID].sorted())
        XCTAssertEqual(stored.first { $0.chat == aJID }?.dropLinkOnly, true)
        XCTAssertEqual(stored.first { $0.chat == bJID }?.dropDuplicates, true)
        // ...and the editor sees one effective rule for the merged conversation.
        let byJID = Dictionary(stored.map { ($0.chat, $0) }, uniquingKeysWith: { _, last in last })
        let union = try XCTUnwrap(MergeIdentity.unionRule(jids: store.mergedJIDs(chatJID: aJID), rules: byJID))
        XCTAssertTrue(union.dropLinkOnly)
        XCTAssertTrue(union.dropDuplicates)
        XCTAssertEqual(MergeIdentity.effectiveRuleRows(stored, members: [
            aJID: [aJID, bJID], bJID: [aJID, bJID],
        ]).count, 1)

        // Saved summaries for both numbers stay reachable, and a new summary writes under the member-set key.
        let keys = try XCTUnwrap(SummaryCacheKeys.make(chatJIDs: store.mergedJIDs(chatJID: dm.jid), days: 30, modelID: "m1", detail: "quick"))
        XCTAssertEqual(keys.readKeys, [aJID, bJID].sorted().map { $0 + suffix } + [keys.writeKey])
        XCTAssertEqual(cache.latestSummary(keys: keys.readKeys)?.summary.points.first?.text, "summary for the new number")
        cache.saveSummary(key: keys.writeKey, lastTS: 0, messageCount: 4, points: [.init(text: "merged summary", uids: [])])
        XCTAssertEqual(cache.summary(key: aJID + suffix)?.points.first?.text, "summary for the old number")
        XCTAssertEqual(cache.summary(key: bJID + suffix)?.points.first?.text, "summary for the new number")
        XCTAssertEqual(cache.latestSummary(keys: keys.readKeys)?.key, keys.writeKey)      // newest wins

        // No ignores were involved, and the archive itself was never rewritten.
        XCTAssertTrue(try f.report().ignored.isEmpty)
        XCTAssertEqual(try f.segmentsDigest(), digestBefore)

        // Unmerge: same suggestion comes back, single identities, original rule effects and cache entries.
        try MergeConfig.remove(try XCTUnwrap(MergeConfig.load(f.vault).first), from: f.vault)
        try f.rebuild()
        let after = try f.report()
        XCTAssertEqual(after.suggestions.count, 1)
        XCTAssertEqual(after.suggestions.first?.id, suggestion.id)
        XCTAssertEqual(Set(try XCTUnwrap(after.suggestions.first).reasons), Set(suggestion.reasons))

        let restored = try f.store()
        XCTAssertEqual(restored.mergedJIDs(chatJID: aJID), [aJID])
        XCTAssertEqual(try restored.detail(for: aKey).numbers.count, 1)
        XCTAssertEqual(try restored.detail(for: bKey).numbers.count, 1)
        XCTAssertEqual(try f.textCount("https://old.example/a"), 0)          // the old number's own rule
        XCTAssertEqual(try f.textCount("https://new.example/b"), 1)          // back to its original effect
        XCTAssertEqual(try f.textCount("same long repeated line here"), 2)
        XCTAssertEqual(try f.textCount("line from the new number"), 1)       // the new number's own rule
        let ownKeys = try XCTUnwrap(SummaryCacheKeys.make(chatJIDs: restored.mergedJIDs(chatJID: aJID), days: 30, modelID: "m1", detail: "quick"))
        XCTAssertEqual(ownKeys.readKeys, [aJID + suffix])
        XCTAssertEqual(cache.latestSummary(keys: ownKeys.readKeys)?.summary.points.first?.text, "summary for the old number")
        XCTAssertNotNil(cache.summary(key: keys.writeKey))                  // the merged result is kept, just unreachable
        XCTAssertEqual(try f.segmentsDigest(), digestBefore)
    }

    func testMergeInTheOppositePrimaryOrderStillCarriesTheDiscardedNumbersData() throws {
        let f = try mainFixture()
        // Rules deliberately on the numbers whose JID does not survive: link on B, repeats on A.
        var link = PruneRule(chat: bJID, label: "Asha"); link.dropLinkOnly = true
        var dups = PruneRule(chat: aJID, label: "Asha"); dups.dropDuplicates = true
        try PruneConfig.save([link, dups], to: f.vault)
        try f.rebuild()
        let cache = try AICache(path: f.dir.appendingPathComponent("ai.db").path)
        let suffix = "|14|m2|balanced"
        try summary(cache, aJID + suffix, created: 100, text: "old")
        try summary(cache, bJID + suffix, created: 300, text: "new")

        // The user keeps the new number (the one whose chat JID sorts last).
        try MergeConfig.add(keys: [bKey, aKey], name: "Asha Rao", to: f.vault)
        try f.rebuild()
        let store = try f.store()

        XCTAssertEqual(store.mergedJIDs(chatJID: aJID), [aJID, bJID].sorted())
        let detail = try store.detail(for: bKey)
        XCTAssertEqual(detail.numbers.count, 2)
        XCTAssertEqual(detail.dmChat?.count, 4)
        XCTAssertEqual(try f.count("SELECT count(*) FROM chats WHERE person='\(bKey)' AND is_group=0 AND jid='\(aJID)'"), 1)
        XCTAssertEqual(try f.count("SELECT count(*) FROM chats WHERE jid='\(bJID)'"), 0)     // folded away
        XCTAssertEqual(try f.textCount("https://new.example/b"), 0)                          // rule from the discarded JID
        XCTAssertEqual(try f.textCount("same long repeated line here"), 1)                   // rule from the other one
        XCTAssertEqual(try f.textCount("line from the new number"), 1)                       // ...now applied to B too
        let mergedKeys = try XCTUnwrap(SummaryCacheKeys.make(chatJIDs: store.mergedJIDs(chatJID: aJID), days: 14, modelID: "m2", detail: "balanced"))
        XCTAssertEqual(cache.latestSummary(keys: mergedKeys.readKeys)?.summary.points.first?.text, "new")

        try MergeConfig.remove(try XCTUnwrap(MergeConfig.load(f.vault).first), from: f.vault)
        try f.rebuild()
        let restored = try f.store()
        XCTAssertEqual(try restored.detail(for: bKey).numbers.count, 1)
        XCTAssertEqual(try restored.detail(for: aKey).numbers.count, 1)
        XCTAssertEqual(try f.textCount("https://new.example/b"), 0)                          // B still hides its own links
        XCTAssertEqual(try f.textCount("same long repeated line here"), 1)                   // A still hides its own repeats
        XCTAssertEqual(try f.textCount("line from the new number"), 2)                       // B got its messages back
    }

    // MARK: ignores across a merge

    func testIgnoredSuggestionKeepsItsExactSetThroughAMergeAndUnmerge() throws {
        let f = try mainFixture()
        let original = try XCTUnwrap(try f.report().suggestions.first)
        try MergeSuggestionIgnores.add(original.people.map(\.key), to: f.vault)
        XCTAssertTrue(try f.report().suggestions.isEmpty)
        XCTAssertEqual(try f.report().ignored.map(\.keys), [original.people.map(\.key).sorted()])

        // The user merges the same pair by hand from the manual picker, in the other order.
        try MergeConfig.add(keys: [bKey, aKey], name: "Asha Ra", to: f.vault)
        try f.rebuild()
        let report = try f.report()
        XCTAssertTrue(report.suggestions.isEmpty)
        XCTAssertEqual(report.ignored.count, 1)
        XCTAssertEqual(report.ignored.first?.keys, original.people.map(\.key).sorted())      // exact set, unchanged
        XCTAssertEqual(report.ignored.first?.people.map(\.key), [bKey])                     // shown as the merged person
        XCTAssertEqual(report.ignored.first?.isNowMerged, true)

        // Unmerge: the ignore is still exact, so the suggestion stays hidden until it is explicitly restored.
        try MergeConfig.remove(try XCTUnwrap(MergeConfig.load(f.vault).first), from: f.vault)
        try f.rebuild()
        XCTAssertTrue(try f.report().suggestions.isEmpty)
        try MergeSuggestionIgnores.remove(try XCTUnwrap(try f.report().ignored.first).keys, from: f.vault)
        let restored = try f.report()
        XCTAssertEqual(restored.suggestions.map(\.id), [original.id])
        XCTAssertTrue(restored.ignored.isEmpty)
    }

    // MARK: a suggestion whose keys normalization does not collapse

    func testTrailingDigitSuggestionMergesTwoDistinctKeysIntoOneConversation() throws {
        let long = "9123456789@s.whatsapp.net"       // key 9123456789
        let short = "123456789@s.whatsapp.net"       // key 123456789
        let f = try fixture([
            ChatSpec(jid: long, messages: [Msg(ts: 1_000, text: "long number hi")]),
            ChatSpec(jid: short, messages: [Msg(ts: 2_000, text: "short number hi")]),
        ], names: ["9123456789": "Old Line", "123456789": "New Line"])

        let suggestion = try XCTUnwrap(try f.report().suggestions.first)
        XCTAssertEqual(suggestion.reasons, [.sharedTrailingDigits(9)])
        XCTAssertEqual(suggestion.confidence, .low)
        XCTAssertEqual(Set(suggestion.people.map(\.key)), ["123456789", "9123456789"])

        try MergeConfig.add(keys: suggestion.people.map(\.key), name: "Line", to: f.vault)
        try f.rebuild()
        let store = try f.store()
        let detail = try store.detail(for: "123456789")
        XCTAssertEqual(detail.numbers.count, 2)
        XCTAssertEqual(Set(detail.numbers.map(\.display)), [fullNumber(long), fullNumber(short)])
        XCTAssertEqual(detail.dmChat?.count, 2)
        XCTAssertTrue(try f.report().suggestions.isEmpty)

        try MergeConfig.remove(try XCTUnwrap(MergeConfig.load(f.vault).first), from: f.vault)
        try f.rebuild()
        XCTAssertEqual(try f.report().suggestions.map(\.id), [suggestion.id])
        XCTAssertEqual(try f.store().mergeMembers(person: "123456789").count, 1)
    }

    // MARK: cleanup-rule list at the seam

    func testCleanupRuleListCollapsesAMergedPersonIntoOneRow() {
        var link = PruneRule(chat: aJID, label: "Asha"); link.dropLinkOnly = true
        var dups = PruneRule(chat: bJID, label: "Asha"); dups.dropDuplicates = true
        var group = PruneRule(chat: groupJID, label: "Club"); group.dropMedia = true
        var single = PruneRule(chat: otherJID, label: "Ravi"); single.dropDuplicates = true

        let rows = MergeIdentity.effectiveRuleRows([link, dups, group, single], members: [
            aJID: [aJID, bJID], bJID: [aJID, bJID],
        ])
        XCTAssertEqual(rows.count, 3)                                        // merged person once, group, other person
        let merged = rows.first { $0.chat == [aJID, bJID].sorted()[0] }
        XCTAssertEqual(merged?.dropLinkOnly, true)
        XCTAssertEqual(merged?.dropDuplicates, true)
        XCTAssertEqual(merged?.label, "Asha")
        XCTAssertEqual(merged?.summary, "Hiding repeats, link-only posts")
        XCTAssertTrue(rows.contains { $0.chat == groupJID && $0.dropMedia })
        XCTAssertTrue(rows.contains { $0.chat == otherJID && $0.dropDuplicates })
        XCTAssertFalse(rows.contains { $0.chat == bJID })                   // no duplicate row for the second number
    }
}
