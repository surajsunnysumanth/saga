import XCTest
@testable import SagaCore

final class DuoWrappedTests: XCTestCase {

    // MARK: - Laugh detection

    func testLaughDetection() {
        XCTAssertEqual(DuoWrappedBuilder.laughScore("ok sure"), 0)
        XCTAssertGreaterThan(DuoWrappedBuilder.laughScore("hahahahaha"), DuoWrappedBuilder.laughScore("lol"))
        XCTAssertGreaterThan(DuoWrappedBuilder.laughScore("😂😂"), 0)
        XCTAssertEqual(DuoWrappedBuilder.laughScore("that was a challenge"), 0)             // "ha" inside a word is not a laugh
        XCTAssertEqual(DuoWrappedBuilder.laughScore("Shall we go"), 0)
    }

    // MARK: - Fixtures

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func build(_ rows: [(Date, Bool, String)]) async throws -> DuoWrapped {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-duo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        var values: [String] = []
        for (i, row) in rows.enumerated() {
            let ts = Int(row.0.timeIntervalSince1970 * 1000)
            let text = row.2.replacingOccurrences(of: "'", with: "''")
            values.append("(\(i + 1),10,\(row.1 ? 1 : 0),\(row.1 ? "NULL" : "1"),\(ts),0,'\(text)','K\(i + 1)')")
        }
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO chat VALUES (10,1,NULL);
        INSERT INTO message VALUES \(values.joined(separator: ","));
        """)
        let idx = dir.appendingPathComponent("i.db").path
        _ = try Importer.run(ImportOptions(sourceDB: dir.appendingPathComponent("m.db").path, outputDB: idx,
                                           extraContacts: ["9833052771": "Asha"]))
        let st = try VaultStore(path: idx)
        var cid: Int64 = 0; try st.db.query("SELECT chat_id FROM chats") { cid = $0.int(0) }
        return try await DuoWrappedBuilder.build(store: st, chatID: cid, me: "Sam", fetchTitles: false)
    }

    private func originalFixture() async throws -> DuoWrapped {
        var rows: [(Date, Bool, String)] = []
        let base = date(2023, 11, 14, 10, 0)
        func add(_ day: Int, _ hour: Int, _ min: Int, _ me: Bool, _ text: String) {
            rows.append((base.addingTimeInterval(Double(day * 86400 + hour * 3600 + min * 60)), me, text))
        }
        add(0, 10, 0, false, "hi it's Asha from the quiz team")
        add(0, 10, 1, true, "oh hi the capital city genius")
        add(0, 10, 2, false, "hahahahaha that's me")
        add(3, 21, 0, true, "I just waved at a stranger who was waving behind me")
        add(3, 21, 1, false, "hahahahahaha oh no 😂😂")
        add(3, 21, 5, true, "https://youtu.be/dQw4w9WgXcQ")
        add(3, 21, 7, false, "ohh I love this one 🔥")
        add(9, 2, 0, false, "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        add(9, 2, 3, true, "nice")
        add(40, 9, 0, true, "good morning")
        add(40, 9, 1, false, "morning!")
        return try await build(rows)
    }

    // MARK: - Stats

    func testStatsLaughsAndMusic() async throws {
        let w = try await originalFixture()
        XCTAssertEqual(w.total, 11); XCTAssertEqual(w.mine, 5); XCTAssertEqual(w.theirs, 6)
        XCTAssertEqual(w.them, "Asha"); XCTAssertEqual(w.firstText?.author, "Asha")
        XCTAssertEqual(w.activeDays, 4)
        XCTAssertEqual(w.startsTheirs + w.startsMine, 4)
        XCTAssertEqual(w.longestGapDays, 31)
        XCTAssertEqual(w.gapBrokenBy, "You", "the owner speaks as you, not as the display name")
        XCTAssertGreaterThan(w.madeThemLaugh, 0)
        XCTAssertTrue(w.funniest.contains { $0.text.contains("waved") })
        XCTAssertEqual(w.linksTotal, 2); XCTAssertEqual(w.linksMine, 1); XCTAssertEqual(w.linksTheirs, 1)
        let first = try XCTUnwrap(w.tracks.first)
        XCTAssertEqual(first.role, "The first one"); XCTAssertEqual(first.service, .youtube)
        XCTAssertEqual(first.landed, 1)
        XCTAssertEqual(first.reactionBy, "Asha")
        XCTAssertEqual(w.tracks.count, 2); XCTAssertEqual(w.tracks.last?.role, "Along the way")
        XCTAssertEqual(w.tracks.last?.landed, 0)
        XCTAssertEqual(w.byYear.map(\.year), [2023])
        XCTAssertNotNil(w.bestYear)
    }

    // MARK: - Copy

    func testSpanSentenceIsGrammaticalForEveryCase() {
        let first = date(2024, 3, 1)
        XCTAssertEqual(WrappedCopy.span(spanDays: 1, activeDays: 1, first: first), "All of it on 1 March 2024.")
        XCTAssertEqual(WrappedCopy.span(spanDays: 59, activeDays: 60, first: first),
                       "60 days, every single one of them with something in it.")
        XCTAssertEqual(WrappedCopy.span(spanDays: 59, activeDays: 12, first: first),
                       "59 days, 12 of them with something to say.")
        XCTAssertEqual(WrappedCopy.span(spanDays: 59, activeDays: 1, first: first),
                       "59 days apart, with one day of actual talking.")
        XCTAssertEqual(WrappedCopy.span(spanDays: 2, activeDays: 0, first: first),
                       "2 days on the calendar, none of them with a message.")
    }

    func testOpeningAndPaceCarryTheNumbers() {
        XCTAssertEqual(WrappedCopy.opening(total: 41_203), "You two sent 41,203 messages.")
        XCTAssertEqual(WrappedCopy.opening(total: 1), "You two sent one message. It's a start.")
        XCTAssertEqual(WrappedCopy.pace(count: 4_380, year: 2023, activeDays: 365), "In 2023 alone that was 12 per day you talked.")
        XCTAssertEqual(WrappedCopy.pace(count: 2_920, year: 2023, activeDays: 730), "In 2023 alone that was 4 per day you talked.")
        XCTAssertEqual(WrappedCopy.pace(count: 120, year: 2023, activeDays: 365), "In 2023 that was 120 messages in all.")
        XCTAssertEqual(WrappedCopy.pace(count: 2, year: 2023, activeDays: 2), "In 2023 alone that was 1 per day you talked.")
        XCTAssertEqual(WrappedCopy.pace(count: 2, year: 2023, activeDays: 1), "In 2023 that was 2 messages on the one day it was used.")
        XCTAssertNil(WrappedCopy.pace(count: 0, year: 2023, activeDays: 365))
    }

    func testBalanceReplyAndConversationSentences() {
        XCTAssertEqual(WrappedCopy.balance(me: "Sam", them: "Asha", mine: 500, theirs: 500),
                       "You split the messages exactly down the middle — 500 each.")
        XCTAssertEqual(WrappedCopy.balance(me: "Sam", them: "Asha", mine: 506, theirs: 500),
                       "Practically even: 506 from you, 500 from Asha.")
        XCTAssertEqual(WrappedCopy.balance(me: "Sam", them: "Asha", mine: 3_000, theirs: 1_000),
                       "You sent 75% of them — 3,000 to 1,000.")
        XCTAssertEqual(WrappedCopy.balance(me: "Sam", them: "Asha", mine: 1_000, theirs: 3_000),
                       "Asha sent 75% of them — 3,000 to 1,000.")
        XCTAssertNil(WrappedCopy.balance(me: "Sam", them: "Asha", mine: 0, theirs: 0))

        XCTAssertEqual(WrappedCopy.replyRace(me: "Sam", them: "Asha", mine: 120, theirs: 300,
                                             mineSamples: 40, theirsSamples: 30),
                       "You answer in \(WrappedCopy.duration(120)); Asha takes \(WrappedCopy.duration(300)).")
        XCTAssertEqual(WrappedCopy.replyRace(me: "Sam", them: "Asha", mine: 120, theirs: 132,
                                             mineSamples: 40, theirsSamples: 30),
                       "You both answer in about \(WrappedCopy.duration(120)). Neither of you keeps the other waiting.")
        // "A day or more" needs evidence: answers at a day or more, and no median to report.
        XCTAssertEqual(WrappedCopy.replyRace(me: "Sam", them: "Asha", mine: 120, theirs: nil,
                                             mineSamples: 40, theirsSamples: 0, theirsSlow: 6),
                       "You usually reply in \(WrappedCopy.duration(120)). Asha takes a day or more.")
        // No evidence about them is not the same as being slow: nothing is said about them.
        XCTAssertEqual(WrappedCopy.replyRace(me: "Sam", them: "Asha", mine: 120, theirs: nil,
                                             mineSamples: 40, theirsSamples: 0, theirsSlow: 0),
                       "You usually reply in \(WrappedCopy.duration(120)).")
        XCTAssertNil(WrappedCopy.replyRace(me: "Sam", them: "Asha", mine: 120, theirs: 300,
                                           mineSamples: 1, theirsSamples: 1),
                     "one reply each is an anecdote, not a habit")
        XCTAssertEqual(WrappedCopy.replyRace(me: "Sam", them: "Asha", mine: nil, theirs: nil,
                                             mineSamples: 0, theirsSamples: 0, mineSlow: 2, theirsSlow: 3),
                       "Neither of you is in a hurry: no reply landed inside a day.")
        XCTAssertNil(WrappedCopy.replyRace(me: "Sam", them: "Asha", mine: nil, theirs: nil,
                                           mineSamples: 0, theirsSamples: 0),
                     "a chat with no replies at all gets no reply sentence")

        XCTAssertEqual(WrappedCopy.conversations(me: "Sam", them: "Asha", mine: 312, theirs: 180),
                       "You start 63% of them — 312 to 180.")
        XCTAssertEqual(WrappedCopy.conversations(me: "Sam", them: "Asha", mine: 90, theirs: 90),
                       "You start conversations equally often — 90 times each.")
        XCTAssertEqual(WrappedCopy.conversations(me: "Sam", them: "Asha", mine: 1, theirs: 1),
                       "You start conversations equally often — once each.")
    }

    func testLaughAndFirstMessageCopyAvoidFixedSuperlatives() {
        XCTAssertEqual(WrappedCopy.laughs(me: "Sam", them: "Asha", madeThemLaugh: 12, madeMeLaugh: 12, peakMonth: nil),
                       "Dead even: you each got 12 laughs out of the other.")
        let lead = WrappedCopy.laughs(me: "Sam", them: "Asha", madeThemLaugh: 1_204, madeMeLaugh: 621,
                                      peakMonth: (month: "2021-06", count: 94))
        XCTAssertTrue(lead.hasPrefix("Your messages drew 1,204 laughs from Asha. 621 went back the other way."),
                      "the owner speaks as 'you' even when the builder was handed a name")
        XCTAssertTrue(lead.contains("Peak month: June 2021, 94 laughs."))
        XCTAssertTrue(WrappedCopy.laughs(me: "Sam", them: "Asha", madeThemLaugh: 0, madeMeLaugh: 60, peakMonth: nil)
            .contains("Nothing came back the other way."))
        XCTAssertEqual(WrappedCopy.laughs(me: "Sam", them: "Asha", madeThemLaugh: 5, madeMeLaugh: 1,
                                          peakMonth: (month: "2021-06", count: 1)),
                       "Your messages drew 5 laughs from Asha. 1 went back the other way. Peak month: June 2021, 1 laugh.")
        XCTAssertEqual(WrappedCopy.laughs(me: "Sam", them: "Asha", madeThemLaugh: 3, madeMeLaugh: 9, peakMonth: nil),
                       "Asha's messages drew 9 laughs from you. 3 went back the other way.")
        XCTAssertEqual(WrappedCopy.laughs(me: "Sam", them: "Asha", madeThemLaugh: 0, madeMeLaugh: 0, peakMonth: nil),
                       "No laugh-out-louds in here. Very serious correspondence.")

        XCTAssertEqual(WrappedCopy.firstKicker(text: "hi"), "No grand opening. Just a hello.")
        XCTAssertEqual(WrappedCopy.firstKicker(text: "are you coming?"), "A question first, so someone had to answer.")
        XCTAssertEqual(WrappedCopy.firstKicker(text: "😂"), "Straight in with an emoji.")
        XCTAssertEqual(WrappedCopy.firstKicker(text: "ok"), "One word, and it stuck.")
    }

    func testGroupAndSectionCopy() {
        XCTAssertEqual(WrappedCopy.groupOpening(name: "Weekend Club", total: 68_401, contributors: 7, spanDays: 1_204, activeDays: 890),
                       "Weekend Club sent 68,401 messages. 7 people across 1,204 days, 890 of them with something to say.")
        XCTAssertEqual(WrappedCopy.groupVoices(top: "Asha", topCount: 12_004, funniest: "River", laughs: 312, of: 2_000,
                                               runnerUpRate: 0.05, roomRate: 0.02),
                       "Asha writes the most — 12,004 messages. Per message, the room laughs hardest at River: 312 laughs across 2,000 messages (15.6%).")
        XCTAssertEqual(WrappedCopy.groupVoices(top: "Asha", topCount: 12_004, funniest: "Asha", laughs: 312, of: 12_004,
                                               runnerUpRate: nil, roomRate: 0.02),
                       "Asha writes the most — 12,004 messages, and a laugh lands on 2.6% of them (312 laughs).")
        XCTAssertEqual(WrappedCopy.groupVoices(top: "Asha", topCount: 12_004, funniest: "Asha", laughs: 300, of: 12_004,
                                               runnerUpRate: 0.0255, roomRate: 0.02),
                       "Asha writes the most — 12,004 messages. Nobody runs away with it: a laugh lands on about 2% of what anyone writes.",
                       "a leader level with the room is not 'the funniest'")
        XCTAssertEqual(WrappedCopy.groupVoices(top: "Asha", topCount: 12_004, funniest: nil, laughs: 0, of: 0,
                                               runnerUpRate: nil, roomRate: 0),
                       "Asha writes the most — 12,004 messages; nobody has landed a laugh yet.")
        XCTAssertEqual(WrappedCopy.groupVoices(top: "You", topCount: 60, funniest: nil, laughs: 0, of: 0,
                                               runnerUpRate: nil, roomRate: 0),
                       "You write the most — 60 messages; nobody has landed a laugh yet.")
        XCTAssertTrue(WrappedCopy.laughs(me: "You", them: "Jules", madeThemLaugh: 60, madeMeLaugh: 0, peakMonth: nil)
            .hasPrefix("Your messages drew 60 laughs from Jules."))
        XCTAssertEqual(WrappedCopy.quietYear(year: 2021, count: 43, nextYear: 2022, nextCount: 2_100),
                       "2021 went quiet — 43 messages in twelve months. Then 2022 picked straight back up.")
        XCTAssertNil(WrappedCopy.night(me: "Sam", them: "Asha", mine: 2, theirs: 3))       // too little to make a claim
        XCTAssertEqual(WrappedCopy.emojiPair(a: "😂", b: "🥲", count: 41),
                       "😂🥲 is your signature pair — 41 times, side by side.")
    }

    // MARK: - Selection

    func testMomentsSpreadAcrossYearsAndDropBroadcasts() async throws {
        var rows: [(Date, Bool, String)] = []
        for (index, year) in [2021, 2022, 2023].enumerated() {
            for i in 0..<6 {
                let mine = i % 2 == 0
                let d = date(year, 6, 1, 12, 0).addingTimeInterval(Double(index * 20 + i) * 86_400)
                rows.append((d, mine, "the \(year) story number \(index * 6 + i)"))
                rows.append((d.addingTimeInterval(120), !mine, "hahahahaha \(year) is unreal"))
            }
        }
        // A broadcast with a laugh reply: it should never be featured as a memory.
        let b = date(2022, 9, 3, 9, 0)
        rows.append((b, false, "Our monthly digest: view in browser to unsubscribe from these updates"))
        rows.append((b.addingTimeInterval(60), true, "hahahahahaha"))

        let w = try await build(rows.sorted { $0.0 < $1.0 })
        XCTAssertFalse(w.funniest.contains { $0.text.lowercased().contains("unsubscribe") })
        let years = Set(w.funniest.map { Calendar.current.component(.year, from: $0.date) })
        XCTAssertEqual(years, [2021, 2022, 2023], "each year that had a laugh should be represented")
        for year in [2021, 2022, 2023] {
            XCTAssertLessThanOrEqual(w.funniest.filter { Calendar.current.component(.year, from: $0.date) == year }.count, 2)
        }
    }

    func testQuietYearNightOwlAndEmojiPair() async throws {
        var rows: [(Date, Bool, String)] = []
        for i in 0..<20 {                                                       // a loud 2021
            rows.append((date(2021, 3, 1, 10, 0).addingTimeInterval(Double(i) * 86_400), i % 2 == 0, "plans for the weekend number \(i)"))
        }
        for i in 0..<2 {                                                        // a nearly silent 2022
            rows.append((date(2022, 5, 1, 3, 42).addingTimeInterval(Double(i) * 60), i % 2 == 0, "are you still awake? 😂😂"))
        }
        for i in 0..<20 {                                                       // 2023 back to normal
            rows.append((date(2023, 3, 1, 10, 0).addingTimeInterval(Double(i) * 86_400), i % 2 == 0, "ok this is day \(i) of the group chat"))
        }
        let w = try await build(rows.sorted { $0.0 < $1.0 })
        XCTAssertEqual(w.quietestYear?.year, 2022)
        XCTAssertEqual(w.quietestYear?.count, 2)
        XCTAssertEqual(w.nightOwl?.hour, 3)
        XCTAssertGreaterThanOrEqual(w.nightOwl?.minute ?? 0, 42)
        XCTAssertFalse(w.nightOwl?.text.isEmpty ?? true)
        XCTAssertEqual(w.emojiPair?.a, "😂")
        XCTAssertEqual(w.emojiPair?.b, "😂")
        XCTAssertEqual(w.emojiPair?.count, 2)
        XCTAssertEqual(w.byYear.map(\.year), [2021, 2022, 2023])
    }

    // MARK: - Export

    func testHTMLIsSelfContainedEscapedAndSharesTheCopy() async throws {
        var w = try await originalFixture()
        w.me = "Sam <b>"
        let page = DuoWrappedHTML.render(w, interactive: false)
        XCTAssertTrue(page.contains("Sam &lt;b&gt;")); XCTAssertFalse(page.contains("Sam <b>"))
        XCTAssertFalse(page.contains("webkit.messageHandlers"))                 // the shareable copy has no in-app buttons
        XCTAssertTrue(DuoWrappedHTML.render(w, interactive: true).contains("webkit.messageHandlers"))
        XCTAssertTrue(page.contains("#075E54"))                                 // the WhatsApp palette, same as the app
        XCTAssertTrue(page.contains(WrappedCopy.opening(total: w.total)))
        XCTAssertFalse(page.contains("and \(w.activeDays) days you actually talked"))   // the old buggy sentence
    }

    func testGroupHTMLSharesThePalette() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = try SQLiteDB(path: dir.appendingPathComponent("m.db").path, readOnly: false)
        try src.exec("""
        CREATE TABLE jid(_id INTEGER PRIMARY KEY, user TEXT, server TEXT, agent INT, device INT, type INT, raw_string TEXT);
        CREATE TABLE chat(_id INTEGER PRIMARY KEY, jid_row_id INT, subject TEXT);
        CREATE TABLE message(_id INTEGER PRIMARY KEY, chat_row_id INT, from_me INT, sender_jid_row_id INT, timestamp INT, message_type INT, text_data TEXT, key_id TEXT);
        CREATE TABLE message_media(message_row_id INTEGER PRIMARY KEY, chat_row_id INT, mime_type TEXT, file_path TEXT, file_length INT, file_hash TEXT, media_caption TEXT);
        INSERT INTO jid VALUES (1,'919833052771','s.whatsapp.net',0,0,0,'919833052771@s.whatsapp.net');
        INSERT INTO jid VALUES (2,'919833052772','s.whatsapp.net',0,0,0,'919833052772@s.whatsapp.net');
        INSERT INTO chat VALUES (20,1,'Weekend Club');
        INSERT INTO message VALUES (1,20,0,1,1700000000000,0,'who is coming on saturday','k1');
        INSERT INTO message VALUES (2,20,0,2,1700000060000,0,'hahahahaha count me in','k2');
        INSERT INTO message VALUES (3,20,1,NULL,1700000120000,0,'same, I will bring the speaker','k3');
        """)
        let idx = dir.appendingPathComponent("i.db").path
        _ = try Importer.run(ImportOptions(sourceDB: dir.appendingPathComponent("m.db").path, outputDB: idx,
                                           extraContacts: ["9833052771": "Asha", "9833052772": "River"]))
        let st = try VaultStore(path: idx)
        var cid: Int64 = 0; try st.db.query("SELECT chat_id FROM chats") { cid = $0.int(0) }
        let w = try await GroupWrappedBuilder.build(store: st, chatID: cid, me: "Sam", fetchTitles: false)
        let page = GroupWrappedHTML.render(w, interactive: false)
        XCTAssertTrue(page.contains("#075E54"))
        XCTAssertTrue(page.contains(WrappedCopy.groupOpening(name: w.name, total: w.total, contributors: w.contributors.count,
                                                            spanDays: 1, activeDays: w.activeDays)))
        XCTAssertFalse(page.contains("webkit.messageHandlers"))
    }
}
