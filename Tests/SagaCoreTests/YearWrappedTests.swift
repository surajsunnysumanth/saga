import XCTest
@testable import SagaCore

/// The year Wrapped: the story beats it picks, the years it refuses to invent, and
/// the sentences that carry them. All against a hand-built index, so the numbers in
/// the assertions are the numbers the copy has to spell out.
final class YearWrappedTests: XCTestCase {

    // MARK: Fixture

    private func makeDB(_ dir: URL) throws -> String {
        let path = dir.appendingPathComponent("idx.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
        CREATE TABLE chats(chat_id INTEGER PRIMARY KEY, jid TEXT, is_group INT, name TEXT, resolved INT, person TEXT);
        CREATE TABLE people(person TEXT PRIMARY KEY, name TEXT, resolved INT);
        CREATE TABLE messages(id INTEGER PRIMARY KEY, chat_id INT, from_me INT, sender TEXT, person TEXT, ts INT, type INT, text TEXT, uid TEXT);
        CREATE TABLE media(msg_id INTEGER PRIMARY KEY, chat_id INT, ts INT, mime TEXT, kind TEXT, file_path TEXT, size INT, file_hash TEXT, caption TEXT, rel TEXT);
        CREATE TABLE message_replies(uid TEXT PRIMARY KEY, target_uid TEXT NOT NULL);
        INSERT INTO chats VALUES (10,'meera@s.whatsapp.net',0,'Meera Nair',1,'p-meera'),
                                 (11,'group@g.us',1,'Flat 4B',1,NULL);
        INSERT INTO people VALUES ('p-meera','Meera Nair',1);
        """)
        let cal = Calendar.current
        func ts(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Int64 {
            let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        func msg(_ id: Int64, _ chat: Int64, _ me: Int, _ sender: String, _ person: String, _ date: Int64,
                 _ text: String, _ uid: String, _ type: Int = 0) {
            try? db.exec("INSERT INTO messages VALUES (\(id),\(chat),\(me),'\(sender)','\(person)',\(date),\(type),'\(text)','\(uid)')")
        }
        // 2025: three months of a quiet, real little year.
        msg(1, 10, 0, "Meera Nair", "p-meera", ts(2025, 1, 5), "hi", "d1")
        msg(2, 10, 1, "You", "p-meera", ts(2025, 1, 6), String(repeating: "a", count: 200), "d2")
        msg(3, 10, 0, "Meera Nair", "p-meera", ts(2025, 1, 7), "why did the chai cross the road", "d3")
        msg(4, 10, 0, "Meera Nair", "p-meera", ts(2025, 1, 7, 13), "hahahaha 😂", "d4")
        msg(5, 10, 1, "You", "p-meera", ts(2025, 2, 10), "https://open.spotify.com/track/2UVxQoXyJQs98RrXJoLoZK", "d5")
        msg(6, 11, 0, "Nikhil Rao", "", ts(2025, 3, 1), "sunday football at 7", "d6")
        msg(7, 11, 1, "You", "", ts(2025, 3, 1, 14), "pitch is booked", "d7")
        // A longer message that is only a pasted link must never be "the message that says the most".
        msg(8, 11, 0, "Nikhil Rao", "", ts(2025, 3, 2),
            "https://www.youtube.com/watch?v=z0mVvLBAVg0&list=" + String(repeating: "x", count: 220), "d8")
        // The same song three times: the soundtrack has a clear repeat and a clear service.
        msg(10, 10, 1, "You", "p-meera", ts(2025, 2, 10, 15), "https://open.spotify.com/track/2UVxQoXyJQs98RrXJoLoZK", "d10")
        msg(11, 10, 0, "Meera Nair", "p-meera", ts(2025, 2, 11), "again https://open.spotify.com/track/2UVxQoXyJQs98RrXJoLoZK", "d11")
        // Next year, so a year build cannot leak across the boundary.
        msg(9, 10, 0, "Meera Nair", "p-meera", ts(2026, 1, 2), "new year", "d9")
        try db.exec("""
        INSERT INTO message_replies VALUES ('d4','d3');
        INSERT INTO media VALUES (2,10,0,'image/jpeg','image','Media/IMG-1.jpg',10,'h','cap',NULL);
        """)
        return path
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("saga-year-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Builder

    func testYearBuildPicksTheStoryBeatsAndStaysInsideTheYear() async throws {
        let path = try makeDB(try tempDir())
        let store = try VaultStore(path: path)
        let w = try await YearWrappedBuilder.build(store: store, year: "2025")

        XCTAssertEqual(w.year, "2025")
        XCTAssertEqual(w.total, 10)                      // the 2026 message is not in it
        XCTAssertEqual(w.sent, 4)
        XCTAssertEqual(w.activeDays, 7)                  // 5, 6, 7 Jan; 10, 11 Feb; 1, 2 Mar
        XCTAssertEqual(w.daysInYear, 365)
        XCTAssertEqual(w.months, 3)
        XCTAssertEqual(w.monthly.map(\.month), ["2025-01", "2025-02", "2025-03"])
        XCTAssertTrue(w.isPartial)                       // January to March is not a year
        XCTAssertEqual(w.chats.count, 2)
        XCTAssertEqual(w.chats.first?.name, "Meera Nair")
        XCTAssertEqual(w.dmChats.count, 1)
        XCTAssertEqual(w.groupChats.count, 1)
        XCTAssertEqual(w.people.first?.name, "Meera Nair")
        XCTAssertEqual(w.peopleCount, 1)
        XCTAssertEqual(w.media.photos, 1)
        XCTAssertEqual(w.longestStreak, 3)               // 5, 6 and 7 January

        // The longest message is the 200-character one, not the pasted YouTube link.
        let longest = try XCTUnwrap(w.longest)
        XCTAssertEqual(longest.chars, 200)
        XCTAssertTrue(longest.fromMe)
        XCTAssertEqual(longest.chatName, "Meera Nair")
        XCTAssertEqual(longest.messageID, 2)

        // The laugh came from a real quoted reply, and the moment is the message it answered.
        XCTAssertEqual(w.laughs, 1)
        let moment = try XCTUnwrap(w.laughMoment)
        XCTAssertEqual(moment.messageID, 3)
        XCTAssertEqual(moment.text, "why did the chai cross the road")
        XCTAssertEqual(moment.replyBy, "Meera Nair")
        XCTAssertEqual(moment.reply, "hahahaha 😂")

        // Music: the same song three times, and one video — so the repeat and the
        // service both have a winner instead of a tie.
        XCTAssertEqual(w.linksTotal, 4)
        XCTAssertTrue(w.hasMusic)
        XCTAssertEqual(w.tracks.count, 2)
        XCTAssertEqual(w.tracks.first?.service, .spotify)
        XCTAssertEqual(w.tracks.first?.times, 3)
        XCTAssertEqual(w.tracks.first?.firstBy, "You")
        XCTAssertEqual(w.tracks.first?.firstChat, "Meera Nair")
        XCTAssertEqual(w.tracks.first?.embed, "https://open.spotify.com/embed/track/2UVxQoXyJQs98RrXJoLoZK")
        XCTAssertEqual(w.topService, .spotify)
    }

    /// The archive in this fixture runs 5 January – 2 March 2025 and then stops:
    /// 2025 is a partial year, and every sentence about it has to say so.
    func testAPartialYearIsMeasuredByTheDaysTheArchiveCovers() async throws {
        let path = try makeDB(try tempDir())
        let store = try VaultStore(path: path)
        let w = try await YearWrappedBuilder.build(store: store, year: "2025")

        XCTAssertTrue(w.isPartial)
        XCTAssertEqual(w.coveredDays, 57, "5 January to 2 March inclusive, not 365")
        XCTAssertEqual(w.activeDays, 7)
        XCTAssertEqual(w.yourDays, 3, "only the days you sent something")

        let line = WrappedCopy.yearDays(yourDays: w.yourDays, coveredDays: w.coveredDays,
                                        daysInYear: w.daysInYear, partial: w.isPartial)
        XCTAssertEqual(line, "Of the 57 days this archive covers, you wrote on 3.")
        XCTAssertFalse(line.contains("missed"), "nothing was missed on days that had not happened")

        XCTAssertEqual(WrappedCopy.yearPartial(firstMonth: w.firstMonthIndex, lastMonth: w.lastMonthIndex, months: w.months),
                       "January to March: a message in all 3 months.",
                       "the denominator is the span the archive holds, not twelve months")
    }

    func testYearCountsMatchTheArchiveAndContentSkipsSystemNotices() async throws {
        let path = try makeDB(try tempDir())
        let db = try SQLiteDB(path: path, readOnly: false)
        let cal = Calendar.current
        let noticeTs = Int64(cal.date(from: DateComponents(year: 2023, month: 6, day: 1, hour: 12))!.timeIntervalSince1970 * 1000)
        try db.exec("INSERT INTO messages VALUES (20,10,0,'Meera Nair','p-meera',\(noticeTs),7,'Security code changed','d20')")
        let store = try VaultStore(path: path)

        let w2025 = try await YearWrappedBuilder.build(store: store, year: "2025")
        XCTAssertEqual(w2025.total, 10, "the count matches the sidebar and the archive stats")

        // A system notice is still a row, but it is never the laugh, the longest message
        // or the thing the soundtrack is built from.
        let noticeYear = try await YearWrappedBuilder.build(store: store, year: "2023")
        XCTAssertEqual(noticeYear.total, 1)
        XCTAssertNil(noticeYear.longest, "a security-code notice is not a message that says the most")
        XCTAssertNil(noticeYear.laughMoment)

        let empty = try await YearWrappedBuilder.build(store: store, year: "2019")
        XCTAssertEqual(empty.total, 0)
        XCTAssertTrue(empty.chats.isEmpty)
        XCTAssertNil(empty.longest)
        XCTAssertNil(empty.laughMoment)
        XCTAssertFalse(empty.hasMusic)
    }

    func testYearCacheKeyFollowsContentNotRowIDs() async throws {
        let path = try makeDB(try tempDir())
        let store = try VaultStore(path: path)
        let key = YearWrappedBuilder.cacheKey(store: store, year: "2025")
        XCTAssertEqual(key, YearWrappedBuilder.cacheKey(store: store, year: "2025"), "reopening the same archive must reuse the build")
        XCTAssertNotEqual(key, YearWrappedBuilder.cacheKey(store: store, year: "2026"))

        let db = try SQLiteDB(path: path, readOnly: false)
        let cal = Calendar.current
        let now = Int64(cal.date(from: DateComponents(year: 2025, month: 6, day: 1, hour: 12))!.timeIntervalSince1970 * 1000)
        try db.exec("INSERT INTO messages VALUES (30,10,0,'Meera Nair','p-meera',\(now),0,'one more','d30')")
        XCTAssertNotEqual(key, YearWrappedBuilder.cacheKey(store: store, year: "2025"), "a new message must invalidate the cached story")
    }

    // MARK: Copy

    func testYearCopyReadsAsSentencesCarryingNumbers() {
        XCTAssertEqual(WrappedCopy.yearOpening(year: "2025", total: 41_203, chats: 34),
                       "2025 held 41,203 messages across 34 conversations.")
        XCTAssertEqual(WrappedCopy.yearOpening(year: "2025", total: 200, chats: 1),
                       "2025 held 200 messages, all in one conversation.")
        XCTAssertEqual(WrappedCopy.yearOpening(year: "2025", total: 0, chats: 0), "Nothing from 2025 in here.")

        XCTAssertEqual(WrappedCopy.yearDays(yourDays: 304, coveredDays: 365, daysInYear: 365, partial: false),
                       "You wrote on 304 days. The other 61 went by without a message from you.")
        XCTAssertEqual(WrappedCopy.yearDays(yourDays: 365, coveredDays: 365, daysInYear: 365, partial: false), "You wrote on all 365 days.")
        XCTAssertEqual(WrappedCopy.yearDays(yourDays: 1, coveredDays: 365, daysInYear: 365, partial: false),
                       "You wrote on one day; the other 364 went by without a message from you.")
        XCTAssertEqual(WrappedCopy.yearDays(yourDays: 0, coveredDays: 365, daysInYear: 365, partial: false), "Not one day of it had a message from you.")

        // A partial year is measured against what the archive holds, not the calendar.
        XCTAssertEqual(WrappedCopy.yearDays(yourDays: 304, coveredDays: 304, daysInYear: 365, partial: true),
                       "You wrote on all 304 days this archive covers.")
        XCTAssertEqual(WrappedCopy.yearDays(yourDays: 200, coveredDays: 304, daysInYear: 365, partial: true),
                       "Of the 304 days this archive covers, you wrote on 200.")

        XCTAssertEqual(WrappedCopy.yearPartial(firstMonth: 3, lastMonth: 11, months: 9),
                       "March to November: a message in all 9 months.")
        XCTAssertEqual(WrappedCopy.yearPartial(firstMonth: 1, lastMonth: 10, months: 10),
                       "January to October: a message in all 10 months.")
        XCTAssertEqual(WrappedCopy.yearPartial(firstMonth: 1, lastMonth: 12, months: 11),
                       "January to December: 11 of the twelve months have messages.")
        XCTAssertEqual(WrappedCopy.yearPartial(firstMonth: 3, lastMonth: 11, months: 8),
                       "March to November: 8 of the 9 months between them have messages.")
        XCTAssertEqual(WrappedCopy.yearPartial(firstMonth: 6, lastMonth: 6, months: 1), "Only June is in here so far.")
        XCTAssertNil(WrappedCopy.yearPartial(firstMonth: 1, lastMonth: 12, months: 12))
        XCTAssertNil(WrappedCopy.yearPartial(firstMonth: 1, lastMonth: 1, months: 0))

        let day = Calendar.current.date(from: DateComponents(year: 2025, month: 8, day: 18, hour: 12))!
        XCTAssertEqual(WrappedCopy.yearShape(month: "2025-08", count: 6_204, busiest: day, busiestCount: 312, hour: 22),
                       "August carried the most — 6,204 messages. The loudest day was 18 August, with 312. Most of it landed around 10 pm.")

        XCTAssertEqual(WrappedCopy.yearPeople(top: "Meera Nair", topCount: 6_204, people: 22),
                       "Meera Nair got the most of your attention: 6,204 messages. 22 people wrote to you in all.")
        XCTAssertEqual(WrappedCopy.yearPeople(top: "Meera Nair", topCount: 12, people: 1),
                       "Meera Nair was the only person who wrote to you: 12 messages.")
        XCTAssertNil(WrappedCopy.yearPeople(top: nil, topCount: 0, people: 0))

        XCTAssertEqual(WrappedCopy.yearRoom(group: "Sunday Football XI", count: 6_201, groups: 10),
                       "The loudest room was Sunday Football XI — 6,201 messages, ahead of 9 other groups.")

        XCTAssertEqual(WrappedCopy.yearLaughs(count: 243), "243 messages earned a proper laugh out loud.")
        XCTAssertEqual(WrappedCopy.yearLaughs(count: 1), "One message earned a proper laugh out loud.")
        XCTAssertEqual(WrappedCopy.yearLaughs(count: 0), "No laugh came back this year. Very serious correspondence.")
        XCTAssertEqual(WrappedCopy.yearLaughMoment(author: "Meera Nair", chat: "Flat 4B", on: day),
                       "The biggest one: Meera Nair in Flat 4B, 18 August.")

        XCTAssertEqual(WrappedCopy.yearSoundtrack(total: 137, senders: 2, top: "You", topCount: 52, service: .spotify),
                       "137 songs and videos went round. You sent 52, more than anyone. Most of it was Spotify.")
        XCTAssertEqual(WrappedCopy.yearSoundtrack(total: 4, senders: 1, top: "Meera Nair", topCount: 4, service: nil),
                       "4 songs and videos went round, every one of them from Meera Nair.")
        XCTAssertNil(WrappedCopy.yearSoundtrack(total: 0, senders: 0, top: "You", topCount: 0, service: nil))

        XCTAssertEqual(WrappedCopy.yearLongest(chars: 1_204, runnerUp: 300, chat: "Flat 4B", fromMe: true, author: "You"),
                       "You typed 1,204 characters in one message in Flat 4B. Nothing else came close.")
        XCTAssertEqual(WrappedCopy.yearLongest(chars: 900, runnerUp: 120, chat: "Flat 4B", fromMe: false, author: "Nikhil Rao"),
                       "Nikhil Rao wrote 900 characters in one go in Flat 4B. Nothing else came close.")
        XCTAssertEqual(WrappedCopy.yearLongest(chars: 321, runnerUp: 40, chat: "Meera Nair", fromMe: false, author: "Meera Nair"),
                       "Meera Nair wrote 321 characters in one go. Nothing else came close.")
        // A 77-character winner against a 76-character runner-up is not "nothing came close".
        XCTAssertEqual(WrappedCopy.yearLongest(chars: 77, runnerUp: 76, chat: "Flat 4B", fromMe: false, author: "Ritu Sharma"),
                       "Ritu Sharma wrote 77 characters in one go in Flat 4B. The next longest was 76.")
        XCTAssertEqual(WrappedCopy.yearLongest(chars: 76, runnerUp: 76, chat: "Flat 4B", fromMe: false, author: "Arjun Kamath"),
                       "Arjun Kamath wrote 76 characters in one go in Flat 4B. Another message matched it.")

        XCTAssertEqual(WrappedCopy.yearMedia(photos: 812, videos: 40, voice: 61),
                       "Along the way you also kept 812 photos, 40 videos and 61 voice notes.")
        XCTAssertEqual(WrappedCopy.yearMedia(photos: 812, videos: 0, voice: 0), "Along the way you also kept 812 photos.")
        XCTAssertNil(WrappedCopy.yearMedia(photos: 0, videos: 0, voice: 0))

        XCTAssertEqual(WrappedCopy.yearClosing(year: "2025", total: 41_203, people: 22),
                       "That was 2025. 41,203 messages, 22 people, and not one of them left this Mac.")
        XCTAssertEqual(WrappedCopy.yearClosing(year: "2025", total: 3, people: 0),
                       "That was 2025. 3 messages, and not one of them left this Mac.")
        XCTAssertEqual(WrappedCopy.yearStreak(days: 41), "41 days in a row was the best run.")
        XCTAssertNil(WrappedCopy.yearStreak(days: 1))
        XCTAssertEqual(WrappedCopy.yearNight(count: 61), "61 messages landed between midnight and 5 am.")
        XCTAssertNil(WrappedCopy.yearNight(count: 0))
        XCTAssertEqual(WrappedCopy.monthName(3), "March")
        XCTAssertEqual(WrappedCopy.yearNoMoment(year: "2025"),
                       "No single message in 2025 got a reply like that. Plenty of talking, just a serious crowd.")
        XCTAssertEqual(WrappedCopy.yearMoreChats(6), "…and 6 more conversations.")
        XCTAssertNil(WrappedCopy.yearMoreChats(0))
    }
}
