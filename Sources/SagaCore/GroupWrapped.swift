import Foundation

/// A multi-person look back. Participant identity is the indexed person key, never the display name.
public struct GroupWrapped: Sendable {
    public struct Contributor: Sendable {
        public let key: String, name: String, messages: Int
    }
    public struct Funny: Sendable {
        public let key: String, name: String, laughsEarned: Int
        /// Messages this person wrote, so the ranking can be laughs *per message* rather
        /// than raw volume.
        public var messages: Int = 0
        /// Laughs earned per message written, 0…1.
        public var rate: Double { messages > 0 ? Double(laughsEarned) / Double(messages) : 0 }
    }
    public struct Moment: Sendable {
        public let date: Date, author: String, text: String, replyBy: String, reply: String, messageID: Int64
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
        public var title: String?
        public var author: String? = nil
        public var thumbnail: String? = nil
        public let firstDate: Date, firstBy: String, times: Int, messageID: Int64
    }
    public let chatID: Int64, name: String, total: Int
    public let contributors: [Contributor]
    public let monthly: [(month: String, count: Int)]
    /// Days with at least one message — the denominator for "a day" in the copy.
    public var activeDays = 0
    /// First to last message, inclusive, so two consecutive days read as two days.
    public var spanDays = 0
    public var first: Date? = nil, last: Date? = nil
    public var peakMonth: (month: String, count: Int)? = nil
    /// Who earned laughs from someone else, ranked by laughs per message.
    public var funniest: [Funny] = []
    /// Messages that earned at least one laugh-emoji reaction, counted inside `funniest`.
    public var laughsByReaction = 0
    /// Messages that earned at least one heart reaction from someone else. Separate from
    /// laughs: the room can find a line funny or love it, and those are two different facts.
    public var heartsByReaction = 0
    /// The message with the most hearts, when any message earned one.
    public var loved: Moment? = nil
    /// Share of the group's messages that earned a laugh, for the "spread evenly" sentence.
    public var laughRate: Double = 0
    /// The best rate after the leader, when there is someone to compare against.
    public var witRunnerUpRate: Double? {
        funniest.dropFirst().first { $0.messages >= GroupWrappedBuilder.minRateSample }?.rate
    }
    public var moments: [Moment] = []
    public var insideJokes: [DuoWrapped.Phrase] = []
    /// Most-used emoji, and the pair the group keeps putting together.
    public var emoji: [DuoWrapped.Phrase] = []
    public var emojiPair: (a: String, b: String, count: Int)? = nil
    public var linksTotal = 0
    public var linkSharers: [Contributor] = []
    public var tracks: [Track] = []
    public var serviceCounts: [(MediaService, Int)] = []
    /// Sticker sends in this room, distinct by SHA-256, and the busiest one.
    public var stickers = Stickers.Summary()
    public var hasMusic: Bool { linksTotal > 0 }
}

public enum GroupWrappedBuilder {
    /// Below this many messages a "laughs per message" rate is noise, so those people are
    /// ranked after everyone with a real sample.
    public static let minRateSample = 10

    public static func build(store: VaultStore, chatID: Int64, me: String, fetchTitles: Bool = false) async throws -> GroupWrapped {
        var name = "Group"
        try store.db.query("SELECT name FROM chats WHERE chat_id=\(chatID)") { name = $0.text(0) ?? name }
        struct M { let id: Int64, ts: Date, key: String, me: Bool, text: String, uid: String }
        var counts: [String: Int] = [:], names: [String: String] = [:], months: [String: Int] = [:]
        var msgs: [M] = []
        var first: Date?, last: Date?
        var days = Set<Int>()
        let cal = Calendar.current
        let mf = DateFormatter(); mf.locale = Locale(identifier: "en_US_POSIX"); mf.dateFormat = "yyyy-MM"
        try store.db.query("""
            SELECT m.from_me, m.person, m.sender, m.ts, m.id, COALESCE(m.text,''), COALESCE(m.uid,'') FROM messages m
            LEFT JOIN media md ON md.msg_id=m.id
            WHERE m.chat_id=\(chatID) AND m.type NOT IN (7,27,36,55,90)
              AND (COALESCE(m.text,'')<>'' OR md.kind IS NOT NULL) ORDER BY m.ts, m.id
            """) { row in
            let sender = row.text(2) ?? ""
            let key = row.int(0) != 0 ? "self" : row.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown:\(sender)"
            names[key] = row.int(0) != 0 ? me : sender.isEmpty ? "Unknown participant" : sender
            counts[key, default: 0] += 1
            let date = VaultStore.date(row.int(3))
            if first == nil { first = date }; last = date
            days.insert(Int(cal.startOfDay(for: date).timeIntervalSince1970 / 86_400))
            months[mf.string(from: date), default: 0] += 1
            msgs.append(M(id: row.int(4), ts: date, key: key, me: row.int(0) != 0,
                          text: store.resolveMentions(row.text(5) ?? ""), uid: row.text(6) ?? ""))
        }
        func ranked(_ c: [String: Int]) -> [String] { c.keys.sorted { c[$0] != c[$1] ? c[$0]! > c[$1]! : $0 < $1 } }
        func contributor(_ k: String, _ c: [String: Int]) -> GroupWrapped.Contributor { .init(key: k, name: names[k] ?? "Unknown participant", messages: c[k]!) }
        let contributors = ranked(counts).map { contributor($0, counts) }
        let monthly = first.flatMap { start in last.map { DuoWrappedBuilder.fillMonths(months, from: start, to: $0, f: mf) } } ?? []
        var w = GroupWrapped(chatID: chatID, name: name, total: counts.values.reduce(0, +), contributors: contributors, monthly: monthly)
        w.first = first; w.last = last; w.activeDays = days.count
        if let first, let last {
            w.spanDays = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: first),
                                                    to: cal.startOfDay(for: last)).day ?? 0) + 1)
        }
        w.peakMonth = monthly.max { $0.count != $1.count ? $0.count < $1.count : $0.month > $1.month }.flatMap { $0.count > 0 ? $0 : nil }
        guard msgs.count >= 2 else { return w }

        // Funniest: a laugh from a different person within 6 messages / 10 minutes credits the earlier author,
        // and so does a laugh-emoji reaction on the message itself — WhatsApp names the reactor and the
        // message, so that credit is exact rather than a proximity guess.
        let detector = WrappedReactionDetector()
        let scores = msgs.map { detector.laughScore($0.text) }
        let storedReactions = try MessageReactions.load(store.db, chatID: chatID)
        struct Hit { let score: Int, i: Int, replyBy: String, reply: String }
        var best: [Hit] = []
        var earned: [String: Int] = [:]
        var reactionHit = Set<Int>()          // messages already credited by a reaction
        for (i, m) in msgs.enumerated() {
            let laugh = (storedReactions[m.id] ?? []).filter { r in
                guard r.isLaugh else { return false }
                return m.me ? !r.isMine : r.sender != m.key          // a reaction on your own message is not a laugh from someone else
            }
            guard !laugh.isEmpty else { continue }
            let giver = laugh.first { !$0.isMine } ?? laugh[0]
            earned[m.key, default: 0] += 1
            w.laughsByReaction += 1
            reactionHit.insert(i)
            best.append(Hit(score: laugh.count, i: i,
                            replyBy: giver.isMine ? me : (giver.senderName.isEmpty ? "Unknown participant" : giver.senderName),
                            reply: laugh.map(\.emoji).joined()))
        }
        for i in msgs.indices where !msgs[i].text.isEmpty && i + 1 < msgs.count && !reactionHit.contains(i) {
            for j in (i + 1)..<min(i + 7, msgs.count) {
                guard msgs[j].ts.timeIntervalSince(msgs[i].ts) <= 600 else { break }
                if msgs[j].key != msgs[i].key, scores[j] >= 2 {
                    earned[msgs[i].key, default: 0] += 1
                    best.append(Hit(score: scores[j], i: i, replyBy: names[msgs[j].key] ?? "Unknown participant", reply: msgs[j].text))
                    break
                }
            }
        }
        w.funniest = ranked(earned).map { key in
            GroupWrapped.Funny(key: key, name: names[key] ?? "Unknown participant",
                               laughsEarned: earned[key]!, messages: counts[key] ?? 0)
        }
        // Rank by laughs per message, not by how much someone posted. A floor keeps a couple
        // of lucky reactions from crowning someone who wrote twice.
        w.funniest.sort { a, b in
            let aEnough = a.messages >= Self.minRateSample, bEnough = b.messages >= Self.minRateSample
            if aEnough != bEnough { return aEnough }
            if a.rate != b.rate { return a.rate > b.rate }
            if a.laughsEarned != b.laughsEarned { return a.laughsEarned > b.laughsEarned }
            return a.name < b.name
        }
        w.laughRate = Double(earned.values.reduce(0, +)) / Double(max(w.total, 1))

        // Hearts are a separate family: a message can be loved without being funny, and the
        // card must not add the two together. Same attribution rule as laughs.
        var bestHearts = 0
        for m in msgs {
            let hearts = (storedReactions[m.id] ?? []).filter { r in
                guard r.isHeart else { return false }
                return m.me ? !r.isMine : r.sender != m.key
            }
            guard !hearts.isEmpty else { continue }
            w.heartsByReaction += 1
            let giver = hearts.first { !$0.isMine } ?? hearts[0]
            let candidate = GroupWrapped.Moment(
                date: m.ts, author: names[m.key] ?? "Unknown participant",
                text: m.text.isEmpty ? "[media]" : DuoWrappedBuilder.clip(m.text, 240),
                replyBy: giver.isMine ? me : (giver.senderName.isEmpty ? "Someone" : giver.senderName),
                reply: hearts.map(\.emoji).joined(), messageID: m.id, uid: m.uid)
            if w.loved == nil || hearts.count > bestHearts
                || (hearts.count == bestHearts && m.ts > w.loved!.date) {
                bestHearts = hearts.count; w.loved = candidate
            }
        }
        // One moment per person, spread over the years, and never a forwarded announcement.
        let rankedBest = best
            .filter { !DuoWrappedBuilder.isBroadcast(msgs[$0.i].text) && !DuoWrappedBuilder.isBroadcast($0.reply) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : msgs[$0.i].ts < msgs[$1.i].ts }
        var seenAuthors = Set<String>(), seenYears = Set<Int>()
        func take(_ b: Hit) {
            let a = msgs[b.i]
            w.moments.append(.init(date: a.ts, author: names[a.key] ?? "Unknown participant", text: DuoWrappedBuilder.clip(a.text, 240),
                                   replyBy: b.replyBy, reply: DuoWrappedBuilder.clip(b.reply, 90), messageID: a.id, uid: a.uid))
        }
        for b in rankedBest where w.moments.count < 5 {
            let y = cal.component(.year, from: msgs[b.i].ts)
            if seenYears.contains(y) || seenAuthors.contains(msgs[b.i].key) { continue }
            seenYears.insert(y); seenAuthors.insert(msgs[b.i].key)
            take(b)
        }
        for b in rankedBest where w.moments.count < 5 {
            if seenAuthors.contains(msgs[b.i].key) { continue }
            seenAuthors.insert(msgs[b.i].key)
            take(b)
        }
        w.moments.sort { $0.date < $1.date }

        // What each card prints beside a moment: how many people reacted, how that splits by
        // emoji, and the replies that quoted it.
        if !w.moments.isEmpty || w.loved != nil {
            let byID = Dictionary(msgs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func author(_ id: Int64) -> String {
                guard let m = byID[id] else { return "" }
                return m.me ? "me" : m.key
            }
            func extras(_ id: Int64) -> MomentReactions {
                MomentReactionsLoader.load(store: store, chatID: chatID,
                                           targets: [.init(id: id, uid: byID[id]?.uid ?? "", author: author(id))])[id]
                    ?? MomentReactions()
            }
            for i in w.moments.indices {
                let e = extras(w.moments[i].messageID)
                w.moments[i].reactors = e.reactors
                w.moments[i].reactionSummary = e.summary
                w.moments[i].quoted = MomentReactions.stack(
                    lead: w.moments[i].reply.isEmpty ? nil : QuotedReply(uid: "moment-\(w.moments[i].messageID)",
                                                                         author: w.moments[i].replyBy,
                                                                         text: w.moments[i].reply,
                                                                         fromMe: w.moments[i].replyBy == me),
                    others: e.quoted)
            }
            if let loved = w.loved {
                let e = extras(loved.messageID)
                var m = loved
                m.reactors = e.reactors
                m.reactionSummary = e.summary
                m.quoted = e.quoted
                w.loved = m
            }
        }

        // Inside jokes: phrases this room alone uses, never a member's name.
        let dm = msgs.map { DuoWrappedBuilder.Msg(id: $0.id, ts: $0.ts, me: $0.me, text: $0.text, kind: nil) }
        w.insideJokes = try DuoWrappedBuilder.distinctive(store: store, chatID: chatID, msgs: dm,
                                                          participantNames: Array(names.values)).0
        w.stickers = try Stickers.summary(store: store, chatID: chatID)

        // Emoji: what the room actually types, plus a pair if one repeats.
        var emojiCount: [String: Int] = [:], pairCount: [String: Int] = [:]
        for m in msgs where !m.text.isEmpty {
            let found = DuoWrappedBuilder.emojis(in: m.text)
            for e in found { emojiCount[e, default: 0] += 1 }
            if found.count >= 2 { for i in 0..<(found.count - 1) { pairCount[found[i] + " " + found[i + 1], default: 0] += 1 } }
        }
        w.emoji = emojiCount.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8).map { .init(text: $0.key, count: $0.value) }
        if let p = pairCount.filter({ $0.value >= 2 }).max(by: { $0.value < $1.value }) {
            let parts = p.key.split(separator: " ").map(String.init)
            if parts.count == 2 { w.emojiPair = (parts[0], parts[1], p.value) }
        }

        // Music and video links
        typealias Link = (service: MediaService, kind: String, embed: String, key: String, clean: String, ytID: String?, slug: String?)
        var linkCounts: [String: Int] = [:], svc: [MediaService: Int] = [:]
        var byKey: [String: (link: Link, idx: Int, n: Int)] = [:]
        var order: [String] = []
        for (i, m) in msgs.enumerated() where !m.text.isEmpty {
            for l in MediaLinks.links(in: m.text) {
                linkCounts[m.key, default: 0] += 1; svc[l.service, default: 0] += 1
                if byKey[l.key] == nil { byKey[l.key] = (l, i, 0); order.append(l.key) }
                byKey[l.key]!.n += 1
            }
        }
        w.linksTotal = linkCounts.values.reduce(0, +)
        w.linkSharers = ranked(linkCounts).map { contributor($0, linkCounts) }
        w.serviceCounts = svc.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map { ($0.key, $0.value) }
        let picks = order.sorted { byKey[$0]!.n != byKey[$1]!.n ? byKey[$0]!.n > byKey[$1]!.n : byKey[$0]!.idx < byKey[$1]!.idx }.prefix(8)
        w.tracks = picks.map { k in
            let e = byKey[k]!, m = msgs[e.idx]
            return GroupWrapped.Track(service: e.link.service, kind: e.link.kind, url: e.link.clean, embed: e.link.embed, title: e.link.slug,
                                      firstDate: m.ts, firstBy: names[m.key] ?? "Unknown participant", times: e.n, messageID: m.id)
        }.sorted { $0.firstDate < $1.firstDate }
        if fetchTitles {
            for i in w.tracks.indices {
                let t = w.tracks[i]
                let sl = SharedLink(messageID: 0, chatID: 0, uid: "", ts: t.firstDate, sender: "", fromMe: false, chatName: "", url: t.url, service: t.service, kind: t.kind, embedURL: t.embed, key: "", youtubeID: nil, slugTitle: t.title)
                if let m = await MediaLinks.fetchMeta(sl) {
                    w.tracks[i].title = m.title
                    w.tracks[i].author = m.author.isEmpty ? nil : m.author
                    w.tracks[i].thumbnail = m.thumbnail
                }
            }
        }
        return w
    }
}
