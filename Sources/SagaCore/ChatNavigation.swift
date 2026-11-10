import Foundation

/// What the conversation pane is showing for the chat that is open.
///
/// The pane is not just a message list: it holds the media the chat shared and its Heartbeat
/// story. The mode belongs to *one conversation* — see `ChatNavigation`, which owns the rule.
public enum ChatMode: String, CaseIterable, Identifiable, Sendable {
    case messages = "Messages"
    case media = "Media"
    case wrapped = "Heartbeat"
    public var id: String { rawValue }
}

/// Where the reader was before a jump. Search and Wrapped hand the window a destination that is
/// not a conversation, so a return has to restore a place as well as a chat.
public enum OriginPlace: String, CaseIterable, Sendable {
    case conversation, search, insights
}

/// A place in the archive the reader can come back to: the chat, the message (or the point in
/// the transcript) they were at, the pane they were in and the date to fall back on when the
/// message itself is gone.
public struct ChatOrigin: Equatable, Sendable {
    public var place: OriginPlace
    public var chatID: Int64?
    /// The anchor: the message the reader was looking at, usually the newest loaded one.
    public var messageID: Int64?
    /// That anchor's timestamp, so a pruned message can still reopen the conversation at the
    /// same point in time instead of dropping the reader at the bottom.
    public var date: Date
    public var mode: ChatMode

    public init(place: OriginPlace, chatID: Int64? = nil, messageID: Int64? = nil,
                date: Date = .distantPast, mode: ChatMode = .messages) {
        self.place = place
        self.chatID = chatID
        self.messageID = messageID
        self.date = date
        self.mode = mode
    }
}

/// What pressing the return affordance does. Resolved against the archive first, so a stale
/// origin lands somewhere honest instead of doing nothing.
public enum ChatReturn: Equatable, Sendable {
    /// The chat and the anchor message are both still here.
    case message(chatID: Int64, messageID: Int64, mode: ChatMode)
    /// The chat is here, the message is not: open it at the same date.
    case date(chatID: Int64, date: Date, mode: ChatMode)
    /// The origin was the archive search's result list.
    case search
    /// The origin was the Wrapped story on Insights.
    case insights
    /// The conversation the reader came from is not in the archive any more.
    case gone
}

/// The conversation pane's navigation state: which chat is open, which mode it is showing, and
/// where the reader came from when a jump took them somewhere else.
///
/// Two rules live here, and they are deliberately boring:
///
/// 1. **A different conversation always opens on Messages.** The mode is a property of the chat
///    you are reading, not a setting the window carries around. Landing on chat B and finding
///    chat A's Heartbeat in the pane reads as a broken tab, and the owner reported exactly that
///    ("if I'm on a Heartbeat page on a message, and I hop into another chat, it stays on the
///    heartbeat").
/// 2. **The mode is kept for the chat that is still open.** Re-selecting the same conversation,
///    changing its filter, or finding inside it never throws the mode away silently.
public struct ChatNavigation: Equatable, Sendable {
    public private(set) var chatID: Int64?
    public private(set) var mode: ChatMode
    public private(set) var origin: ChatOrigin?

    public init(chatID: Int64? = nil, mode: ChatMode = .messages, origin: ChatOrigin? = nil) {
        self.chatID = chatID
        self.mode = mode
        self.origin = origin
    }

    /// True while the pane should offer "Back to where you were".
    public var canReturn: Bool { origin != nil }

    /// Select a conversation. A *different* chat resets the mode to Messages and returns it to a
    /// fresh state; the same chat is a no-op and keeps both its mode and its origin.
    @discardableResult
    public mutating func select(_ newChatID: Int64?) -> ChatMode {
        guard newChatID != chatID else { return mode }
        chatID = newChatID
        mode = .messages
        return mode
    }

    /// The reader chose a mode inside the open conversation: it stays for that conversation.
    public mutating func setMode(_ newMode: ChatMode) { mode = newMode }

    /// Remember where the reader was, on the way to `target`. A jump that stays inside the same
    /// conversation, in the same pane, has nowhere to go back to and clears any older origin, so
    /// a stale bar can never outlive the jump it belonged to.
    @discardableResult
    public mutating func remember(_ candidate: ChatOrigin, jumpingTo target: Int64) -> Bool {
        guard isReturnable(candidate, jumpingTo: target) else { origin = nil; return false }
        origin = candidate
        return true
    }

    /// Whether `candidate` describes a place other than the one the jump lands on.
    public func isReturnable(_ candidate: ChatOrigin, jumpingTo target: Int64) -> Bool {
        switch candidate.place {
        case .search, .insights:
            // A different place entirely: always worth coming back to.
            return true
        case .conversation:
            if let from = candidate.chatID, from != target { return true }
            // Same chat: only a different pane is a place to come back to. A jump between two
            // messages of one chat is a scroll, not a journey.
            return candidate.mode != .messages
        }
    }

    /// Dismissing the bar. The origin is gone for good; nothing can resurrect it later.
    public mutating func dismissOrigin() { origin = nil }

    /// The plan for the return button, resolved against what the archive still holds.
    /// - Parameters:
    ///   - chatExists: whether the origin conversation is still in the index.
    ///   - anchorExists: whether the origin message still resolves in that conversation.
    public func returnPlan(chatExists: Bool = true, anchorExists: Bool = true) -> ChatReturn? {
        guard let origin else { return nil }
        switch origin.place {
        case .search:
            return .search
        case .insights:
            return .insights
        case .conversation:
            guard let chatID = origin.chatID, chatExists else { return .gone }
            if let messageID = origin.messageID, anchorExists {
                return .message(chatID: chatID, messageID: messageID, mode: origin.mode)
            }
            // The message was pruned or renumbered: the conversation at the same date is the
            // closest thing to the place the reader left.
            return .date(chatID: chatID, date: origin.date, mode: origin.mode)
        }
    }

    /// The plan, and the origin consumed: a return happens once.
    public mutating func takeReturnPlan(chatExists: Bool = true, anchorExists: Bool = true) -> ChatReturn? {
        let plan = returnPlan(chatExists: chatExists, anchorExists: anchorExists)
        if plan != nil { origin = nil }
        return plan
    }
}
