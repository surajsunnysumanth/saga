import Foundation

/// The words Saga Wrapped uses.
///
/// Kept apart from the builder and the renderers so every sentence is one
/// testable function, and so the native story and the exported page say exactly
/// the same thing. The rules the copy follows:
///
/// - every claim carries a number, a name or a date — never a sentence that
///   would read the same in any other chat;
/// - no fixed superlative: the winner is computed and a tie says so;
/// - no repeated section opener ("The group chat discusses…");
/// - every sentence reads correctly for 1, 2 and many, and returns `nil`
///   rather than printing a nonsense zero.
public enum WrappedCopy {

    // MARK: - Formatting primitives

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// 41,203
    public static func n(_ i: Int) -> String { numberFormatter.string(from: NSNumber(value: i)) ?? "\(i)" }

    public static func pct(_ a: Int, of b: Int) -> Int { b == 0 ? 0 : Int((100.0 * Double(a) / Double(b)).rounded()) }

    public static func date(_ d: Date, _ format: String = "d MMM yyyy") -> String {
        if format == "d MMM yyyy" { return dateFormatter.string(from: d) }
        if format == "MMMM yyyy" { return monthFormatter.string(from: d) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = format
        return f.string(from: d)
    }

    /// "2023-06" → "June 2023"
    public static func month(_ key: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"
        return f.date(from: key).map { monthFormatter.string(from: $0) } ?? key
    }

    public static func day(_ n: Int) -> String { n == 1 ? "1 day" : "\(self.n(n)) days" }

    public static func time(_ n: Int) -> String { n == 1 ? "once" : "\(self.n(n)) times" }

    public static func people(_ n: Int) -> String { n == 1 ? "one person" : "\(self.n(n)) people" }

    /// "1 message" / "3 messages" — the one place a count meets a noun.
    ///
    /// Every "N nouns" in the copy goes through this (or through `noun`), so a count of
    /// one can never print "1 laughs" again. Pass an explicit plural when adding an "s"
    /// would be wrong ("song or video" → "songs and videos", "reply" → "replies").
    public static func plural(_ n: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        "\(self.n(n)) \(noun(n, singular, pluralForm))"
    }

    /// "message" / "messages" — the bare noun, for labels that print the number separately.
    public static func noun(_ n: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        if n == 1 { return singular }
        return pluralForm ?? singular + "s"
    }

    public static func hour(_ h: Int) -> String { h == 0 ? "12 am" : h < 12 ? "\(h) am" : h == 12 ? "12 pm" : "\(h - 12) pm" }

    /// 4:12 am — the exact clock time, for a message worth naming.
    public static func clock(hour h: Int, minute m: Int) -> String {
        let suffix = h < 12 ? "am" : "pm"
        let display = h == 0 ? 12 : h > 12 ? h - 12 : h
        return "\(display):" + String(format: "%02d", m) + " " + suffix
    }

    /// A duration in seconds, phrased the way a person would say it.
    ///
    /// Under a minute the number itself is the interesting part ("42 seconds"), so it is
    /// never folded into "under a minute" — that phrase made every quick chat look the same.
    public static func duration(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite else { return "a while" }
        if s < 60 {
            let n = max(1, Int(s.rounded()))
            return n == 1 ? "1 second" : "\(n) seconds"
        }
        if s < 90 { return "about a minute" }
        if s < 3600 { return "\(Int((s / 60).rounded())) min" }
        if s < 5400 { return "about an hour" }
        if s < 86400 * 2 { return String(format: "%.1f hr", s / 3600) }
        return "\(Int((s / 86400).rounded())) days"
    }

    /// "12" / "3.4" — no trailing .0.
    static func rate(_ x: Double) -> String {
        if abs(x.rounded() - x) < 0.05 { return n(Int(x.rounded())) }
        return String(format: "%.1f", x)
    }

    // MARK: - Cover

    /// "You two sent 41,203 messages."
    public static func opening(total: Int) -> String {
        switch total {
        case 0: return "Nothing in here yet."
        case 1: return "You two sent one message. It's a start."
        default: return "You two sent \(n(total)) messages."
        }
    }

    /// "59 days, 60 of them with something to say." — the day-count sentence.
    /// Fixes the old "across 59 days and 60 days you actually talked".
    public static func span(spanDays: Int, activeDays: Int, first: Date) -> String {
        let span = max(spanDays, 1), active = max(activeDays, 0)
        if span == 1 { return "All of it on \(date(first, "d MMMM yyyy"))." }
        if active >= span { return "\(day(active)), every single one of them with something in it." }
        if active == 0 { return "\(day(span)) on the calendar, none of them with a message." }
        if active == 1 { return "\(n(span)) days apart, with one day of actual talking." }
        return "\(day(span)), \(n(active)) of them with something to say."
    }

    /// "In 2023 alone that was 12 per day you talked."
    ///
    /// The denominator is the days with a message, so the sentence says so: dividing by
    /// active days and then calling the result "a day" described a chat that wrote on two
    /// days as if it wrote every day.
    public static func pace(count: Int, year: Int, activeDays: Int) -> String? {
        guard count > 0, activeDays > 0 else { return nil }
        let perDay = Double(count) / Double(activeDays)
        if perDay < 1 { return "In \(year) that was \(n(count)) messages in all." }
        if activeDays == 1 { return "In \(year) that was \(n(count)) messages on the one day it was used." }
        return "In \(year) alone that was \(rate(perDay)) per day you talked."
    }

    // MARK: - Balance

    public static func balance(me: String, them: String, mine: Int, theirs: Int) -> String? {
        let total = mine + theirs
        guard total > 0 else { return nil }
        let spread = abs(mine - theirs)
        if spread == 0 { return "You split the messages exactly down the middle — \(n(mine)) each." }
        if Double(spread) <= Double(total) * 0.01 {
            return "Practically even: \(n(mine)) from you, \(n(theirs)) from \(them)."
        }
        if mine > theirs { return "You sent \(pct(mine, of: total))% of them — \(n(mine)) to \(n(theirs))." }
        return "\(them) sent \(pct(theirs, of: total))% of them — \(n(theirs)) to \(n(mine))."
    }

    /// "You answer in 37 min; Meera Nair takes 2.6 hr." — and nothing at all when the
    /// chat has too few replies to say what either person's typical answer is.
    ///
    /// `samples` counts answers that landed inside a day; `slow` counts answers that took
    /// longer. A handful of turns is an anecdote, not a habit, so the sentence waits for
    /// three. "Takes a day or more" is only printed when every answer that person gave
    /// took a day, never because the fast ones were missing.
    public static func replyRace(me: String, them: String, mine: Double?, theirs: Double?,
                                 mineSamples: Int, theirsSamples: Int,
                                 mineSlow: Int = 0, theirsSlow: Int = 0) -> String? {
        let enoughMine = mineSamples >= 3, enoughTheirs = theirsSamples >= 3
        func theirsTail() -> String { theirsSlow > 0 ? " \(them) takes a day or more." : "" }
        func mineTail() -> String { mineSlow > 0 ? " You take a day or more." : "" }

        guard enoughMine || enoughTheirs else {
            if mineSlow + theirsSlow > 0 { return "Neither of you is in a hurry: no reply landed inside a day." }
            return nil
        }
        switch (enoughMine ? mine : nil, enoughTheirs ? theirs : nil) {
        case let (m?, nil):
            return "You usually reply in \(duration(m))." + theirsTail()
        case let (nil, t?):
            return "\(them) usually replies in \(duration(t))." + mineTail()
        case let (m?, t?):
            if m == 0 || t == 0 { return nil }
            if abs(m - t) <= 0.15 * max(m, t) { return "You both answer in about \(duration(m)). Neither of you keeps the other waiting." }
            if m < t { return "You answer in \(duration(m)); \(them) takes \(duration(t))." }
            return "\(them) answers in \(duration(t)); you take \(duration(m))."
        default:
            return nil
        }
    }

    public static func conversations(me: String, them: String, mine: Int, theirs: Int) -> String? {
        let total = mine + theirs
        guard total > 0 else { return nil }
        if mine == theirs { return "You start conversations equally often — \(time(mine)) each." }
        if mine > theirs { return "You start \(pct(mine, of: total))% of them — \(n(mine)) to \(n(theirs))." }
        return "\(them) starts \(pct(theirs, of: total))% of them — \(n(theirs)) to \(n(mine))."
    }

    // MARK: - First message

    public static func firstKicker(text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let greetings: Set<String> = ["hi", "hey", "hello", "yo", "hola", "hiya", "namaste", "good morning", "morning"]
        if greetings.contains(lower) || greetings.contains(where: { lower.hasPrefix($0 + " ") && lower.count < 24 }) {
            return "No grand opening. Just a hello."
        }
        if t.hasSuffix("?") { return "A question first, so someone had to answer." }
        if !emoji(in: t).isEmpty { return "Straight in with an emoji." }
        if t.count > 200 { return "A long first message. Bold way to begin." }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if words == 1 { return "One word, and it stuck." }
        if words <= 4 { return "\(words) words, and it stuck." }
        return "It didn't need to be clever."
    }

    static func emoji(in t: String) -> [String] {
        t.filter { ch in ch.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x238C) } }.map(String.init)
    }

    /// "Jules's" / "your" — a possessive that also reads when the name is the word "You".
    public static func possessive(_ name: String) -> String {
        if name.lowercased() == "you" { return "Your" }
        return "\(name)'s"
    }

    /// Present-tense verb agreement for a display name ("You write", "Jules writes").
    static func verb(_ name: String, singular: String, plural: String) -> String {
        name.lowercased() == "you" ? plural : singular
    }

    // MARK: - Laughs

    public static func laughs(me: String, them: String, madeThemLaugh: Int, madeMeLaugh: Int,
                              peakMonth: (month: String, count: Int)?) -> String {
        let peak = peakMonth.map { " Peak month: \(month($0.month)), \(plural($0.count, "laugh"))." } ?? ""
        switch (madeThemLaugh, madeMeLaugh) {
        case (0, 0): return "No laugh-out-louds in here. Very serious correspondence."
        case let (a, b) where a == b: return "Dead even: you each got \(plural(a, "laugh")) out of the other.\(peak)"
        default:
            // The owner is always "you" here, whatever display name the builder was given:
            // a story cannot say "You two sent 2,200 messages" and then "Suraj's messages".
            let iLead = madeThemLaugh > madeMeLaugh
            let opener = iLead ? "Your messages drew" : "\(them)'s messages drew"
            let quieter = iLead ? them : "you"
            let high = max(madeThemLaugh, madeMeLaugh), low = min(madeThemLaugh, madeMeLaugh)
            let tail = low == 0 ? " Nothing came back the other way." : " \(n(low)) went back the other way."
            return "\(opener) \(plural(high, "laugh")) from \(quieter).\(tail)\(peak)"
        }
    }

    // MARK: - Hearts

    /// "12 of your messages got a heart, against 8 of theirs." — affection, counted
    /// separately from laughs and never added to them.
    public static func hearts(me: String, them: String, mine: Int, theirs: Int) -> String? {
        guard mine + theirs > 0 else { return nil }
        if mine == theirs {
            return "Hearts landed evenly: \(plural(mine, "message")) of yours and \(n(theirs)) of theirs."
        }
        if mine > theirs {
            return "\(plural(mine, "message")) of yours got a heart, against \(n(theirs)) of theirs."
        }
        return "\(plural(theirs, "message")) of \(them)'s got a heart, against \(n(mine)) of yours."
    }

    // MARK: - Stickers

    /// "41 stickers went round, 12 of them different. One did a lot of the work: sent 27 times."
    ///
    /// A sticker has no words, so the card names counts instead of pretending to quote it.
    /// `distinct` is the number of different files (by SHA-256), not a count of sends.
    public static func stickers(total: Int, distinct: Int, topCount: Int) -> String? {
        guard total > 0 else { return nil }
        let head = total == 1 ? "One sticker went round."
            : "\(n(total)) stickers went round, \(n(max(distinct, 1))) of them different."
        guard topCount >= 2 else { return head }
        if distinct <= 1 { return head + " It was the same one every time." }
        return head + " One did a lot of the work: sent \(n(topCount)) times."
    }

    // MARK: - Clock

    public static func night(me: String, them: String, mine: Int, theirs: Int) -> String? {
        let total = mine + theirs
        guard total >= 20 else { return nil }
        if mine == theirs { return "\(n(mine)) messages each between midnight and 5 am. Two night owls." }
        let boss = mine > theirs ? "You" : them
        return "\(n(total)) messages went out between midnight and 5 am. \(boss) sent \(pct(max(mine, theirs), of: total))% of them."
    }

    /// "The 3 am message" — a clock time, an author and the text itself.
    public static func nightOwlLead(author: String, hour: Int, minute: Int, on day: Date) -> String {
        "\(author) at \(clock(hour: hour, minute: minute)), \(date(day, "d MMMM yyyy"))"
    }

    // MARK: - Years

    public static func quietYear(year: Int, count: Int, nextYear: Int?, nextCount: Int?) -> String? {
        guard count >= 0 else { return nil }
        let base = "\(year) went quiet — \(plural(count, "message")) in twelve months."
        guard let nextYear, let nextCount, nextCount > max(count * 2, count + 50) else { return base }
        return base + " Then \(nextYear) picked straight back up."
    }

    public static func peakMonth(month key: String, count: Int, total: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(month(key)) was the loudest month: \(plural(count, "message")), \(pct(count, of: total))% of the whole thing."
    }

    public static func streak(days: Int, ended: Date?) -> String? {
        guard days > 1 else { return nil }
        guard let ended else { return "\(plural(days, "day")) in a row at the best run." }
        return "\(plural(days, "day")) in a row at the best run, ending \(date(ended))."
    }

    public static func gap(days: Int, from: Date?, to: Date?, brokenBy: String) -> String? {
        guard days >= 14 else { return nil }
        let when: String
        if let from, let to {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMMM yyyy"
            let a = f.string(from: from), b = f.string(from: to)
            when = a == b ? a : "\(a) to \(b)"
        } else { when = "somewhere in the middle" }
        return "The longest silence was \(n(days)) days, \(when). \(brokenBy) broke it."
    }

    // MARK: - Emoji

    public static func emojiPair(a: String, b: String, count: Int) -> String {
        "\(a)\(b) is your signature pair — \(n(count)) times, side by side."
    }

    public static func emojiLeaders(me: String, them: String, mine: String?, theirs: String?) -> String? {
        switch (mine, theirs) {
        case let (m?, t?) where m == t: return "You both reach for \(m) more than anything else."
        case let (m?, t?): return "You reach for \(m); \(them) reaches for \(t)."
        case let (m?, nil): return "You reach for \(m). \(them) is harder to pin down."
        case let (nil, t?): return "\(them) reaches for \(t). You are harder to pin down."
        default: return nil
        }
    }

    // MARK: - Music

    /// "You traded 39 songs and videos — 13 from you, 26 from Meera Nair. 7 were the same
    /// link sent by both of you."
    ///
    /// One link sent by one person is not a trade, so a one-way soundtrack says so, and
    /// the owner is "you" here even when the builder was handed a display name.
    public static func soundtrack(me: String, them: String, total: Int, mine: Int, theirs: Int, twins: Int) -> String? {
        guard total > 0 else { return nil }
        var line: String
        if mine == 0 || theirs == 0 {
            let who = mine == 0 ? them : "you"
            line = total == 1
                ? "One song or video went round in here, from \(who)."
                : "\(n(total)) songs and videos went round, every one of them from \(who)."
        } else if mine == theirs {
            line = "You traded \(n(total)) songs and videos — \(n(mine)) each."
        } else {
            line = "You traded \(n(total)) songs and videos — \(n(mine)) from you, \(n(theirs)) from \(them)."
        }
        if twins == 1 { line += " One was the same link sent by both of you." }
        else if twins > 1 { line += " \(n(twins)) were the same link sent by both of you." }
        return line
    }

    public static func trackDetail(by: String, date: Date, times: Int) -> String {
        let shared = times > 1 ? " · \(n(times)) times in all" : ""
        return "\(by) sent it on \(self.date(date))\(shared)"
    }

    // MARK: - Inside jokes

    public static func jokes(count: Int, top: String?, topCount: Int) -> String? {
        guard count > 0 else { return nil }
        let head = "\(plural(count, "phrase")) \(count == 1 ? "lives" : "live") only in this chat."
        guard let top else { return head }
        return head + " “\(top)” leads, \(time(topCount))."
    }

    // MARK: - Superlatives

    /// "Your longest message is 1,204 characters; theirs is 321."
    ///
    /// A person who never sent anything has no longest message, so a one-sided chat is
    /// described from the side that spoke instead of printing "0 characters".
    public static func longestMessage(me: String, them: String, mine: Int, theirs: Int) -> String? {
        guard max(mine, theirs) > 0 else { return nil }
        if mine == 0 { return "You didn't send one; \(them)'s record is \(n(theirs)) characters." }
        if theirs == 0 { return "\(them) didn't send one; your record is \(n(mine)) characters." }
        if mine == theirs { return "Your longest messages are both \(n(mine)) characters. Symmetry." }
        return "Your longest message is \(n(mine)) characters; \(them)'s record is \(n(theirs))."
    }

    // MARK: - Year Wrapped

    /// "March" — the month name for a 1-based index, so partial years read honestly.
    public static func monthName(_ m: Int) -> String {
        guard (1...12).contains(m) else { return "\(m)" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US")
        return f.monthSymbols[m - 1]
    }

    /// "2025 held 41,203 messages across 34 conversations."
    public static func yearOpening(year: String, total: Int, chats: Int) -> String {
        switch total {
        case 0: return "Nothing from \(year) in here."
        case 1: return "\(year) held one message, in one conversation."
        default:
            if chats <= 1 { return "\(year) held \(n(total)) messages, all in one conversation." }
            return "\(year) held \(n(total)) messages across \(n(chats)) conversations."
        }
    }

    /// "You wrote on 304 days. The other 61 went by without a message from you."
    ///
    /// `yourDays` counts the days *you* sent something — the old count was every day anyone
    /// wrote, which described a quiet year as one you turned up on. A year the archive only
    /// half covers is still measured by the days it covers, never by twelve months of its own.
    public static func yearDays(yourDays: Int, coveredDays: Int, daysInYear: Int, partial: Bool) -> String {
        let mine = max(yourDays, 0)
        if mine == 0 { return "Not one day of it had a message from you." }
        if partial {
            let span = max(coveredDays, 1)
            if mine >= span { return "You wrote on all \(n(span)) days this archive covers." }
            if mine == 1 { return "Of the \(n(span)) days this archive covers, one had a message from you." }
            return "Of the \(n(span)) days this archive covers, you wrote on \(n(mine))."
        }
        let span = max(daysInYear, 1)
        if mine >= span { return "You wrote on all \(n(span)) days." }
        if mine == 1 { return "You wrote on one day; the other \(n(span - 1)) went by without a message from you." }
        return "You wrote on \(plural(mine, "day")). The other \(n(span - mine)) went by without a message from you."
    }

    /// "No single message in 2025 got a reply like that." — the body of an empty laugh card.
    public static func yearNoMoment(year: String) -> String {
        "No single message in \(year) got a reply like that. Plenty of talking, just a serious crowd."
    }

    /// "…and 6 more conversations." — nil when the shortlist already holds them all.
    public static func yearMoreChats(_ more: Int) -> String? {
        guard more > 0 else { return nil }
        return "…and \(plural(more, "more conversation"))."
    }

    /// "March to November: 9 of those 9 months have messages." — nil for a full year.
    ///
    /// The old sentence said "9 of the twelve months" for a year the archive only covers
    /// part of, which meant a year ending in October was described as if November and
    /// December had gone by without a message. The denominator is now the span itself.
    public static func yearPartial(firstMonth: Int, lastMonth: Int, months: Int) -> String? {
        guard months > 0, months < 12 else { return nil }
        if firstMonth == lastMonth { return "Only \(monthName(firstMonth)) is in here so far." }
        let span = max(1, lastMonth - firstMonth + 1)
        let range = "\(monthName(firstMonth)) to \(monthName(lastMonth))"
        if span == 12 { return "\(range): \(n(months)) of the twelve months have messages." }
        if months >= span { return "\(range): a message in all \(n(span)) months." }
        return "\(range): \(n(months)) of the \(n(span)) months between them have messages."
    }

    /// The busiest month, the loudest day and the hour it all lands in, in one breath.
    public static func yearShape(month: String, count: Int, busiest: Date?, busiestCount: Int, hour: Int) -> String? {
        guard count > 0 else { return nil }
        var line = "\(monthName(Int(month.suffix(2)) ?? 1)) carried the most — \(n(count)) messages."
        if let busiest, busiestCount > 0 {
            line += " The loudest day was \(date(busiest, "d MMMM")), with \(n(busiestCount))."
        }
        line += " Most of it landed around \(WrappedCopy.hour(hour))."
        return line
    }

    /// "Meera got the most of your attention: 6,204 messages. 22 people wrote to you in all."
    public static func yearPeople(top: String?, topCount: Int, people count: Int) -> String? {
        guard let top, topCount > 0 else { return nil }
        if count <= 1 { return "\(top) was the only person who wrote to you: \(n(topCount)) messages." }
        return "\(top) got the most of your attention: \(n(topCount)) messages. \(n(count)) people wrote to you in all."
    }

    /// "The loudest room was Sunday Football XI — 6,201 messages, ahead of 9 other groups."
    ///
    /// `groups` is the number of groups with a message this year, so the comparison is a
    /// count of rooms, never a count of messages.
    public static func yearRoom(group: String?, count: Int, groups: Int) -> String? {
        guard let group, count > 0 else { return nil }
        if groups <= 1 { return "Your one group, \(group), carried \(plural(count, "message"))." }
        return "The loudest room was \(group) — \(plural(count, "message")), ahead of \(plural(groups - 1, "other group"))."
    }

    /// "243 messages earned a proper laugh out loud." A laugh is a laugh whether it arrived as
    /// a reply or as a 😂 tapped on the message, so the sentence names the message, not the reply.
    public static func yearLaughs(count: Int) -> String {
        switch count {
        case 0: return "No laugh came back this year. Very serious correspondence."
        case 1: return "One message earned a proper laugh out loud."
        default: return "\(n(count)) messages earned a proper laugh out loud."
        }
    }

    /// "The biggest one: Meera in Flat 4B, 18 August."
    public static func yearLaughMoment(author: String, chat: String, on day: Date) -> String {
        "The biggest one: \(author) in \(chat), \(date(day, "d MMMM"))."
    }

    /// "58 messages got a heart from someone else." — nil when none did, so a heartless
    /// year says nothing rather than printing a zero.
    public static func yearHearts(count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "One message got a heart from someone else."
        default: return "\(n(count)) messages got a heart from someone else."
        }
    }

    /// "The one everyone loved: Meera in Flat 4B, 18 August."
    public static func yearHeartMoment(author: String, chat: String, on day: Date) -> String {
        "The one everyone loved: \(author) in \(chat), \(date(day, "d MMMM"))."
    }

    /// "137 songs and videos went round. You sent 52, more than anyone. Spotify was most of it."
    public static func yearSoundtrack(total: Int, senders: Int, top: String, topCount: Int, service: MediaService?) -> String? {
        guard total > 0 else { return nil }
        let mine = top.lowercased() == "you"
        var line: String
        if total == 1 {
            line = "One song or video went round, and \(mine ? "you" : top) sent it."
        } else if senders <= 1 {
            line = "\(n(total)) songs and videos went round, every one of them from \(mine ? "you" : top)."
        } else {
            line = "\(n(total)) songs and videos went round. \(mine ? "You" : top) sent \(n(topCount)), more than anyone."
        }
        if let service { line += " Most of it was \(service.rawValue)." }
        return line
    }

    /// "You typed 1,204 characters in one message in Flat 4B. Nothing else came close."
    ///
    /// The claim is only made when the runner-up really was nowhere near: with a 77- and a
    /// 76-character message in the same year, the second-longest is named instead.
    /// A one-to-one chat is named after the person, so the sentence never repeats the name.
    public static func yearLongest(chars: Int, runnerUp: Int, chat: String, fromMe: Bool, author: String) -> String {
        let place = (chat == author && !fromMe) ? "" : " in \(chat)"
        let opener = fromMe ? "You typed \(n(chars)) characters in one message\(place)."
                            : "\(author) wrote \(n(chars)) characters in one go\(place)."
        if runnerUp > 0, Double(chars) >= 1.5 * Double(runnerUp) { return opener + " Nothing else came close." }
        if runnerUp > 0, runnerUp == chars { return opener + " Another message matched it." }
        if runnerUp > 0 { return opener + " The next longest was \(n(runnerUp))." }
        return opener
    }

    /// "Along the way you also kept 812 photos and 61 voice notes."
    public static func yearMedia(photos: Int, videos: Int, voice: Int) -> String? {
        var parts: [String] = []
        if photos > 0 { parts.append(plural(photos, "photo")) }
        if videos > 0 { parts.append(plural(videos, "video")) }
        if voice > 0 { parts.append(plural(voice, "voice note")) }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0]
            : parts.count == 2 ? "\(parts[0]) and \(parts[1])"
            : "\(parts[0]), \(parts[1]) and \(parts[2])"
        return "Along the way you also kept \(list)."
    }

    /// "That was 2025. 41,203 messages, 22 people, and not one of them left this Mac."
    public static func yearClosing(year: String, total: Int, people count: Int) -> String {
        let who = count > 0 ? "\(WrappedCopy.people(count)), " : ""
        return "That was \(year). \(n(total)) messages, \(who)and not one of them left this Mac."
    }

    /// "41 days in a row was the best run." — nil when there is no run worth naming.
    public static func yearStreak(days: Int) -> String? {
        guard days > 1 else { return nil }
        return "\(plural(days, "day")) in a row was the best run."
    }

    /// "61 messages landed between midnight and 5 am." — nil when none did.
    /// It used to read "61 of them were sent", where "them" was the days of the streak
    /// in the sentence before it; days are not sent.
    public static func yearNight(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(plural(count, "message")) landed between midnight and 5 am."
    }

    // MARK: - Group Wrapped

    public static func groupOpening(name: String, total: Int, contributors: Int, spanDays: Int, activeDays: Int) -> String {
        let amount = total == 1 ? "one message" : "\(n(total)) messages"
        let who = contributors == 1 ? "one person" : "\(n(contributors)) people"
        if spanDays <= 1 { return "\(name) sent \(amount). \(who), one day, one conversation." }
        if activeDays >= spanDays { return "\(name) sent \(amount). \(who) across \(day(activeDays)), every one of them with something to say." }
        return "\(name) sent \(amount). \(who) across \(day(spanDays)), \(n(activeDays)) of them with something to say."
    }

    public static func groupVoices(top: String?, topCount: Int,
                                   funniest: String?, laughs: Int, of messages: Int,
                                   runnerUpRate: Double?, roomRate: Double) -> String? {
        guard let top else { return nil }
        let writes = "\(top) \(verb(top, singular: "writes", plural: "write")) the most — \(plural(topCount, "message"))"
        guard let funniest, laughs > 0, messages > 0 else { return writes + "; nobody has landed a laugh yet." }
        // Laughs per message, not per person: the loudest writer is not automatically the
        // funniest, and raw counts only say who posted the most.
        let rate = Double(laughs) / Double(messages)
        let clearLeader = runnerUpRate.map { rate >= max($0 * 1.25, $0 + 0.02) } ?? true
        if !clearLeader {
            let room = self.rate(max(roomRate, 0) * 100)
            return writes + ". Nobody runs away with it: a laugh lands on about \(room)% of what anyone writes."
        }
        if funniest == top {
            return writes + ", and a laugh lands on \(self.rate(rate * 100))% of them (\(plural(laughs, "laugh")))."
        }
        return writes + ". Per message, the room laughs hardest at \(funniest): \(plural(laughs, "laugh")) across \(plural(messages, "message")) (\(self.rate(rate * 100))%)."
    }

    public static func groupSoundtrack(total: Int, sharers: Int, top: String?, topCount: Int) -> String? {
        guard total > 0 else { return nil }
        let base = total == 1
            ? "One link landed in the chat, from \(people(sharers))."
            : "\(n(total)) links landed in the chat, from \(people(sharers))."
        guard let top, topCount > 0 else { return base }
        return base + " \(top) shared \(total == topCount ? (total == 1 ? "it" : "all of them") : n(topCount) + " of them")."
    }

    // MARK: - Quotes

    /// A one-line wrapper so views never print an empty bubble.
    public static func quote(_ text: String, limit: Int = 240) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}
