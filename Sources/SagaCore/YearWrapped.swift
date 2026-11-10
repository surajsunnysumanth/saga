import Foundation

/// The year Wrapped: one calendar year of the whole archive, in the order a story
/// wants it — the opening number, who you talked to, what made you laugh, the
/// soundtrack, the message that says the most, and a line to close on.
///
/// Computed from the local library only. Song and video titles are looked up in
/// `link_meta.db` first and fetched only when the caller asks for it.
public struct YearWrapped: Sendable {
    public struct ChatCount: Sendable, Identifiable {
        public let id: Int64
        public let name: String
        public let isGroup: Bool
        public let count: Int
        /// Messages you sent in this conversation this year.
        public let sent: Int
    }

    public struct PersonCount: Sendable, Identifiable {
        public let key: String
        public let name: String
        public let count: Int
        public var id: String { key }
    }

    /// The exchange that earned the biggest laugh: what was said, and who laughed at it.
    public struct Moment: Sendable {
        public let date: Date
        public let author: String
        public let fromMe: Bool
        public let chatName: String
        public let text: String
        public let reply: String
        public let replyBy: String
        public let replyFromMe: Bool
        public let messageID: Int64
        public let chatID: Int64
        public let score: Int
        /// Stable message identity, so quoted replies can be found even after a rebuild.
        public var uid: String = ""
        /// People who reacted to this message, and how those reactions split by emoji.
        public var reactors: Int = 0
        public var reactionSummary: String = ""
        /// The replies that quoted it, the one that earned the laugh first.
        public var quoted: [QuotedReply] = []
    }

    public struct Longest: Sendable {
        public let date: Date
        public let author: String
        public let fromMe: Bool
        public let chatName: String
        public let chatID: Int64
        public let messageID: Int64
        public let text: String
        public let chars: Int
        /// The second-longest message that qualified, so the copy can check "nothing else
        /// came close" instead of asserting it.
        public var runnerUp: Int = 0
    }

    public struct Track: Sendable {
        public let service: MediaService
        public let kind: String
        public let url: String
        public let embed: String
        public var title: String?
        public var author: String?
        public var thumbnail: String?
        public let firstDate: Date
        public let firstBy: String
        public let firstChat: String
        public let times: Int
        public let messageID: Int64
        public let chatID: Int64
    }

    public struct Media: Sendable {
        public let photos: Int, videos: Int, voice: Int, docs: Int
        public var total: Int { photos + videos + voice + docs }
        public init(photos: Int = 0, videos: Int = 0, voice: Int = 0, docs: Int = 0) {
            self.photos = photos; self.videos = videos; self.voice = voice; self.docs = docs
        }
    }

    public var year: String
    public var total = 0, sent = 0, words = 0
    /// Days anyone wrote, and the days *you* wrote — the claim "you wrote on N days" uses
    /// the second, because a day a group was busy is not a day you turned up.
    public var activeDays = 0, yourDays = 0
    public var daysInYear = 365
    /// Days from the first archived message of this year to the last, inclusive. For a
    /// year the archive only partly covers this is the honest denominator: what exists
    /// here, not the 365 days the calendar would have offered.
    public var coveredDays = 0
    public var first: Date?, last: Date?
    /// Every conversation with a message that year, busiest first.
    public var chats: [ChatCount] = []
    /// Everyone who wrote to you that year, most first.
    public var people: [PersonCount] = []
    public var peopleCount = 0
    /// Conversations and groups with a message this year, even beyond the shortlist.
    public var chatCount = 0, groupCount = 0
    /// Only the months that actually have messages, keyed "2025-01".
    public var monthly: [(month: String, count: Int)] = []
    public var hourly: [(hour: Int, count: Int)] = []
    public var busiestHour = 0
    public var busiestDay: (date: Date, count: Int)?
    public var longestStreak = 0
    public var nightMessages = 0
    public var laughs = 0
    public var laughMoment: Moment?
    /// Messages that earned a heart from someone else, and the one that earned the most.
    /// Kept apart from `laughs` on purpose: a ❤️ is not a punchline.
    public var hearts = 0
    public var heartMoment: Moment?
    public var stickers = Stickers.Summary()
    public var longest: Longest?
    public var media = Media()
    public var tracks: [Track] = []
    public var linksTotal = 0
    public var linkSenders: [PersonCount] = []
    public var topService: MediaService?
    public var peakMonth: (month: String, count: Int)?

    public init(year: String) { self.year = year }

    public var hasMusic: Bool { linksTotal > 0 }
    public var months: Int { monthly.count }
    public var dmChats: [ChatCount] { chats.filter { !$0.isGroup } }
    public var groupChats: [ChatCount] { chats.filter(\.isGroup) }
    public var spanDays: Int {
        guard let first, let last else { return 1 }
        let cal = Calendar.current
        return max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: first),
                                          to: cal.startOfDay(for: last)).day ?? 0) + 1)
    }
    public var firstMonthIndex: Int { monthly.first.flatMap { Int($0.month.suffix(2)) } ?? 1 }
    public var lastMonthIndex: Int { monthly.last.flatMap { Int($0.month.suffix(2)) } ?? 12 }
    /// A year whose data does not start in January or end in December — a fixture, a
    /// mid-year import, or the current year still running. The chart and the cover say so.
    public var isPartial: Bool { !monthly.isEmpty && (firstMonthIndex > 1 || lastMonthIndex < 12) }
}

public enum YearWrappedBuilder {
    /// System notices and deleted-message placeholders are not part of the story.
    static let excludedTypes = "(7,27,36,55,90)"
    static let linkLike = "(m.text LIKE '%spotify%' OR m.text LIKE '%youtu%' OR m.text LIKE '%soundcloud%' OR m.text LIKE '%music.apple.com%')"

    static func yearCond(_ year: String, prefix: String = "m.ts") -> String {
        let safe = year.replacingOccurrences(of: "'", with: "''")
        return "strftime('%Y',\(prefix)/1000,'unixepoch','localtime')='\(safe)'"
    }

    /// Cache identity: the year, its message count and its newest message uid.
    /// Row ids change when the library is rebuilt; a uid does not, so a rebuilt
    /// archive with identical content keeps its built story.
    public static func cacheKey(store: VaultStore, year: String) -> String {
        let cond = yearCond(year)
        var count = 0
        var uid = ""
        try? store.db.query("SELECT count(*) FROM messages m WHERE \(cond)") { count = Int($0.int(0)) }
        try? store.db.query("SELECT m.uid FROM messages m WHERE \(cond) ORDER BY m.ts DESC, m.id DESC LIMIT 1") { uid = $0.text(0) ?? "" }
        return "\(year)-\(count)-\(uid)"
    }

    public static func build(store: VaultStore, year: String, fetchTitles: Bool = false,
                             cache: LinkMetaCache? = nil,
                             reactions: WrappedReactionDetector = WrappedReactionDetector()) async throws -> YearWrapped {
        var w = YearWrapped(year: year)
        let cond = yearCond(year)

        var minTs: Int64 = 0, maxTs: Int64 = 0
        try store.db.query("""
            SELECT count(*), COALESCE(sum(m.from_me),0), COALESCE(sum(length(m.text)),0), COALESCE(min(m.ts),0), COALESCE(max(m.ts),0)
            FROM messages m WHERE \(cond)
            """) {
            w.total = Int($0.int(0)); w.sent = Int($0.int(1)); w.words = Int($0.int(2)) / 5
            minTs = $0.int(3); maxTs = $0.int(4)
        }
        guard w.total > 0, minTs > 0 else { return w }
        w.first = VaultStore.date(minTs); w.last = VaultStore.date(maxTs)
        if let first = w.first { w.daysInYear = Calendar.current.range(of: .day, in: .year, for: first)?.count ?? 365 }
        if let first = w.first, let last = w.last {
            let cal = Calendar.current
            let a = cal.startOfDay(for: first), b = cal.startOfDay(for: last)
            w.coveredDays = (cal.dateComponents([.day], from: a, to: b).day ?? 0) + 1
        }

        try store.db.query("SELECT count(DISTINCT date(m.ts/1000,'unixepoch','localtime')) FROM messages m WHERE \(cond)") {
            w.activeDays = Int($0.int(0))
        }
        try store.db.query("SELECT count(DISTINCT date(m.ts/1000,'unixepoch','localtime')) FROM messages m WHERE \(cond) AND m.from_me=1") {
            w.yourDays = Int($0.int(0))
        }
        try store.db.query("""
            SELECT strftime('%Y-%m',m.ts/1000,'unixepoch','localtime') k, count(*) n FROM messages m
            WHERE \(cond) GROUP BY k ORDER BY k
            """) { w.monthly.append(($0.text(0) ?? "", Int($0.int(1)))) }
        w.peakMonth = w.monthly.max { $0.count < $1.count }.map { ($0.month, $0.count) }

        try store.db.query("""
            SELECT CAST(strftime('%H',m.ts/1000,'unixepoch','localtime') AS INT) h, count(*) n,
                   sum(CASE WHEN CAST(strftime('%H',m.ts/1000,'unixepoch','localtime') AS INT) < 5 THEN 1 ELSE 0 END)
            FROM messages m WHERE \(cond) GROUP BY h ORDER BY h
            """) {
            w.hourly.append((Int($0.int(0)), Int($0.int(1))))
            w.nightMessages += Int($0.int(2))
        }
        w.busiestHour = w.hourly.max { $0.count < $1.count }?.hour ?? 0

        try store.db.query("""
            SELECT date(m.ts/1000,'unixepoch','localtime') d, count(*) n FROM messages m
            WHERE \(cond) GROUP BY d ORDER BY n DESC, d LIMIT 1
            """) {
            guard let day = $0.text(0), let date = Self.day(day) else { return }
            w.busiestDay = (date, Int($0.int(1)))
        }
        w.longestStreak = try streak(store: store, cond: cond)

        try store.db.query("""
            SELECT m.chat_id, c.name, c.is_group, count(*) n, COALESCE(sum(m.from_me),0)
            FROM messages m JOIN chats c USING(chat_id)
            WHERE \(cond) GROUP BY m.chat_id ORDER BY n DESC, c.name LIMIT 8
            """) {
            w.chats.append(.init(id: $0.int(0), name: $0.text(1) ?? "", isGroup: $0.int(2) != 0,
                                 count: Int($0.int(3)), sent: Int($0.int(4))))
        }
        // `is_group` is a flag on the chat, so the number of groups is a count of chats —
        // it used to be `sum(c.is_group)` over the message join, i.e. group *messages*,
        // which printed "ahead of 7,669 other groups" for an archive of ten.
        try store.db.query("""
            SELECT count(DISTINCT m.chat_id), count(DISTINCT CASE WHEN c.is_group=1 THEN m.chat_id END)
            FROM messages m JOIN chats c USING(chat_id)
            WHERE \(cond)
            """) { w.chatCount = Int($0.int(0)); w.groupCount = Int($0.int(1)) }

        try store.db.query("""
            SELECT m.person, COALESCE(NULLIF(p.name,''), NULLIF(max(m.sender),''), m.person) nm, count(*) n
            FROM messages m LEFT JOIN people p ON p.person=m.person
            WHERE \(cond) AND m.from_me=0
              AND m.person IS NOT NULL AND m.person<>'unknown' AND m.person<>''
            GROUP BY m.person ORDER BY n DESC LIMIT 12
            """) {
            let name = $0.text(1) ?? ""
            guard !Self.isNumber(name) else { return }
            w.people.append(.init(key: $0.text(0) ?? "", name: name, count: Int($0.int(2))))
        }
        w.people = Array(w.people.prefix(8))
        try store.db.query("""
            SELECT count(DISTINCT m.person) FROM messages m
            WHERE \(cond) AND m.from_me=0
              AND m.person IS NOT NULL AND m.person<>'unknown' AND m.person<>''
            """) { w.peopleCount = Int($0.int(0)) }

        try store.db.query("""
            SELECT md.kind, count(*) n FROM media md JOIN messages m ON m.id=md.msg_id
            WHERE \(cond) AND m.type NOT IN \(excludedTypes) GROUP BY md.kind
            """) {
            let n = Int($0.int(1))
            switch $0.text(0) ?? "" {
            case "image": w.media = YearWrapped.Media(photos: n, videos: w.media.videos, voice: w.media.voice, docs: w.media.docs)
            case "video": w.media = YearWrapped.Media(photos: w.media.photos, videos: n, voice: w.media.voice, docs: w.media.docs)
            case "audio": w.media = YearWrapped.Media(photos: w.media.photos, videos: w.media.videos, voice: n, docs: w.media.docs)
            // A sticker is its own kind: counting it as a photo inflated the photo number, and
            // counting it as a document (the old default) was simply wrong.
            case "sticker": break
            default: w.media = YearWrapped.Media(photos: w.media.photos, videos: w.media.videos, voice: w.media.voice, docs: n)
            }
        }

        w.longest = try longestMessage(store: store, cond: cond)
        (w.laughs, w.laughMoment) = try laughs(store: store, cond: cond, reactions: reactions)
        (w.hearts, w.heartMoment) = try hearts(store: store, cond: cond)
        w.stickers = try Stickers.summary(store: store, year: year)

        var music = YearMusic.load(store: store, cond: cond)
        await music.titles(cache: cache, fetch: fetchTitles)
        w.tracks = music.tracks
        w.linksTotal = music.total
        w.linkSenders = music.senders
        w.topService = music.topService
        return w
    }

    // MARK: - Pieces

    static func day(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// A raw phone number or LID is not a name, so it never leads a sentence.
    static func isNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        return !t.contains(where: \.isLetter)
    }

    /// The best run of consecutive days with a message. 366 rows at most.
    static func streak(store: VaultStore, cond: String) throws -> Int {
        var days: [Date] = []
        try store.db.query("""
            SELECT DISTINCT date(m.ts/1000,'unixepoch','localtime') d FROM messages m
            WHERE \(cond) ORDER BY d
            """) { if let d = day($0.text(0) ?? "") { days.append(d) } }
        let cal = Calendar.current
        var best = days.isEmpty ? 0 : 1, run = days.isEmpty ? 0 : 1
        for i in 1..<max(days.count, 1) {
            let gap = cal.dateComponents([.day], from: cal.startOfDay(for: days[i - 1]), to: cal.startOfDay(for: days[i])).day ?? 99
            run = gap == 1 ? run + 1 : 1
            best = max(best, run)
        }
        return best
    }

    /// The longest thing a person actually typed: links and forwarded broadcasts
    /// are skipped, because a pasted URL is not a message that says the most.
    ///
    /// The runner-up is returned too: "nothing else came close" is a claim about the rest
    /// of the year, and with a 77- and a 76-character message it was simply false.
    static func longestMessage(store: VaultStore, cond: String) throws -> YearWrapped.Longest? {
        struct Row { let id: Int64, chatID: Int64, chat: String, ts: Date, me: Bool, sender: String, text: String, chars: Int }
        var rows: [Row] = []
        try store.db.query("""
            SELECT m.id, m.chat_id, c.name, m.ts, m.from_me, COALESCE(m.sender,''), COALESCE(m.text,''), length(m.text)
            FROM messages m JOIN chats c USING(chat_id)
            WHERE \(cond) AND m.type NOT IN \(excludedTypes) AND m.text IS NOT NULL AND length(m.text) > 0
            ORDER BY length(m.text) DESC LIMIT 50
            """) {
            rows.append(Row(id: $0.int(0), chatID: $0.int(1), chat: $0.text(2) ?? "", ts: VaultStore.date($0.int(3)),
                            me: $0.int(4) != 0, sender: $0.text(5) ?? "", text: store.resolveMentions($0.text(6) ?? ""),
                            chars: Int($0.int(7))))
        }
        // No `?? rows.first`: when every candidate is a link or a broadcast, the year has no
        // message worth naming and the card stays hidden.
        let typed = rows.filter { !$0.text.isEmpty && MediaLinks.links(in: $0.text).isEmpty && !DuoWrappedBuilder.isBroadcast($0.text) }
        guard let r = typed.first else { return nil }
        return YearWrapped.Longest(date: r.ts, author: r.me ? "You" : (r.sender.isEmpty ? "Someone" : r.sender),
                                   fromMe: r.me, chatName: r.chat, chatID: r.chatID, messageID: r.id,
                                   text: r.text, chars: r.chars, runnerUp: typed.dropFirst().first?.chars ?? 0)
    }

    /// Laughs are a real laugh back: either a quoted reply that scored, crediting the message
    /// it answered, or a laugh-emoji reaction naming the message it landed on. One message
    /// earns one laugh even if several people reacted; the moment score keeps the total.
    static func laughs(store: VaultStore, cond: String,
                       reactions: WrappedReactionDetector) throws -> (Int, YearWrapped.Moment?) {
        struct Reply { let targetUID: String, id: Int64, uid: String, chatID: Int64, ts: Date, me: Bool, sender: String, text: String, score: Int }
        var replies: [Reply] = []
        let hasReplies = ((try? store.db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='message_replies'")) ?? 0) > 0
        if hasReplies {
            try store.db.query("""
                SELECT r.target_uid, m.id, COALESCE(m.uid,''), m.chat_id, m.ts, m.from_me, COALESCE(m.sender,''), COALESCE(m.text,'')
                FROM message_replies r JOIN messages m ON m.uid=r.uid
                WHERE \(cond) AND m.type NOT IN \(excludedTypes) AND COALESCE(m.text,'')<>''
                ORDER BY m.ts DESC LIMIT 6000
                """) {
                let text = $0.text(7) ?? ""
                let score = reactions.laughScore(text)
                guard score > 0 else { return }
                replies.append(Reply(targetUID: $0.text(0) ?? "", id: $0.int(1), uid: $0.text(2) ?? "", chatID: $0.int(3),
                                     ts: VaultStore.date($0.int(4)), me: $0.int(5) != 0, sender: $0.text(6) ?? "",
                                     text: text, score: score))
            }
        }

        // Reactions are attached to the message they answered, so the year is the message's
        // year, not the reaction's. A reaction from the author is not a reaction from someone else.
        let reacted = try reactedMessages(store: store, cond: cond) { WrappedReactionDetector.isLaughEmoji($0) }

        var replyMoment: (score: Int, moment: YearWrapped.Moment)?
        if !replies.isEmpty {
            let best = replies.sorted { a, b in a.score != b.score ? a.score > b.score : a.ts > b.ts }.prefix(6)
            let uids = best.map { "'" + $0.targetUID.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
            struct Target { let id: Int64, uid: String, chatID: Int64, chat: String, ts: Date, me: Bool, person: String, sender: String, text: String }
            var targets: [String: Target] = [:]
            if !uids.isEmpty {
                try store.db.query("""
                    SELECT m.id, COALESCE(m.uid,''), m.chat_id, c.name, m.ts, m.from_me, COALESCE(m.person,''), COALESCE(m.sender,''), COALESCE(m.text,'')
                    FROM messages m JOIN chats c USING(chat_id)
                    WHERE m.uid IN (\(uids)) AND \(cond) AND COALESCE(m.text,'')<>''
                    """) {
                    let t = Target(id: $0.int(0), uid: $0.text(1) ?? "", chatID: $0.int(2), chat: $0.text(3) ?? "",
                                   ts: VaultStore.date($0.int(4)), me: $0.int(5) != 0, person: $0.text(6) ?? "",
                                   sender: $0.text(7) ?? "", text: $0.text(8) ?? "")
                    targets[t.uid] = t
                }
            }
            for r in best {
                guard let t = targets[r.targetUID] else { continue }
                var m = YearWrapped.Moment(
                    date: t.ts, author: t.me ? "You" : (t.sender.isEmpty ? "Someone" : t.sender), fromMe: t.me,
                    chatName: t.chat, text: WrappedCopy.quote(t.text, limit: 320),
                    reply: WrappedCopy.quote(r.text, limit: 120),
                    replyBy: r.me ? "You" : (r.sender.isEmpty ? "Someone" : r.sender), replyFromMe: r.me,
                    messageID: t.id, chatID: t.chatID, score: r.score, uid: t.uid)
                decorate(&m, authorKey: t.me ? "me" : t.person, store: store,
                         lead: QuotedReply(uid: r.uid, author: m.replyBy,
                                           text: WrappedCopy.quote(r.text, limit: 140), fromMe: r.me))
                replyMoment = (r.score, m)
                break
            }
        }

        var reactionMoment = reacted.first.map(reactionMoment(_:))
        if var m = reactionMoment?.1 {
            decorate(&m, authorKey: m.fromMe ? "me" : authorKey(of: m.messageID, store: store), store: store, lead: nil)
            reactionMoment = (reactionMoment?.0 ?? 0, m)
        }
        // The strongest single laugh wins; a reply breaks a tie because it carries words.
        let moment = [replyMoment, reactionMoment].compactMap { $0 }.max { a, b in
            a.0 != b.0 ? a.0 < b.0 : a.1.reply.count < b.1.reply.count
        }?.1
        return (replies.count + reacted.count, moment)
    }

    /// Attaches what the card prints beside a moment: how many people reacted, how that splits
    /// by emoji, and the replies that quoted it (the one that earned the moment first).
    static func decorate(_ m: inout YearWrapped.Moment, authorKey: String, store: VaultStore,
                         lead: QuotedReply?) {
        let extras = MomentReactionsLoader.load(store: store, chatID: m.chatID,
                                                targets: [.init(id: m.messageID, uid: m.uid,
                                                                author: authorKey)])[m.messageID]
        guard let extras else { return }
        m.reactors = extras.reactors
        m.reactionSummary = extras.summary
        m.quoted = MomentReactions.stack(lead: lead, others: extras.quoted)
    }

    /// The person key behind one message, so a self-reaction can be left out of the count.
    static func authorKey(of id: Int64, store: VaultStore) -> String {
        var key = ""
        try? store.db.query("SELECT COALESCE(m.person,'') FROM messages m WHERE m.id=\(id)") { key = $0.text(0) ?? "" }
        return key
    }

    /// One message that earned a reaction from someone else, with every matching emoji from
    /// every other reactor folded into one count.
    struct Reacted {
        let id: Int64, chatID: Int64, chat: String, ts: Date, me: Bool
        let sender: String, text: String, by: String, emoji: String, count: Int
        /// The message's stable identity and its author's person key, so the card can find the
        /// quoted replies and leave the author's own reaction out of the count.
        let uid: String, person: String
    }

    /// The shared reaction pass. `isMember` chooses the family (laughs, hearts), so the two
    /// stats use exactly the same attribution rules and can never drift apart:
    ///  * one message counts once, however many people tapped the same family;
    ///  * a reaction the author gave their own message is not a reaction from someone else;
    ///  * the reactor named on the card is a real person, resolved at import time.
    static func reactedMessages(store: VaultStore, cond: String,
                                isMember: (String) -> Bool) throws -> [Reacted] {
        guard ((try? store.db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='reactions'")) ?? 0) > 0 else { return [] }
        var grouped: [Int64: Reacted] = [:]
        try store.db.query("""
            SELECT m.id, m.chat_id, c.name, m.ts, m.from_me, COALESCE(m.person,''), COALESCE(m.sender,''),
                   COALESCE(m.text,''), r.sender, COALESCE(NULLIF(r.sender_name,''), r.sender), r.emoji,
                   COALESCE(m.uid,'')
            FROM reactions r JOIN messages m ON m.id=r.message_id JOIN chats c ON c.chat_id=m.chat_id
            WHERE \(cond) AND m.type NOT IN \(excludedTypes) AND COALESCE(m.text,'')<>''
            """) {
            let emoji = $0.text(10) ?? ""
            guard isMember(emoji) else { return }
            let me = $0.int(4) != 0
            let reactor = $0.text(8) ?? ""
            // Only the author reacting to their own message is excluded. The owner reacting to
            // someone else's message *is* a reaction from someone else, and used to be dropped.
            if me ? reactor == "me" : reactor == $0.text(5) { return }
            let id = $0.int(0)
            if var old = grouped[id] {
                old = Reacted(id: old.id, chatID: old.chatID, chat: old.chat, ts: old.ts, me: old.me, sender: old.sender,
                              text: old.text, by: old.by, emoji: old.emoji + emoji, count: old.count + 1,
                              uid: old.uid, person: old.person)
                grouped[id] = old
            } else {
                grouped[id] = Reacted(id: id, chatID: $0.int(1), chat: $0.text(2) ?? "", ts: VaultStore.date($0.int(3)),
                                      me: me, sender: $0.text(6) ?? "", text: $0.text(7) ?? "",
                                      by: $0.text(9) ?? "", emoji: emoji, count: 1,
                                      uid: $0.text(11) ?? "", person: $0.text(5) ?? "")
            }
        }
        return grouped.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.ts > $1.ts }
    }

    static func reactionMoment(_ r: Reacted) -> (Int, YearWrapped.Moment) {
        (r.count, YearWrapped.Moment(
            date: r.ts, author: r.me ? "You" : (r.sender.isEmpty ? "Someone" : r.sender), fromMe: r.me,
            chatName: r.chat, text: WrappedCopy.quote(r.text, limit: 320),
            reply: r.emoji, replyBy: r.by == "me" ? "You" : (r.by.isEmpty ? "Someone" : r.by), replyFromMe: r.by == "me",
            messageID: r.id, chatID: r.chatID, score: r.count, uid: r.uid))
    }

    /// Messages that earned a heart from someone else. Deliberately a separate pass from
    /// `laughs`: a ❤️ is affection, not a punchline, and the two counts never share a row.
    static func hearts(store: VaultStore, cond: String) throws -> (Int, YearWrapped.Moment?) {
        let reacted = try reactedMessages(store: store, cond: cond) { WrappedReactionDetector.isHeartEmoji($0) }
        let moment = reacted.first.map(reactionMoment(_:)).map { decorated($0.1, store: store) }
        return (reacted.count, moment)
    }

    /// A moment with the reaction count and quoted replies attached, resolving the author's
    /// person key itself so a self-reaction never counts.
    static func decorated(_ m: YearWrapped.Moment, store: VaultStore, lead: QuotedReply? = nil) -> YearWrapped.Moment {
        var out = m
        decorate(&out, authorKey: m.fromMe ? "me" : authorKey(of: m.messageID, store: store), store: store, lead: lead)
        return out
    }
}

/// Music and video links shared in one year, grouped by the thing shared.
struct YearMusic {
    var tracks: [YearWrapped.Track] = []
    var total = 0
    var senders: [YearWrapped.PersonCount] = []
    var topService: MediaService?

    private struct Event {
        let date: Date, me: Bool, sender: String, chatID: Int64, chatName: String, messageID: Int64
        let service: MediaService, kind: String, url: String, embed: String, key: String, slug: String?
    }

    static func load(store: VaultStore, cond: String) -> YearMusic {
        var events: [Event] = []
        try? store.db.query("""
            SELECT m.id, m.chat_id, c.name, m.ts, m.from_me, COALESCE(m.sender,''), COALESCE(m.text,'')
            FROM messages m JOIN chats c USING(chat_id)
            WHERE \(cond) AND m.type NOT IN \(YearWrappedBuilder.excludedTypes) AND \(YearWrappedBuilder.linkLike)
            ORDER BY m.ts, m.id
            """) {
            let ts = VaultStore.date($0.int(3)), me = $0.int(4) != 0
            let sender = $0.text(5) ?? "", chatID = $0.int(1), chatName = $0.text(2) ?? "", id = $0.int(0)
            for l in MediaLinks.links(in: $0.text(6) ?? "") {
                events.append(Event(date: ts, me: me, sender: sender, chatID: chatID, chatName: chatName, messageID: id,
                                    service: l.service, kind: l.kind, url: l.clean, embed: l.embed, key: l.key, slug: l.slug))
            }
        }
        var out = YearMusic()
        guard !events.isEmpty else { return out }
        out.total = events.count
        var svc: [MediaService: Int] = [:]
        for e in events { svc[e.service, default: 0] += 1 }
        out.topService = svc.max { $0.value < $1.value }.map(\.key)

        var counts: [String: Int] = [:]
        for e in events { counts[e.key, default: 0] += 1 }
        var shareCounts: [String: (name: String, n: Int)] = [:]
        for e in events {
            let name = e.me ? "You" : (e.sender.isEmpty ? "Someone" : e.sender)
            shareCounts[name, default: (name, 0)].n += 1
        }
        out.senders = shareCounts.values.sorted { $0.n > $1.n }.map { .init(key: $0.name, name: $0.name, count: $0.n) }

        // The song played most, then the most-repeated rest, then a spread so a quiet
        // year still has a soundtrack instead of one lonely card.
        var firstByKey: [String: Event] = [:]
        for e in events where firstByKey[e.key] == nil { firstByKey[e.key] = e }
        let ordered = counts.keys.sorted { a, b in
            counts[a] != counts[b] ? counts[a]! > counts[b]! : (firstByKey[a]?.date ?? .distantPast) < (firstByKey[b]?.date ?? .distantPast)
        }
        var picks: [String] = []
        func add(_ keys: [String], _ limit: Int) {
            for k in keys where picks.count < limit && !picks.contains(k) { picks.append(k) }
        }
        add(ordered, 6)
        if picks.count < min(4, ordered.count) { picks = Array(ordered.prefix(4)) }
        for k in picks {
            guard let first = firstByKey[k] else { continue }
            out.tracks.append(YearWrapped.Track(
                service: first.service, kind: first.kind, url: first.url, embed: first.embed,
                title: first.slug, author: nil, thumbnail: nil,
                firstDate: first.date, firstBy: first.me ? "You" : (first.sender.isEmpty ? "Someone" : first.sender),
                firstChat: first.chatName, times: counts[k] ?? 1, messageID: first.messageID, chatID: first.chatID))
        }
        return out
    }

    /// Cached titles first (always, no network); the services themselves only when asked.
    mutating func titles(cache: LinkMetaCache?, fetch: Bool) async {
        for i in tracks.indices {
            let key = "\(tracks[i].service.rawValue)|\(tracks[i].url)"
            if let m = cache?.get(key), !m.title.isEmpty {
                tracks[i].title = m.title
                tracks[i].author = m.author.isEmpty ? nil : m.author
                tracks[i].thumbnail = m.thumbnail
                continue
            }
            guard fetch else { continue }
            let link = SharedLink(messageID: tracks[i].messageID, chatID: tracks[i].chatID, uid: "", ts: tracks[i].firstDate,
                                  sender: tracks[i].firstBy, fromMe: tracks[i].firstBy == "You", chatName: tracks[i].firstChat,
                                  url: tracks[i].url, service: tracks[i].service, kind: tracks[i].kind,
                                  embedURL: tracks[i].embed, key: key, youtubeID: nil, slugTitle: tracks[i].title)
            guard let m = await MediaLinks.fetchMeta(link) else { continue }
            tracks[i].title = m.title
            tracks[i].author = m.author.isEmpty ? nil : m.author
            tracks[i].thumbnail = m.thumbnail
            cache?.put(key, m)
        }
    }
}
