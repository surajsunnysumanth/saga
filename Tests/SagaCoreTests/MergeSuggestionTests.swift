import XCTest
@testable import SagaCore

/// Synthetic fixtures only: made-up numbers, names and timestamps. No real library or contact data.
final class MergeSuggestionTests: XCTestCase {
    struct Msg {
        var ts: Int64
        var fromMe = false
        var text = "hello"
        var sender: String? = nil
    }
    struct Chat {
        var jid: String
        var group = false
        var subject: String? = nil
        var messages: [Msg] = []
    }
    struct Fixture {
        let vault: Vault
        let dir: URL
        let index: String
        var names: [String: String]
        func store() throws -> VaultStore { try VaultStore(path: index) }
        func rebuild(names: [String: String]? = nil) throws {
            _ = try VaultIndexer.build(vault: vault, out: index, extraContacts: names ?? self.names)
        }
        func report() throws -> MergeSuggestionReport { try store().mergeSuggestionReport(vault: vault) }
    }

    let day: Int64 = 86_400_000

    func fixture(_ chats: [Chat], push: [String: String] = [:], names: [String: String] = [:],
                 merges: [PersonMerge] = []) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-suggest-\(UUID().uuidString)")
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
            sql += "\nINSERT INTO chat VALUES (\(i + 1),\(jidRow(chat.jid)),\(subject));"
        }
        for (raw, name) in push {
            guard let row = jids.firstIndex(of: raw) else { continue }
            sql += "\nINSERT INTO lid_display_name VALUES (\(row + 1),'\(name)',NULL);"
        }
        for (ci, chat) in chats.enumerated() {
            for (mi, msg) in chat.messages.enumerated() {
                let sender = msg.sender.map { String(jidRow($0)) } ?? "NULL"
                sql += "\nINSERT INTO message VALUES (\(ci * 1000 + mi + 1),\(ci + 1),\(msg.fromMe ? 1 : 0),\(sender),\(msg.ts),0,'\(msg.text)','k\(ci)-\(mi)');"
            }
        }
        let dbPath = dir.appendingPathComponent("m.db").path
        try SQLiteDB(path: dbPath, readOnly: false).exec(sql)
        let vault = try Vault(url: dir.appendingPathComponent("v"))
        _ = try vault.ingest(msgstore: dbPath, label: "t")
        if !merges.isEmpty { try MergeConfig.save(merges, to: vault) }
        let index = dir.appendingPathComponent("i.db").path
        _ = try VaultIndexer.build(vault: vault, out: index, extraContacts: names)
        return Fixture(vault: vault, dir: dir, index: index, names: names)
    }

    // MARK: same name

    func testSameNameStillSuggestedWithStableMemberIdentity() throws {
        let f = try fixture([
            Chat(jid: "919800000001@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000002@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
        ], names: ["9800000001": "Asha", "9800000002": "Asha"])

        // Callers without a vault keep the original behaviour.
        XCTAssertEqual(try f.store().mergeSuggestions().count, 1)

        let report = try f.report()
        XCTAssertEqual(report.suggestions.count, 1)
        let s = try XCTUnwrap(report.suggestions.first)
        XCTAssertEqual(s.people.map(\.key).sorted(), ["9800000001", "9800000002"])
        XCTAssertEqual(s.id, "9800000001+9800000002")
        XCTAssertEqual(s.name, "Asha")
        XCTAssertEqual(s.reasons, [.sameName])
        XCTAssertEqual(s.confidence, .medium)

        // Renaming both people must not change the identity used for ignore/dedupe.
        try f.rebuild(names: ["9800000001": "Asha Rao", "9800000002": "Asha Rao"])
        XCTAssertEqual(try f.report().suggestions.first?.id, "9800000001+9800000002")
    }

    func testPlaceholderNamesAreNotEvidence() throws {
        let f = try fixture([
            Chat(jid: "919800000003@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000004@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
        ])
        XCTAssertTrue(try f.report().suggestions.isEmpty)      // two unnamed numbers are not "the same name"
    }

    // MARK: WhatsApp profile name

    func testSameUpstreamNameLinksDifferentlyNamedPeople() throws {
        let f = try fixture([
            Chat(jid: "919800000011@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000012@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
        ], push: ["919800000011@s.whatsapp.net": "Zed Nair", "919800000012@s.whatsapp.net": "Zed Nair"],
           names: ["9800000011": "Asha"])                       // only one side has a saved contact name

        let s = try XCTUnwrap(try f.report().suggestions.first)
        XCTAssertEqual(Set(s.people.map(\.key)), ["9800000011", "9800000012"])
        XCTAssertEqual(s.reasons, [.sameUpstreamName])
        XCTAssertEqual(s.confidence, .medium)
    }

    func testDistinctOrMissingUpstreamNamesDoNotMatch() throws {
        let f = try fixture([
            Chat(jid: "919800000013@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000014@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
        ], push: ["919800000013@s.whatsapp.net": "Alice Smith", "919800000014@s.whatsapp.net": "Bob Jones"],
           names: ["9800000013": "Alice", "9800000014": "Bob"])
        XCTAssertTrue(try f.report().suggestions.isEmpty)

        let blank = try fixture([
            Chat(jid: "919800000015@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000016@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
        ], names: ["9800000015": "Carol", "9800000016": "Carol D"])
        XCTAssertTrue(try blank.report().suggestions.isEmpty)   // no metadata: no guessed evidence
    }

    func testPushNameCapturedOnlyInGroupMessagesIsEvidence() throws {
        let f = try fixture([
            Chat(jid: "919800000017@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000018@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
            Chat(jid: "120363000000@g.us", group: true, subject: "Club", messages: [
                Msg(ts: 5_000, sender: "919800000017@s.whatsapp.net"),
                Msg(ts: 6_000, sender: "919800000018@s.whatsapp.net"),
            ]),
        ], push: ["919800000017@s.whatsapp.net": "Kai", "919800000018@s.whatsapp.net": "Kai"],
           names: ["9800000017": "Ravi", "9800000018": "Ravi K"])
        let s = try XCTUnwrap(try f.report().suggestions.first { $0.reasons.contains(.sameUpstreamName) })
        XCTAssertEqual(Set(s.people.map(\.key)), ["9800000017", "9800000018"])
    }

    // MARK: trailing digits

    func testSharedTrailingDigitsAcrossDifferentLengths() throws {
        let f = try fixture([
            Chat(jid: "123456789@s.whatsapp.net", messages: [Msg(ts: 1_000)]),
            Chat(jid: "9123456789@s.whatsapp.net", messages: [Msg(ts: 2_000)]),
        ], names: ["123456789": "Old Line", "9123456789": "New Line"])

        let s = try XCTUnwrap(try f.report().suggestions.first)
        XCTAssertEqual(s.reasons, [.sharedTrailingDigits(9)])
        XCTAssertEqual(s.confidence, .low)
    }

    func testShortSuffixesAndLIDsAreNotEvidence() throws {
        let short = try fixture([
            Chat(jid: "3456789@s.whatsapp.net", messages: [Msg(ts: 1_000)]),
            Chat(jid: "913456789@s.whatsapp.net", messages: [Msg(ts: 2_000)]),
        ], names: ["3456789": "Short Line", "913456789": "Long Line"])
        XCTAssertTrue(try short.report().suggestions.isEmpty)   // 7 shared digits is below the conservative cutoff

        let lid = try fixture([
            Chat(jid: "123456789@lid", messages: [Msg(ts: 1_000)]),
            Chat(jid: "9123456789@s.whatsapp.net", messages: [Msg(ts: 2_000)]),
        ], names: ["9123456789": "Phone Line"])
        XCTAssertTrue(try lid.report().suggestions.isEmpty)     // a LID is not a phone number
    }

    // MARK: DM handoff

    func testDMHandoffWithSharedGroup() throws {
        // Timing only supplements identity, so the pair is named alike here: the handoff reason is what this
        // test is about, not the name match it rides along with.
        let f = try fixture([
            Chat(jid: "919800000021@s.whatsapp.net", messages: [Msg(ts: day - 1_000), Msg(ts: day)]),
            Chat(jid: "919800000022@s.whatsapp.net", messages: [Msg(ts: 4 * day), Msg(ts: 4 * day + 1_000)]),
            Chat(jid: "120363000001@g.us", group: true, subject: "Club", messages: [
                Msg(ts: 5_000, sender: "919800000021@s.whatsapp.net"),
                Msg(ts: 6_000, sender: "919800000022@s.whatsapp.net"),
            ]),
        ], names: ["9800000021": "Amma", "9800000022": "Amma"])

        let s = try XCTUnwrap(try f.report().suggestions.first)
        XCTAssertTrue(s.reasons.contains(.dmHandoff(gapDays: 3, sharedGroups: 1)))
        XCTAssertTrue(s.reasons.contains(.sameName))
        XCTAssertEqual(s.confidence, .high)
    }

    /// The regression the user reported: a handoff paired a stranger with someone else's chat purely because one
    /// went quiet before the other began. Different real names must veto the timing signal outright.
    func testDMHandoffBetweenDifferentRealNamesIsRejected() throws {
        let f = try fixture([
            Chat(jid: "919800000021@s.whatsapp.net", messages: [Msg(ts: day - 1_000), Msg(ts: day)]),
            Chat(jid: "919800000022@s.whatsapp.net", messages: [Msg(ts: 4 * day), Msg(ts: 4 * day + 1_000)]),
            Chat(jid: "120363000001@g.us", group: true, subject: "Club", messages: [
                Msg(ts: 5_000, sender: "919800000021@s.whatsapp.net"),
                Msg(ts: 6_000, sender: "919800000022@s.whatsapp.net"),
            ]),
        ], names: ["9800000021": "Lata", "9800000022": "Lata Rao"])

        XCTAssertTrue(try f.report().suggestions.isEmpty)
    }

    func testDMHandoffRequiresSilenceGapAndSharedGroups() throws {
        // Unnamed members on purpose in the negative cases: with no real names the veto cannot fire, so an empty
        // report can only come from the timing rules under test.
        func pair(xMsgs: [Msg], yMsgs: [Msg], groups: [Chat], names: [String: String] = [:]) throws -> MergeSuggestionReport {
            try fixture([
                Chat(jid: "919800000031@s.whatsapp.net", messages: xMsgs),
                Chat(jid: "919800000032@s.whatsapp.net", messages: yMsgs),
            ] + groups, names: names).report()
        }
        let club = Chat(jid: "120363000002@g.us", group: true, subject: "Club", messages: [
            Msg(ts: 5_000, sender: "919800000031@s.whatsapp.net"),
            Msg(ts: 6_000, sender: "919800000032@s.whatsapp.net"),
        ])
        // Group-only participation, no shared group at all.
        let xClub = Chat(jid: "120363000003@g.us", group: true, subject: "X Club", messages: [
            Msg(ts: 5_000, sender: "919800000031@s.whatsapp.net"),
            Msg(ts: 5_001, sender: "919800000031@s.whatsapp.net"),
        ])
        let yClub = Chat(jid: "120363000004@g.us", group: true, subject: "Y Club", messages: [
            Msg(ts: 6_000, sender: "919800000032@s.whatsapp.net"),
        ])

        // Exactly one silent day is enough.
        let oneDay = try XCTUnwrap(try pair(xMsgs: [Msg(ts: 1_000), Msg(ts: day)],
                                            yMsgs: [Msg(ts: 2 * day), Msg(ts: 2 * day + 1)],
                                            groups: [club],
                                            names: ["9800000031": "Mohan", "9800000032": "Mohan"]).suggestions.first)
        XCTAssertTrue(oneDay.reasons.contains(.dmHandoff(gapDays: 1, sharedGroups: 1)))
        // One millisecond short of it is not.
        XCTAssertTrue(try pair(xMsgs: [Msg(ts: 1_000), Msg(ts: day)],
                               yMsgs: [Msg(ts: 2 * day - 1), Msg(ts: 2 * day + 1)],
                               groups: [club]).suggestions.isEmpty)
        // Overlapping DM histories are not a handoff.
        XCTAssertTrue(try pair(xMsgs: [Msg(ts: day), Msg(ts: 2 * day)],
                               yMsgs: [Msg(ts: day + 500), Msg(ts: day + 900)],
                               groups: [club]).suggestions.isEmpty)
        // No shared group: nothing ties the two people together.
        XCTAssertTrue(try pair(xMsgs: [Msg(ts: 1_000), Msg(ts: day)],
                               yMsgs: [Msg(ts: 2 * day), Msg(ts: 2 * day + 1)],
                               groups: [xClub, yClub]).suggestions.isEmpty)

        // Group-only activity is not a DM handoff.
        let groupOnly = try fixture([
            Chat(jid: "919800000033@s.whatsapp.net", messages: []),
            Chat(jid: "919800000034@s.whatsapp.net", messages: [Msg(ts: 2 * day), Msg(ts: 2 * day + 1)]),
            Chat(jid: "120363000004@g.us", group: true, subject: "Club", messages: [
                Msg(ts: day, sender: "919800000033@s.whatsapp.net"),
                Msg(ts: day + 1, sender: "919800000033@s.whatsapp.net"),
                Msg(ts: 6_000, sender: "919800000034@s.whatsapp.net"),
            ]),
        ])
        XCTAssertTrue(try groupOnly.report().suggestions.isEmpty)
    }

    // MARK: combining, ranking and safety

    func testEvidenceCoalescesIntoOneSuggestion() throws {
        let f = try fixture([
            Chat(jid: "919800000041@s.whatsapp.net", messages: [Msg(ts: day), Msg(ts: day + 1_000)]),
            Chat(jid: "919800000042@s.whatsapp.net", messages: [Msg(ts: 4 * day), Msg(ts: 4 * day + 1_000)]),
            Chat(jid: "120363000005@g.us", group: true, subject: "Club", messages: [
                Msg(ts: 5_000, sender: "919800000041@s.whatsapp.net"),
                Msg(ts: 6_000, sender: "919800000042@s.whatsapp.net"),
            ]),
        ], push: ["919800000041@s.whatsapp.net": "Nina P", "919800000042@s.whatsapp.net": "Nina P"],
           names: ["9800000041": "Nina", "9800000042": "Nina"])

        let report = try f.report()
        XCTAssertEqual(report.suggestions.count, 1)
        let s = try XCTUnwrap(report.suggestions.first)
        XCTAssertEqual(s.reasons.count, 3)
        XCTAssertTrue(s.reasons.contains(.sameName))
        XCTAssertTrue(s.reasons.contains(.sameUpstreamName))
        XCTAssertEqual(s.confidence, .high)
    }

    func testSuggestionsDoNotMergeUnsupportedPairsTransitively() throws {
        // A and B share a saved name; B and C share a WhatsApp profile name; A and C share nothing.
        let f = try fixture([
            Chat(jid: "919800000051@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000052@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
            Chat(jid: "919800000053@s.whatsapp.net", messages: [Msg(ts: 5_000), Msg(ts: 6_000)]),
        ], push: ["919800000052@s.whatsapp.net": "Kai", "919800000053@s.whatsapp.net": "Kai"],
           names: ["9800000051": "Sam", "9800000052": "Sam", "9800000053": "Dev"])

        let groups = try f.report().suggestions.map { Set($0.people.map(\.key)) }
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains(["9800000051", "9800000052"]))       // saved name
        XCTAssertTrue(groups.contains(["9800000052", "9800000053"]))       // profile name
        XCTAssertFalse(groups.contains(["9800000051", "9800000052", "9800000053"]))
        XCTAssertFalse(groups.contains(["9800000051", "9800000053"]))      // never an unsupported pair
    }

    func testRankingIsDeterministic() throws {
        let f = try fixture([
            Chat(jid: "919800000061@s.whatsapp.net", messages: [Msg(ts: 1_000)]),
            Chat(jid: "919800000062@s.whatsapp.net", messages: [Msg(ts: 2_000)]),
            Chat(jid: "919800000063@s.whatsapp.net", messages: Array(repeating: Msg(ts: 3_000), count: 5)),
            Chat(jid: "919800000064@s.whatsapp.net", messages: Array(repeating: Msg(ts: 4_000), count: 5)),
        ], names: ["9800000061": "Quiet One", "9800000062": "Quiet One",
                   "9800000063": "Busy One", "9800000064": "Busy One"])
        // Five messages per chat need distinct WhatsApp keys; the fixture generator already keys per message.
        let first = try f.report().suggestions.map(\.id)
        let second = try f.report().suggestions.map(\.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first, "9800000063+9800000064")              // more messages ranks first
    }

    // MARK: merges and ignores

    func testAlreadyMergedMembersAreExcluded() throws {
        let f = try fixture([
            Chat(jid: "919800000071@s.whatsapp.net", messages: [Msg(ts: 1_000), Msg(ts: 2_000)]),
            Chat(jid: "919800000072@s.whatsapp.net", messages: [Msg(ts: 3_000), Msg(ts: 4_000)]),
        ], names: ["9800000071": "Asha", "9800000072": "Asha"],
           merges: [PersonMerge(keys: ["9800000071", "9800000072"], name: "Asha")])
        XCTAssertTrue(try f.report().suggestions.isEmpty)
    }

    func testIgnoreIsExactPersistedAndRestorable() throws {
        let f = try fixture([
            Chat(jid: "919800000081@s.whatsapp.net", messages: [Msg(ts: 1_000)]),
            Chat(jid: "919800000082@s.whatsapp.net", messages: [Msg(ts: 2_000)]),
            Chat(jid: "919800000083@s.whatsapp.net", messages: [Msg(ts: 3_000)]),
        ], names: ["9800000081": "Sam", "9800000082": "Sam", "9800000083": "Sam"])

        let all = try XCTUnwrap(try f.report().suggestions.first)
        XCTAssertEqual(Set(all.people.map(\.key)), ["9800000081", "9800000082", "9800000083"])

        // Ignoring a smaller pairing must not hide the larger candidate.
        try MergeSuggestionIgnores.add(["9800000081", "9800000082"], to: f.vault)
        XCTAssertEqual(try f.report().suggestions.map(\.id), ["9800000081+9800000082+9800000083"])
        XCTAssertEqual(try f.report().ignored.map(\.keys), [["9800000081", "9800000082"]])

        try MergeSuggestionIgnores.add(["9800000081", "9800000082", "9800000083"], to: f.vault)
        XCTAssertTrue(try f.report().suggestions.isEmpty)

        // Survives a library rebuild, a fresh store and a fresh vault handle.
        try f.rebuild()
        XCTAssertTrue(try f.report().suggestions.isEmpty)
        XCTAssertEqual(try VaultStore(path: f.index).mergeSuggestionReport(vault: try Vault.open(url: f.vault.url)).ignored.count, 2)

        // Durable in the vault, so a fresh store sees it; format is the documented one.
        XCTAssertEqual(try f.store().mergeSuggestionReport(vault: f.vault).ignored.count, 2)
        let file = f.vault.url.appendingPathComponent("config/merge-suggestion-ignores.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let ignored = try XCTUnwrap(json["ignored"] as? [[String]])
        XCTAssertEqual(Set(ignored), [["9800000081", "9800000082"], ["9800000081", "9800000082", "9800000083"]])

        try MergeSuggestionIgnores.remove(["9800000081", "9800000082", "9800000083"], from: f.vault)
        XCTAssertEqual(try f.report().suggestions.map(\.id), ["9800000081+9800000082+9800000083"])
    }

    func testDamagedIgnoreFileIsReportedNotOverwritten() throws {
        let f = try fixture([
            Chat(jid: "919800000091@s.whatsapp.net", messages: [Msg(ts: 1_000)]),
            Chat(jid: "919800000092@s.whatsapp.net", messages: [Msg(ts: 2_000)]),
        ], names: ["9800000091": "Asha", "9800000092": "Asha"])
        let file = f.vault.url.appendingPathComponent("config/merge-suggestion-ignores.json")
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: file)

        XCTAssertEqual(try f.report().suggestions.count, 1)          // suggestions still usable
        XCTAssertTrue(try f.report().ignored.isEmpty)
        XCTAssertThrowsError(try MergeSuggestionIgnores.add(["9800000091", "9800000092"], to: f.vault))
        XCTAssertEqual(try Data(contentsOf: file), damaged)          // existing file left untouched
    }

    func testNoIgnoreFileMeansNoIgnoredEntries() throws {
        let f = try fixture([
            Chat(jid: "919800000093@s.whatsapp.net", messages: [Msg(ts: 1_000)]),
            Chat(jid: "919800000094@s.whatsapp.net", messages: [Msg(ts: 2_000)]),
        ], names: ["9800000093": "Asha", "9800000094": "Asha"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.vault.url.appendingPathComponent("config/merge-suggestion-ignores.json").path))
        XCTAssertTrue(try f.report().ignored.isEmpty)
    }
}
