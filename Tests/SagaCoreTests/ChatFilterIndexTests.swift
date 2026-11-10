import XCTest
@testable import SagaCore

/// The Gallery's conversation filter replaced a menu that listed every chat in the archive.
/// These tests pin what a reader can type and what comes back: names, numbers, a handful of
/// rows, and an empty result for an empty field ("All conversations").
final class ChatFilterIndexTests: XCTestCase {
    private func index() -> ChatFilterIndex {
        ChatFilterIndex([
            .init(id: 1, name: "Alpha Group", jid: "11111@g.us"),
            .init(id: 2, name: "Alpha", jid: "22222@s.whatsapp.net"),
            .init(id: 3, name: "Beta Team", jid: "33333@g.us"),
            .init(id: 4, name: "Gamma", jid: "15550001@s.whatsapp.net"),
            .init(id: 5, name: "Delta Society", jid: "15550002@s.whatsapp.net"),
            .init(id: 6, name: "José Alvarez", jid: "15550003@s.whatsapp.net"),
            .init(id: 7, name: "Alpha Beta", jid: "44444@g.us"),
        ])
    }

    func testEmptyQueryIsAllConversations() {
        XCTAssertTrue(index().matches("").isEmpty)
        XCTAssertTrue(index().matches("   ").isEmpty)
    }

    func testNameMatchesRankAnExactNameFirst() {
        let hits = index().matches("Alpha")
        XCTAssertEqual(hits.map(\.id).first, 2, "the exact name beats the two names it prefixes")
        XCTAssertEqual(hits.count, 3)
    }

    func testPrefixAndWordPrefixBothMatch() {
        XCTAssertEqual(index().matches("gam").map(\.id), [4])
        XCTAssertEqual(index().matches("team").map(\.id), [3], "a word inside a name is a match")
    }

    func testNumbersMatchWithOrWithoutSpaces() {
        XCTAssertEqual(index().matches("15550001").map(\.id), [4])
        XCTAssertEqual(index().matches("+1 555 0002").map(\.id), [5])
        XCTAssertEqual(index().matches("0003").map(\.id), [6], "a trailing run of digits is enough")
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertEqual(index().matches("jose").map(\.id), [6])
        XCTAssertEqual(index().matches("JOSÉ").map(\.id), [6])
    }

    func testNoMatchReturnsNothingRatherThanEverything() {
        XCTAssertTrue(index().matches("zzzz").isEmpty)
    }

    func testResultsAreCappedAtEight() {
        let many = ChatFilterIndex((1...9_700).map { .init(id: Int64($0), name: "Chat \($0)", jid: "\($0)@s.whatsapp.net") })
        let hits = many.matches("chat", limit: 8)
        XCTAssertEqual(hits.count, 8)
        XCTAssertEqual(many.matches("chat", limit: 3).count, 3)
        XCTAssertEqual(many.count, 9_700)
    }

    func testASingleRowLibraryStillSearches() {
        let one = ChatFilterIndex([.init(id: 42, name: "Only Chat", jid: "")])
        XCTAssertEqual(one.matches("only").map(\.id), [42])
        XCTAssertEqual(one.name(for: 42), "Only Chat")
        XCTAssertNil(one.name(for: 9))
    }

    func testDigitsInTheNameAreSearchable() {
        let named = ChatFilterIndex([.init(id: 8, name: "Flat 4B", jid: "")])
        XCTAssertEqual(named.matches("4b").map(\.id), [8])
    }
}
