import Foundation
import Testing
@testable import SagaCore

/// The conversation draws one chip per emoji under a bubble, and a page of bubbles must be
/// filled by a single query. These pin the read-side aggregation: counts, several emoji on one
/// message, many people on one emoji, a message nobody reacted to, the owner, and a reactor the
/// archive cannot name. The fixtures are synthetic indices written with the real schema, never
/// the owner's archive.
@Suite struct ReactionChipTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("saga-reaction-chips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A store over a hand-written index: `reactions` rows are given as
    /// `(message, sender, name, emoji, ts)` so every case can be stated exactly.
    func store(_ dir: URL, messages: Int = 3,
               reactions: [(message: Int64, sender: String, name: String, emoji: String, ts: Int64)] = []) throws -> VaultStore {
        let path = dir.appendingPathComponent("vault_index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec(Importer.schema)
        try db.exec("INSERT INTO chats VALUES (1,'demo-group@g.us',1,'Quiz club',1,'');")
        for i in 1...max(1, messages) {
            try db.exec("INSERT INTO messages VALUES (\(i),1,\(i % 2),'Sender \(i)','55500000\(i)',\(1_700_000_000_000 + Int64(i) * 60_000),0,'message \(i)','u\(i)');")
        }
        for r in reactions {
            try db.exec("""
                INSERT INTO reactions(message_id, chat_id, sender, sender_name, emoji, ts)
                VALUES (\(r.message),1,'\(r.sender)','\(r.name)','\(r.emoji)',\(r.ts));
                """)
        }
        return try VaultStore(path: path)
    }

    // MARK: - The four shapes the conversation has to draw

    @Test func oneEmojiFromOnePersonIsOneChip() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir, reactions: [(1, "5550000002", "Asha", "😂", 100)])
        let chips = s.reactions(for: [1, 2, 3])
        #expect(chips.count == 1)
        #expect(chips[1]?.tallies.count == 1)
        #expect(chips[1]?.tallies.first?.emoji == "😂")
        #expect(chips[1]?.tallies.first?.count == 1)
        #expect(chips[1]?.tallies.first?.names == ["Asha"])
        #expect(chips[1]?.total == 1)
    }

    @Test func severalEmojiOnOneMessageKeepTheOrderPeopleReacted() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir, reactions: [
            (1, "5550000003", "Ben", "❤️", 100),
            (1, "5550000002", "Asha", "😂", 110),
            (1, "me", "me", "❤️", 120),
        ])
        let chips = s.reactions(for: [1])[1]
        // CI's type-checker gives up on a key path inside #expect, so the arrays are drawn first.
        let chipEmoji = chips?.tallies.map { $0.emoji }
        let chipCounts = chips?.tallies.map { $0.count }
        #expect(chipEmoji == ["❤️", "😂"])                        // first arrival, not biggest first
        #expect(chipCounts == [2, 1])
        #expect(chips?.tallies.first?.names == ["Ben", "You"])    // the owner is never "me"
        #expect(chips?.total == 3)
    }

    @Test func manyPeopleOnOneEmojiAreACountNotAFanOfChips() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["Asha", "Ben", "Chitra", "Dev", "Esha", "Farah", "Gita"]
        let s = try store(dir, reactions: names.enumerated().map {
            (Int64(1), "55500000\(10 + $0.offset)", $0.element, "🔥", Int64(100 + $0.offset))
        } + [(1, "me", "me", "🔥", 200)])
        let tally = try #require(s.reactions(for: [1])[1]?.tallies.first)
        #expect(tally.count == 8)                                  // one chip, eight people
        #expect(tally.names.count == 8)
        #expect(tally.names.last == "You")
        #expect(tally.namesLabel == "Asha, Ben, Chitra, Dev, Esha, Farah, Gita, You")
    }

    @Test func aMessageWithNoReactionsDrawsNothing() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir, reactions: [(2, "5550000002", "Asha", "❤️", 100)])
        let chips = s.reactions(for: [1, 2, 3])
        #expect(chips[1] == nil)                                   // absent, not an empty summary
        #expect(chips[3] == nil)
        #expect(chips[2]?.isEmpty == false)
    }

    @Test func idsOutsideThePageAreNotReturned() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir, messages: 5, reactions: [
            (1, "5550000002", "Asha", "😂", 100),
            (4, "5550000003", "Ben", "👍", 100),
        ])
        let chips = s.reactions(for: [1, 2, 3])
        #expect(Set(chips.keys) == [1])                            // 4 was not asked about
    }

    // MARK: - Naming

    @Test func aReactorTheArchiveCannotNameIsStillCredited() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir, messages: 2, reactions: [
            // A `jid` row the backup no longer carries: the importer records Unknown.
            (1, "unknown", "Unknown", "😂", 100),
            // A `lid:` identity whose phone number is unknown: four digits is all there is.
            (2, "lid:447100009999", "Unknown", "❤️", 100),
        ])
        let chips = s.reactions(for: [1, 2])
        #expect(chips[1]?.tallies.first?.names == ["Unnamed sender"])
        #expect(chips[2]?.tallies.first?.names == ["Number ending 9999"])
        for summary in chips.values {
            #expect(summary.tallies.allSatisfy { $0.names.allSatisfy { $0.lowercased() != "unknown" } })
        }
    }

    @Test func aLongListOfNamesIsClippedButStillCountsTheRest() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try store(dir, reactions: (1...12).map {
            (Int64(1), "55500000\(20 + $0)", "Person \($0)", "😂", Int64(100 + $0))
        })
        let tally = try #require(s.reactions(for: [1])[1]?.tallies.first)
        #expect(tally.count == 12)
        #expect(tally.namesLabel.hasSuffix("and 4 more"))
    }

    // MARK: - Rows the index can hold twice

    /// WhatsApp replaces a reaction: the old row can survive in an index built by an earlier
    /// importer. One person is still one count, and the newest emoji is the one shown.
    @Test func aChangedReactionCountsOnceAtItsNewestEmoji() throws {
        let rows = [
            MessageReaction(messageID: 1, chatID: 1, sender: "5550000002", senderName: "Asha", emoji: "😂", ts: 100),
            MessageReaction(messageID: 1, chatID: 1, sender: "5550000002", senderName: "Asha", emoji: "❤️", ts: 200),
        ]
        let summary = MessageReactionSummary.build(rows)
        #expect(summary.total == 1)
        #expect(summary.tallies.map { $0.emoji } == ["❤️"])
    }

    @Test func anEmptyEmojiRowDrawsNoChip() throws {
        let rows = [MessageReaction(messageID: 1, chatID: 1, sender: "me", senderName: "me", emoji: "  ", ts: 1)]
        #expect(MessageReactionSummary.build(rows).isEmpty)
    }

    // MARK: - A whole page, and a whole conversation, in one call

    @Test func aPageOfNineHundredMessagesIsAnsweredInOneCall() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Every seventh message was reacted to: 128 of 900, the shape a real chat has.
        // Built with a loop rather than flatMap + tuple literals: the CI toolchain times out
        // type-checking the closure form.
        var reactions: [(Int64, String, String, String, Int64)] = []
        for m in stride(from: 1, through: 900, by: 7) {
            let id = Int64(m)
            reactions.append((id, "5550000002", "Asha", "😂", Int64(1000 + m)))
            reactions.append((id, "me", "me", "❤️", Int64(1001 + m)))
        }
        let s = try store(dir, messages: 900, reactions: reactions)
        let summary = s.reactions(for: (1...900).map(Int64.init))
        #expect(summary.count == 129)                              // ids 1,8,…,897 → 129 messages
        #expect(summary.values.allSatisfy { $0.total == 2 })
        let emojiOnEight = summary[8]?.tallies.map { $0.emoji }
        #expect(emojiOnEight == ["😂", "❤️"])
        // Asking for a page that has nothing is empty rather than an error.
        #expect(s.reactions(for: (901...950).map(Int64.init)).isEmpty)
    }

    @Test func anIndexFromBeforeReactionsDrawsNoChipsInsteadOfFailing() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("old_index.db").path
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.exec("""
            CREATE TABLE chats(chat_id INTEGER PRIMARY KEY, jid TEXT, is_group INT, name TEXT, resolved INT, person TEXT);
            CREATE TABLE messages(id INTEGER PRIMARY KEY, chat_id INT, from_me INT, sender TEXT, person TEXT, ts INT, type INT, text TEXT, uid TEXT);
            INSERT INTO chats VALUES (1,'a@g.us',0,'Asha',1,'5550000002');
            INSERT INTO messages VALUES (1,1,0,'Asha','5550000002',1700000000000,0,'hi','u1');
            """)
        let s = try VaultStore(path: path)
        #expect(s.hasReactions == false)
        #expect(s.reactions(for: [1]).isEmpty)
    }

    /// An import lands reactions after the messages, and the app re-opens the index when an
    /// update finishes (`open(path:)` drops its chip cache and asks again). This pins what that
    /// rests on: a store opened over the new index answers with the new counts.
    @Test func aStoreOpenedAfterAnImportSeesTheNewReactions() throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store(dir, reactions: [(1, "5550000002", "Asha", "😂", 100)])
        #expect(first.reactions(for: [1])[1]?.total == 1)

        // The pull adds a second reactor to the same message; the app then reopens the file.
        let path = dir.appendingPathComponent("vault_index.db").path
        let writer = try SQLiteDB(path: path, readOnly: false)
        try writer.exec("INSERT INTO reactions VALUES (1,1,'me','me','❤️',200);")

        let second = try VaultStore(path: path)
        #expect(second.reactions(for: [1])[1]?.total == 2)
        let afterPull = second.reactions(for: [1])[1]?.tallies.map { $0.emoji }
        #expect(afterPull == ["😂", "❤️"])
    }
}
