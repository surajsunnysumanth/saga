import XCTest
@testable import SagaCore

/// Synthetic fixtures only: made-up names, numbers and text. No archive is read here.
final class ReplyResponsibilityTests: XCTestCase {
    /// Fixed clock, so elapsed-day arithmetic is exact and independent of the wall clock.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    struct Chat {
        var id: Int64
        var jid: String = "15550001111@s.whatsapp.net"
        var name: String = "Example Person"
        var isGroup = false
        var person: String = "5550001111"
    }

    struct Msg {
        var id: Int64
        var chat: Int64
        /// Elapsed days before `now`; negative means the future.
        var days: Double
        var uid: String? = nil
        var fromMe = false
        var type = 0
        var text = ""
        var media: String? = nil
    }

    private var scratch: [String] = []

    override func tearDown() {
        for p in scratch { try? FileManager.default.removeItem(atPath: p) }
        scratch = []
        super.tearDown()
    }

    private func nowMS() -> Int64 { Int64((Self.now.timeIntervalSince1970 * 1000).rounded()) }
    /// Exact millisecond for "this many days before the fixed clock".
    private func ms(days: Double) -> Int64 { nowMS() - Int64((days * 86_400_000).rounded()) }

    private func makeIndex(chats: [Chat], messages: [Msg]) throws -> VaultStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("replies-\(UUID().uuidString).sqlite").path
        scratch.append(path)
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        let chatInsert = try db.prepare("INSERT INTO chats(chat_id, jid, is_group, name, resolved, person) VALUES(?,?,?,?,1,?)")
        let msgInsert = try db.prepare("INSERT INTO messages(id, chat_id, from_me, sender, person, ts, type, text, uid) VALUES(?,?,?,?,?,?,?,?,?)")
        let mediaInsert = try db.prepare("INSERT INTO media(msg_id, chat_id, ts, mime, kind, file_path, size, file_hash, caption) VALUES(?,?,?,?,?,?,?,?,?)")
        try db.exec("BEGIN")
        for c in chats {
            try chatInsert.run([.int(c.id), .text(c.jid), .int(c.isGroup ? 1 : 0), .text(c.name), .text(c.person)])
        }
        for m in messages {
            let ts = ms(days: m.days)
            try msgInsert.run([.int(m.id), .int(m.chat), .int(m.fromMe ? 1 : 0), .text(m.fromMe ? "Me" : "Example Person"),
                               .text("p"), .int(ts), .int(Int64(m.type)), .text(m.text), m.uid.map { .text($0) } ?? .null])
            if let kind = m.media {
                try mediaInsert.run([.int(m.id), .int(m.chat), .int(ts), .text("image/jpeg"), .text(kind),
                                     .text("media/synthetic.jpg"), .int(1024), .text("hash-\(m.id)"), .null])
            }
        }
        try db.exec("COMMIT")
        return try VaultStore(path: path)
    }

    private func find(_ store: VaultStore, quiet: Int = ReplyResponsibility.defaultQuietDays,
                      window: Int = ReplyResponsibility.defaultWindowMonths,
                      now: Date = ReplyResponsibilityTests.now) throws -> [ReplyCandidate] {
        try ReplyResponsibility.find(store: store, quietDays: quiet, windowMonths: window, now: now).candidates
    }

    // MARK: - The documented cases

    func testIncomingQuestionQualifies() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 4, uid: "q-1", text: "Are we still on for lunch?")])
        let found = try find(store)
        XCTAssertEqual(found.count, 1)
        let c = try XCTUnwrap(found.first)
        XCTAssertEqual(c.id, "q-1")
        XCTAssertEqual(c.chatJID, "15550001111@s.whatsapp.net")
        XCTAssertEqual(c.chatName, "Example Person")
        XCTAssertEqual(c.source.messageID, 10)
        XCTAssertEqual(c.source.chatID, 1)
        XCTAssertEqual(c.source.uid, "q-1")
        XCTAssertEqual(c.quietDays, 4)
        XCTAssertEqual(c.questionDate, Date(timeIntervalSince1970: Double(ms(days: 4)) / 1000))
        XCTAssertEqual(c.preview, "Are we still on for lunch?")
    }

    func testOutgoingReplyClearsIt() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: "q", text: "Lunch on Friday?"),
                                             Msg(id: 11, chat: 1, days: 4, uid: "a", fromMe: true, text: "Sounds good")])
        XCTAssertTrue(try find(store).isEmpty)
    }

    func testIncomingNonQuestionAsLastWordDoesNotQualify() throws {
        // A later incoming non-question means the latest message is no longer the question.
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 6, uid: "q", text: "Can you send the file?"),
                                             Msg(id: 11, chat: 1, days: 5, uid: "m", text: "Sent it earlier")])
        XCTAssertTrue(try find(store).isEmpty)
    }

    func testTooRecentDoesNotQualifyButLowerThresholdDoes() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 2, uid: "q", text: "Call tomorrow?")])
        XCTAssertTrue(try find(store, quiet: 3).isEmpty)
        XCTAssertEqual(try find(store, quiet: 2).count, 1)
        XCTAssertEqual(try find(store, quiet: 1).count, 1)
    }

    func testExactElapsedDayBoundary() throws {
        let exact = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 3, uid: "q", text: "Still there?")])
        XCTAssertEqual(try find(exact, quiet: 3).map(\.id), ["q"])

        // One millisecond short of three whole days is still two.
        let short = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 3 - 0.000_000_01, uid: "q", text: "Still there?")])
        XCTAssertTrue(try find(short, quiet: 3).isEmpty)
        XCTAssertEqual(try find(short, quiet: 2).count, 1)
    }

    func testFutureTimestampDoesNotQualify() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: -2, uid: "q", text: "Tomorrow at ten?")])
        XCTAssertTrue(try find(store).isEmpty)
    }

    func testEqualTimestampsFollowIdOrder() throws {
        // Same timestamp: the higher row id is the later message, so an outgoing reply at the
        // same instant means the question was answered.
        let answered = try makeIndex(chats: [Chat(id: 1)],
                                     messages: [Msg(id: 10, chat: 1, days: 4, uid: "q", text: "Coming?"),
                                                Msg(id: 11, chat: 1, days: 4, uid: "a", fromMe: true, text: "Yes")])
        XCTAssertTrue(try find(answered).isEmpty)

        // The reverse order at the same instant leaves the question as the last word.
        let open = try makeIndex(chats: [Chat(id: 1)],
                                 messages: [Msg(id: 10, chat: 1, days: 4, uid: "a", fromMe: true, text: "Yes"),
                                            Msg(id: 11, chat: 1, days: 4, uid: "q", text: "Coming?")])
        XCTAssertEqual(try find(open).map(\.id), ["q"])
    }

    func testOutgoingMediaCountsAsReply() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: "q", text: "Can you send the photo?"),
                                             Msg(id: 11, chat: 1, days: 2, uid: "m", fromMe: true, text: "", media: "image")])
        XCTAssertTrue(try find(store).isEmpty)
    }

    func testSystemNoticesAreIgnored() throws {
        // A later encryption notice is not an answer and is not a last word either.
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: "q", text: "Dinner Sunday?"),
                                             Msg(id: 11, chat: 1, days: 1, uid: "sys", type: 27, text: "Messages are end-to-end encrypted")])
        XCTAssertEqual(try find(store).map(\.id), ["q"])

        // A chat holding only notices has no last word a person wrote.
        let notices = try makeIndex(chats: [Chat(id: 1)],
                                    messages: [Msg(id: 10, chat: 1, days: 5, uid: "sys", type: 7, text: "You joined using this group's invite link")])
        XCTAssertTrue(try find(notices).isEmpty)
    }

    func testEmptyTextIsNotSubstantive() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: "q", text: "Send the address?"),
                                             Msg(id: 11, chat: 1, days: 1, uid: "blank", text: ""),
                                             Msg(id: 12, chat: 1, days: 0.5, uid: "space", text: "   \n ")])
        XCTAssertEqual(try find(store).map(\.id), ["q"])
    }

    func testGroupsAndUnattributableChatsAreExcluded() throws {
        let chats = [
            Chat(id: 1, jid: "120363000000000001@g.us", name: "Example Group", isGroup: true),
            Chat(id: 2, name: "Unknown", person: "unknown"),
            Chat(id: 3, jid: "120363000000000002@newsletter", name: "Example Channel", person: "newsletter:120363000000000002"),
            Chat(id: 4, jid: "status@broadcast", name: "Status", person: "broadcast:status"),
            Chat(id: 5, jid: "867051314767696@bot", name: "Example Bot", person: "bot:867051314767696"),
            Chat(id: 6, jid: "", name: "", person: ""),
        ]
        let messages = chats.map { Msg(id: $0.id * 10, chat: $0.id, days: 5, uid: "q\($0.id)", text: "Anyone there?") }
        let store = try makeIndex(chats: chats, messages: messages)
        XCTAssertTrue(try find(store).isEmpty)
    }

    func testMergedPersonChatsAreEvaluatedSeparately() throws {
        // Same person and display name, two chats (e.g. a merged number): one answered, one not.
        let chats = [Chat(id: 1, jid: "15550001111@s.whatsapp.net", person: "5550001111"),
                     Chat(id: 2, jid: "15550002222@s.whatsapp.net", person: "5550001111")]
        let store = try makeIndex(chats: chats,
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: "q1", text: "Old number, still you?"),
                                             Msg(id: 20, chat: 2, days: 5, uid: "q2", text: "New number, dinner?"),
                                             Msg(id: 21, chat: 2, days: 4, uid: "a2", fromMe: true, text: "Yes")])
        let found = try find(store)
        XCTAssertEqual(found.map(\.id), ["q1"])
        XCTAssertEqual(found.first?.chatJID, "15550001111@s.whatsapp.net")
    }

    func testQuestionMarkersIncludingFullWidthAndArabic() throws {
        let chats = (1...3).map { Chat(id: Int64($0), jid: "1555000111\($0)@s.whatsapp.net") }
        let store = try makeIndex(chats: chats,
                                  messages: [Msg(id: 10, chat: 1, days: 4, uid: "ascii", text: "Ready?"),
                                             Msg(id: 20, chat: 2, days: 4, uid: "full", text: "准备好了吗？"),
                                             Msg(id: 30, chat: 3, days: 4, uid: "arabic", text: "هل أنت مستعد؟")])
        XCTAssertEqual(Set(try find(store).map(\.id)), ["ascii", "full", "arabic"])

        let statement = try makeIndex(chats: [Chat(id: 1)],
                                      messages: [Msg(id: 10, chat: 1, days: 4, uid: "plain", text: "I will send the file today")])
        XCTAssertTrue(try find(statement).isEmpty)
    }

    func testNewestQuestionFirstThenUID() throws {
        let chats = (1...4).map { Chat(id: Int64($0), jid: "1555000333\($0)@s.whatsapp.net") }
        let store = try makeIndex(chats: chats,
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: "b-tie", text: "One?"),
                                             Msg(id: 20, chat: 2, days: 9, uid: "oldest", text: "Two?"),
                                             Msg(id: 30, chat: 3, days: 5, uid: "a-tie", text: "Three?"),
                                             Msg(id: 40, chat: 4, days: 4, uid: "newest", text: "Four?")])
        XCTAssertEqual(try find(store).map(\.id), ["newest", "a-tie", "b-tie", "oldest"])
    }

    // MARK: - Recency window

    func testQuestionOlderThanTheDefaultWindowIsLeftOutButCounted() throws {
        // The complaint this rule fixes: an unanswered 2017 thread must not outrank today's.
        let chats = [Chat(id: 1),
                     Chat(id: 2, jid: "15550002222@s.whatsapp.net", name: "Recent Person", person: "5550002222")]
        let store = try makeIndex(chats: chats,
                                  messages: [Msg(id: 10, chat: 1, days: 3_000, uid: "ancient", text: "Still coming?"),
                                             Msg(id: 20, chat: 2, days: 10, uid: "recent", text: "Lunch today?")])
        let scan = try ReplyResponsibility.find(store: store, now: Self.now)
        XCTAssertEqual(scan.candidates.map(\.id), ["recent"])
        XCTAssertEqual(scan.beyondWindow, 1)
    }

    func testWindowIsAdjustableAndWideningItBringsOlderQuestionsBack() throws {
        // Roughly nine months: outside the six-month default, inside a year.
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 270, uid: "nine-months", text: "Still there?")])
        let narrow = try ReplyResponsibility.find(store: store, windowMonths: 6, now: Self.now)
        XCTAssertTrue(narrow.candidates.isEmpty)
        XCTAssertEqual(narrow.beyondWindow, 1)

        let wide = try ReplyResponsibility.find(store: store, windowMonths: 12, now: Self.now)
        XCTAssertEqual(wide.candidates.map(\.id), ["nine-months"])
        XCTAssertEqual(wide.beyondWindow, 0)
    }

    func testWindowCutoffIsCalendarMonthsAndInclusiveToTheMillisecond() throws {
        let start = ReplyResponsibility.windowStart(months: 6, now: Self.now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(calendar.dateComponents([.month], from: start, to: Self.now).month, 6)
        XCTAssertEqual(calendar.component(.day, from: start), calendar.component(.day, from: Self.now))

        func evidence(_ uid: String, _ ts: Int64) -> ReplyLatestEvidence {
            ReplyLatestEvidence(chatID: 1, chatJID: "15550001111@s.whatsapp.net", chatName: "Example",
                                person: "5550001111", isGroup: false, messageID: 1, uid: uid,
                                tsMS: ts, fromMe: false, text: "Still there?", mediaKind: nil)
        }
        let edge = Int64((start.timeIntervalSince1970 * 1000).rounded(.down))
        let inside = ReplyResponsibility.candidates([evidence("edge", edge)], quietDays: 1, windowMonths: 6, now: Self.now)
        XCTAssertEqual(inside.candidates.map(\.id), ["edge"], "the first instant of the window is inside it")
        XCTAssertEqual(inside.beyondWindow, 0)

        let outside = ReplyResponsibility.candidates([evidence("just-before", edge - 1)], quietDays: 1, windowMonths: 6, now: Self.now)
        XCTAssertTrue(outside.candidates.isEmpty)
        XCTAssertEqual(outside.beyondWindow, 1)
    }

    func testWindowIsClampedToTheSupportedRange() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 20, uid: "q", text: "Any update?")])
        // Zero months behaves as one, not as "no window at all".
        XCTAssertEqual(try find(store, quiet: 1, window: 0).map(\.id), ["q"])
        // A huge value behaves as the 60-month ceiling, not as all time.
        let ancient = try makeIndex(chats: [Chat(id: 1)],
                                    messages: [Msg(id: 10, chat: 1, days: 3_000, uid: "q", text: "Any update?")])
        let clamped = try ReplyResponsibility.find(store: ancient, quietDays: 1, windowMonths: 9_999, now: Self.now)
        XCTAssertTrue(clamped.candidates.isEmpty)
        XCTAssertEqual(clamped.beyondWindow, 1)
    }

    func testWindowDefaultsToSixMonths() {
        XCTAssertEqual(ReplyResponsibility.defaultWindowMonths, 6)
        XCTAssertEqual(ReplyResponsibility.windowMonthRange, 1...60)
        XCTAssertTrue(ReplyResponsibility.windowMonthOptions.contains(ReplyResponsibility.defaultWindowMonths))
        XCTAssertTrue(ReplyResponsibility.windowMonthOptions.allSatisfy(ReplyResponsibility.windowMonthRange.contains))
    }

    func testThresholdIsClampedToTheSupportedRange() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 1, uid: "q", text: "Any update?")])
        XCTAssertEqual(try find(store, quiet: 0).count, 1)              // treated as 1 day, not "no quiet time"
        XCTAssertTrue(try find(store, quiet: 99).isEmpty)               // treated as 30 days
        XCTAssertEqual(try find(store, quiet: -5).count, 1)
    }

    func testMessagesWithoutStableIdentityAreExcluded() throws {
        let store = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: nil, text: "Who is this?"),
                                             Msg(id: 11, chat: 1, days: 5, uid: "", text: "And this?")])
        XCTAssertTrue(try find(store).isEmpty)
    }

    func testEmptyChatsAndChatsWithNoMessagesAreExcluded() throws {
        let store = try makeIndex(chats: [Chat(id: 1), Chat(id: 2, jid: "15550004444@s.whatsapp.net", person: "5550004444")],
                                  messages: [Msg(id: 10, chat: 2, days: 5, uid: "q", text: "Hello?")])
        XCTAssertEqual(try find(store).map(\.source.chatID), [2])
    }

    func testPreviewIsOneLineAndClipped() throws {
        let long = "Could you check the plan for the trip?\n" + String(repeating: "More synthetic words ", count: 40)
        let store = try makeIndex(chats: [Chat(id: 1)], messages: [Msg(id: 10, chat: 1, days: 4, uid: "q", text: long)])
        let preview = try XCTUnwrap(try find(store).first?.preview)
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertLessThanOrEqual(preview.count, ReplyResponsibility.previewLength + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    // MARK: - Library rebuilds

    func testRebuildKeepsTheCandidateAndResolvesToCurrentRowIDs() throws {
        let first = try makeIndex(chats: [Chat(id: 1)],
                                  messages: [Msg(id: 10, chat: 1, days: 5, uid: "stable-uid", text: "Still coming?")])
        let original = try find(first)
        XCTAssertEqual(original.map(\.id), ["stable-uid"])

        // A rebuild renumbers chats and messages; nothing about the candidate's identity changes.
        let rebuilt = try makeIndex(chats: [Chat(id: 700, jid: "15550001111@s.whatsapp.net", person: "5550001111")],
                                    messages: [Msg(id: 4000, chat: 700, days: 5, uid: "stable-uid", text: "Still coming?")])
        let again = try find(rebuilt)
        XCTAssertEqual(again.map(\.id), ["stable-uid"])
        XCTAssertEqual(again.first?.source.messageID, 4000)

        let resolved = try XCTUnwrap(rebuilt.resolve(uids: ["stable-uid"])["stable-uid"])
        XCTAssertEqual(resolved.id, 4000)
        XCTAssertEqual(resolved.chatID, 700)
        XCTAssertNil(rebuilt.resolve(uids: ["gone-uid"])["gone-uid"])
    }

    // MARK: - Pure rule seam (no database)

    func testPureEvaluationRejectsNonDirectAndUnknownChats() {
        let base = ReplyLatestEvidence(chatID: 1, chatJID: "15550001111@s.whatsapp.net", chatName: "Example",
                                       person: "5550001111", isGroup: false, messageID: 1, uid: "u",
                                       tsMS: ms(days: 5), fromMe: false, text: "Still there?", mediaKind: nil)
        XCTAssertNotNil(ReplyResponsibility.evaluate(base, quietDays: 3, now: Self.now))
        XCTAssertNil(ReplyResponsibility.evaluate(base, quietDays: 3, now: Self.now.addingTimeInterval(-7 * 86_400)))
        let group = ReplyLatestEvidence(chatID: 1, chatJID: "1@g.us", chatName: "G", person: "unknown",
                                        isGroup: true, messageID: 1, uid: "u", tsMS: base.tsMS,
                                        fromMe: false, text: "Still there?", mediaKind: nil)
        XCTAssertNil(ReplyResponsibility.evaluate(group, quietDays: 3, now: Self.now))
    }

    // MARK: - 100k-message scan

    func testHundredThousandMessageScan() throws {
        let chats = (1...200).map { Chat(id: Int64($0), jid: "1555000\(String(format: "%04d", $0))@s.whatsapp.net", person: "55500\(String(format: "%04d", $0))") }
        var messages: [Msg] = []
        var id: Int64 = 1
        for c in chats {
            for i in 0..<500 {
                // Every fourth chat's last word is an unanswered question from them.
                let question = (c.id % 4 == 0 || c.id % 4 == 1) && i == 499
                messages.append(Msg(id: id, chat: c.id, days: 90 - Double(i) / 6, uid: "u\(id)",
                                    fromMe: !question, text: question ? "Any update on this?" : "Synthetic chatter \(i)"))
                id += 1
            }
        }
        let store = try makeIndex(chats: chats, messages: messages)
        let t0 = Date()
        let found = try find(store, quiet: 1)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(found.count, 100)
        XCTAssertEqual(found.count, found.map(\.id).count)
        print("REPLIES-BENCH messages=100000 chats=200 candidates=\(found.count) elapsed_s=\(String(format: "%.3f", elapsed)) throughput_msg_per_s=\(Int(100_000 / max(elapsed, 0.001)))")
    }
}
