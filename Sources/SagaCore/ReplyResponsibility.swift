import Foundation

/// One archived chat's last word: the only evidence this feature needs.
///
/// Built by `VaultStore.replyLatestEvidence()` from the visible index, so pruning and
/// contact merges already apply. Internal and plain: the rule can be exercised from
/// tests without a database.
struct ReplyLatestEvidence: Sendable, Equatable {
    let chatID: Int64
    /// The chat's JID — what a rebuilt index keeps, unlike row ids.
    let chatJID: String
    let chatName: String
    /// The index's participant key (`1234567890`, `lid:…`), never a display name.
    let person: String
    let isGroup: Bool
    let messageID: Int64
    let uid: String
    /// Milliseconds since 1970, as the index stores timestamps.
    let tsMS: Int64
    let fromMe: Bool
    /// Message text, or the media caption when the text is empty.
    let text: String
    let mediaKind: String?
}

/// A question in a one-to-one chat that may still need an answer.
///
/// `id` is the question's stable `uid`, so the list survives a library rebuild.
/// `source` carries row and chat ids from the session that produced it: resolve the
/// UID against the current index (`VaultStore.resolve(uids:)`) before jumping.
public struct ReplyCandidate: Identifiable, Sendable, Hashable {
    /// The question message's UID.
    public let id: String
    /// The chat's JID: stable across rebuilds, unlike `source.chatID`.
    public let chatJID: String
    /// Display label for this run only — the participant's name as the index knows it.
    public let chatName: String
    public let source: MessageRef
    /// When the question was sent, from the archive's timestamps.
    public let questionDate: Date
    /// Whole 24-hour days between the question and `now`.
    public let quietDays: Int
    /// One line of the question itself, for the sheet. Never persisted or logged.
    public let preview: String

    public init(id: String, chatJID: String, chatName: String, source: MessageRef, questionDate: Date, quietDays: Int, preview: String) {
        self.id = id
        self.chatJID = chatJID
        self.chatName = chatName
        self.source = source
        self.questionDate = questionDate
        self.quietDays = quietDays
        self.preview = preview
    }
}

/// One scan's answer: the questions still worth showing, and how many real-but-stale
/// questions the window left out. Counting the second number is what lets the sheet
/// explain its rule instead of silently hiding history.
public struct ReplyScan: Sendable, Equatable {
    public let candidates: [ReplyCandidate]
    /// Start of the recency window, inclusive, as an absolute instant.
    public let windowStart: Date
    /// Unanswered questions older than the window. Counted, never listed.
    public let beyondWindow: Int

    public init(candidates: [ReplyCandidate], windowStart: Date, beyondWindow: Int) {
        self.candidates = candidates
        self.windowStart = windowStart
        self.beyondWindow = beyondWindow
    }
}

/// "Might need your reply": a deterministic reading of who is waiting on an answer.
///
/// The rule, in order, for a visible one-to-one chat:
/// 1. the chat's latest *substantive* message came from the other person (not me);
/// 2. it contains an explicit question marker (`?`, `？`, `؟`);
/// 3. at least `quietDays` whole 24-hour days have passed since it, measured against an
///    injected `now` — archived timestamps in the future never qualify;
/// 4. it was asked inside the recency window (default 6 months). Older unanswered
///    questions are counted and dropped.
///
/// Step 4 is the answer to "what does an owed reply mean once the chat has gone quiet?":
/// silence only counts as an open question while the thread is still recent. Past the
/// window, the conversation is history, not an obligation, so the sheet stops asking.
/// The window is the person's to widen; nothing is ever claimed about the other side.
///
/// There is nothing to infer: no model, no sentiment, no score, no "they owe you". The
/// rule is asymmetric on purpose — it only ever asks whether *I* might owe a reply.
/// Group chats, channels and chats whose participant the index cannot name are skipped
/// rather than guessed at.
public enum ReplyResponsibility {
    /// Days of quiet before a question is worth showing. The sheet lets the person change it.
    public static let defaultQuietDays = 3
    /// Bounds for the adjustable threshold, so the UI cannot ask for 0 or 10 years.
    public static let quietDayRange = 1...30
    /// How far back a question can be asked and still count. Default: half a year.
    public static let defaultWindowMonths = 6
    /// Bounds for the adjustable window, so a stray value cannot scan from 1970.
    public static let windowMonthRange = 1...60
    /// The choices the sheet offers, in calendar months.
    public static let windowMonthOptions = [1, 3, 6, 12, 24]

    /// Explicit question marks, including the full-width and Arabic marks WhatsApp carries.
    static let questionMarkers: [Character] = ["?", "？", "؟"]
    /// Longest question preview shown in the sheet.
    static let previewLength = 140

    /// Candidates across every visible one-to-one chat, newest unanswered question first,
    /// limited to questions asked inside `windowMonths` of `now`.
    ///
    /// Cheap enough to recompute on every Scan: one batched statement reads a single row
    /// per chat (see `VaultStore.replyLatestEvidence()`), never the archive's history.
    public static func find(store: VaultStore, quietDays: Int = defaultQuietDays,
                            windowMonths: Int = defaultWindowMonths, now: Date = Date()) throws -> ReplyScan {
        let days = min(max(quietDays, quietDayRange.lowerBound), quietDayRange.upperBound)
        let months = min(max(windowMonths, windowMonthRange.lowerBound), windowMonthRange.upperBound)
        return candidates(try store.replyLatestEvidence(), quietDays: days, windowMonths: months, now: now)
    }

    /// Splits the unanswered questions into "still open" and "older than the window".
    /// Sorting is newest first so today's question outranks a stale one; UID breaks ties
    /// so two scans of the same archive always produce the same order.
    static func candidates(_ evidence: [ReplyLatestEvidence], quietDays: Int,
                           windowMonths: Int = defaultWindowMonths, now: Date) -> ReplyScan {
        let start = windowStart(months: windowMonths, now: now)
        var kept: [ReplyCandidate] = []
        var older = 0
        for item in evidence {
            guard let candidate = evaluate(item, quietDays: quietDays, now: now) else { continue }
            if candidate.questionDate >= start { kept.append(candidate) } else { older += 1 }
        }
        kept.sort { a, b in
            if a.questionDate != b.questionDate { return a.questionDate > b.questionDate }
            return a.id < b.id
        }
        return ReplyScan(candidates: kept, windowStart: start, beyondWindow: older)
    }

    /// First instant inside the window: the same calendar day, `months` months back.
    ///
    /// Calendar arithmetic (not 30-day months) so "last 6 months" means what a person
    /// means by it. Fixed to UTC so the cut-off does not shift with the machine's zone
    /// between a scan and the explanation next to it.
    public static func windowStart(months: Int, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar.date(byAdding: .month, value: -max(months, 1), to: now)
            ?? now.addingTimeInterval(-Double(max(months, 1)) * 30 * 86_400)
    }

    /// Applies the rule to one chat's latest substantive message. Returns `nil` for every
    /// conversation shape the feature must not assign responsibility to.
    static func evaluate(_ evidence: ReplyLatestEvidence, quietDays: Int, now: Date) -> ReplyCandidate? {
        let days = max(quietDays, 1)
        guard isDirectChat(evidence) else { return nil }
        guard !evidence.uid.isEmpty else { return nil }                 // no stable identity: cannot hold or resolve it
        guard !evidence.fromMe else { return nil }                     // I had the last word
        guard isSubstantive(evidence.text, mediaKind: evidence.mediaKind) else { return nil }
        guard containsQuestion(evidence.text) else { return nil }      // their last word was not a question
        let asked = Date(timeIntervalSince1970: Double(evidence.tsMS) / 1000)
        let quiet = now.timeIntervalSince(asked)
        guard quiet >= 0 else { return nil }                           // a future timestamp is not quiet time
        let elapsed = Int(quiet / 86_400)                              // whole elapsed 24-hour days
        guard elapsed >= days else { return nil }
        return ReplyCandidate(id: evidence.uid, chatJID: evidence.chatJID, chatName: displayName(evidence.chatName),
                              source: MessageRef(messageID: evidence.messageID, chatID: evidence.chatID, uid: evidence.uid),
                              questionDate: asked, quietDays: elapsed,
                              preview: preview(evidence.text))
    }

    // MARK: - Who may be assigned a reply

    /// One-to-one, with a participant the index actually identifies.
    ///
    /// `isGroup` comes from the index. The JID decides the rest: `@s.whatsapp.net` and
    /// `@lid` are people; `@broadcast`, `@newsletter`, `@bot` and `@temp` rows are status
    /// updates, channels and ephemeral addresses, and the index marks some of them as
    /// non-group. "unknown" or an empty participant key means the chat cannot be
    /// attributed to a person, so no responsibility is assigned.
    static func isDirectChat(_ evidence: ReplyLatestEvidence) -> Bool {
        guard !evidence.isGroup else { return false }
        guard isDirectJID(evidence.chatJID) else { return false }
        return isIndividual(evidence.person)
    }

    static func isDirectJID(_ jid: String) -> Bool {
        let j = jid.lowercased()
        return j.hasSuffix("@s.whatsapp.net") || j.hasSuffix("@lid") || j.hasSuffix("@hosted.lid")
    }

    /// A participant key that stands for one person. Not a display name, not "me",
    /// not a merged/derived bucket.
    static func isIndividual(_ person: String) -> Bool {
        let p = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p != "unknown", p != "me" else { return false }
        for derived in ["newsletter:", "broadcast:", "bot:", "temp:"] where p.hasPrefix(derived) { return false }
        return true
    }

    // MARK: - What counts as a last word

    /// Text a person typed, or any media — the same visibility rule the conversation list
    /// uses, so "their last message" here is what the person would see in the chat.
    /// System notices never reach this helper: the store query drops them.
    static func isSubstantive(_ text: String, mediaKind: String?) -> Bool {
        if mediaKind != nil { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func containsQuestion(_ text: String) -> Bool {
        text.contains { questionMarkers.contains($0) }
    }

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed contact" : trimmed
    }

    /// Whitespace collapsed to single spaces and clipped, so a long message cannot blow
    /// up the sheet. Display only.
    static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > previewLength else { return flat }
        return String(flat.prefix(previewLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
