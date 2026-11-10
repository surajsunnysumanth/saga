import Foundation

/// A "Wrapped" for one conversation between two people: how it started, who carries it, what made you laugh,
/// the songs and videos you traded, inside jokes. Computed from the library; nothing leaves the Mac.
public struct DuoWrapped: Sendable {
    public struct Moment: Sendable {
        public let date: Date, author: String, text: String, reply: String, score: Int, messageID: Int64
        /// Stable message identity, so quoted replies can be found after an index rebuild.
        public var uid = ""
        /// People who reacted to this message, and the emoji split the card prints beside it.
        public var reactors = 0
        public var reactionSummary = ""
        /// Replies that quoted the message, the one that earned the laugh first.
        public var quoted: [QuotedReply] = []
    }
    public struct Track: Sendable {
        public let service: MediaService, kind: String, url: String, embed: String
        public var title: String?, author: String?, thumbnail: String?
        public let firstDate: Date, firstBy: String, sharedBy: [String], times: Int
        public let landed: Int, reaction: String, reactionBy: String, messageID: Int64
        public var role: String            // why it is featured: "First song", "Landed", "On repeat", "Both of you"
    }
    public struct Phrase: Sendable { public let text: String, count: Int }

    public var me: String, them: String, chatID: Int64
    public var total = 0, mine = 0, theirs = 0
    public var first: Date = Date(), last: Date = Date()
    public var firstText: (date: Date, author: String, text: String)?
    public var activeDays = 0, spanDays = 0, longestStreak = 0
    public var streakEnd: Date?
    public var longestGapDays = 0
    public var gapFrom: Date?, gapTo: Date?, gapBrokenBy = ""
    public var startsMine = 0, startsTheirs = 0
    public var medianReplyMine: Double?, medianReplyTheirs: Double?           // seconds
    /// How many answers each person gave inside a day, and how many took longer. The copy
    /// needs both: a median over two turns is an anecdote, and "takes a day or more" is only
    /// true when every answer actually took a day.
    public var replyCountMine = 0, replyCountTheirs = 0
    public var slowReplyMine = 0, slowReplyTheirs = 0
    public var busiestHour = 0, nightMine = 0, nightTheirs = 0                // 0 to 5 am message counts
    public var busiestWeekday = 1
    public var busiestDay: (date: Date, count: Int)?
    public var monthly: [(month: String, count: Int)] = []
    public var peakMonth: (month: String, count: Int)?
    /// Every calendar year with messages, and how many of its days were active.
    public var byYear: [(year: Int, count: Int, activeDays: Int)] = []
    public var bestYear: (year: Int, count: Int, activeDays: Int)?
    /// A fully covered year that sank well below the chat's normal volume.
    public var quietestYear: (year: Int, count: Int)?
    /// The latest message either of you sent between midnight and 5 am.
    public var nightOwl: (date: Date, author: String, text: String, hour: Int, minute: Int, messageID: Int64)?
    /// Two emoji used side by side, repeated — the pair that is *ours*.
    public var emojiPair: (a: String, b: String, count: Int)?
    public var wordsMine = 0, wordsTheirs = 0
    public var avgWordsMine = 0.0, avgWordsTheirs = 0.0
    public var longestMine: (date: Date, text: String, messageID: Int64)?, longestTheirs: (date: Date, text: String, messageID: Int64)?
    public var laughsMine = 0, laughsTheirs = 0                                // laugh messages sent
    public var madeThemLaugh = 0, madeMeLaugh = 0                              // times a message got a laugh back
    /// Messages that earned at least one heart from the other person — the owner's, and
    /// theirs. Never mixed into the laugh numbers: a ❤️ is not a laugh.
    public var heartsMine = 0, heartsTheirs = 0
    /// The single message that collected the most hearts, with who gave them, plus the count
    /// of everyone who reacted and the replies that quoted it.
    public var loved: (date: Date, author: String, text: String, by: String, count: Int,
                       messageID: Int64, reactors: Int, summary: String, quoted: [QuotedReply])?
    /// Messages that earned at least one laugh-emoji reaction (part of `madeThemLaugh` +
    /// `madeMeLaugh`, reported separately so the numbers can be audited).
    public var laughsByReaction = 0
    public var funniest: [Moment] = []
    public var laughMonth: (month: String, count: Int)?
    public var insideJokes: [Phrase] = []
    public var myWords: [Phrase] = [], theirWords: [Phrase] = []
    public var emojiMine: [Phrase] = [], emojiTheirs: [Phrase] = [], emojiTogether: [Phrase] = []
    public var photos = (mine: 0, theirs: 0), videos = (mine: 0, theirs: 0), voice = (mine: 0, theirs: 0), docs = (mine: 0, theirs: 0)
    public var tracks: [Track] = []
    public var linksTotal = 0, linksMine = 0, linksTheirs = 0, twinTracks = 0
    public var musicPeakMonth: (month: String, count: Int)?
    public var serviceCounts: [(MediaService, Int)] = []
    /// The sticker habit of this conversation: sends, distinct files (by SHA-256), busiest one.
    public var stickers = Stickers.Summary()

    public var hasMusic: Bool { linksTotal > 0 }
}

public enum DuoWrappedBuilder {
    struct Msg { let id: Int64, ts: Date, me: Bool, text: String, kind: String?; var uid = ""; var person = ""; var laugh = 0 }

    static let urlRegex = try! NSRegularExpression(pattern: #"https?://\S+|www\.\S+"#, options: [.caseInsensitive])
    static let filler: Set<String> = ["haha", "hahaha", "hahah", "lol", "lmao", "yeah", "yes", "yep", "nope", "okay", "ok", "hmm", "umm", "also", "okie", "alright", "right", "well", "still", "really", "very", "much", "more", "now", "too", "don", "doesn", "didn", "isn", "wasn", "can", "let", "lets", "going", "gonna", "wanna", "think", "know", "want", "need", "see", "come", "make", "take", "give", "look", "good", "nice", "sure", "thing", "things", "something", "anything", "everything", "today", "tomorrow", "tonight", "yesterday", "later", "soon"]

    /// Default-vocabulary laugh score (shared with Group Wrapped). Configurable detection lives in `WrappedReactionDetector`.
    static func laughScore(_ t: String) -> Int { WrappedReactionDetector().laughScore(t) }
    static func has(_ re: NSRegularExpression, _ t: String) -> Bool { re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }
    static func stripURLs(_ t: String) -> String { urlRegex.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " ") }
    static func tokens(_ t: String) -> [String] {
        stripURLs(t).lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
    }
    static func isContent(_ w: String) -> Bool { w.count >= 3 && !VaultStore.stopwords.contains(w) && !filler.contains(w) }
    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    /// Newsletters, digests and forwarded announcements dress up as messages but never make a good memory.
    static func isBroadcast(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = ["unsubscribe", "view in browser", "manage preferences", "you're receiving this",
                       "this message was sent to", "opt out", "no-reply", "noreply"]
        if markers.contains(where: { lower.contains($0) }) { return true }
        if text.count > 700 { return true }
        return MediaLinks.links(in: text).count >= 3
    }

    /// Drop stopwords hanging off either end, so a tag reads like a phrase
    /// ("blue kite", not "blue kite at") and can stand alone in a sentence.
    static func trimPhrase(_ phrase: String) -> String {
        var words = phrase.split(separator: " ").map(String.init)
        while let first = words.first, !isContent(first) { words.removeFirst() }
        while let last = words.last, !isContent(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Cache identity for a built Wrapped: the chat, its message count and its newest key.
    /// Re-importing or reading more into the chat changes the key; simply reopening the
    /// same archive does not, so the expensive pass runs once.
    public static func cacheKey(store: VaultStore, chatID: Int64) -> String {
        var count: Int64 = 0, lastID: Int64 = 0
        try? store.db.query("SELECT count(*), COALESCE(MAX(id),0) FROM messages WHERE chat_id=\(chatID)") {
            count = $0.int(0); lastID = $0.int(1)
        }
        var uid = ""
        try? store.db.query("SELECT uid FROM messages WHERE chat_id=\(chatID) ORDER BY id DESC LIMIT 1") { uid = $0.text(0) ?? "" }
        return "\(chatID)-\(count)-\(lastID)-\(uid)"
    }
    static func emojis(in t: String) -> [String] {
        var out: [String] = []
        for ch in t where ch.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) }) { out.append(String(ch)) }
        return out
    }

    public static func build(store: VaultStore, chatID: Int64, me: String, fetchTitles: Bool = true,
                             reactions: WrappedReactionDetector = WrappedReactionDetector()) async throws -> DuoWrapped {
        var them = "them"
        try store.db.query("SELECT name FROM chats WHERE chat_id=\(chatID)") { them = $0.text(0) ?? "them" }
        var w = DuoWrapped(me: me, them: them, chatID: chatID)

        var msgs: [Msg] = []
        try store.db.query("""
            SELECT m.id, m.ts, m.from_me, COALESCE(m.text,''), md.kind, m.uid, COALESCE(m.person,'') FROM messages m LEFT JOIN media md ON md.msg_id=m.id
            WHERE m.chat_id=\(chatID) AND m.type NOT IN (7,27,36,55,90) AND (COALESCE(m.text,'')<>'' OR md.kind IS NOT NULL) ORDER BY m.ts, m.id
            """) { msgs.append(Msg(id: $0.int(0), ts: VaultStore.date($0.int(1)), me: $0.int(2) != 0, text: store.resolveMentions($0.text(3) ?? ""), kind: $0.text(4), uid: $0.text(5) ?? "", person: $0.text(6) ?? "")) }
        guard msgs.count >= 2 else { return w }
        for i in msgs.indices { msgs[i].laugh = reactions.laughScore(msgs[i].text) }
        // Real WhatsApp quotes (when the vault has them): reaction index -> replied-to index. A reply whose target isn't in
        // this chat is "explicit but unresolved" and is never re-attributed by proximity.
        let replyTarget = try MessageReplies.load(store.db)
        var indexOfUID: [String: Int] = [:]
        for (i, m) in msgs.enumerated() where !m.uid.isEmpty { indexOfUID[m.uid] = i }
        var explicit = Set<Int>(), repliesTo: [Int: [Int]] = [:]
        for (j, m) in msgs.enumerated() {
            guard let t = replyTarget[m.uid] else { continue }
            explicit.insert(j)
            if let i = indexOfUID[t], i != j { repliesTo[i, default: []].append(j) }
        }
        let reactionCtx = ReactionContext(explicit: explicit, repliesTo: repliesTo, detector: reactions)

        // Emoji reactions on a message are laughter aimed at *that* message, given by the
        // person who tapped them. They arrive from WhatsApp's own add-on tables, keyed by
        // message id, so there is no proximity guesswork and no way to credit a later
        // re-share: the row names one message and one reactor. A 👍 is not laughter.
        let storedReactions = try MessageReactions.load(store.db, chatID: chatID)
        var reactionsEarned: [Int: (count: Int, emoji: String)] = [:]
        var heartsEarned: [Int: (count: Int, emoji: String, by: String)] = [:]
        for (i, m) in msgs.enumerated() {
            let laugh = (storedReactions[m.id] ?? []).filter { $0.isLaugh && $0.isMine != m.me }
            if !laugh.isEmpty { reactionsEarned[i] = (laugh.count, laugh.map(\.emoji).joined()) }
            let hearts = (storedReactions[m.id] ?? []).filter { $0.isHeart && $0.isMine != m.me }
            if !hearts.isEmpty {
                let by = hearts.first.map { $0.isMine ? me : ($0.senderName.isEmpty ? "Someone" : $0.senderName) } ?? "Someone"
                heartsEarned[i] = (hearts.count, hearts.map(\.emoji).joined(), by)
            }
        }

        let cal = Calendar.current
        w.total = msgs.count; w.mine = msgs.filter(\.me).count; w.theirs = w.total - w.mine
        w.first = msgs.first!.ts; w.last = msgs.last!.ts
        if let f = msgs.first(where: { !$0.text.isEmpty && $0.kind == nil }) { w.firstText = (f.ts, f.me ? me : them, clip(f.text, 240)) }
        w.spanDays = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: w.first), to: cal.startOfDay(for: w.last)).day ?? 0) + 1)

        // days, streaks, gaps
        let dayIdx = msgs.map { Int(cal.startOfDay(for: $0.ts).timeIntervalSince1970 / 86400.0 + 0.5) }
        let uniq = Array(Set(dayIdx)).sorted(); w.activeDays = uniq.count
        var run = 1, best = 1, bestEnd = uniq.first ?? 0
        for i in 1..<max(uniq.count, 1) where uniq.count > 1 { run = uniq[i] == uniq[i - 1] + 1 ? run + 1 : 1; if run > best { best = run; bestEnd = uniq[i] } }
        w.longestStreak = best; w.streakEnd = Date(timeIntervalSince1970: Double(bestEnd) * 86400)
        for i in 1..<msgs.count {
            let g = Int(msgs[i].ts.timeIntervalSince(msgs[i - 1].ts) / 86400)
            if g > w.longestGapDays { w.longestGapDays = g; w.gapFrom = msgs[i - 1].ts; w.gapTo = msgs[i].ts; w.gapBrokenBy = msgs[i].me ? "You" : them }
        }
        var counts: [Int: Int] = [:]; for d in dayIdx { counts[d, default: 0] += 1 }
        if let top = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) { w.busiestDay = (Date(timeIntervalSince1970: Double(top.key) * 86400), top.value) }

        // who starts conversations, how fast each replies
        //
        // Two different questions live here. "How fast do they answer mid-conversation" is
        // measured by every turn; "how long until they get back to you" only counts the first
        // answer after the thread went quiet for half an hour, which is the number people
        // recognise. The second is the headline, with the first as the fallback for chats
        // that never go quiet.
        var repMine: [Double] = [], repTheirs: [Double] = []
        var backMine: [Double] = [], backTheirs: [Double] = []
        for i in msgs.indices {
            let gap = i == 0 ? Double.infinity : msgs[i].ts.timeIntervalSince(msgs[i - 1].ts)
            // Two independent questions, so a long silence can be *both* a new conversation
            // and the first reply to it. They used to share an `if/else if`, which meant a
            // gap of six hours or more was only ever a conversation start — the median never
            // saw a 6-to-24-hour answer, and a same-day replier could be called "a day or more".
            if gap >= 6 * 3600 { if msgs[i].me { w.startsMine += 1 } else { w.startsTheirs += 1 } }
            // Gaps under four seconds are a double-send, not a reply; a day or more is
            // dormancy, not an answer time. Everything in between is a reply, and the slow
            // ones are counted separately so the copy can tell "no data" from "always slow".
            guard i > 0, msgs[i].me != msgs[i - 1].me, gap >= 4 else { continue }
            if gap < 86400 {
                if msgs[i].me { w.replyCountMine += 1; repMine.append(gap) } else { w.replyCountTheirs += 1; repTheirs.append(gap) }
                if gap >= 1800 {
                    if msgs[i].me { backMine.append(gap) } else { backTheirs.append(gap) }
                }
            } else if msgs[i].me { w.slowReplyMine += 1 } else { w.slowReplyTheirs += 1 }
        }
        func median(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.sorted()[a.count / 2] }
        w.medianReplyMine = median(backMine) ?? median(repMine)
        w.medianReplyTheirs = median(backTheirs) ?? median(repTheirs)

        // clock
        var hours = [Int](repeating: 0, count: 24), weekdays = [Int](repeating: 0, count: 8)
        var monthCount: [String: Int] = [:]
        var yearCount: [Int: Int] = [:], yearDays: [Int: Set<Int>] = [:]
        let mf = DateFormatter(); mf.dateFormat = "yyyy-MM"; mf.locale = Locale(identifier: "en_US_POSIX")
        for (i, m) in msgs.enumerated() {
            let c = cal.dateComponents([.hour, .weekday], from: m.ts)
            let h = c.hour ?? 12
            hours[h] += 1; weekdays[c.weekday ?? 1] += 1
            if h < 5 {
                if m.me { w.nightMine += 1 } else { w.nightTheirs += 1 }
                // The night message worth naming: the latest one that still has
                // words in it (not a bare link or emoji), so 4:56 am beats 1:02 am.
                if stripURLs(m.text).trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 {
                    let minute = cal.component(.minute, from: m.ts)
                    if w.nightOwl == nil || (h * 60 + minute) > (w.nightOwl!.hour * 60 + w.nightOwl!.minute) {
                        w.nightOwl = (m.ts, m.me ? me : them, clip(m.text, 200), h, minute, m.id)
                    }
                }
            }
            monthCount[mf.string(from: m.ts), default: 0] += 1
            let y = cal.component(.year, from: m.ts)
            yearCount[y, default: 0] += 1
            yearDays[y, default: []].insert(dayIdx[i])
        }
        w.busiestHour = hours.firstIndex(of: hours.max() ?? 0) ?? 0
        w.busiestWeekday = weekdays.indices.dropFirst().max { weekdays[$0] < weekdays[$1] } ?? 1
        w.monthly = fillMonths(monthCount, from: w.first, to: w.last, f: mf)
        w.peakMonth = w.monthly.max { $0.count < $1.count }.map { ($0.month, $0.count) }

        // years: the loudest one, and the fully covered one that went quiet
        w.byYear = yearCount.keys.sorted().map { ($0, yearCount[$0] ?? 0, yearDays[$0]?.count ?? 0) }
        w.bestYear = w.byYear.max { $0.count != $1.count ? $0.count < $1.count : $0.year > $1.year }
        if w.byYear.count >= 3 {
            let interior = w.byYear.dropFirst().dropLast()
            let counts = w.byYear.map(\.count).sorted()
            let median = counts[counts.count / 2]
            w.quietestYear = interior.filter { $0.count > 0 && Double($0.count) < Double(median) * 0.4 }
                .min { $0.count < $1.count }.map { ($0.year, $0.count) }
        }

        // words and long messages
        for m in msgs where !m.text.isEmpty {
            let n = tokens(m.text).count
            if m.me { w.wordsMine += n } else { w.wordsTheirs += n }
            if m.text.count > (m.me ? w.longestMine?.text.count ?? 0 : w.longestTheirs?.text.count ?? 0), !has(urlRegex, m.text) || m.text.count > 120 {
                if m.me { w.longestMine = (m.ts, clip(m.text, 320), m.id) } else { w.longestTheirs = (m.ts, clip(m.text, 320), m.id) }
            }
            if m.laugh > 0 { if m.me { w.laughsMine += 1 } else { w.laughsTheirs += 1 } }
        }
        w.avgWordsMine = Double(w.wordsMine) / Double(max(1, msgs.filter { $0.me && !$0.text.isEmpty }.count))
        w.avgWordsTheirs = Double(w.wordsTheirs) / Double(max(1, msgs.filter { !$0.me && !$0.text.isEmpty }.count))
        for m in msgs { switch m.kind { case "image": if m.me { w.photos.mine += 1 } else { w.photos.theirs += 1 }
            case "video": if m.me { w.videos.mine += 1 } else { w.videos.theirs += 1 }
            case "audio": if m.me { w.voice.mine += 1 } else { w.voice.theirs += 1 }
            case "doc": if m.me { w.docs.mine += 1 } else { w.docs.theirs += 1 }
            default: break } }                                                    // a sticker is neither a photo nor a document

        // Hearts: the messages the other person loved, by the same one-per-message rule as
        // laughs. The busiest one is named for the card; ties go to the more recent message.
        for (i, m) in msgs.enumerated() {
            guard let h = heartsEarned[i] else { continue }
            if m.me { w.heartsMine += 1 } else { w.heartsTheirs += 1 }
            let text = m.text.isEmpty ? "[\(m.kind ?? "media")]" : clip(m.text, 240)
            if w.loved == nil || h.count > w.loved!.count
                || (h.count == w.loved!.count && m.ts > w.loved!.date) {
                w.loved = (m.ts, m.me ? me : them, text, h.by, h.count, m.id, 0, "", [])
            }
        }
        w.stickers = try Stickers.summary(store: store, chatID: chatID)

        // laugh triggers: a message followed within 5 minutes by laughter from the other person
        var moments: [DuoWrapped.Moment] = []; var laughByMonth: [String: Int] = [:]
        for i in msgs.indices {
            let m = msgs[i]
            var score = reactionsEarned[i]?.count ?? 0
            var sample = reactionsEarned[i]?.emoji ?? ""
            if score > 0 { w.laughsByReaction += 1 }
            if m.laugh == 0, m.text.count >= 6 || m.kind != nil {
            for j in reactionCtx.repliesTo[i] ?? [] where msgs[j].me != m.me && msgs[j].laugh > 0 {     // quoted replies count at any distance
                score += msgs[j].laugh; if sample.isEmpty { sample = msgs[j].text }
            }
            for j in (i + 1)..<min(i + 5, msgs.count) where i + 1 < msgs.count {
                guard msgs[j].ts.timeIntervalSince(m.ts) <= 300 else { break }
                if reactionCtx.explicit.contains(j) { continue }                                          // quoted elsewhere: not a proximity guess
                if msgs[j].me != m.me, msgs[j].laugh > 0 { score += msgs[j].laugh; if sample.isEmpty { sample = msgs[j].text } }
            }
            }
            if score > 0 {
                if m.me { w.madeThemLaugh += 1 } else { w.madeMeLaugh += 1 }
                laughByMonth[mf.string(from: m.ts), default: 0] += 1
                if score >= 3 { moments.append(DuoWrapped.Moment(date: m.ts, author: m.me ? me : them, text: m.text.isEmpty ? "[\(m.kind ?? "media")]" : clip(m.text, 240), reply: clip(sample, 120), score: score, messageID: m.id)) }
            }
        }
        // spread the picks across the years, and prefer exchanges where the reply was a real sentence,
        // not the fourth "lol" of the afternoon. Broadcasts and forwards never make the cut.
        let eligible = moments.filter { !isBroadcast($0.text) && !isBroadcast($0.reply) }
        func replyDepth(_ s: String) -> Int { tokens(s).count }
        func better(_ a: DuoWrapped.Moment, _ b: DuoWrapped.Moment) -> Bool {
            if a.score != b.score { return a.score > b.score }
            let ra = replyDepth(a.reply), rb = replyDepth(b.reply)
            if ra != rb { return ra > rb }
            return a.text.count > b.text.count
        }
        var perYear: [Int: [DuoWrapped.Moment]] = [:]
        for m in eligible { perYear[cal.component(.year, from: m.date), default: []].append(m) }
        let yearWinners = perYear.compactMap { year, list -> (year: Int, best: DuoWrapped.Moment)? in
            list.max(by: better).map { (year, $0) }
        }.sorted { better($0.best, $1.best) }
        var picked: [DuoWrapped.Moment] = []
        // The demo (and real group chats) repeat the same reply word for word; one is enough.
        var seenReplies = Set<String>()
        func replyKey(_ m: DuoWrapped.Moment) -> String {
            String(m.reply.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(120))
        }
        func acceptable(_ m: DuoWrapped.Moment) -> Bool {
            guard !picked.contains(where: { $0.messageID == m.messageID }) else { return false }
            let key = replyKey(m)
            return key.isEmpty || !seenReplies.contains(key)
        }
        func take(_ m: DuoWrapped.Moment) {
            picked.append(m); seenReplies.insert(replyKey(m))
        }
        for winner in yearWinners where picked.count < 6 {
            if acceptable(winner.best) { take(winner.best) }
        }
        for m in eligible.sorted(by: better) where picked.count < 6 {
            guard acceptable(m) else { continue }
            let y = cal.component(.year, from: m.date)
            if picked.filter({ cal.component(.year, from: $0.date) == y }).count >= 2 { continue }
            take(m)
        }
        w.funniest = picked.sorted { $0.date != $1.date ? $0.date < $1.date : $0.messageID < $1.messageID }

        // What each card prints beside a moment: how many people reacted, how that splits by
        // emoji, and the replies that quoted it. The reply that earned the moment already
        // exists in this builder, so it leads the stack instead of being looked up again.
        let byID = Dictionary(msgs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func extras(_ id: Int64, reply: String?, fromMe: Bool) -> MomentReactions {
            var out = MomentReactionsLoader.load(store: store, chatID: chatID,
                                                 targets: [.init(id: id, uid: byID[id]?.uid ?? "",
                                                                 author: byID[id]?.me == true ? "me" : (byID[id]?.person ?? ""))])[id]
                ?? MomentReactions()
            if let reply, !reply.isEmpty {
                out.quoted = MomentReactions.stack(
                    lead: QuotedReply(uid: "moment-\(id)", author: fromMe ? me : them, text: reply, fromMe: fromMe),
                    others: out.quoted)
            }
            return out
        }
        for i in w.funniest.indices {
            let m = w.funniest[i]
            let e = extras(m.messageID, reply: m.reply, fromMe: m.author != me)
            w.funniest[i].uid = byID[m.messageID]?.uid ?? ""
            w.funniest[i].reactors = e.reactors
            w.funniest[i].reactionSummary = e.summary
            w.funniest[i].quoted = e.quoted
        }
        if let loved = w.loved {
            let e = extras(loved.messageID, reply: nil, fromMe: false)
            w.loved = (loved.date, loved.author, loved.text, loved.by, loved.count, loved.messageID,
                       e.reactors, e.summary, e.quoted)
        }
        w.laughMonth = laughByMonth.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }.map { ($0.key, $0.value) }

        // emojis: the obvious leaders, plus the pair that keeps turning up together
        var em = [String: Int](), emMe = [String: Int](), emThem = [String: Int](), pairs = [String: Int]()
        for m in msgs where !m.text.isEmpty {
            let found = emojis(in: m.text)
            for e in found { em[e, default: 0] += 1; if m.me { emMe[e, default: 0] += 1 } else { emThem[e, default: 0] += 1 } }
            if found.count >= 2 { for i in 0..<(found.count - 1) { pairs[found[i] + " " + found[i + 1], default: 0] += 1 } }
        }
        func top(_ d: [String: Int], _ n: Int) -> [DuoWrapped.Phrase] { d.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map { .init(text: $0.key, count: $0.value) } }
        w.emojiMine = top(emMe, 4); w.emojiTheirs = top(emThem, 4); w.emojiTogether = top(em, 8)
        if let p = pairs.filter({ $0.value >= 2 }).max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            let parts = p.key.split(separator: " ").map(String.init)
            if parts.count == 2 { w.emojiPair = (parts[0], parts[1], p.value) }
        }

        // inside jokes and signature words: phrases this chat alone uses
        let (jokes, mine, theirs) = try distinctive(store: store, chatID: chatID, msgs: msgs,
                                                     participantNames: [me, them])
        w.insideJokes = jokes; w.myWords = mine; w.theirWords = theirs

        // music and video
        await music(&w, msgs: msgs, ctx: reactionCtx, fetchTitles: fetchTitles, cal: cal, mf: mf)
        return w
    }

    static func fillMonths(_ c: [String: Int], from: Date, to: Date, f: DateFormatter) -> [(month: String, count: Int)] {
        var out: [(String, Int)] = [], d = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: from))!
        let end = to
        while d <= end { let k = f.string(from: d); out.append((k, c[k] ?? 0)); d = Calendar.current.date(byAdding: .month, value: 1, to: d)! }
        return out
    }

    /// The words that only mean something in *this* conversation.
    ///
    /// An inside joke is a phrase, not a token: it needs at least two content words, at least
    /// three uses here, and no use anywhere else in the archive. Names are the usual impostor —
    /// "@Priya Menon look" tokenises to "priya menon look" and would otherwise outrank a real
    /// joke in a chat that tags people — so every participant's name, every @mention and every
    /// phone-number-shaped string is rejected before counting. Single words are never jokes;
    /// they are the separate "signature words" list, and they get the same name filter.
    static func distinctive(store: VaultStore, chatID: Int64, msgs: [Msg],
                            participantNames: [String] = []) throws
        -> ([DuoWrapped.Phrase], [DuoWrapped.Phrase], [DuoWrapped.Phrase]) {
        let blocked = nameTokens(participantNames)
        var uni = [String: Int](), uniMe = [String: Int](), uniThem = [String: Int](), bi = [String: Int](), tri = [String: Int]()
        for m in msgs where !m.text.isEmpty {
            let t = tokens(withoutMentions(m.text))
            for x in t where isContent(x) && !blocked.contains(x) && !isPhoneLike(x) {
                uni[x, default: 0] += 1
                if m.me { uniMe[x, default: 0] += 1 } else { uniThem[x, default: 0] += 1 }
            }
            // A phrase is rejected whole when any word in it is a name: "@Priya Menon look"
            // must not leave "priya look" or "menon look" behind as a candidate.
            if t.count >= 2 {
                for i in 0..<(t.count - 1) where t[i].count >= 2 && t[i + 1].count >= 2
                    && !blocked.contains(t[i]) && !blocked.contains(t[i + 1]) && !isPhoneLike(t[i]) && !isPhoneLike(t[i + 1])
                    && (isContent(t[i]) || isContent(t[i + 1])) {
                    bi[t[i] + " " + t[i + 1], default: 0] += 1
                }
            }
            if t.count >= 3 {
                for i in 0..<(t.count - 2) where !blocked.contains(t[i]) && !blocked.contains(t[i + 1]) && !blocked.contains(t[i + 2])
                    && [t[i], t[i + 1], t[i + 2]].filter(isContent).count >= 2 {
                    tri[t[i] + " " + t[i + 1] + " " + t[i + 2], default: 0] += 1
                }
            }
        }
        // Frequency ≥3, and the phrase must live here alone. The old lift test compared this
        // chat with a sample of the rest of the archive, which let a name that happens to be
        // common in one other chat through; exclusivity is the definition of an inside joke.
        let candidates = (tri.filter { $0.value >= 3 }.map { ($0.key, $0.value) }
                          + bi.filter { $0.value >= 3 }.map { ($0.key, $0.value) })
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                let aw = a.0.split(separator: " ").count, bw = b.0.split(separator: " ").count
                if aw != bw { return aw > bw }
                return a.0 < b.0
            }
        var jokes: [DuoWrapped.Phrase] = []
        var checked = 0
        for (key, count) in candidates {
            let phrase = trimPhrase(key)
            let words = Set(phrase.split(separator: " ").map(String.init))
            guard words.count >= 2 else { continue }
            // Two words in common with a phrase already picked is the same joke seen from a
            // different angle ("mine not touching" / "not mine not"), so it is not a second one.
            if jokes.contains(where: { Set($0.text.split(separator: " ").map(String.init)).intersection(words).count >= 2 }) { continue }
            // Every check is a scan for the phrase elsewhere; forty is more than enough to
            // fill eight cards, and bounds the cost on a six-hundred-thousand-message archive.
            guard checked < 40 else { break }
            checked += 1
            guard try !appearsElsewhere(store: store, chatID: chatID, phrase: phrase) else { continue }
            jokes.append(.init(text: phrase, count: count))
            if jokes.count == 8 { break }
        }
        // Signature words stay single words, but never a person's name, never a number, and
        // never a word the rest of the archive also uses — a word everyone says is not a
        // signature. Exclusivity is checked for the top few only, to bound the cost.
        func sig(_ own: [String: Int]) throws -> [DuoWrapped.Phrase] {
            let ranked = own.filter { $0.value >= 6 && !blocked.contains($0.key) && !isPhoneLike($0.key)
                && ($0.value * 100 >= (uni[$0.key] ?? 1) * 70) }   // used mostly by this person
                .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            var out: [DuoWrapped.Phrase] = []
            var checked = 0
            for (word, count) in ranked {
                guard checked < 15 else { break }
                checked += 1
                if try appearsElsewhere(store: store, chatID: chatID, phrase: word) { continue }
                out.append(.init(text: word, count: count))
                if out.count == 5 { break }
            }
            return out
        }
        return (jokes, try sig(uniMe), try sig(uniThem))
    }

    /// "@Priya" and "@Priya Menon" are mentions, not vocabulary. Removing the handle leaves
    /// the surname behind, which is why `nameTokens` also blocks every participant's name.
    static let mentionRegex = try! NSRegularExpression(pattern: #"@[\p{L}\p{N}_]+"#)
    static func withoutMentions(_ text: String) -> String {
        mentionRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    /// Every word of every participant's display name, lowercased the same way `tokens` does.
    static func nameTokens(_ names: [String]) -> Set<String> {
        var out = Set<String>()
        for name in names {
            for token in tokens(name.replacingOccurrences(of: "@", with: " ")) where token.count >= 2 { out.insert(token) }
        }
        return out
    }

    /// A token shaped like a phone number or a LID: digits with the punctuation numbers carry.
    static func isPhoneLike(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard t.filter(\.isNumber).count >= 7 else { return false }
        return t.allSatisfy { $0.isNumber || "+-() .".contains($0) }
    }

    /// True when the phrase appears in a message outside this chat. LIKE finds the candidate
    /// cheaply; the token check then rejects a substring hit ("cat" inside "concatenate").
    static func appearsElsewhere(store: VaultStore, chatID: Int64, phrase: String) throws -> Bool {
        let needle = phrase.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "'", with: "''")
        let wanted = phrase.split(separator: " ").map(String.init)
        var found = false
        try store.db.query("""
            SELECT text FROM messages
            WHERE chat_id <> \(chatID) AND text IS NOT NULL AND text LIKE '%\(needle)%' ESCAPE '\\'
            LIMIT 8
            """) { row in
            guard !found else { return }
            let hay = tokens(row.text(0) ?? "")
            for i in 0...(max(0, hay.count - wanted.count)) where i + wanted.count <= hay.count {
                if Array(hay[i..<(i + wanted.count)]) == wanted { found = true; return }
            }
        }
        return found
    }

    struct ReactionContext { let explicit: Set<Int>, repliesTo: [Int: [Int]], detector: WrappedReactionDetector }

    static func music(_ w: inout DuoWrapped, msgs: [Msg], ctx: ReactionContext, fetchTitles: Bool, cal: Calendar, mf: DateFormatter) async {
        struct Ev { let idx: Int; let me: Bool; let l: (service: MediaService, kind: String, embed: String, key: String, clean: String, ytID: String?, slug: String?) }
        var evs: [Ev] = []
        for (i, m) in msgs.enumerated() where !m.text.isEmpty { for l in MediaLinks.links(in: m.text) { evs.append(Ev(idx: i, me: m.me, l: l)) } }
        guard !evs.isEmpty else { return }
        w.linksTotal = evs.count; w.linksMine = evs.filter(\.me).count; w.linksTheirs = w.linksTotal - w.linksMine
        var svc: [MediaService: Int] = [:]; for e in evs { svc[e.l.service, default: 0] += 1 }
        w.serviceCounts = svc.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        var byMonth: [String: Int] = [:]; for e in evs { byMonth[mf.string(from: msgs[e.idx].ts), default: 0] += 1 }
        w.musicPeakMonth = byMonth.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }.map { ($0.key, $0.value) }

        struct Agg { var evs: [Ev] = []; var landed = 0; var reaction = ""; var reactionBy = ""; var reactionScore = 0 }
        var agg: [String: Agg] = [:], order: [String] = []
        for e in evs {
            let isFirstShare = agg[e.l.key] == nil
            if isFirstShare { order.append(e.l.key) }
            agg[e.l.key, default: Agg()].evs.append(e)
            // Did the other person react warmly within 30 minutes? The reaction always
            // credits the share it answered — a like on a later re-share of the same link is
            // not a reaction to the version the card names, which is how Meera ended up
            // "reacting" to her own song.
            func credit(_ j: Int) {
                agg[e.l.key]!.landed += 1
                guard isFirstShare, agg[e.l.key]!.reaction.isEmpty else { return }
                agg[e.l.key]!.reaction = clip(msgs[j].text, 90)
                agg[e.l.key]!.reactionBy = msgs[j].me ? w.me : w.them
            }
            if let j = (ctx.repliesTo[e.idx] ?? []).first(where: { msgs[$0].me != e.me && ctx.detector.likes(msgs[$0].text) }) { credit(j); continue }
            for j in (e.idx + 1)..<min(e.idx + 7, msgs.count) where e.idx + 1 < msgs.count {
                guard msgs[j].ts.timeIntervalSince(msgs[e.idx].ts) <= 1800 else { break }
                if ctx.explicit.contains(j) { continue }
                if msgs[j].me != e.me, ctx.detector.likes(msgs[j].text) { credit(j); break }
            }
        }
        w.twinTracks = agg.values.filter { Set($0.evs.map(\.me)).count == 2 }.count
        func track(_ k: String, role: String) -> DuoWrapped.Track {
            let a = agg[k]!, f = a.evs[0]
            var sharers: [String] = []; for e in a.evs { let n = e.me ? w.me : w.them; if !sharers.contains(n) { sharers.append(n) } }
            return DuoWrapped.Track(service: f.l.service, kind: f.l.kind, url: f.l.clean, embed: f.l.embed, title: f.l.slug, author: nil, thumbnail: nil,
                                    firstDate: msgs[f.idx].ts, firstBy: f.me ? "You" : w.them, sharedBy: sharers, times: a.evs.count, landed: a.landed,
                                    reaction: a.reaction, reactionBy: a.reactionBy, messageID: msgs[f.idx].id, role: role)
        }
        var picks: [DuoWrapped.Track] = [track(order[0], role: "The first one")]
        func add(_ keys: [String], _ role: String, _ n: Int) {
            for k in keys.prefix(n * 3) where !picks.contains(where: { $0.url == agg[k]!.evs[0].l.clean }) { picks.append(track(k, role: role)); if picks.filter({ $0.role == role }).count >= n { break } }
        }
        add(order.filter { agg[$0]!.landed > 0 }.sorted { agg[$0]!.landed != agg[$1]!.landed ? agg[$0]!.landed > agg[$1]!.landed : agg[$0]!.evs.count > agg[$1]!.evs.count }, "It landed", 5)
        add(order.filter { agg[$0]!.evs.count > 1 }.sorted { agg[$0]!.evs.count > agg[$1]!.evs.count }, "On repeat", 3)
        add(order.filter { Set(agg[$0]!.evs.map(\.me)).count == 2 }, "You both shared it", 3)
        let rest = order.filter { k in !picks.contains { $0.url == agg[k]!.evs[0].l.clean } }
        if picks.count < 8, !rest.isEmpty {                                   // pad with an even spread of the rest, so quiet chats still get a soundtrack
            let want = min(8 - picks.count, rest.count), step = Double(rest.count) / Double(want)
            for i in 0..<want { picks.append(track(rest[Int(Double(i) * step)], role: "Along the way")) }
        }
        picks.sort { $0.firstDate < $1.firstDate }
        if fetchTitles {
            for i in picks.indices {
                let sl = SharedLink(messageID: 0, chatID: 0, uid: "", ts: picks[i].firstDate, sender: "", fromMe: false, chatName: "", url: picks[i].url, service: picks[i].service, kind: picks[i].kind, embedURL: picks[i].embed, key: "", youtubeID: nil, slugTitle: picks[i].title)
                if let m = await MediaLinks.fetchMeta(sl) { picks[i].title = m.title; picks[i].author = m.author.isEmpty ? nil : m.author; picks[i].thumbnail = m.thumbnail }
            }
        }
        w.tracks = picks
    }
}
