import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Deterministic pseudo-random source (SplitMix64). No system RNG and no clock: the same seed
/// produces the same archive on every machine and every run.
struct DemoRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func range(_ lo: Int, _ hi: Int) -> Int { lo + int(max(1, hi - lo + 1)) }
    mutating func double() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func chance(_ p: Double) -> Bool { double() < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
    mutating func weighted(_ xs: [Double]) -> Int {
        let total = xs.reduce(0, +)
        guard total > 0 else { return 0 }
        var r = double() * total
        for (i, w) in xs.enumerated() { r -= w; if r <= 0 { return i } }
        return xs.count - 1
    }
    mutating func shuffle<T>(_ xs: inout [T]) {
        guard xs.count > 1 else { return }
        for i in stride(from: xs.count - 1, to: 0, by: -1) { xs.swapAt(i, int(i + 1)) }
    }
}

/// One generated message, before it becomes a vault record.
struct DemoMessage {
    var ts: Int64
    var fromMe: Bool
    var sender: String?              // cast key; nil when fromMe
    var text: String?
    var type: Int64 = 0
    var media: DemoMedia?
    var quoteIndex: Int?             // index (within the same chat) of the quoted message
    var gone = false
    var kid = ""
    var uid = ""
    /// Emoji reactions WhatsApp stores beside the message, never inside its text.
    var reacts: [DemoReaction] = []
}

struct DemoReaction {
    let by: String?                  // cast key of the reactor; nil when the owner reacted
    let emoji: String
}

/// A placeholder attachment. The file itself is written later, when the total count is known,
/// so every generated file gets a unique, dated name.
struct DemoMedia {
    var kind: String                 // image | video | audio | doc | sticker
    var mime: String
    var relPath = ""
    var size: Int64 = 0
    var hash = ""
    var caption: String?
    var type: Int64 {
        switch kind {
        case "image": 1
        case "audio": 2
        case "video": 3
        case "sticker": 20
        default: 9
        }
    }
}

/// A chat to generate: who is in it, how much they talk, and what they talk about.
struct DemoChatPlan {
    let jid: String
    let name: String
    let isGroup: Bool
    let members: [String]            // cast keys, without "me"
    let pools: [[String]]
    let target: Int
    let mediaQuota: Int
    let linkQuota: Int
    let meanBurst: Int
    let mineShare: Double
    let hours: [Double]
    var gap: (from: Date, to: Date)? = nil
    var streak: (from: Date, to: Date)? = nil
    var systemNotice: String? = nil
    var weightBias: [String: Double] = [:]
    var jokePool: [String] = []      // phrases that only exist in this conversation
    var opener: String? = nil        // the line Wrapped shows as "how it started"
    var anchors = false              // add the scripted late-night and long-message moments
}

enum DemoFixture {
    // MARK: fixed frame

    static let seed: UInt64 = 0x5A6A_D3E0_1B2C_4F77
    /// Three years, UTC, ending on a fixed date so every run and every screenshot agree.
    static let firstDay = "2023-11-01"
    static let lastDay = "2026-10-31"
    /// The whole archive goes quiet here: the Wrapped "quiet month" copy needs a real dip.
    static let quietMonth = "2026-06"
    /// 2024 was a low year for this fictional circle (people moved cities, jobs changed).
    static let quietYear = 2024

    static func day(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")     // the archive's own clock
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)!
    }

    /// Fixed clock for generation: the fictional circle lives in one time zone, so the hour
    /// pattern (lunch, evening, the 3 am stragglers) lands the same way on every machine.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()

    // MARK: hourly shapes

    static let groupHours: [Double] = [
        0.2, 0.1, 0.1, 0.1, 0.1, 0.2, 0.6, 1.2, 1.8, 1.4, 1.0, 1.2,
        1.6, 2.0, 1.6, 1.2, 1.2, 1.6, 2.2, 3.0, 4.0, 4.6, 3.6, 1.8,
    ]
    static let eveningHours: [Double] = [
        0.6, 0.4, 0.2, 0.2, 0.1, 0.2, 0.4, 0.9, 1.1, 0.8, 0.6, 0.7,
        0.8, 0.8, 0.6, 0.6, 0.8, 1.2, 1.8, 2.6, 3.4, 4.4, 4.0, 2.2,
    ]
    static let lunchHours: [Double] = [
        0.2, 0.1, 0.1, 0.1, 0.1, 0.2, 0.5, 1.0, 1.8, 2.2, 1.6, 1.8,
        3.4, 4.2, 2.6, 1.6, 1.2, 1.6, 2.2, 2.4, 2.6, 2.8, 2.0, 1.0,
    ]
    static let morningHours: [Double] = [
        0.2, 0.1, 0.1, 0.1, 0.2, 0.6, 2.2, 4.0, 4.4, 3.2, 1.8, 1.2,
        1.0, 0.8, 0.8, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0, 1.4, 0.6,
    ]

    // MARK: the archive's shape

    /// Four people in one-to-one chats (one of them on two numbers, later merged) and ten
    /// groups, of which one carries roughly a third of everything.
    static func plans() -> [DemoChatPlan] {
        let m = DemoCorpus.self
        var plans: [DemoChatPlan] = [
            DemoChatPlan(jid: "demo-meera@lid", name: "Meera Nair", isGroup: false, members: ["meera"],
                         pools: [m.dmMeera, m.setups], target: 2200, mediaQuota: 40, linkQuota: 40,
                         meanBurst: 5, mineShare: 0.46, hours: eveningHours,
                         gap: (day("2026-02-06"), day("2026-03-03")),
                         streak: (day("2025-09-01"), day("2025-10-12"))),
            DemoChatPlan(jid: "demo-aravind@lid", name: "Aravind Pillai", isGroup: false, members: ["aravind"],
                         pools: [m.dmAravind, m.setups], target: 800, mediaQuota: 10, linkQuota: 5,
                         meanBurst: 4, mineShare: 0.44, hours: morningHours),
            DemoChatPlan(jid: "demo-nikhil@lid", name: "Nikhil Rao", isGroup: false, members: ["nikhil"],
                         pools: [m.dmNikhil, m.setups], target: 450, mediaQuota: 8, linkQuota: 6,
                         meanBurst: 4, mineShare: 0.42, hours: eveningHours),
            DemoChatPlan(jid: "demo-priya@lid", name: "Priya Menon", isGroup: false, members: ["priya"],
                         pools: [m.dmPriya, m.setups], target: 300, mediaQuota: 6, linkQuota: 2,
                         meanBurst: 3, mineShare: 0.45, hours: morningHours,
                         systemNotice: "Security code with Priya Menon changed. Tap to learn more."),
            // The same person on an old number: a merged identity the index folds into one conversation.
            DemoChatPlan(jid: "demo-nikhil-old@lid", name: "Nikhil Rao", isGroup: false, members: ["nikhil"],
                         pools: [m.dmNikhil, m.setups], target: 350, mediaQuota: 4, linkQuota: 4,
                         meanBurst: 4, mineShare: 0.42, hours: eveningHours),
            DemoChatPlan(jid: "demo-football@g.us", name: "Sunday Football XI", isGroup: true,
                         members: ["arjun", "sandeep", "farhan", "imran", "vivek", "manoj", "josy", "karan"],
                         pools: [m.football, m.setups], target: 6000, mediaQuota: 60, linkQuota: 20,
                         meanBurst: 7, mineShare: 0.16, hours: groupHours,
                         weightBias: ["arjun": 2.2, "sandeep": 2.6, "farhan": 1.4, "karan": 1.2]),
            DemoChatPlan(jid: "demo-flat4b@g.us", name: "Flat 4B", isGroup: true,
                         members: ["nikhil", "ritu", "vivek", "sneha"],
                         pools: [m.flat4B, m.setups], target: 2400, mediaQuota: 38, linkQuota: 10,
                         meanBurst: 5, mineShare: 0.24, hours: groupHours,
                         weightBias: ["ritu": 2.0, "nikhil": 1.6]),
            DemoChatPlan(jid: "demo-office@g.us", name: "Office Lunch Crew", isGroup: true,
                         members: ["divya", "deepak", "neha", "sameer", "anjali"],
                         pools: [m.officeLunch, m.setups], target: 1700, mediaQuota: 16, linkQuota: 5,
                         meanBurst: 5, mineShare: 0.22, hours: lunchHours,
                         weightBias: ["divya": 1.8, "deepak": 1.4]),
            DemoChatPlan(jid: "demo-cousins@g.us", name: "Cousins' Chaos", isGroup: true,
                         members: ["anjali", "ritu", "lakshmi", "neha", "manoj", "meera"],
                         pools: [m.cousins, m.setups], target: 1500, mediaQuota: 45, linkQuota: 8,
                         meanBurst: 5, mineShare: 0.18, hours: groupHours,
                         weightBias: ["anjali": 2.0, "lakshmi": 1.8, "ritu": 1.6]),
            DemoChatPlan(jid: "demo-wedding@g.us", name: "Wedding Prep — Aditi & Rohan", isGroup: true,
                         members: ["ritu", "sneha", "tara", "priya", "lakshmi", "anjali"],
                         pools: [m.weddingPrep, m.setups], target: 1100, mediaQuota: 55, linkQuota: 6,
                         meanBurst: 4, mineShare: 0.14, hours: lunchHours,
                         weightBias: ["ritu": 2.4, "sneha": 1.8]),
            DemoChatPlan(jid: "demo-trekkers@g.us", name: "Weekend Trekkers", isGroup: true,
                         members: ["josy", "tara", "farhan", "rachel", "sandeep"],
                         pools: [m.trekkers, m.setups], target: 1000, mediaQuota: 28, linkQuota: 10,
                         meanBurst: 5, mineShare: 0.2, hours: morningHours,
                         weightBias: ["josy": 2.0, "tara": 1.6]),
            DemoChatPlan(jid: "demo-bookclub@g.us", name: "Book Club (mostly snacks)", isGroup: true,
                         members: ["divya", "rachel", "tara", "priya", "sneha"],
                         pools: [m.bookClub, m.setups], target: 800, mediaQuota: 10, linkQuota: 6,
                         meanBurst: 4, mineShare: 0.2, hours: eveningHours,
                         weightBias: ["divya": 1.8, "rachel": 1.6]),
            DemoChatPlan(jid: "demo-college@g.us", name: "College Gang 2016", isGroup: true,
                         members: ["sameer", "sandeep", "karan", "deepak", "rachel", "farhan"],
                         pools: [m.collegeGang, m.setups], target: 900, mediaQuota: 8, linkQuota: 12,
                         meanBurst: 5, mineShare: 0.2, hours: eveningHours,
                         weightBias: ["sameer": 1.8, "sandeep": 2.0]),
            DemoChatPlan(jid: "demo-kerala@g.us", name: "Kerala Trip Crew", isGroup: true,
                         members: ["lakshmi", "josy", "meera", "aravind", "manoj"],
                         pools: [m.keralaTrip, m.setups], target: 700, mediaQuota: 32, linkQuota: 6,
                         meanBurst: 4, mineShare: 0.2, hours: morningHours,
                         weightBias: ["lakshmi": 2.2, "josy": 1.8]),
            DemoChatPlan(jid: "demo-garden@g.us", name: "Terrace Gardeners", isGroup: true,
                         members: ["sneha", "tara", "rachel", "lakshmi"],
                         pools: [m.garden, m.setups], target: 400, mediaQuota: 34, linkQuota: 4,
                         meanBurst: 3, mineShare: 0.22, hours: morningHours,
                         weightBias: ["sneha": 2.0, "tara": 1.6]),
        ]
        // How each conversation started: the first line is written, not sampled, because
        // Wrapped (and the hosted demo page) open on it.
        let openers: [String: String] = [
            "demo-meera@lid": "ok new chat, the old one had four hundred messages about a kettle",
            "demo-aravind@lid": "dei are you awake, i need yesterday's score",
            "demo-nikhil@lid": "sending you a song, listen on headphones not the laptop speaker",
            "demo-nikhil-old@lid": "this is my new number, save it and delete the old one",
            "demo-priya@lid": "did you finish the book or did the cat sit on it",
            "demo-football@g.us": "new group for sunday football. whoever doesn't reply is assumed in",
            "demo-flat4b@g.us": "new flat, new group. the rent split is in the pinned message",
            "demo-office@g.us": "lunch group. leave the work talk outside",
            "demo-cousins@g.us": "family group. amma says everyone must reply",
            "demo-wedding@g.us": "wedding group. dates are fixed, panic responsibly",
            "demo-trekkers@g.us": "trek group for december. drop your names below",
            "demo-bookclub@g.us": "book club. snacks are mandatory, reading is optional",
            "demo-college@g.us": "found all of you. reunion plans start here",
            "demo-kerala@g.us": "kerala trip group. tickets, food, and who is carrying the charger",
            "demo-garden@g.us": "garden group. the tomato has flowered",
        ]
        for i in plans.indices {
            plans[i].opener = openers[plans[i].jid]
            if plans[i].jid == "demo-meera@lid" { plans[i].jokePool = m.jokeLinesMeera; plans[i].anchors = true }
        }
        return plans
    }

    // MARK: month and weekday weighting

    static func monthWeight(_ comps: DateComponents) -> Double {
        let y = comps.year ?? 2025, m = comps.month ?? 1
        var w = 1.0
        if y == quietYear { w *= 0.19 }
        if String(format: "%04d-%02d", y, m) == quietMonth { w *= 0.12 }
        switch m {
        case 8: w *= 1.20          // Onam
        case 10, 11: w *= 1.35     // Diwali
        case 12: w *= 1.15         // holidays
        case 1: w *= 1.05
        case 4, 5: w *= 0.95       // exams, heat
        default: break
        }
        return w
    }

    static func weekdayWeight(_ weekday: Int) -> Double {   // 1 = Sunday
        switch weekday {
        case 1: return 1.25
        case 7: return 1.30
        case 6: return 1.10
        case 2: return 0.82
        case 3, 4: return 0.90
        default: return 0.96
        }
    }

    // MARK: message text

    static func fill(_ template: String, members: [String], rng: inout DemoRandom) -> String {
        var s = template
        if s.contains("{name}") {
            let other = members.isEmpty ? "meera" : rng.pick(members)
            s = s.replacingOccurrences(of: "{name}", with: DemoCorpus.firstName[other] ?? "there")
        }
        if s.contains("{place}") { s = s.replacingOccurrences(of: "{place}", with: rng.pick(DemoCorpus.places)) }
        if s.contains("{food}") { s = s.replacingOccurrences(of: "{food}", with: rng.pick(DemoCorpus.foods)) }
        if s.contains("{day}") { s = s.replacingOccurrences(of: "{day}", with: rng.pick(DemoCorpus.days)) }
        if s.contains("{object}") { s = s.replacingOccurrences(of: "{object}", with: rng.pick(DemoCorpus.objects)) }
        if s.contains("{spot}") { s = s.replacingOccurrences(of: "{spot}", with: rng.pick(DemoCorpus.spots)) }
        if s.contains("{verdict}") { s = s.replacingOccurrences(of: "{verdict}", with: rng.pick(DemoCorpus.verdicts)) }
        return s
    }

    /// Emoji are personal: each person leans on their own three, so Wrapped has something to say.
    static func decorate(_ text: String, sender: String, rng: inout DemoRandom, rate: Double) -> String {
        guard rng.chance(rate), let set = DemoCorpus.emoji[sender], !text.isEmpty else { return text }
        if rng.chance(0.25), set.count >= 2 { return text + " " + set[0] + set[1] }
        return text + " " + rng.pick(set)
    }

    // MARK: chat generation

    static func generate(_ plan: DemoChatPlan, rng: inout DemoRandom) -> [DemoMessage] {
        let cal = calendar
        let first = day(firstDay), last = day(lastDay)
        // A few days a year the chat goes off: a trip, a wedding, an argument. Those spikes are
        // what Wrapped's "busiest day" needs, and they are why a chat does not look like a line.
        var surge = Set<Int>()
        for _ in 0..<5 { surge.insert(rng.range(0, max(1, cal.dateComponents([.day], from: first, to: last).day ?? 0))) }
        var days: [(date: Date, weight: Double)] = []
        var d = first
        var dayIndex = 0
        while d <= last {
            let comps = cal.dateComponents([.year, .month, .weekday], from: d)
            var w = monthWeight(comps) * weekdayWeight(comps.weekday ?? 1)
            if rng.chance(0.22) { w *= 0.15 }                       // ordinary days with nothing to say
            if surge.contains(dayIndex) { w *= 7 }
            if let gap = plan.gap, d >= gap.from, d < gap.to { w = 0 }
            days.append((d, w))
            d = cal.date(byAdding: .day, value: 1, to: d)!
            dayIndex += 1
        }

        // The streak is a fixed, guaranteed run of days — the one Wrapped counts as "our longest run".
        var streakMessages: [DemoMessage] = []
        if let streak = plan.streak {
            var s = streak.from
            while s < streak.to {
                for k in 0..<rng.range(3, 5) {
                    let t = Int64(s.timeIntervalSince1970) * 1000 + Int64(20 + k) * 60_000 + Int64(rng.range(0, 55)) * 1000
                    streakMessages.append(DemoMessage(ts: t, fromMe: rng.chance(plan.mineShare),
                                                      sender: nil, text: rng.pick(DemoCorpus.dmMeera)))
                }
                s = cal.date(byAdding: .day, value: 1, to: s)!
            }
        }
        // One or two messages are reserved for the scripted anchors added below.
        let bodyTarget = max(1, plan.target - streakMessages.count - (plan.anchors ? 1 : 0))

        let totalWeight = days.reduce(0.0) { $0 + $1.weight }
        var out: [DemoMessage] = []
        var carry = 0.0
        outer: for entry in days where entry.weight > 0 {
            carry += Double(bodyTarget) * entry.weight / max(totalWeight, 0.0001)
            let wanted = Int(carry)
            carry -= Double(wanted)
            var remaining = wanted
            while remaining > 0 {
                if out.count >= bodyTarget { break outer }
                let length = min(remaining, max(2, plan.meanBurst + rng.range(-2, 4)))
                let hour = rng.weighted(plan.hours)
                let base = Int64(entry.date.timeIntervalSince1970) * 1000
                    + Int64(hour) * 3_600_000 + Int64(rng.range(0, 59)) * 60_000 + Int64(rng.range(0, 59)) * 1000
                appendBurst(&out, plan: plan, rng: &rng, base: base, length: length)
                remaining -= length
            }
        }
        if out.count > bodyTarget { out = Array(out.prefix(bodyTarget)) }
        // Rounding can leave a chat a message or two short; top it up on its last day so every
        // conversation reaches exactly its target.
        var topUp = 0
        while out.count < bodyTarget {
            let ts = Int64(last.timeIntervalSince1970) * 1000 + 21 * 3_600_000 + Int64(topUp) * 60_000
            appendBurst(&out, plan: plan, rng: &rng, base: ts, length: 1)
            topUp += 1
            if topUp > 500 { break }
        }
        out.append(contentsOf: streakMessages)

        // A scripted late-night message and one long one: both are Wrapped copy anchors.
        if plan.anchors {
            let night = Int64(day("2026-04-11").timeIntervalSince1970) * 1000 + 4 * 3_600_000 + 12 * 60_000
            out.append(DemoMessage(ts: night, fromMe: true, sender: nil,
                                   text: "3 am again and i'm on the terrace, the rain stopped and the whole street smells of wet earth, and i'm sitting here like a fool thinking about the sambar index"))
            if out.count > 40 {
                let longText = "ok so full update because you asked: work is the same, the review went fine, amma is convinced i don't eat properly, the balcony plant has three new leaves now which is basically a forest, and i finally fixed the tap myself after watching two videos and breaking one spanner. the plumber would have charged 900. i spent 240 on a spanner. it counts as a win."
                let at = out.count / 3
                if out[at].type == 0 { out[at].text = longText }
                let second = out.count * 2 / 3
                if out[second].type == 0 {
                    out[second].text = "ok listen, i have thought about this properly: if we leave by six we miss the traffic, if we leave by seven we sit in it together and that is fine, but then the market is closed by eight and the whole plan is pointless, so six it is and i will bring the flask and the biscuits and you bring the umbrella you always forget"
                    out[second].fromMe = false
                    out[second].sender = plan.members.first
                }
            }
        }
        if let notice = plan.systemNotice, out.count > 10 {
            let at = out.count - 3
            out[at].type = 7
            out[at].text = notice
            out[at].media = nil
        }
        // The night-owl quote is the *latest* small-hours message with words in it, so make sure
        // that one is worth quoting rather than a stray "haha".
        if plan.anchors {
            let small = out.indices.filter { out[$0].media == nil && (1...5).contains(Self.hour(of: out[$0].ts)) }
            func clock(_ ts: Int64) -> Int {
                let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(ts) / 1000))
                return (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
            if let latest = small.max(by: { clock(out[$0].ts) < clock(out[$1].ts) }),
               out[latest].text?.hasPrefix("3 am") != true {
                out[latest].text = "still awake, listening to the fan and the traffic outside, cannot sleep again"
            }
        }
        // The written first line of the conversation.
        if let opener = plan.opener, !out.isEmpty, let first = out.indices.min(by: { out[$0].ts < out[$1].ts }) {
            out[first].text = opener
            out[first].type = 0
            out[first].media = nil
            out[first].fromMe = false
            out[first].sender = plan.members.first
        }
        return out
    }

    static func appendBurst(_ out: inout [DemoMessage], plan: DemoChatPlan, rng: inout DemoRandom,
                            base: Int64, length: Int) {
        var ts = base
        var lastSender: String?
        var previousText: String?
        let funniest = rng.chance(0.3)
        for k in 0..<length {
            let fromMe = rng.chance(plan.mineShare)
            // One side of this circle answers in minutes; the other reads, thinks and comes
            // back twenty minutes later. Wrapped reports both medians.
            if k > 0 { ts += Int64(fromMe && rng.chance(0.5) ? rng.range(300, 2_400) : rng.range(20, 240)) * 1000 }
            var sender: String? = nil
            if !fromMe {
                if plan.isGroup {
                    let weights = plan.members.map { plan.weightBias[$0] ?? 1.0 }
                    sender = plan.members[rng.weighted(weights)]
                } else {
                    sender = plan.members[0]
                }
                if sender == lastSender, plan.members.count > 1, rng.chance(0.35) {
                    sender = plan.members[rng.int(plan.members.count)]
                }
            }
            lastSender = fromMe ? nil : sender

            var text: String?
            if funniest && k == 1 && !fromMe {
                text = rng.pick(DemoCorpus.setups)
            } else if funniest && k == 2 && !fromMe {
                text = rng.pick(DemoCorpus.laughs)
            } else {
                switch rng.double() {
                case ..<0.16: text = rng.pick(DemoCorpus.shorts)
                case ..<0.30: text = rng.pick(DemoCorpus.agrees)
                case ..<0.38: text = rng.pick(DemoCorpus.laughs)
                case ..<0.46: text = rng.pick(DemoCorpus.questions)
                default:
                    if !plan.jokePool.isEmpty, rng.chance(0.13) {
                        text = rng.pick(plan.jokePool)
                    } else {
                        let pool = rng.pick(plan.pools)
                        text = rng.pick(pool)
                    }
                }
            }
            if var t = text {
                t = fill(t, members: plan.members, rng: &rng)
                if let s = sender { t = decorate(t, sender: s, rng: &rng, rate: plan.isGroup ? 0.42 : 0.34) }
                text = t
            }
            // Two identical lines in a row read as a generator, not as people. Jokes are
            // allowed to recur, but never back to back.
            if rng.chance(0.22) { text = fill(rng.pick(DemoCorpus.varied), members: plan.members, rng: &rng) }
            if let t = text, t == previousText, !plan.jokePool.contains(t) {
                text = fill(rng.pick(DemoCorpus.varied), members: plan.members, rng: &rng)
            }
            previousText = text
            out.append(DemoMessage(ts: ts, fromMe: fromMe, sender: sender, text: text))
        }
    }

    // MARK: feature placement (links, media, quotes, deletions)

    /// Emoji reactions, the way a real room uses them: a 😂 or a ❤️ tapped on the line that
    /// earned it. Written after the conversation exists so every reaction names a real member
    /// of that chat and the author is never counted as laughing at themselves.
    ///
    /// A group occasionally piles on: real rooms put five or six names on the one line that
    /// landed, and without that the demo could never show a moment earning more than two.
    static func addReactions(_ msgs: inout [DemoMessage], plan: DemoChatPlan, rng: inout DemoRandom) {
        guard !msgs.isEmpty, !plan.members.isEmpty else { return }
        let palette = ["😂", "😂", "😂", "❤️", "👍", "🔥"]
        for i in msgs.indices {
            guard msgs[i].type == 0, !msgs[i].gone, msgs[i].media == nil,
                  (msgs[i].text?.isEmpty == false), rng.chance(0.17) else { continue }
            let author = msgs[i].fromMe ? nil : msgs[i].sender
            var givers = plan.members.filter { $0 != author }
            rng.shuffle(&givers)
            let pileOn = plan.isGroup && plan.members.count >= 6 && rng.chance(0.12)
            let n = plan.isGroup
                ? min(givers.count, pileOn ? rng.range(4, 7) : rng.range(1, 2))
                : min(givers.count, 1)
            for key in givers.prefix(n) {
                msgs[i].reacts.append(DemoReaction(by: key, emoji: rng.pick(palette)))
            }
            if !plan.isGroup, rng.chance(0.12) {                 // sometimes the owner reacts instead
                msgs[i].reacts.append(DemoReaction(by: nil, emoji: rng.pick(palette)))
            }
        }
    }

    /// A few stickers per chat, the way a room actually uses them: no words, the same file
    /// coming back. Placed by rewriting existing text messages, so message counts and dates do
    /// not move and every other Wrapped beat stays comparable.
    static func addStickers(_ msgs: inout [DemoMessage], plan: DemoChatPlan, rng: inout DemoRandom) {
        guard plan.mediaQuota > 0, !msgs.isEmpty else { return }
        let want = min(max(1, plan.mediaQuota / 12), 10)
        var slots = msgs.indices.filter { i in
            let m = msgs[i]
            return m.type == 0 && !m.gone && m.media == nil && m.quoteIndex == nil
                && (m.text ?? "").contains("http") == false
        }
        guard slots.count > want else { return }
        rng.shuffle(&slots)
        for i in slots.prefix(want) {
            msgs[i].media = DemoMedia(kind: "sticker", mime: "image/webp")
            msgs[i].type = 20
            msgs[i].text = nil
        }
    }

    /// Places the links, media, quoted replies and deletions a Wrapped needs, without disturbing order.
    static func addFeatures(_ msgs: inout [DemoMessage], plan: DemoChatPlan, chatIndex: Int, rng: inout DemoRandom) {
        let n = msgs.count
        guard n > 0 else { return }
        let links = DemoLinks.rotation(for: chatIndex, count: plan.linkQuota)

        // Music and video links, spread across the years, some of them answered warmly.
        if plan.linkQuota > 0, !links.isEmpty {
            for (i, slot) in spread(n, count: plan.linkQuota, rng: &rng).enumerated() where msgs[slot].type == 0 {
                let intro = rng.chance(0.55) ? rng.pick(DemoCorpus.musicIntros) + " " : ""
                msgs[slot].text = intro + links[i % links.count]
                // A warm reply from someone else, close behind — that is what "landed" measures.
                if rng.chance(0.68) {
                    for j in (slot + 1)..<min(slot + 4, n) where msgs[j].ts - msgs[slot].ts <= 1_800_000 {
                        guard msgs[j].type == 0 else { continue }
                        if msgs[j].fromMe != msgs[slot].fromMe || plan.isGroup {
                            msgs[j].text = rng.pick(DemoCorpus.warm)
                            msgs[j].media = nil
                            break
                        }
                    }
                }
            }
        }

        // Photos, videos, voice notes and the odd document.
        if plan.mediaQuota > 0 {
            for slot in spread(n, count: min(plan.mediaQuota, n), rng: &rng) where msgs[slot].type == 0 {
                let roll = rng.double()
                let kind: (String, String)
                switch roll {
                case ..<0.74: kind = ("image", "image/jpeg")
                case ..<0.87: kind = ("video", "video/mp4")
                case ..<0.97: kind = ("audio", "audio/wav")
                default: kind = ("doc", "application/pdf")
                }
                var media = DemoMedia(kind: kind.0, mime: kind.1)
                if rng.chance(0.45) {
                    media.caption = fill(rng.pick(DemoCorpus.mediaCaptions), members: plan.members, rng: &rng)
                }
                msgs[slot].media = media
                msgs[slot].type = media.type
                msgs[slot].text = media.caption
            }
        }

        // Quoted replies: a person answers something specific, which is how the app finds
        // "what made them laugh" without guessing from proximity.
        let quoteCount = max(2, Int(Double(n) * 0.035))
        for slot in spread(n, count: quoteCount, rng: &rng) where slot > 2 {
            guard msgs[slot].type == 0, msgs[slot].text?.contains("http") != true else { continue }
            let back = rng.range(1, min(12, slot))
            let target = slot - back
            let sameSender = msgs[slot].fromMe == msgs[target].fromMe && msgs[slot].sender == msgs[target].sender
            if sameSender { continue }
            msgs[slot].quoteIndex = target
            msgs[slot].text = rng.chance(0.7) ? rng.pick(DemoCorpus.laughs) : rng.pick(DemoCorpus.reactions)
        }

        // A handful of messages the phone later deleted: still in the archive, flagged as gone.
        let goneCount = plan.target > 1_500 ? 2 : 1
        for slot in spread(n, count: goneCount, rng: &rng) where msgs[slot].media == nil { msgs[slot].gone = true }

        // The busiest photo-sharing chats end on recent pictures, the way a real one does —
        // the last screen of a conversation is where photos usually are.
        if plan.mediaQuota >= 30, n > 24 {
            for slot in [n - 7, n - 11] where msgs[slot].type == 0 {
                var media = DemoMedia(kind: "image", mime: "image/jpeg")
                if rng.chance(0.6) { media.caption = fill(rng.pick(DemoCorpus.mediaCaptions), members: plan.members, rng: &rng) }
                msgs[slot].media = media
                msgs[slot].type = media.type
                msgs[slot].text = media.caption
            }
        }
    }

    /// One direct chat ends on an unanswered question, so "Might need your reply" has real demo
    /// evidence instead of opening empty. The chat's last substantive message is rewritten in
    /// place: counts, timestamps, order and identities are unchanged, so every other demo beat
    /// (Wrapped, On This Day, Search) stays exactly as it was.
    static func plantUnansweredQuestion(_ msgs: inout [DemoMessage], plan: DemoChatPlan) {
        let systemTypes: Set<Int64> = [7, 27, 36, 55, 90]
        guard let last = msgs.indices.last(where: { i in
            let m = msgs[i]
            return !systemTypes.contains(m.type) && ((m.media != nil) || !(m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }) else { return }
        msgs[last].fromMe = false
        msgs[last].sender = plan.members.first
        msgs[last].text = "did you book the cab for saturday? the one at six"
        msgs[last].type = 0
        msgs[last].media = nil
        msgs[last].quoteIndex = nil
        msgs[last].gone = false
    }

    /// Evenly spaced slots with a little jitter, so features do not clump.
    static func spread(_ n: Int, count: Int, rng: inout DemoRandom) -> [Int] {
        guard count > 0, n > 0 else { return [] }
        var out: [Int] = []
        let step = Double(n) / Double(count)
        for i in 0..<count {
            let width = max(1, Int(step))
            out.append(min(n - 1, Int(Double(i) * step) + rng.int(width)))
        }
        return Array(Set(out)).sorted()
    }

    // MARK: identity

    /// Hour of day on the fixture's own clock, used for the small-hours anchors.
    static func hour(of ts: Int64) -> Int {
        calendar.component(.hour, from: Date(timeIntervalSince1970: Double(ts) / 1000))
    }

    static func sortChronologically(_ msgs: inout [DemoMessage]) {
        msgs.sort { $0.ts != $1.ts ? $0.ts < $1.ts : ($0.sender ?? "") < ($1.sender ?? "") }
    }

    static func assignIdentities(_ msgs: inout [DemoMessage], chatIndex: Int, jid: String) {
        for i in msgs.indices {
            msgs[i].kid = String(format: "saga-demo-%02d-%05d", chatIndex, i + 1)
            msgs[i].uid = Uid.make(chat: jid, keyId: msgs[i].kid, fromMe: msgs[i].fromMe ? 1 : 0)
        }
    }
}

/// Writes the placeholder attachments. Images are drawn scenes by default — abstract art built
/// from gradients and shapes — or, when `saga demo --photos <folder>` supplied real photographs,
/// those photographs cycled in filename order. Videos are short silent clips, voice notes are
/// soft tones and documents are one-page PDFs. Nothing here is copied from a phone, and with no
/// photo folder nothing depicts a real person or place.
struct DemoMediaWriter {
    let root: URL                     // <demo>/media
    private let clips: [Data]
    private let photos: [Data]        // square JPEGs from --photos; empty means draw the scenes
    private var sequence = 0

    init(root: URL, rng: inout DemoRandom, photos: [Data] = []) {
        self.root = root
        self.photos = photos
        // Four clips are encoded once and reused, which keeps generation well under a second.
        var variants: [Data] = []
        for i in 0..<4 {
            let colour = DemoMediaWriter.colour(hue: Double(i) / 4, saturation: 0.6, brightness: 0.75)
            variants.append(DemoMediaAssets.clip(width: 320, height: 240, colour: colour))
        }
        self.clips = variants.filter { !$0.isEmpty }
    }

    static func colour(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let i = Int(hue * 6), f = hue * 6 - Double(i)
        let p = brightness * (1 - saturation), q = brightness * (1 - f * saturation)
        let t = brightness * (1 - (1 - f) * saturation)
        let rgb: (Double, Double, Double)
        switch i % 6 {
        case 0: rgb = (brightness, t, p); case 1: rgb = (q, brightness, p); case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness); case 4: rgb = (t, p, brightness); default: rgb = (brightness, p, q)
        }
        return CGColor(red: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
    }

    /// Fills in `relPath`, `size` and `hash` and writes the file. Names are dated and numbered
    /// like a phone's media folder, and are unique by construction.
    mutating func materialise(_ media: inout DemoMedia, ts: Int64, rng: inout DemoRandom,
                              photoIndex: Int? = nil) throws {
        sequence += 1
        let date = Date(timeIntervalSince1970: Double(ts) / 1000)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        df.timeZone = TimeZone(identifier: "UTC")
        let folder: String, prefix: String, ext: String
        switch media.kind {
        case "image": folder = "WhatsApp Images"; prefix = "IMG"; ext = "jpg"
        case "video": folder = "WhatsApp Video"; prefix = "VID"; ext = "mp4"
        case "audio": folder = "WhatsApp Voice Notes"; prefix = "PTT"; ext = "wav"
        case "sticker": folder = "WhatsApp Stickers"; prefix = "STK"; ext = "webp"
        default: folder = "WhatsApp Documents"; prefix = "DOC"; ext = "pdf"
        }
        let base = "\(prefix)-\(df.string(from: date))-WA\(String(format: "%04d", sequence))"
        let dir = root.appendingPathComponent("Media/\(folder)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data: Data
        switch media.kind {
        case "image":
            // DemoVault numbers each picture by its place in the Gallery, where the grid is
            // sorted by date; the writer's own sequence is only a fallback for a folder used
            // without that mapping.
            if photos.isEmpty {
                data = DemoMediaAssets.imageData(rng: &rng)
            } else {
                data = photos[(photoIndex ?? (sequence - 1)) % photos.count]
            }
        case "video": data = clips.isEmpty ? Data() : clips[sequence % clips.count]
        case "audio": data = DemoMediaAssets.audioData(index: sequence, rng: &rng)
        case "sticker": data = DemoMediaAssets.stickerData(index: sequence)
        default: data = DemoMediaAssets.documentData(index: sequence)
        }
        try data.write(to: dir.appendingPathComponent(base + "." + ext))
        media.relPath = "Media/\(folder)/\(base).\(ext)"
        media.size = Int64(data.count)
        media.hash = SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

enum DemoMediaAssets {
    /// A generated stand-in for a photograph. Each image is one of eight drawn scenes — a
    /// coastline, ridges at dusk, a café table, a plant in a window — built from gradients and
    /// shapes in the app's teal and green register, so a grid of them reads as pictures someone
    /// shared rather than as grey placeholder tiles. They are illustrations: nothing here was
    /// copied from a phone, and none of it depicts a real person or place.
    static func imageData(rng: inout DemoRandom) -> Data {
        let w = 480, h = 360
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        // Draw in y-down coordinates, the way the scenes are composed on paper.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let size = CGSize(width: w, height: h)
        // Every picture is a slightly different crop: shifted, zoomed a little, and sometimes
        // mirrored, so ten compositions do not repeat as ten identical tiles.
        if rng.chance(0.5) {
            ctx.translateBy(x: size.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        let zoom = 1.0 + CGFloat(rng.double()) * 0.45
        let dx = CGFloat(rng.double() - 0.5) * size.width * 0.18
        let dy = CGFloat(rng.double() - 0.5) * size.height * 0.14
        ctx.translateBy(x: size.width / 2 + dx, y: size.height / 2 + dy)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        switch rng.int(10) {
        case 0: DemoScenes.coast(ctx, size, &rng)
        case 1: DemoScenes.ridges(ctx, size, &rng)
        case 2: DemoScenes.forest(ctx, size, &rng)
        case 3: DemoScenes.skyline(ctx, size, &rng)
        case 4: DemoScenes.cafe(ctx, size, &rng)
        case 5: DemoScenes.windowPlant(ctx, size, &rng)
        case 6: DemoScenes.street(ctx, size, &rng)
        case 7: DemoScenes.plate(ctx, size, &rng)
        case 8: DemoScenes.flowers(ctx, size, &rng)
        default: DemoScenes.lake(ctx, size, &rng)
        }
        DemoScenes.finish(ctx, size, &rng)
        guard let cg = ctx.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return data as Data
    }

    /// Four tiny, real WebP stickers (96×96 colour gradients), encoded once and cycled.
    /// Drawings, not photographs: nothing here was copied from a phone. A sticker's identity
    /// is its file's SHA-256, so cycling four files gives the demo a believable "same sticker
    /// again" habit without inventing a thousand distinct pictures.
    static func stickerData(index: Int) -> Data {
        guard !stickerBase64.isEmpty else { return Data() }
        return Data(base64Encoded: stickerBase64[index % stickerBase64.count]) ?? Data()
    }

    private static let stickerBase64: [String] = [
        "UklGRpYAAABXRUJQVlA4TIoAAAAvX8AXADmFAAKgoInof7wZhEE4CHj/Axhw4HDQRpIjuVkspOOPKvXl+xdBtm2oszjSBQIpbKlDjdu2kdJTkzf/YfoQBCgECAUIonk5SFbJoTArR4T2GSP19B/h8A91+bXUQ5dfo56oXn/+e2cc6pHDP0I9dPk1Dl/T5deo5/9b76h+/fPbO1E74wA=",
        "UklGRqgAAABXRUJQVlA4TJsAAAAvX8AXADmFAAKgoInof7yLiP4HGEeS1GYmE0Ij/zSQFx4eBNm2oU7hMCfItlmNjnrkUOS2bePuYTvHIE+IPwIFyCQeJQgUQRc8C5AgogAJBQfeXYRAPYoQkbsIDcq9hQ2yh6r+hLKHyX7qfxqVPaT7aST/6+VLs/LPu7qfRro/b5fq540wvrT9oW4wvrT9v24wvrTtuW5gckfYAAA=",
        "UklGRtYAAABXRUJQVlA4TMoAAAAvX8AXADmFAAKgoInof7yLiP4HGLeRFGammlBi+hfhtboDlAdBtm2oszjSCbJtQ53HsR4M3DZS1GWmg+wX3h9AKAFkQJABJESBECRgzfNRBBQYULCajyAioIigxXwogWk+Bj7zQQIGTfOxIN2MLV8SL6p8D+KF4mXq72j7s1H5VUi81Pa812R7OoJ4WfHe/eEuVf53D7bnv2Z2J/vZ4PfAXVJ+M7L/3FV/R6fLXWNrgLvO9959vtxV/3/nfnJX/ffu/cm+PtxlpWts",
        "UklGRsYAAABXRUJQVlA4TLoAAAAvX8AXADmFAAKgoInof7yLiP4H1LSR5MxweXjPn0Cq0r6+Ici26XyOeXCCbNtQZ3CUhyK3kRrK3FYqwCh8of4ABogiQsAgImCAEgIGLCAyyccAkZaPkC4fIhRM8iGKQJePgZaPASFDPn36q8+yrT/M8YUsP9TxRdaXeN4dOn9Y/L5K5e9LxxcrHq6Q78tdJh9fzYe78vHV9+WueIRaP+x/cVf8/z54X+56Xl+lzh+Wj69+X+4y6XBR2QA=",
    ]

    static func audioData(index: Int, rng: inout DemoRandom) -> Data {
        let seconds = rng.range(4, 26)
        let rate = 8_000, frames = seconds * rate
        var pcm = Data(capacity: frames * 2)
        let hz = 180.0 + Double(index % 12) * 22
        for i in 0..<frames {
            let t = Double(i) / Double(rate)
            let envelope = sin(Double.pi * min(1, t / Double(seconds)))
            let v = sin(2 * .pi * hz * t) * 0.22 * envelope + sin(2 * .pi * hz * 2.01 * t) * 0.08 * envelope
            var sample = Int16(max(-1, min(1, v)) * 12_000)
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var out = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        out.append("RIFF".data(using: .ascii)!); le32(UInt32(36 + pcm.count))
        out.append("WAVEfmt ".data(using: .ascii)!); le32(16); le16(1); le16(1)
        le32(UInt32(rate)); le32(UInt32(rate * 2)); le16(2); le16(16)
        out.append("data".data(using: .ascii)!); le32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    static func documentData(index: Int) -> Data {
        let title = ["Trip plan", "Grocery list", "Budget sheet", "Reading list", "Guest list"][index % 5]
        let content = "BT /F1 18 Tf 60 720 Td (\(title)) Tj ET"
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
        objects.append("<< /Length \(content.count) >>\nstream\n\(content)\nendstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for off in offsets { body += String(format: "%010d 00000 n \n", off) }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return body.data(using: .ascii) ?? Data()
    }

    /// A three-frame H.264 clip: enough for AVFoundation to make a real poster and play it.
    static func clip(width: Int, height: Int, colour: CGColor) -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("saga-demo-clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let writer = try? AVAssetWriter(outputURL: tmp, fileType: .mp4) else { return Data() }
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
                                       AVVideoWidthKey: width, AVVideoHeightKey: height]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { return Data() }
        writer.add(input)
        guard writer.startWriting() else { return Data() }
        writer.startSession(atSourceTime: .zero)
        let rgb = colour.components ?? [0.5, 0.5, 0.5, 1]
        let red = UInt8(max(0, min(255, Double(rgb[0]) * 255)))
        let green = UInt8(max(0, min(255, Double(rgb[1]) * 255)))
        let blue = UInt8(max(0, min(255, Double(rgb[2]) * 255)))
        for frame in 0..<3 {
            var pb: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
            guard let buffer = pb else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                let shift = UInt8(frame * 10)
                for y in 0..<height {
                    for x in 0..<width {
                        let o = y * stride + x * 4
                        ptr[o] = blue &+ shift
                        ptr[o + 1] = green
                        ptr[o + 2] = red
                        ptr[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let deadline = Date().addingTimeInterval(3)
            while !input.isReadyForMoreMediaData && Date() < deadline { usleep(1_000) }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 2)) { break }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 8) == .success, writer.status == .completed else { return Data() }
        return (try? Data(contentsOf: tmp)) ?? Data()
    }
}
