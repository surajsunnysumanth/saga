import Foundation

/// One original identity inside a person: the full chat JID it was stored under, the person key it resolved to,
/// and what it actually is. A merged person keeps every one of these, so cleanup rules, saved summaries and the
/// person page can still reach all of their numbers after the index has collapsed them into one row.
public struct MergeMember: Identifiable, Hashable, Sendable {
    public var id: String { jid }
    public let person: String      // person key the archive currently shows this identity as (keys[0] after a merge)
    public let member: String      // original person key: last ten phone digits, or "lid:<id>"
    public let jid: String         // original full chat JID
    public let phone: String?      // full international digits from the JID, when it is a phone number
    public let lid: String?        // WhatsApp LID user part, when the chat is (or resolves through) a LID

    public init(person: String, member: String, jid: String, phone: String?, lid: String?) {
        self.person = person; self.member = member; self.jid = jid; self.phone = phone; self.lid = lid
    }

    /// What to show a person. A phone is shown in full international digits (never the truncated search key);
    /// a LID is labelled as a WhatsApp ID because it is not a phone number.
    public var display: String {
        if let phone { return "+" + phone }
        if let lid { return "LID " + lid }
        return member
    }
    public var isPhone: Bool { phone != nil }
    public var isUnresolvedLID: Bool { phone == nil && lid != nil }
}

/// Resolution helpers shared by the indexer, `VaultStore` and the UI. Identity is always JIDs/person keys, never
/// display names or SQLite row ids.
public enum MergeIdentity {
    /// One membership row from a chat record: `rawJID` is what `prune.json` and saved summaries are keyed by,
    /// `resolvedJID` is the phone JID a LID chat maps through (same value as `rawJID` for a plain phone chat).
    public static func member(person: String, member: String, rawJID: String, resolvedJID: String) -> MergeMember {
        let raw = split(rawJID), resolved = split(resolvedJID)
        var phone: String? = nil
        var lid: String? = nil
        if resolved.server == "s.whatsapp.net" || resolved.server == "c.us" {
            let digits = resolved.user.filter { $0.isASCII && $0.isNumber }
            if !digits.isEmpty { phone = digits }
        }
        if raw.server == "lid" || raw.server == "hosted.lid" { lid = raw.user }
        else if resolved.server == "lid" || resolved.server == "hosted.lid" { lid = resolved.user }
        return MergeMember(person: person, member: member, jid: rawJID, phone: phone, lid: lid)
    }

    /// Disposable index table, recreated by every rebuild. Nothing durable depends on it; an index without it
    /// behaves as if every person had exactly the chat row it shows.
    public static let indexSchema = """
    DROP TABLE IF EXISTS merge_members;
    CREATE TABLE merge_members(person TEXT NOT NULL, member TEXT NOT NULL, jid TEXT NOT NULL, phone TEXT, lid TEXT,
                               PRIMARY KEY(person, jid));
    CREATE INDEX ix_merge_members_member ON merge_members(member);
    """

    /// Raw person key -> the key the index stores for that person after merging.
    public static func personAliases(_ merges: [PersonMerge]) -> [String: String] {
        var out: [String: String] = [:]
        for group in merges where group.keys.count > 1 {
            for key in group.keys { out[key] = group.keys[0] }
        }
        return out
    }

    /// Boolean OR of every rule that applies to one conversation made of `jids`. Used both when merging a chat's
    /// rules for indexing and when the editor shows the effective rule of a merged person. Labels are display-only.
    public static func unionRule(jids: [String], rules: [String: PruneRule], label: String? = nil) -> PruneRule? {
        let ordered = Array(Set(jids.filter { !$0.isEmpty })).sorted()
        guard let first = ordered.first else { return nil }
        var out = PruneRule(chat: first, label: label ?? ordered.compactMap { rules[$0]?.label }.first ?? "")
        var any = false
        var senders: [String] = []
        for jid in ordered {
            guard let r = rules[jid] else { continue }
            any = true
            out.hideChat = out.hideChat || r.hideChat
            out.dropMedia = out.dropMedia || r.dropMedia
            out.dropDuplicates = out.dropDuplicates || r.dropDuplicates
            out.dropLinkOnly = out.dropLinkOnly || r.dropLinkOnly
            for s in r.dropSenders where !senders.contains(s) { senders.append(s) }
        }
        guard any else { return nil }
        out.dropSenders = senders.sorted()
        return out.isEmpty ? nil : out
    }

    /// The rules actually applied while indexing: each merged DM conversation gets the union of its members' rules
    /// (so a rule saved for the old number still applies to the surviving chat), group rules keep their own scope,
    /// and every sender exclusion is resolved to the person key the index now stores. `prune.json` itself is never
    /// touched, so unmerging restores the original per-chat effects.
    public static func effectiveRules(_ rules: [PruneRule], merges: [PersonMerge],
                                      conversationMembers: [String: [String]]) -> [PruneRule] {
        let aliases = personAliases(merges)
        let byJID = Dictionary(rules.map { ($0.chat, $0) }, uniquingKeysWith: { _, last in last })
        var out: [PruneRule] = []
        var handled = Set<String>()
        for person in conversationMembers.keys.sorted() {
            let jids = Array(Set(conversationMembers[person] ?? [])).sorted()
            guard jids.count > 1, let merged = unionRule(jids: jids, rules: byJID) else { continue }
            let resolved = resolvingSenders(merged, aliases: aliases)
            for jid in jids where handled.insert(jid).inserted {
                var copy = resolved
                copy.chat = jid
                if let own = byJID[jid] { copy.label = own.label }
                out.append(copy)
            }
        }
        for rule in rules where !handled.contains(rule.chat) { out.append(resolvingSenders(rule, aliases: aliases)) }
        return out
    }

    /// One row per conversation for the cleanup editor's list. A merged person is stored as one rule per original
    /// number; without this the list shows the same person's rule again for every number, and Restore on one row
    /// makes the others vanish. The rows are the union actually applied while indexing, so what the list says is
    /// what the library does.
    public static func effectiveRuleRows(_ rules: [PruneRule], members: [String: [String]]) -> [PruneRule] {
        let byJID = Dictionary(rules.map { ($0.chat, $0) }, uniquingKeysWith: { _, last in last })
        var rows: [PruneRule] = []
        var seen = Set<String>()
        for rule in rules.sorted(by: { $0.chat < $1.chat }) {
            let jids = Array(Set((members[rule.chat] ?? [rule.chat]).filter { !$0.isEmpty })).sorted()
            guard !jids.isEmpty else { continue }
            let key = jids.joined(separator: "\u{1F}")
            guard seen.insert(key).inserted else { continue }
            rows.append(unionRule(jids: jids, rules: byJID, label: rule.label) ?? rule)
        }
        return rows
    }

    static func resolvingSenders(_ rule: PruneRule, aliases: [String: String]) -> PruneRule {
        guard !rule.dropSenders.isEmpty else { return rule }
        var out = rule
        out.dropSenders = Array(Set(rule.dropSenders.map { aliases[$0] ?? $0 })).sorted()
        return out
    }

    static func split(_ raw: String) -> (user: String, server: String) {
        guard let at = raw.lastIndex(of: "@") else { return (raw, "") }
        return (String(raw[..<at]), String(raw[raw.index(after: at)...]))
    }
}

/// Cache-key set for one saved AI summary. A conversation that is one person with several numbers reads every
/// original number's key, so summaries saved before the merge stay reachable, and writes under a separate
/// deterministic member-set key so regenerating cannot overwrite either original. A singleton keeps the legacy
/// `jid|days|model|detail` key.
public struct SummaryCacheKeys: Hashable, Sendable {
    public let readKeys: [String]    // deterministic; AICache picks the newest match
    public let writeKey: String
    public let suffix: String
    public let mergedBase: String?   // "person:jid-a,jid-b" when the conversation covers several numbers

    public var isMerged: Bool { mergedBase != nil }

    public static func make(chatJIDs: [String], days: Int, modelID: String, detail: String) -> SummaryCacheKeys? {
        let jids = Array(Set(chatJIDs.filter { !$0.isEmpty })).sorted()
        guard !jids.isEmpty, !modelID.isEmpty else { return nil }
        let suffix = "|\(days)|\(modelID)|\(detail)"
        guard jids.count > 1 else {
            return SummaryCacheKeys(readKeys: [jids[0] + suffix], writeKey: jids[0] + suffix, suffix: suffix, mergedBase: nil)
        }
        let base = "person:" + jids.joined(separator: ",")
        let reads = jids.map { $0 + suffix } + [base + suffix]
        return SummaryCacheKeys(readKeys: reads, writeKey: base + suffix, suffix: suffix, mergedBase: base)
    }

    /// A summary generated while merged (under the member-set namespace).
    public func isMergedSummary(_ key: String) -> Bool { mergedBase.map { key == $0 + suffix } ?? false }
    /// The legacy key of this exact chat row, i.e. a summary saved before any merge.
    public func isOwnSummary(_ key: String, chatJID: String) -> Bool { !chatJID.isEmpty && key == chatJID + suffix }
}

// MARK: - Read-only member lookup

private func mergeSQLQuote(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

extension VaultStore {
    /// Every original identity behind one person, ordered by JID. An index built before this table existed
    /// falls back to the chat rows it has, which is exactly the singleton view those indices represent.
    public func mergeMembers(person: String) -> [MergeMember] {
        var out: [MergeMember] = []
        if hasMergeMembers {
            try? db.query("""
                SELECT person, member, jid, phone, lid FROM merge_members
                WHERE person='\(mergeSQLQuote(person))' ORDER BY jid
                """) {
                out.append(MergeMember(person: $0.text(0) ?? person, member: $0.text(1) ?? "", jid: $0.text(2) ?? "",
                                       phone: $0.text(3), lid: $0.text(4)))
            }
        }
        if out.isEmpty {
            var jids: [String] = []
            try? db.query("SELECT jid FROM chats WHERE person='\(mergeSQLQuote(person))' AND is_group=0 ORDER BY jid") {
                jids.append($0.text(0) ?? "")
            }
            out = jids.filter { !$0.isEmpty }.map {
                MergeIdentity.member(person: person, member: person, rawJID: $0, resolvedJID: $0)
            }
        }
        return out
    }

    /// Identities behind the person a chat row belongs to. A chat that was pruned out of the index still resolves
    /// through the disposable membership table when it is there.
    public func mergeMembers(chatJID: String) -> [MergeMember] {
        guard !chatJID.isEmpty else { return [] }
        var person: String? = nil
        try? db.query("SELECT person FROM chats WHERE jid='\(mergeSQLQuote(chatJID))' LIMIT 1") { person = $0.text(0) }
        if let person, !person.isEmpty { return mergeMembers(person: person) }
        if hasMergeMembers {
            try? db.query("SELECT person FROM merge_members WHERE jid='\(mergeSQLQuote(chatJID))' LIMIT 1") { person = $0.text(0) }
            if let person, !person.isEmpty { return mergeMembers(person: person) }
        }
        return [MergeIdentity.member(person: person ?? "", member: "", rawJID: chatJID, resolvedJID: chatJID)]
    }

    /// Full JIDs of every number in this conversation, sorted. Empty for an empty JID (never a valid identity).
    public func mergedJIDs(chatJID: String) -> [String] {
        let jids = mergeMembers(chatJID: chatJID).map(\.jid).filter { !$0.isEmpty }
        if !jids.isEmpty { return jids }
        return chatJID.isEmpty ? [] : [chatJID]
    }
}
