import Foundation

/// "On this day": everything the archive holds for one calendar date, across every year.
///
/// Scripted, local and deterministic: counts, first/last message, the exchange that got the
/// biggest laugh (quoted replies plus the same laugh detection Wrapped uses), photos and
/// videos, and the music/video links shared that day. Nothing is exported and nothing leaves
/// the Mac. The view adds optional one-line captions from a local model.
public struct OnThisDay: Sendable {
    public struct PersonCount: Sendable, Identifiable {
        public let chatID: Int64
        public let name: String
        public let isGroup: Bool
        public let count: Int
        public var id: Int64 { chatID }
    }

    public struct Moment: Sendable, Identifiable {
        public let messageID: Int64
        /// Stable message identity. Row IDs change when the library is rebuilt, so
        /// anything durable (a cached caption) keys off this, never `messageID`.
        public let uid: String
        public let chatID: Int64
        public let chatName: String
        public let ts: Date
        public let sender: String
        public let fromMe: Bool
        public let text: String
        public let mediaKind: String?
        /// What someone replied when this made them laugh, e.g. "River: hahahaha 😂".
        public let reaction: String?
        public let reactionBy: String?
        public let reactionScore: Int
        public var id: String { "\(messageID)" }

        /// A display-safe one-liner: links become "Spotify track" instead of a raw URL,
        /// and anything longer than `limit` is clipped. The archive stores links as text,
        /// so a "last message" would otherwise be a wall of tracking parameters.
        public func preview(_ limit: Int = 120) -> String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                if mediaKind == "video" { return "A video" }
                if mediaKind != nil { return "A photo" }
                return "No text"
            }
            if let first = MediaLinks.links(in: t).first {
                var without = t
                for url in MediaLinks.urls(in: t) { without = without.replacingOccurrences(of: url, with: "") }
                without = without.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "–—-·,"))
                return without.isEmpty ? "\(first.service.rawValue) \(first.kind)" : OnThisDay.clip(without, limit)
            }
            return OnThisDay.clip(t, limit)
        }
    }

    public struct MediaItem: Sendable, Identifiable {
        public let messageID: Int64
        public let chatName: String
        public let ts: Date
        public let fromMe: Bool
        public let media: ChatMedia
        public var id: Int64 { messageID }
    }

    public struct Link: Sendable, Identifiable {
        public let messageID: Int64
        public let key: String
        public let url: String
        public let service: MediaService
        public let kind: String
        public let chatName: String
        public let sender: String
        public let fromMe: Bool
        public let ts: Date
        public let times: Int
        public var id: String { key }
    }

    public struct Year: Sendable, Identifiable {
        public let year: Int
        public let firstDay: Date
        public let count: Int
        public let sent: Int
        public let chatCount: Int
        /// The chats you talked in that day, busiest first (up to six).
        public let people: [PersonCount]
        public let first: Moment?
        public let last: Moment?
        public let highlight: Moment?
        public let media: [MediaItem]
        public let mediaCount: Int
        public let links: [Link]
        public var id: Int { year }
    }

    public struct StripYear: Sendable, Identifiable {
        public let year: Int
        public let count: Int
        /// False for 29 February in a non-leap year: the date simply did not exist.
        public let dateExists: Bool
        public var id: Int { year }
    }

    /// The compact hook the Home card shows. One year, one number, one human detail.
    public struct Peek: Sendable {
        public let year: Year
        public let headline: String
        public let detail: String
        public let media: MediaItem?
        public let link: Link?
    }

    public let month: Int
    public let day: Int
    /// Newest year first; only years that have something on this date.
    public let years: [Year]
    /// Every year between the first and last, including quiet ones, oldest first.
    public let strip: [StripYear]
    /// The earliest message in the archive on this date, whichever year it was.
    public let firstEver: Moment?
    public let total: Int
    public let generatedAt: Date

    public var isEmpty: Bool { total == 0 }
    public var quietYears: [Int] { strip.filter { $0.dateExists && $0.count == 0 }.map(\.year) }

    /// The most recent active year in the last six, preferring the busiest. Falls back to the
    /// newest year with messages. This is what "On this day, 3 years ago…" hooks onto.
    public var peek: Peek? {
        guard let first = years.first else { return nil }
        let nowYear = Calendar.current.component(.year, from: generatedAt)
        let recent = years.filter { $0.year < nowYear && $0.year >= nowYear - 6 }
        let pick = recent.max { $0.count < $1.count } ?? first
        var names = pick.people.prefix(2).map(\.name)
        if pick.people.count > 2 { names.append("+\(pick.people.count - 2) more") }
        let who = names.isEmpty ? "your archive" : names.joined(separator: " and ")
        var detail = "with \(who)"
        if let h = pick.highlight {
            detail += " · “\(h.preview(72))”"
        } else if let l = pick.links.first {
            detail += " · \(l.service.rawValue) \(l.kind)"
        } else if pick.mediaCount > 0 {
            detail += " · \(pick.mediaCount) photo\(pick.mediaCount == 1 ? "" : "s") and video\(pick.mediaCount == 1 ? "" : "s")"
        }
        return Peek(year: pick, headline: "\(pick.count.formatted()) messages", detail: detail,
                    media: pick.media.first, link: pick.links.first)
    }

    public static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)).trimmingCharacters(in: .whitespaces) + "…" : t
    }
}

public enum OnThisDayBuilder {
    /// Builds the view model for one calendar date. Uses local calendar dates, the same way
    /// Wrapped does, so a message at 00:10 belongs to the day the person remembers.
    public static func build(store: VaultStore, month: Int, day: Int,
                             calendar: Calendar = .current,
                             reactions: WrappedReactionDetector = WrappedReactionDetector(),
                             now: Date = Date()) throws -> OnThisDay {
        guard (1...12).contains(month), (1...31).contains(day) else {
            return OnThisDay(month: month, day: day, years: [], strip: [], firstEver: nil, total: 0, generatedAt: now)
        }
        guard try store.db.scalarInt("SELECT count(*) FROM messages") > 0 else {
            return OnThisDay(month: month, day: day, years: [], strip: [], firstEver: nil, total: 0, generatedAt: now)
        }
        let bounds = try store.tsBounds()
        guard bounds.min <= bounds.max else {
            return OnThisDay(month: month, day: day, years: [], strip: [], firstEver: nil, total: 0, generatedAt: now)
        }
        let firstYear = calendar.component(.year, from: bounds.min)
        let lastYear = calendar.component(.year, from: bounds.max)

        var years: [OnThisDay.Year] = []
        var strip: [OnThisDay.StripYear] = []
        let replies = try replyMap(store: store)
        for year in firstYear...lastYear {
            guard let range = dayRange(year: year, month: month, day: day, calendar: calendar) else {
                strip.append(.init(year: year, count: 0, dateExists: false))
                continue
            }
            let y = try buildYear(store: store, year: year, range: range,
                                  reactions: reactions, replies: replies)
            strip.append(.init(year: year, count: y.count, dateExists: true))
            if y.count > 0 { years.append(y) }
        }
        let ascending = years
        years.reverse()
        return OnThisDay(month: month, day: day, years: years, strip: strip,
                         firstEver: ascending.first?.first, total: ascending.reduce(0) { $0 + $1.count },
                         generatedAt: now)
    }

    /// A date that is worth showing: one of the archive's busiest calendar days, so
    /// "Surprise me" never lands on a blank page (unless the archive itself is empty).
    public static func surpriseDate(store: VaultStore, excluding month: Int? = nil, day: Int? = nil,
                                    random: inout RandomNumberGenerator) throws -> (month: Int, day: Int)? {
        var candidates: [(Int, Int)] = []
        try store.db.query("""
            SELECT CAST(strftime('%m',ts/1000,'unixepoch','localtime') AS INT) m,
                   CAST(strftime('%d',ts/1000,'unixepoch','localtime') AS INT) d,
                   count(*) n
            FROM messages GROUP BY m,d ORDER BY n DESC LIMIT 80
            """) { candidates.append((Int($0.int(0)), Int($0.int(1)))) }
        let usable = candidates.filter { !($0.0 == month && $0.1 == day) }
        guard !usable.isEmpty else { return nil }
        let pick = usable[Int.random(in: 0..<usable.count, using: &random)]
        return (pick.0, pick.1)
    }

    /// Last day of the archive, used to keep "next day" from walking past the end forever.
    public static func dateRange(store: VaultStore) throws -> (first: Date, last: Date)? {
        guard try store.db.scalarInt("SELECT count(*) FROM messages") > 0 else { return nil }
        let b = try store.tsBounds()
        return b.min <= b.max ? (b.min, b.max) : nil
    }

    // MARK: - One year

    private static func buildYear(store: VaultStore, year: Int, range: (Date, Date),
                                  reactions: WrappedReactionDetector, replies: [String: [String]]) throws -> OnThisDay.Year {
        let a = VaultStore.ms(range.0), b = VaultStore.ms(range.1)
        let visible = "m.type NOT IN (7,27,36,55,90) AND (COALESCE(m.text,'')<>'' OR EXISTS(SELECT 1 FROM media x WHERE x.msg_id=m.id))"
        var count = 0, sent = 0, chatCount = 0
        try store.db.query("""
            SELECT count(*), COALESCE(sum(m.from_me),0), count(DISTINCT m.chat_id) FROM messages m
            WHERE m.ts>=\(a) AND m.ts<\(b) AND \(visible)
            """) { count = Int($0.int(0)); sent = Int($0.int(1)); chatCount = Int($0.int(2)) }

        var people: [OnThisDay.PersonCount] = []
        try store.db.query("""
            SELECT c.chat_id, c.name, c.is_group, count(*) n FROM messages m JOIN chats c USING(chat_id)
            WHERE m.ts>=\(a) AND m.ts<\(b) AND \(visible)
            GROUP BY c.chat_id ORDER BY n DESC, c.name LIMIT 6
            """) {
            people.append(.init(chatID: $0.int(0), name: $0.text(1) ?? "?", isGroup: $0.int(2) == 1, count: Int($0.int(3))))
        }

        let messages = try dayMessages(store: store, from: a, to: b, visible: visible, reactions: reactions)
        let first = messages.min { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }.map(moment)
        let last = messages.max { $0.ts != $1.ts ? $0.ts < $1.ts : $0.id < $1.id }.map(moment)
        let highlight = try highlight(store: store, messages: messages, reactions: reactions, replies: replies)

        var media: [OnThisDay.MediaItem] = []
        try store.db.query("""
            SELECT md.msg_id, c.name, m.ts, m.from_me, md.kind, md.file_path, md.size, md.mime, md.file_hash, md.caption, m.uid
            FROM media md JOIN messages m ON m.id=md.msg_id JOIN chats c ON c.chat_id=m.chat_id
            WHERE m.ts>=\(a) AND m.ts<\(b) AND md.kind IN ('image','video')
            ORDER BY m.ts, md.msg_id LIMIT 120
            """) {
            let mediaKind = $0.text(4) ?? "image"
            media.append(.init(messageID: $0.int(0), chatName: $0.text(1) ?? "", ts: VaultStore.date($0.int(2)),
                               fromMe: $0.int(3) != 0,
                               media: ChatMedia(uid: $0.text(10) ?? "", kind: mediaKind, filePath: $0.text(5),
                                                size: $0.int(6), mime: $0.text(7), fileHash: $0.text(8),
                                                caption: $0.text(9))))
        }
        let mediaCount = Int(try store.db.scalarInt("""
            SELECT count(*) FROM media md JOIN messages m ON m.id=md.msg_id
            WHERE m.ts>=\(a) AND m.ts<\(b) AND md.kind IN ('image','video')
            """))

        var links: [OnThisDay.Link] = []
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        for m in messages {
            for l in MediaLinks.links(in: m.text) {
                counts[l.key, default: 0] += 1
                guard seen.insert(l.key).inserted else { continue }
                links.append(.init(messageID: m.id, key: l.key, url: l.clean, service: l.service, kind: l.kind,
                                   chatName: m.chatName, sender: m.fromMe ? "You" : m.sender, fromMe: m.fromMe,
                                   ts: m.ts, times: 1))
            }
        }
        // Same link shared twice that day still shows once, but says so.
        links = links.map { link in
            OnThisDay.Link(messageID: link.messageID, key: link.key, url: link.url, service: link.service, kind: link.kind,
                           chatName: link.chatName, sender: link.sender, fromMe: link.fromMe, ts: link.ts,
                           times: counts[link.key] ?? 1)
        }
        links.sort { $0.ts < $1.ts }

        return OnThisDay.Year(year: year, firstDay: range.0, count: count, sent: sent, chatCount: chatCount,
                              people: people, first: first, last: last, highlight: highlight,
                              media: media, mediaCount: mediaCount, links: Array(links.prefix(12)))
    }

    // MARK: - Messages and the funniest exchange

    private struct DayMessage {
        let id: Int64
        let chatID: Int64
        let chatName: String
        let ts: Date
        let fromMe: Bool
        let sender: String
        let text: String
        let uid: String
        let mediaKind: String?
        var laugh: Int
    }

    private static func dayMessages(store: VaultStore, from a: Int64, to b: Int64, visible: String,
                                    reactions: WrappedReactionDetector) throws -> [DayMessage] {
        var out: [DayMessage] = []
        try store.db.query("""
            SELECT m.id, m.chat_id, c.name, m.ts, m.from_me, m.sender, COALESCE(m.text,''), m.uid, md.kind
            FROM messages m JOIN chats c USING(chat_id) LEFT JOIN media md ON md.msg_id=m.id
            WHERE m.ts>=\(a) AND m.ts<\(b) AND \(visible)
            ORDER BY m.chat_id, m.ts, m.id
            """) {
            let text = store.resolveMentions($0.text(6) ?? "")
            out.append(DayMessage(id: $0.int(0), chatID: $0.int(1), chatName: $0.text(2) ?? "", ts: VaultStore.date($0.int(3)),
                                  fromMe: $0.int(4) != 0, sender: $0.text(5) ?? "", text: text, uid: $0.text(7) ?? "",
                                  mediaKind: $0.text(8),
                                  laugh: hasLaughSignal(text) ? reactions.laughScore(text) : 0))
        }
        return out
    }

    /// The day's best exchange. A message scores when someone laughs back at it: a quoted reply
    /// at any distance, or a reply within five minutes in the same chat. With no laughter at all,
    /// the funniest thing said that day stands in on its own.
    /// Every quoted reply in the index, keyed by the message it replies to. Read once per
    /// build: `message_replies` has no index on `target_uid`, so a per-year scan was the
    /// difference between a 1.5 s day and an instant one.
    private static func replyMap(store: VaultStore) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        try store.db.query("SELECT uid, target_uid FROM message_replies") { row in
            guard let reply = row.text(0), let target = row.text(1) else { return }
            out[target, default: []].append(reply)
        }
        return out
    }

    private static func highlight(store: VaultStore, messages: [DayMessage],
                                  reactions: WrappedReactionDetector, replies: [String: [String]]) throws -> OnThisDay.Moment? {
        guard !messages.isEmpty else { return nil }
        var score = [String: Int]()
        var sample = [String: (text: String, by: String, score: Int)]()
        var byUID: [String: Int] = [:]
        for (i, m) in messages.enumerated() where !m.uid.isEmpty { byUID[m.uid] = i }

        func content(_ m: DayMessage) -> Bool {
            m.mediaKind != nil || (m.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6 && m.laugh == 0)
        }

        // A. Quoted replies, even if the reply came later: "this is the one that made them laugh".
        var targetsByReply: [String: [String]] = [:] // reply uid -> target uids in this day
        var allReplyUIDs: [String] = []
        for (target, replyUIDs) in replies where byUID[target] != nil {
            for reply in replyUIDs { targetsByReply[reply, default: []].append(target); allReplyUIDs.append(reply) }
        }
        for batch in stride(from: 0, to: allReplyUIDs.count, by: 400).map({ Array(allReplyUIDs[$0..<min($0 + 400, allReplyUIDs.count)]) }) {
            let list = batch.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
            try store.db.query("""
                SELECT m.uid, m.from_me, m.sender, COALESCE(m.text,'')
                FROM messages m WHERE m.uid IN (\(list))
                """) { row in
                guard let replyUID = row.text(0) else { return }
                let reply = DayMessage(id: 0, chatID: 0, chatName: "", ts: Date(), fromMe: row.int(1) != 0,
                                       sender: row.text(2) ?? "", text: row.text(3) ?? "", uid: "", mediaKind: nil, laugh: 0)
                for target in targetsByReply[replyUID] ?? [] {
                    guard let i = byUID[target], content(messages[i]) else { continue }
                    let s = reactions.laughScore(row.text(3) ?? "")
                    guard s > 0, reply.fromMe != messages[i].fromMe else { continue }
                    score[target, default: 0] += s
                    if sample[target] == nil || s > sample[target]!.score {
                        sample[target] = ("\(reply.sender): \(OnThisDay.clip(row.text(3) ?? "", 90))", reply.sender, s)
                    }
                }
            }
        }

        // B. Laughter inside the day: same chat, other person, within five minutes.
        for i in messages.indices where content(messages[i]) {
            var j = i + 1
            while j < messages.count, messages[j].chatID == messages[i].chatID,
                  messages[j].ts.timeIntervalSince(messages[i].ts) <= 300, j - i <= 40 {
                let reply = messages[j]
                if reply.laugh > 0, reply.fromMe != messages[i].fromMe {
                    if !messages[i].uid.isEmpty { score[messages[i].uid, default: 0] += reply.laugh }
                    if !messages[i].uid.isEmpty, sample[messages[i].uid] == nil || reply.laugh > sample[messages[i].uid]!.score {
                        sample[messages[i].uid] = ("\(reply.sender): \(OnThisDay.clip(reply.text, 90))", reply.sender, reply.laugh)
                    }
                    break
                }
                j += 1
            }
        }

        var best: (Int, Int)? = nil     // index, score
        for i in messages.indices where content(messages[i]) {
            let s = messages[i].uid.isEmpty ? 0 : (score[messages[i].uid] ?? 0)
            guard s > 0 else { continue }
            if best == nil || s > best!.1 || (s == best!.1 && messages[i].ts < messages[best!.0].ts) { best = (i, s) }
        }
        if let best {
            let m = messages[best.0], s = sample[m.uid]
            return OnThisDay.Moment(messageID: m.id, uid: m.uid, chatID: m.chatID, chatName: m.chatName, ts: m.ts, sender: m.sender,
                                    fromMe: m.fromMe, text: m.text, mediaKind: m.mediaKind, reaction: s?.text,
                                    reactionBy: s?.by, reactionScore: best.1)
        }

        // C. Nobody laughed back, but someone did laugh. Show the day's biggest laugh.
        if let i = messages.indices.filter({ messages[$0].laugh > 0 && !messages[$0].text.isEmpty })
            .max(by: { a, b in
                messages[a].laugh != messages[b].laugh ? messages[a].laugh < messages[b].laugh : messages[a].ts > messages[b].ts
            }) {
            let m = messages[i]
            return OnThisDay.Moment(messageID: m.id, uid: m.uid, chatID: m.chatID, chatName: m.chatName, ts: m.ts, sender: m.sender,
                                    fromMe: m.fromMe, text: m.text, mediaKind: m.mediaKind, reaction: nil,
                                    reactionBy: nil, reactionScore: m.laugh)
        }
        return nil
    }

    /// Cheap pre-filter before the full laugh detector. The detector runs several Unicode
    /// regexes per message, which costs ~0.4 ms; on a ten-year date that is most of the build.
    /// Only texts that can possibly score get the expensive path.
    static func hasLaughSignal(_ text: String) -> Bool {
        let t = text.lowercased()
        for token in ["hah", "haa", "heh", "hee", "lol", "lmao", "lmfao", "rofl", "हा", "hasi", "hassi"] where t.contains(token) {
            return true
        }
        for emoji in ["😂", "🤣", "💀", "😆", "😹", "☠"] where t.contains(emoji) { return true }
        return false
    }

    private static func moment(_ m: DayMessage) -> OnThisDay.Moment {
        OnThisDay.Moment(messageID: m.id, uid: m.uid, chatID: m.chatID, chatName: m.chatName, ts: m.ts, sender: m.sender,
                         fromMe: m.fromMe, text: m.text, mediaKind: m.mediaKind, reaction: nil,
                         reactionBy: nil, reactionScore: 0)
    }

    // MARK: - Calendar

    /// Midnight-to-midnight for one calendar date, or nil when the date does not exist
    /// (29 February in a non-leap year). Calendar time zones and DST are respected.
    static func dayRange(year: Int, month: Int, day: Int, calendar: Calendar) -> (Date, Date)? {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        guard let raw = calendar.date(from: c) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: raw)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        let start = calendar.startOfDay(for: raw)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }
}

extension VaultStore {
    /// First and last message timestamps, read through the ts index.
    public func tsBounds() throws -> (min: Date, max: Date) {
        var lo = Date(), hi = Date()
        try db.query("SELECT min(ts), max(ts) FROM messages") {
            lo = Self.date($0.int(0)); hi = Self.date($0.int(1))
        }
        return (lo, hi)
    }
}
