import XCTest
@testable import SagaCore

/// Two navigation bugs the owner reported, pinned as rules so they cannot come back.
///
/// 1. "If I'm on a Heartbeat page on a message, and I hop into another chat, it stays on the
///    heartbeat. Have to manually click Messages tab again." — the pane's mode must belong to
///    the conversation it was chosen in.
/// 2. "jumping to a message from wrapped, leads me to the correct message, but doesn't let me
///    revert back to the current place in chat." — a jump must remember where the reader was,
///    and there must be a deterministic way back, including when the origin is partly gone.
final class ChatNavigationTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_735_689_600)

    // MARK: - The mode rule

    func testSwitchingConversationsResetsTheModeToMessages() {
        var nav = ChatNavigation()
        nav.select(6)
        nav.setMode(.wrapped)                       // the reader opens chat 6's Heartbeat
        XCTAssertEqual(nav.mode, .wrapped)

        nav.select(10)                              // ...then hops into another chat
        XCTAssertEqual(nav.mode, .messages, "a new conversation must open on Messages, never on the previous chat's Heartbeat")
        XCTAssertEqual(nav.chatID, 10)
    }

    func testSwitchingConversationsResetsMediaModeToo() {
        var nav = ChatNavigation()
        nav.select(6)
        nav.setMode(.media)
        nav.select(10)
        XCTAssertEqual(nav.mode, .messages, "the media pane belongs to chat 6; chat 10 opens on its messages")
    }

    func testTheModeIsNotDiscardedWithinTheSameConversation() {
        var nav = ChatNavigation()
        nav.select(6)
        nav.setMode(.wrapped)

        // Re-selecting the open chat is what a list refresh or a re-open does: it is not a switch.
        nav.select(6)
        XCTAssertEqual(nav.mode, .wrapped, "re-selecting the same chat must not throw its mode away")

        nav.setMode(.media)
        nav.select(6)
        XCTAssertEqual(nav.mode, .media)
    }

    func testComingBackToAChatLaterStartsOnMessages() {
        // Deterministic by design: the mode is not remembered per chat across a visit, because a
        // chat reopened days later landing on Heartbeat is the surprise the owner complained about.
        var nav = ChatNavigation()
        nav.select(6); nav.setMode(.wrapped)
        nav.select(10)
        nav.select(6)
        XCTAssertEqual(nav.mode, .messages)
    }

    func testSelectingNoConversationResetsTheMode() {
        var nav = ChatNavigation()
        nav.select(6); nav.setMode(.media)
        nav.select(nil)
        XCTAssertEqual(nav.mode, .messages)
        XCTAssertNil(nav.chatID)
    }

    // MARK: - The way back

    func testAJumpFromAnotherChatRemembersTheOrigin() {
        var nav = ChatNavigation()
        nav.select(6)
        nav.setMode(.messages)
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t, mode: .messages)

        nav.select(10)                              // the jump lands here
        XCTAssertTrue(nav.remember(origin, jumpingTo: 10))
        XCTAssertEqual(nav.origin, origin)
        XCTAssertTrue(nav.canReturn)
    }

    func testAJumpFromWrappedRemembersTheStoryAsTheOrigin() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .insights, date: t, mode: .messages)
        XCTAssertTrue(nav.remember(origin, jumpingTo: 10), "a jump out of the Wrapped story is always returnable")
        XCTAssertEqual(nav.origin?.place, .insights)
    }

    func testAJumpFromSearchRemembersTheResultList() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .search, chatID: 6, messageID: 402, date: t, mode: .messages)
        XCTAssertTrue(nav.remember(origin, jumpingTo: 10))
        XCTAssertEqual(nav.origin?.place, .search)
    }

    func testAJumpThatStaysInTheSameChatIsNotAJourney() {
        var nav = ChatNavigation()
        nav.select(6)
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t, mode: .messages)
        XCTAssertFalse(nav.remember(origin, jumpingTo: 6),
                       "stepping between two messages of one chat is a scroll — no bar")
        XCTAssertFalse(nav.canReturn)
    }

    func testAReturnRestoresTheChatAndTheAnchor() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t, mode: .messages)
        nav.remember(origin, jumpingTo: 10)
        nav.select(10)

        XCTAssertEqual(nav.takeReturnPlan(chatExists: true, anchorExists: true),
                       .message(chatID: 6, messageID: 402, mode: .messages))
        XCTAssertFalse(nav.canReturn, "a return happens once; the bar must not survive it")
    }

    func testAReturnRestoresThePaneTheReaderWasIn() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t, mode: .wrapped)
        nav.remember(origin, jumpingTo: 10)
        XCTAssertEqual(nav.takeReturnPlan(chatExists: true, anchorExists: true),
                       .message(chatID: 6, messageID: 402, mode: .wrapped),
                       "the pane the reader left is part of the place they came from")
    }

    func testAReturnWithNoAnchorMessageOpensTheConversationAtTheDate() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: nil, date: t, mode: .messages)
        nav.remember(origin, jumpingTo: 10)
        XCTAssertEqual(nav.takeReturnPlan(chatExists: true, anchorExists: false),
                       .date(chatID: 6, date: t, mode: .messages))
    }

    func testAReturnFallsBackToTheDateWhenTheAnchorMessageIsGone() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t, mode: .messages)
        nav.remember(origin, jumpingTo: 10)

        // The message was pruned or renumbered by a rebuild; the conversation is still here.
        XCTAssertEqual(nav.takeReturnPlan(chatExists: true, anchorExists: false),
                       .date(chatID: 6, date: t, mode: .messages),
                       "a pruned anchor must reopen the conversation at the same point, not drop the reader at the bottom")
    }

    func testAReturnToAVanishedChatSaysSoInsteadOfDoingNothing() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t, mode: .messages)
        nav.remember(origin, jumpingTo: 10)
        XCTAssertEqual(nav.takeReturnPlan(chatExists: false, anchorExists: false), .gone)
        XCTAssertFalse(nav.canReturn)
    }

    func testDismissingTheOriginClearsIt() {
        var nav = ChatNavigation()
        let origin = ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t, mode: .messages)
        nav.remember(origin, jumpingTo: 10)
        XCTAssertTrue(nav.canReturn)

        nav.dismissOrigin()
        XCTAssertFalse(nav.canReturn)
        XCTAssertNil(nav.takeReturnPlan(chatExists: true, anchorExists: true),
                     "a dismissed origin must never resurrect later")
    }

    func testASecondJumpReplacesTheOriginRatherThanStacking() {
        var nav = ChatNavigation()
        nav.remember(ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t), jumpingTo: 10)
        nav.remember(ChatOrigin(place: .conversation, chatID: 10, messageID: 900, date: t), jumpingTo: 11)
        XCTAssertEqual(nav.origin?.chatID, 10, "the bar is about the jump you just took, not a breadcrumb stack")
    }

    func testAJumpWithNowhereToReturnToClearsAnOlderOrigin() {
        var nav = ChatNavigation()
        nav.remember(ChatOrigin(place: .conversation, chatID: 6, messageID: 402, date: t), jumpingTo: 10)
        nav.remember(ChatOrigin(place: .conversation, chatID: 10, messageID: 900, date: t), jumpingTo: 10)
        XCTAssertNil(nav.origin)
    }
}
