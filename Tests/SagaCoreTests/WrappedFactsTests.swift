import XCTest
@testable import SagaCore

/// The factual claims in Wrapped and Heartbeat: the numbers the sentences print, and the
/// sentences that have to change when the numbers do. Each test names the defect it pins.
///
/// Everything here is a hand-built index of fictional messages — no real archive, no names
/// from one.
final class WrappedFactsTests: XCTestCase {

    // MARK: - Fixture

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A tiny index: chats, people, messages, replies. Same schema the importer writes.
    private final class Index {
        let store: VaultStore
        private let db: SQLiteDB
        private var nextID = 1

        init(_ dir: URL) throws {
            let path = dir.appendingPathComponent("idx.db").path
            db = try SQLiteDB(path: path, readOnly: false)
            try db.exec(Importer.schema)
            store = try VaultStore(path: path)
        }

        func chat(_ id: Int64, _ name: String, group: Bool, person: String? = nil) throws {
            let p = person.map { "'\($0)'" } ?? "NULL"
            try db.exec("INSERT INTO chats VALUES(\(id),'\(name)@x',\(group ? 1 : 0),'\(name)',1,\(p))")
        }

        func person(_ key: String, _ name: String) throws {
            try db.exec("INSERT INTO people VALUES('\(key)','\(name)',1)")
        }

        func message(_ chat: Int64, me: Bool, sender: String, person: String?, at date: Date,
                     _ text: String, uid: String? = nil, type: Int = 0) {
            let id = nextID; nextID += 1
            let ts = Int64(date.timeIntervalSince1970 * 1000)
            let u = uid ?? "u\(id)"
            let escaped = text.replacingOccurrences(of: "'", with: "''")
            let s = sender.replacingOccurrences(of: "'", with: "''")
            let p = person.map { "'\($0)'" } ?? "NULL"
            try? db.exec("INSERT INTO messages VALUES(\(id),\(chat),\(me ? 1 : 0),'\(s)',\(p),\(ts),\(type),'\(escaped)','\(u)')")
        }

        func reply(uid: String, to target: String) throws {
            try db.exec("INSERT INTO message_replies VALUES('\(uid)','\(target)')")
        }
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - 1. "ahead of N other groups" counts groups, not group messages

    func testTheGroupComparisonCountsGroupsNotGroupMessages() async throws {
        let index = try Index(try tempDir())
        try index.chat(10, "Meera Nair", group: false, person: "p-meera")
        try index.chat(11, "Sunday Football XI", group: true)
        try index.chat(12, "Flat 4B", group: true)
        try index.chat(13, "Book Club", group: true)
        try index.person("p-meera", "Meera Nair")

        // 40 group messages across three groups: the buggy query printed 40 - 1 "other groups".
        for i in 0..<20 { index.message(11, me: false, sender: "Nikhil Rao", person: nil, at: date(2025, 3, 1, 9).addingTimeInterval(Double(i) * 60), "pitch is booked \(i)") }
        for i in 0..<12 { index.message(12, me: false, sender: "Ritu Sharma", person: nil, at: date(2025, 4, 1, 9).addingTimeInterval(Double(i) * 60), "the tap again \(i)") }
        for i in 0..<8 { index.message(13, me: true, sender: "You", person: nil, at: date(2025, 5, 1, 9).addingTimeInterval(Double(i) * 60), "one more chapter \(i)") }
        index.message(10, me: false, sender: "Meera Nair", person: "p-meera", at: date(2025, 6, 1, 9), "hello")

        let w = try await YearWrappedBuilder.build(store: index.store, year: "2025")
        XCTAssertEqual(w.groupCount, 3, "three groups, not forty group messages")
        XCTAssertEqual(w.chatCount, 4)

        let line = try XCTUnwrap(WrappedCopy.yearRoom(group: w.groupChats.first?.name, count: w.groupChats.first?.count ?? 0,
                                                      groups: w.groupCount))
        XCTAssertEqual(line, "The loudest room was Sunday Football XI — 20 messages, ahead of 2 other groups.")
        XCTAssertFalse(line.contains("39"), "the old sentence printed the message count as a group count")
    }

    // MARK: - 2. "You wrote on N days" counts the days *you* wrote

    func testTheYearDayCountIsYourDaysNotEveryoneElses() async throws {
        let index = try Index(try tempDir())
        try index.chat(10, "Meera Nair", group: false, person: "p-meera")
        try index.chat(11, "Flat 4B", group: true)
        try index.person("p-meera", "Meera Nair")

        // Ten days with messages; you write on the first four of them.
        for day in 1...10 {
            let ts = date(2025, 6, day, 10)
            index.message(10, me: false, sender: "Meera Nair", person: "p-meera", at: ts, "day \(day) from meera")
            if day <= 4 { index.message(11, me: true, sender: "You", person: nil, at: ts.addingTimeInterval(60), "day \(day) from me") }
        }

        let w = try await YearWrappedBuilder.build(store: index.store, year: "2025")
        XCTAssertEqual(w.activeDays, 10, "ten days had a message from someone")
        XCTAssertEqual(w.yourDays, 4, "four days had a message from you")

        let line = WrappedCopy.yearDays(yourDays: w.yourDays, coveredDays: w.coveredDays,
                                        daysInYear: w.daysInYear, partial: w.isPartial)
        XCTAssertEqual(line, "Of the 10 days this archive covers, you wrote on 4.")
    }

    // MARK: - 3. One voice for the owner

    func testTheOwnerSpeaksAsYouEvenWhenTheBuilderGetsARealName() async throws {
        let index = try Index(try tempDir())
        try index.chat(10, "Meera Nair", group: false, person: "p-meera")
        try index.person("p-meera", "Meera Nair")

        // You make her laugh, you break a long silence, and you share a song she shares back.
        index.message(10, me: true, sender: "Suraj", person: nil, at: date(2025, 1, 1, 10), "the kettle is fixed")
        index.message(10, me: false, sender: "Meera Nair", person: "p-meera", at: date(2025, 1, 1, 10, 2), "hahahahaha incredible")
        index.message(10, me: true, sender: "Suraj", person: nil, at: date(2025, 1, 1, 10, 5), "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        index.message(10, me: true, sender: "Suraj", person: nil, at: date(2025, 1, 1, 10, 6), "https://open.spotify.com/track/2UVxQoXyJQs98RrXJoLoZK")
        index.message(10, me: false, sender: "Meera Nair", person: "p-meera", at: date(2025, 1, 1, 10, 7), "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
        index.message(10, me: true, sender: "Suraj", person: nil, at: date(2025, 2, 20, 9), "back after the silence")

        let w = try await DuoWrappedBuilder.build(store: index.store, chatID: 10, me: "Suraj", fetchTitles: false)
        XCTAssertEqual(w.me, "Suraj", "the display name is still what the cover and bubbles say")

        let laugh = WrappedCopy.laughs(me: w.me, them: w.them, madeThemLaugh: w.madeThemLaugh,
                                       madeMeLaugh: w.madeMeLaugh, peakMonth: nil)
        let music = try XCTUnwrap(WrappedCopy.soundtrack(me: w.me, them: w.them, total: w.linksTotal,
                                                        mine: w.linksMine, theirs: w.linksTheirs, twins: w.twinTracks))
        let silence = try XCTUnwrap(WrappedCopy.gap(days: w.longestGapDays, from: w.gapFrom, to: w.gapTo, brokenBy: w.gapBrokenBy))
        let balance = try XCTUnwrap(WrappedCopy.balance(me: w.me, them: w.them, mine: w.mine, theirs: w.theirs))

        for (label, sentence) in [("laughs", laugh), ("music", music), ("silence", silence), ("balance", balance)] {
            XCTAssertFalse(sentence.contains("Suraj"), "\(label) switches to the owner's name: \(sentence)")
        }
        XCTAssertTrue(laugh.hasPrefix("Your messages drew"), laugh)
        XCTAssertTrue(music.contains("from you"), music)
        XCTAssertTrue(silence.contains("You broke it"), silence)
        XCTAssertEqual(w.gapBrokenBy, "You")
    }

    // MARK: - 4. A ten-hour answer is a reply

    func testRepliesAfterSixHoursStillCountAndSparseChatsSayNothing() async throws {
        let index = try Index(try tempDir())
        try index.chat(10, "Aravind Pillai", group: false, person: "p-aravind")
        try index.person("p-aravind", "Aravind Pillai")

        // Six exchanges ten hours apart: every one is a same-day answer, and every one used
        // to be classified as a conversation start and thrown away.
        for i in 0..<12 {
            let me = i % 2 == 1
            index.message(10, me: me, sender: me ? "You" : "Aravind Pillai", person: me ? nil : "p-aravind",
                          at: date(2025, 3, 1, 8).addingTimeInterval(Double(i) * 10 * 3600),
                          "exchange number \(i) with words in it")
        }
        let w = try await DuoWrappedBuilder.build(store: index.store, chatID: 10, me: "Suraj", fetchTitles: false)
        XCTAssertEqual(w.replyCountMine, 6, "six of your answers landed inside a day")
        XCTAssertEqual(w.replyCountTheirs, 5)
        XCTAssertEqual(w.medianReplyMine ?? 0, 36_000, accuracy: 1, "a ten-hour answer, not a discarded one")

        let race = try XCTUnwrap(WrappedCopy.replyRace(me: "Suraj", them: w.them, mine: w.medianReplyMine, theirs: w.medianReplyTheirs,
                                                       mineSamples: w.replyCountMine, theirsSamples: w.replyCountTheirs,
                                                       mineSlow: w.slowReplyMine, theirsSlow: w.slowReplyTheirs))
        XCTAssertFalse(race.contains("a day or more"), "a same-day replier is not 'a day or more': \(race)")

        // Four messages: one reply each. That is an anecdote, so the sentence is not printed.
        let sparse = try Index(try tempDir())
        try sparse.chat(20, "Priya Menon", group: false, person: "p-priya")
        try sparse.person("p-priya", "Priya Menon")
        sparse.message(20, me: true, sender: "You", person: nil, at: date(2025, 3, 1, 9), "are you around today")
        sparse.message(20, me: false, sender: "Priya Menon", person: "p-priya", at: date(2025, 3, 1, 9, 30), "yes, call me")
        sparse.message(20, me: true, sender: "You", person: nil, at: date(2025, 3, 2, 9), "that was a long call")
        sparse.message(20, me: false, sender: "Priya Menon", person: "p-priya", at: date(2025, 3, 2, 20), "sure was")
        let s = try await DuoWrappedBuilder.build(store: sparse.store, chatID: 20, me: "Suraj", fetchTitles: false)
        XCTAssertNil(WrappedCopy.replyRace(me: "Suraj", them: s.them, mine: s.medianReplyMine, theirs: s.medianReplyTheirs,
                                           mineSamples: s.replyCountMine, theirsSamples: s.replyCountTheirs,
                                           mineSlow: s.slowReplyMine, theirsSlow: s.slowReplyTheirs))
    }

    // MARK: - 5. Spans are inclusive

    func testTwoConsecutiveDaysReadAsTwoDays() async throws {
        let index = try Index(try tempDir())
        try index.chat(10, "Priya Menon", group: false, person: "p-priya")
        try index.chat(11, "Flat 4B", group: true)
        try index.person("p-priya", "Priya Menon")

        index.message(10, me: true, sender: "You", person: nil, at: date(2025, 7, 12, 21), "haan haan")
        index.message(10, me: false, sender: "Priya Menon", person: "p-priya", at: date(2025, 7, 13, 9), "you too, sleep well")
        index.message(11, me: false, sender: "Ritu Sharma", person: nil, at: date(2025, 7, 12, 10), "who has the keys")
        index.message(11, me: true, sender: "You", person: nil, at: date(2025, 7, 13, 10), "with me")

        let duo = try await DuoWrappedBuilder.build(store: index.store, chatID: 10, me: "Suraj", fetchTitles: false)
        XCTAssertEqual(duo.spanDays, 2, "12 and 13 July is two days, not one")
        let line = WrappedCopy.span(spanDays: duo.spanDays, activeDays: duo.activeDays, first: duo.first)
        XCTAssertEqual(line, "2 days, every single one of them with something in it.")
        XCTAssertFalse(line.contains("All of it on"), "two days are not 'all of it on 12 July'")

        let group = try await GroupWrappedBuilder.build(store: index.store, chatID: 11, me: "Suraj", fetchTitles: false)
        XCTAssertEqual(group.spanDays, 2)
        let opening = WrappedCopy.groupOpening(name: group.name, total: group.total, contributors: group.contributors.count,
                                              spanDays: group.spanDays, activeDays: group.activeDays)
        XCTAssertFalse(opening.contains("one day"), opening)
    }

    // MARK: - 6. Every count reads right at 0, 1 and 2

    func testEveryCountSentenceReadsRightAtZeroOneAndTwo() {
        let day = date(2025, 8, 18)
        let sentences: [(String, (Int) -> String)] = [
            ("laughs peak", { WrappedCopy.laughs(me: "Sam", them: "Asha", madeThemLaugh: 5, madeMeLaugh: 2,
                                                 peakMonth: (month: "2025-08", count: $0)) }),
            ("soundtrack", { WrappedCopy.soundtrack(me: "Sam", them: "Asha", total: $0, mine: $0, theirs: 0, twins: $0) ?? "" }),
            ("jokes", { WrappedCopy.jokes(count: $0, top: "blue kettle", topCount: $0) ?? "" }),
            ("group soundtrack", { WrappedCopy.groupSoundtrack(total: $0, sharers: 1, top: "Asha", topCount: $0) ?? "" }),
            ("group voices", { WrappedCopy.groupVoices(top: "Asha", topCount: $0, funniest: nil, laughs: 0, of: 0,
                                                       runnerUpRate: nil, roomRate: 0) ?? "" }),
            ("year room", { WrappedCopy.yearRoom(group: "Flat 4B", count: 40, groups: $0 + 1) ?? "" }),
            ("year soundtrack", { WrappedCopy.yearSoundtrack(total: $0, senders: 1, top: "You", topCount: $0, service: .spotify) ?? "" }),
            ("year media", { WrappedCopy.yearMedia(photos: 0, videos: $0, voice: 0) ?? "" }),
            ("year more chats", { WrappedCopy.yearMoreChats($0) ?? "" }),
            ("year night", { WrappedCopy.yearNight(count: $0) ?? "" }),
            ("peak month", { WrappedCopy.peakMonth(month: "2025-08", count: $0, total: 100) ?? "" }),
            ("quiet year", { WrappedCopy.quietYear(year: 2024, count: $0, nextYear: nil, nextCount: nil) ?? "" }),
            ("year days", { WrappedCopy.yearDays(yourDays: $0, coveredDays: 365, daysInYear: 365, partial: false) }),
            ("duration", { WrappedCopy.duration(Double($0) * 60) }),
            ("plural helper", { WrappedCopy.plural($0, "laugh") })
        ]
        let pluralAfterOne = try! NSRegularExpression(
            pattern: #"(?:^|[^0-9])1 (messages|songs|links|phrases|days|laughs|videos|photos|conversations|shares|people|other groups|more conversations|photos)\b"#)

        for (label, sentence) in sentences {
            for n in 0...2 {
                let text = sentence(n)
                let range = NSRange(location: 0, length: (text as NSString).length)
                XCTAssertNil(pluralAfterOne.firstMatch(in: text, range: range),
                             "\(label) at \(n) prints a plural after one: “\(text)”")
            }
            XCTAssertFalse(sentence(1).isEmpty, "\(label) has no sentence at 1")
            XCTAssertTrue(sentence(2).contains("2"), "\(label) at 2 does not carry the number: “\(sentence(2))”")
        }

        // The forms that were actually shipping wrong.
        // A run of one day is not a streak, so those two say nothing at all.
        XCTAssertNil(WrappedCopy.streak(days: 1, ended: day))
        XCTAssertNil(WrappedCopy.yearStreak(days: 1))
        XCTAssertEqual(WrappedCopy.streak(days: 2, ended: day), "2 days in a row at the best run, ending 18 Aug 2025.")
        XCTAssertEqual(WrappedCopy.yearStreak(days: 2), "2 days in a row was the best run.")

        XCTAssertEqual(WrappedCopy.plural(1, "laugh"), "1 laugh")
        XCTAssertEqual(WrappedCopy.plural(2, "laugh"), "2 laughs")
        XCTAssertEqual(WrappedCopy.plural(0, "laugh"), "0 laughs")
        XCTAssertEqual(WrappedCopy.jokes(count: 1, top: "sambar index", topCount: 4),
                       "1 phrase lives only in this chat. “sambar index” leads, 4 times.")
        XCTAssertEqual(WrappedCopy.groupSoundtrack(total: 1, sharers: 1, top: "Tara Bhat", topCount: 1),
                       "One link landed in the chat, from one person. Tara Bhat shared it.")
        XCTAssertEqual(WrappedCopy.yearSoundtrack(total: 1, senders: 1, top: "Nikhil Rao", topCount: 1, service: nil),
                       "One song or video went round, and Nikhil Rao sent it.")
        XCTAssertEqual(WrappedCopy.soundtrack(me: "Sam", them: "Priya Menon", total: 1, mine: 1, theirs: 0, twins: 0),
                       "One song or video went round in here, from you.")
        XCTAssertEqual(WrappedCopy.soundtrack(me: "Sam", them: "Meera Nair", total: 10, mine: 4, theirs: 6, twins: 1),
                       "You traded 10 songs and videos — 4 from you, 6 from Meera Nair. One was the same link sent by both of you.")
        XCTAssertEqual(WrappedCopy.yearRoom(group: "Flat 4B", count: 40, groups: 2),
                       "The loudest room was Flat 4B — 40 messages, ahead of 1 other group.")
        XCTAssertEqual(WrappedCopy.yearMedia(photos: 0, videos: 1, voice: 0), "Along the way you also kept 1 video.")
    }

    /// Found while verifying the rest: a one-sided chat printed "Your longest message is
    /// 0 characters", which is not a message anyone sent.
    func testAOneSidedChatHasNoZeroCharacterLongestMessage() {
        XCTAssertEqual(WrappedCopy.longestMessage(me: "Suraj", them: "Priya Menon", mine: 0, theirs: 49),
                       "You didn't send one; Priya Menon's record is 49 characters.")
        XCTAssertEqual(WrappedCopy.longestMessage(me: "Suraj", them: "Priya Menon", mine: 72, theirs: 0),
                       "Priya Menon didn't send one; your record is 72 characters.")
        XCTAssertNil(WrappedCopy.longestMessage(me: "Suraj", them: "Priya Menon", mine: 0, theirs: 0))
    }

    // MARK: - 7. "Nothing else came close" is checked, not asserted

    func testNothingElseCameCloseOnlyWhenItIsTrue() async throws {
        let index = try Index(try tempDir())
        try index.chat(11, "Flat 4B", group: true)
        index.message(11, me: false, sender: "Ritu Sharma", person: nil, at: date(2024, 3, 1, 9), String(repeating: "a", count: 77))
        index.message(11, me: true, sender: "You", person: nil, at: date(2024, 3, 2, 9), String(repeating: "b", count: 76))

        let w = try await YearWrappedBuilder.build(store: index.store, year: "2024")
        let longest = try XCTUnwrap(w.longest)
        XCTAssertEqual(longest.chars, 77)
        XCTAssertEqual(longest.runnerUp, 76, "the second-longest message is measured, not assumed")

        let line = WrappedCopy.yearLongest(chars: longest.chars, runnerUp: longest.runnerUp, chat: longest.chatName,
                                           fromMe: longest.fromMe, author: longest.author)
        XCTAssertEqual(line, "Ritu Sharma wrote 77 characters in one go in Flat 4B. The next longest was 76.")
        XCTAssertFalse(line.contains("Nothing else came close"))
    }

    // MARK: - 8. A song reaction belongs to the share it answered

    func testAReactionToALaterShareIsNotPinnedOnTheFirstShare() async throws {
        let index = try Index(try tempDir())
        try index.chat(10, "Meera Nair", group: false, person: "p-meera")
        try index.person("p-meera", "Meera Nair")
        let link = "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"

        index.message(10, me: false, sender: "Meera Nair", person: "p-meera", at: date(2025, 5, 1, 9), "\(link)", uid: "m1")
        index.message(10, me: true, sender: "You", person: nil, at: date(2025, 5, 1, 9, 10), "this again \(link)", uid: "m2")
        index.message(10, me: false, sender: "Meera Nair", person: "p-meera", at: date(2025, 5, 1, 9, 11), "on repeat since morning", uid: "m3")

        let w = try await DuoWrappedBuilder.build(store: index.store, chatID: 10, me: "Suraj", fetchTitles: false)
        let track = try XCTUnwrap(w.tracks.first { $0.url.hasPrefix("https://open.spotify.com/track/") })
        XCTAssertEqual(track.firstBy, "Meera Nair")
        // Her reaction answered *your* re-share, so it does not describe the card's own share.
        XCTAssertTrue(track.reaction.isEmpty, "the sender must not be shown reacting to her own song: \(track.reactionBy): \(track.reaction)")
        XCTAssertFalse(track.reactionBy == track.firstBy)
    }

    // MARK: - 9. "Funniest" is laughs per message, not the biggest talker

    func testTheFunniestPersonIsRankedPerMessageNotByVolume() async throws {
        let index = try Index(try tempDir())
        try index.chat(11, "Sunday Football XI", group: true)
        var t = date(2025, 2, 1, 9)
        func tick() -> Date { defer { t = t.addingTimeInterval(60) }; return t }

        // Loud writes 100 messages and earns 8 laughs (8%).
        for i in 0..<100 {
            index.message(11, me: false, sender: "Sandeep Kulkarni", person: nil, at: tick(), "loud message number \(i) about football")
            if i % 12 == 0, i < 96 {
                index.message(11, me: false, sender: "Ritu Sharma", person: nil, at: tick(), "hahahahaha")
            }
        }
        // Quiet writes 20 messages and earns 5 laughs (25%).
        for i in 0..<12 {
            index.message(11, me: false, sender: "Sneha Patil", person: nil, at: tick(), "quiet filler line \(i) about the plants")
        }
        for i in 0..<5 {
            index.message(11, me: false, sender: "Sneha Patil", person: nil, at: tick(), "quiet punchline number \(i) lands")
            index.message(11, me: false, sender: "Sandeep Kulkarni", person: nil, at: tick(), "hahahahaha")
        }

        let w = try await GroupWrappedBuilder.build(store: index.store, chatID: 11, me: "Suraj", fetchTitles: false)
        let loud = try XCTUnwrap(w.funniest.first { $0.name == "Sandeep Kulkarni" })
        let quiet = try XCTUnwrap(w.funniest.first { $0.name == "Sneha Patil" })
        XCTAssertGreaterThan(loud.laughsEarned, quiet.laughsEarned, "the loud writer still has more laughs in total")
        XCTAssertGreaterThan(quiet.rate, loud.rate)
        XCTAssertEqual(w.funniest.first?.name, "Sneha Patil", "ranked per message, not per person")

        let f = try XCTUnwrap(w.funniest.first)
        let copy = try XCTUnwrap(WrappedCopy.groupVoices(top: w.contributors.first?.name,
                                                         topCount: w.contributors.first?.messages ?? 0,
                                                         funniest: f.name, laughs: f.laughsEarned, of: f.messages,
                                                         runnerUpRate: w.witRunnerUpRate, roomRate: w.laughRate))
        XCTAssertTrue(copy.contains("Per message, the room laughs hardest at Sneha Patil"), copy)
        XCTAssertTrue(copy.contains("across \(f.messages) messages"), copy)
        XCTAssertFalse(copy.contains("gets the laughs too"), "the old sentence called the loudest writer the funniest")
    }
}
