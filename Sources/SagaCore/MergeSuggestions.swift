import Foundation

/// How sure the archive is that two entries are the same person. A plain tier, not a probability: the brief gives
/// no calibration data, so these are conservative heuristics (see `MergeSuggestionTuning`).
public enum MergeConfidence: Int, CaseIterable, Sendable, Comparable, Hashable {
    case low = 0, medium = 1, high = 2
    public static func < (a: MergeConfidence, b: MergeConfidence) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .low: return "Weak match"
        case .medium: return "Likely"
        case .high: return "Strong match"
        }
    }
}

/// One piece of evidence that two people keys belong to one person. Every reason is explainable in plain language;
/// none of them merges anything on its own — the user still has to choose Merge.
public enum MergeReason: Hashable, Sendable {
    case sameName
    case sameUpstreamName
    case sharedTrailingDigits(Int)
    case dmHandoff(gapDays: Int, sharedGroups: Int)
    /// The archive literally recorded "X changed their number to Y". Not a heuristic: WhatsApp said so.
    case changedNumber
    /// Two numbers saved under one contact in the owner's address book.
    case savedTogether

    /// Weight used to pick a confidence tier (heuristic, not a stated brief requirement).
    public var weight: Int {
        switch self {
        case .sameName: return 2
        case .sameUpstreamName: return 2
        case .sharedTrailingDigits: return 1
        case .dmHandoff: return 3
        case .changedNumber: return 4
        case .savedTogether: return 5
        }
    }

    /// Plain-language explanation shown next to the suggestion. Deliberately carries no names or numbers of its own:
    /// the rows above it already show what the person is called in the archive.
    public var explanation: String {
        switch self {
        case .sameName:
            return "Saved under the same contact name"
        case .sameUpstreamName:
            return "Same WhatsApp profile name"
        case .sharedTrailingDigits(let n):
            return "Numbers share the last \(n) digits"
        case .changedNumber:
            return "The archive recorded this number changing to the other one"
        case .savedTogether:
            return "Saved as one contact in your address book"
        case .dmHandoff(let days, let groups):
            let d = days == 1 ? "1 day" : "\(days) days"
            let g = groups == 1 ? "1 group" : "\(groups) groups"
            return "One chat goes quiet \(d) before the other starts, with \(g) in common"
        }
    }
}

/// Deterministic heuristics. The brief names signals but no thresholds, time gaps or group-overlap cutoffs, so these
/// are this implementation's conservative choices and the tests pin their exact boundaries.
enum MergeSuggestionTuning {
    /// Shortest shared trailing digits worth reporting. Shorter suffixes are too likely to collide by chance.
    static let minTrailingDigits = 8
    /// A DM handoff needs at least this many days of silence before the other chat starts (inclusive).
    static let dmHandoffGapDays = 1
    /// Both chats must hold at least this many messages, so a single stray message can't look like a handoff.
    static let minDMMessages = 2
    /// Share of the smaller group-membership set the two people must have in common (overlap coefficient).
    static let minGroupOverlap = 0.5
    /// WhatsApp profile names shorter than this many letters are ignored (initials, emoji, numbers).
    static let minPushNameLetters = 2
    /// Confidence tiers: summed reason weights at or above these scores.
    static let mediumScore = 2
    static let highScore = 4

    static let dayMs: Int64 = 86_400_000
}

/// An ignored suggestion: the exact member-key set, plus whichever of those people are still in the library.
public struct IgnoredMergeSuggestion: Identifiable, Sendable, Hashable {
    public let keys: [String]
    public let people: [PersonRow]
    public var id: String { keys.joined(separator: "+") }
    public init(keys: [String], people: [PersonRow]) { self.keys = keys; self.people = people }

    /// The ignored numbers now show as one merged person. The ignore stays tied to the exact original set (so
    /// unmerging does not silently un-ignore anything), but the sheet says so instead of claiming they are gone.
    public var isNowMerged: Bool { keys.count > 1 && people.count == 1 }
}

public struct MergeSuggestionReport: Sendable {
    public let suggestions: [MergeSuggestion]
    public let ignored: [IgnoredMergeSuggestion]
    public init(suggestions: [MergeSuggestion] = [], ignored: [IgnoredMergeSuggestion] = []) {
        self.suggestions = suggestions; self.ignored = ignored
    }
}

public enum MergeSuggestionConfigError: Error, CustomStringConvertible {
    case invalidIgnoreList
    public var description: String {
        "The ignored-suggestions file is damaged. Fix or remove config/merge-suggestion-ignores.json, then try again."
    }
}

/// Ignored suggestions, stored in the vault (`config/merge-suggestion-ignores.json`) so they survive a rebuild:
/// `{"ignored": [["key-a", "key-b"]]}`. Sets are exact: ignoring one pairing never hides a larger or different one.
public enum MergeSuggestionIgnores {
    public static let fileName = "merge-suggestion-ignores.json"

    public static func normalized(_ keys: [String]) -> [String] {
        Array(Set(keys.filter { !$0.isEmpty })).sorted()
    }

    /// Lenient read for display: a damaged file shows no ignored entries (and is never rewritten by this call).
    public static func load(_ vault: Vault) -> [[String]] { (try? loadChecked(vault)) ?? [] }

    /// Strict read for mutators, so a damaged file is reported instead of being silently replaced.
    public static func loadChecked(_ vault: Vault) throws -> [[String]] {
        guard let d = try vault.readConfig(fileName) else { return [] }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let raw = o["ignored"] as? [[String]] else { throw MergeSuggestionConfigError.invalidIgnoreList }
        var seen = Set<String>()
        var out: [[String]] = []
        for entry in raw {
            let keys = normalized(entry)
            guard keys.count > 1, seen.insert(keys.joined(separator: "\u{1F}")).inserted else { continue }
            out.append(keys)
        }
        return out.sorted { $0.joined(separator: "\u{1F}") < $1.joined(separator: "\u{1F}") }
    }

    public static func save(_ sets: [[String]], to vault: Vault) throws {
        var seen = Set<String>()
        var clean: [[String]] = []
        for entry in sets {
            let keys = normalized(entry)
            guard keys.count > 1, seen.insert(keys.joined(separator: "\u{1F}")).inserted else { continue }
            clean.append(keys)
        }
        clean.sort { $0.joined(separator: "\u{1F}") < $1.joined(separator: "\u{1F}") }
        let data = try JSONSerialization.data(withJSONObject: ["ignored": clean], options: [.prettyPrinted, .sortedKeys])
        try vault.writeConfig(data, name: fileName)
    }

    public static func add(_ keys: [String], to vault: Vault) throws {
        let key = normalized(keys)
        guard key.count > 1 else { return }
        var all = try loadChecked(vault)
        guard !all.contains(where: { Set($0) == Set(key) }) else { return }
        all.append(key)
        try save(all, to: vault)
    }

    public static func remove(_ keys: [String], from vault: Vault) throws {
        let set = Set(keys)
        guard set.count > 1 else { return }
        let all = try loadChecked(vault)
        let kept = all.filter { Set($0) != set }
        guard kept.count != all.count else { return }
        try save(kept, to: vault)
    }

    public static func contains(_ keys: [String], in sets: [[String]]) -> Bool {
        let set = Set(keys)
        return sets.contains { Set($0) == set }
    }
}

// MARK: - Engine

extension VaultStore {
    /// Backwards-compatible entry point: callers without a vault get the original same-name suggestions.
    public func mergeSuggestions() throws -> [MergeSuggestion] { try mergeSuggestions(vault: nil) }

    /// Suggestions with every available signal. Pass the vault to include WhatsApp profile names, ignored entries and
    /// segment-level evidence; `nil` keeps the original same-name behaviour.
    public func mergeSuggestions(vault: Vault?) throws -> [MergeSuggestion] {
        try mergeSuggestionReport(vault: vault).suggestions
    }

    public func mergeSuggestionReport(vault: Vault?) throws -> MergeSuggestionReport {
        // Merged people are already collapsed to their primary key by the indexer; unnamed people stay eligible because
        // an old deleted number is exactly the case a suggestion should surface.
        let all = try people(namedOnly: vault == nil, limit: 100_000)
        let index = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var mergePrimary: [String: String] = [:]
        if let vault {
            for group in MergeConfig.load(vault) where group.keys.count > 1 {
                for key in group.keys { mergePrimary[key] = group.keys[0] }
            }
        }

        var builder = Builder(index: index, mergePrimary: mergePrimary)
        builder.addSameNames(all)
        if let vault {
            builder.addUpstreamNames(try Self.upstreamNames(vault: vault))
            builder.addTrailingDigits()
            builder.addSavedContacts(vault: vault)
            builder.addNumberChanges(db: db)
            builder.addDMHandoffs(db: db)
        }

        let ignoredSets = vault.map { MergeSuggestionIgnores.load($0) } ?? []
        var suggestions = builder.candidates.values.compactMap { Self.suggestion($0, index: index) }
            .filter { !MergeSuggestionIgnores.contains($0.people.map(\.key), in: ignoredSets) }
        suggestions.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            let a = $0.people.reduce(0) { $0 + $1.received }, b = $1.people.reduce(0) { $0 + $1.received }
            if a != b { return a > b }
            return $0.id < $1.id
        }
        // An ignored set survives a merge unchanged, but its numbers now resolve to the merged person, so the
        // sheet shows that person instead of "no longer in the library". Keys stay the original exact set.
        let ignored = ignoredSets.map { keys in
            var seen = Set<String>()
            var rows: [PersonRow] = []
            for raw in keys {
                let key = mergePrimary[raw] ?? raw
                guard seen.insert(key).inserted, let row = index[key] else { continue }
                rows.append(row)
            }
            return IgnoredMergeSuggestion(keys: keys, people: rows.sorted(by: MergeSuggestion.personOrder))
        }
        return MergeSuggestionReport(suggestions: suggestions, ignored: ignored)
    }

    // MARK: candidate assembly

    private struct Candidate {
        let keys: [String]
        var reasons: Set<MergeReason>
    }

    private struct Builder {
        let index: [String: PersonRow]
        let mergePrimary: [String: String]
        var candidates: [String: Candidate] = [:]

        /// Original keys (from segments) become the person they are currently merged into, and unknown keys are dropped.
        func resolve(_ raw: String) -> String? {
            let key = mergePrimary[raw] ?? raw
            return index[key] != nil ? key : nil
        }

        /// Timing alone can never prove identity: if the two chats carry different real names, a handoff is
        /// just one conversation ending as another began. Other signals may still pair them, but not this one.
        func namesConflict(_ keys: [String]) -> Bool {
            let names = Set(keys.compactMap { index[$0]?.name }
                .filter { !MergeSuggestion.isPlaceholderName($0) && !isUnresolvedLabel($0) }
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
            return names.count > 1
        }

        mutating func add(_ keys: [String], _ reason: MergeReason) {
            var members = Set<String>()
            for key in keys { if let resolved = resolve(key) { members.insert(resolved) } }
            guard members.count > 1 else { return }
            let sorted = members.sorted()
            // Timing alone can never prove identity. A handoff may never be the reason that pairs two people
            // the archive knows by different real names; deterministic reasons are unaffected.
            if case .dmHandoff = reason, namesConflict(sorted) { return }
            let id = sorted.joined(separator: "+")
            var candidate = candidates[id] ?? Candidate(keys: sorted, reasons: [])
            candidate.reasons.insert(reason)
            candidates[id] = candidate
        }



        /// The strongest evidence there is: the owner's own address book already holds these numbers
        /// under a single contact. No inference, no timing, no name similarity.
        mutating func addSavedContacts(vault: Vault) {
            for group in PhoneContacts.groups(in: vault) { add(group.keys, .savedTogether) }
        }

        /// WhatsApp writes a system message when a contact changes number. That message is proof, not a guess,
        /// and it is the one signal here that the user never has to second-guess.
        mutating func addNumberChanges(db: SQLiteDB) {
            let sql = """
                SELECT c.jid, coalesce(m.text,'') FROM messages m JOIN chats c ON c.chat_id = m.chat_id
                WHERE m.text LIKE '%changed their number%' OR m.text LIKE '%changed their phone number%'
                """
            try? db.query(sql) { r in
                guard let oldJID = r.text(0), let text = r.text(1) else { return }
                let digits = text.filter(\.isNumber)
                guard digits.count >= 10 else { return }
                let newKey = String(digits.suffix(10))
                guard let oldKey = personKey(forJID: oldJID), oldKey != newKey else { return }
                add([oldKey, newKey], .changedNumber)
            }
        }

        /// The original signal: different numbers saved under the same contact name. Unresolved rows are fallback
        /// labels ("+9198…", "Unknown (1234)") and must not be treated as people sharing a name.
        mutating func addSameNames(_ people: [PersonRow]) {
            // A name-only match is worthless when the "name" is a placeholder or a half-masked number:
            // forty groups called "(unnamed group)" would all be proposed against each other. Only a real,
            // saved name is evidence of the same person.
            let named = people.filter { $0.resolved && !MergeSuggestion.isPlaceholderName($0.name) && !isUnresolvedLabel($0.name) }
            let groups = Dictionary(grouping: named) { $0.name.lowercased().trimmingCharacters(in: .whitespaces) }
            for (_, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
                add(group.map(\.key), .sameName)
            }
        }

        /// Same WhatsApp profile ("push") name read from the segments, even when contact names differ. Two distinct
        /// nonblank names never match, and blank/short/number-only names are ignored.
        mutating func addUpstreamNames(_ names: [String: Set<String>]) {
            for (_, keys) in names.sorted(by: { $0.key < $1.key }) where keys.count > 1 {
                add(keys.sorted(), .sameUpstreamName)
            }
        }

        /// Numbers in different country formats whose digits end the same way. Person keys are already the last ten
        /// digits, so this only fires when one side has fewer digits stored — never on LIDs or non-numeric keys.
        mutating func addTrailingDigits() {
            let phone = index.values.filter { !$0.key.isEmpty && $0.key.allSatisfy(\.isNumber) }.sorted { $0.key < $1.key }
            var buckets: [String: [String]] = [:]
            for person in phone where person.key.count >= MergeSuggestionTuning.minTrailingDigits {
                buckets[String(person.key.suffix(MergeSuggestionTuning.minTrailingDigits)), default: []].append(person.key)
            }
            for (_, keys) in buckets.sorted(by: { $0.key < $1.key }) where keys.count > 1 {
                for i in 0..<keys.count {
                    for j in (i + 1)..<keys.count {
                        let (short, long) = keys[i].count <= keys[j].count ? (keys[i], keys[j]) : (keys[j], keys[i])
                        guard short.count >= MergeSuggestionTuning.minTrailingDigits,
                              short.count < long.count, long.hasSuffix(short) else { continue }
                        add([short, long], .sharedTrailingDigits(short.count))
                    }
                }
            }
        }

        /// One DM chat goes silent just as another starts, and the two people take part in overlapping groups.
        /// Uses DM timestamps only (PersonRow.first/last span groups too and would blur the boundary), and treats
        /// observed group messages as a proxy for group membership — full membership history isn't archived.
        mutating func addDMHandoffs(db: SQLiteDB) {
            var dm: [String: (first: Int64, last: Int64, count: Int)] = [:]
            try? db.query("""
                SELECT m.person, MIN(m.ts), MAX(m.ts), COUNT(*) FROM messages m JOIN chats c ON c.chat_id=m.chat_id
                WHERE c.is_group=0 GROUP BY m.person
                """) { r in
                let key = r.text(0) ?? ""
                guard index[key] != nil else { return }
                dm[key] = (r.int(1), r.int(2), Int(r.int(3)))
            }
            var groupsOf: [String: Set<Int64>] = [:]
            try? db.query("""
                SELECT DISTINCT m.person, c.chat_id FROM messages m JOIN chats c ON c.chat_id=m.chat_id WHERE c.is_group=1
                """) { r in
                let key = r.text(0) ?? ""
                guard index[key] != nil else { return }
                groupsOf[key, default: []].insert(r.int(1))
            }
            var members: [Int64: Set<String>] = [:]
            for (key, groups) in groupsOf { for group in groups { members[group, default: []].insert(key) } }
            let minGap = Int64(MergeSuggestionTuning.dmHandoffGapDays) * MergeSuggestionTuning.dayMs
            for (_, people) in members.sorted(by: { $0.key < $1.key }) where people.count > 1 {
                let keys = people.sorted()
                for i in 0..<keys.count {
                    for j in (i + 1)..<keys.count {
                        let a = keys[i], b = keys[j]
                        guard let da = dm[a], let dB = dm[b],
                              da.count >= MergeSuggestionTuning.minDMMessages,
                              dB.count >= MergeSuggestionTuning.minDMMessages else { continue }
                        let gap: Int64
                        if dB.first > da.last { gap = dB.first - da.last }
                        else if da.first > dB.last { gap = da.first - dB.last }
                        else { continue }                               // overlapping DM histories: not a handoff
                        guard gap >= minGap else { continue }
                        let ga = groupsOf[a] ?? [], gb = groupsOf[b] ?? []
                        let shared = ga.intersection(gb).count
                        guard shared > 0,
                              Double(shared) / Double(min(ga.count, gb.count)) >= MergeSuggestionTuning.minGroupOverlap
                        else { continue }
                        add([a, b], .dmHandoff(gapDays: Int(gap / MergeSuggestionTuning.dayMs), sharedGroups: shared))
                    }
                }
            }
        }
    }

    // MARK: helpers

    private static func suggestion(_ candidate: Candidate, index: [String: PersonRow]) -> MergeSuggestion? {
        let rows = candidate.keys.compactMap { index[$0] }.sorted(by: MergeSuggestion.personOrder)
        guard rows.count > 1 else { return nil }
        let name = rows.first { $0.resolved && !MergeSuggestion.isPlaceholderName($0.name) }?.name ?? rows[0].name
        let reasons = candidate.reasons.sorted {
            $0.weight != $1.weight ? $0.weight > $1.weight : $0.explanation < $1.explanation
        }
        let score = reasons.reduce(0) { $0 + $1.weight }
        let confidence: MergeConfidence = score >= MergeSuggestionTuning.highScore ? .high
            : score >= MergeSuggestionTuning.mediumScore ? .medium : .low
        return MergeSuggestion(name: name, people: rows, reasons: reasons, confidence: confidence)
    }


    /// Person key for a raw JID, using the same rules as `Resolver`: last ten phone digits, or `lid:<id>`.
    /// Public because the app needs it too: an unnamed row is a chat, and a merge is keyed by a person.
    public static func personKey(forJID raw: String) -> String? {
        guard let at = raw.lastIndex(of: "@") else { return nil }
        let user = String(raw[..<at]), server = String(raw[raw.index(after: at)...])
        switch server {
        case "s.whatsapp.net", "c.us":
            let digits = normalizePhone(user)
            return digits.isEmpty ? nil : digits
        case "lid", "hosted.lid":
            return user.isEmpty ? nil : "lid:" + user
        default:
            return nil
        }
    }

    /// WhatsApp profile names pushed into the archive, grouped by normalised name: raw segment facts only, so a saved
    /// contact name masking the push name in the index does not hide the evidence.
    static func upstreamNames(vault: Vault) throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        func note(_ jid: String?, _ name: String?) {
            guard let jid, let name, let key = personKey(forJID: jid) else { return }
            let display = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard display.filter({ $0.isLetter }).count >= MergeSuggestionTuning.minPushNameLetters else { return }
            out[display.lowercased(), default: []].insert(key)
        }
        try vault.readAll { record in
            switch record["k"] as? String {
            case "chat":
                note(record["j"] as? String ?? record["jid"] as? String, record["n"] as? String)
            case "j":
                note(record["j"] as? String, record["n"] as? String)
            case "m":
                guard let sender = record["s"] as? [String: Any] else { return }
                note(sender["j"] as? String, sender["n"] as? String)
            default:
                break
            }
        }
        return out
    }
}

/// Labels the archive produces when it has no real name. Matching on these proposes strangers as one person.
func isUnresolvedLabel(_ name: String) -> Bool {
    let lower = name.lowercased()
    if lower.contains("unnamed") || lower.contains("unknown") { return true }
    if name.contains("*") { return true }                 // half-masked numbers, e.g. +918****9745
    return name.filter { $0.isLetter }.count < 2
}
