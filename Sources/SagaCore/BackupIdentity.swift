import Foundation
import CryptoKit

/// What a backup says about itself, reduced to things that survive a round trip through
/// hashing: how big it is, when it runs, which conversations it holds, and a sample of its
/// message identities.
///
/// The phone's own number is deliberately not part of this. An Android `msgstore.db` does not
/// record it reliably (props has no JID, and the sender rows on from-me messages point at
/// groups and at other people), so a check that claimed to verify "the same number" would be
/// guessing. Conversation fingerprints are evidence we actually have.
public struct BackupIdentity: Codable, Sendable, Equatable {
    public var source: String
    public var chats: Int
    public var messages: Int
    public var first: Date?
    public var last: Date?
    /// SHA-256 prefixes of chat JIDs. Never the JIDs themselves: this file can be shared.
    public var chatPrint: [String]
    /// The one-to-one chats only. Two different people can share a dozen group chats;
    /// they almost never share the same set of private conversations.
    public var directPrint: [String]
    /// SHA-256 prefixes of message uids, sampled across the archive.
    public var uidPrint: [String]

    public init(source: String, chats: Int, messages: Int, first: Date?, last: Date?,
                chatPrint: [String], directPrint: [String] = [], uidPrint: [String]) {
        self.source = source; self.chats = chats; self.messages = messages
        self.first = first; self.last = last
        self.chatPrint = chatPrint; self.directPrint = directPrint; self.uidPrint = uidPrint
    }
}

/// One named source of history: a phone, or a number, as the owner thinks of it.
public struct VaultProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var source: String
    public var createdAt: Date
    public var lastImportAt: Date?
    public var messages: Int
    public var chats: Int
    public var first: Date?
    public var last: Date?
    public var chatPrint: [String]
    public var directPrint: [String] = []
    public var uidPrint: [String]

    public init(id: String = UUID().uuidString, name: String, identity: BackupIdentity, at: Date = Date()) {
        self.id = id
        self.name = name
        self.source = identity.source
        self.createdAt = at
        self.lastImportAt = at
        self.messages = identity.messages
        self.chats = identity.chats
        self.first = identity.first
        self.last = identity.last
        self.chatPrint = identity.chatPrint
        self.directPrint = identity.directPrint
        self.uidPrint = identity.uidPrint
    }

    /// Folds a newer backup of the same history into this profile.
    public mutating func absorb(_ identity: BackupIdentity, at: Date = Date()) {
        messages = max(messages, identity.messages)
        chats = max(chats, identity.chats)
        first = [first, identity.first].compactMap { $0 }.min()
        last = [last, identity.last].compactMap { $0 }.max()
        chatPrint = Array(Set(chatPrint).union(identity.chatPrint)).sorted().prefix(400).map { $0 }
        directPrint = Array(Set(directPrint).union(identity.directPrint)).sorted().prefix(300).map { $0 }
        uidPrint = Array(Set(uidPrint).union(identity.uidPrint)).sorted().prefix(600).map { $0 }
        lastImportAt = at
        source = identity.source
    }
}

/// The answer to "is this the archive I already have?".
public enum ProfileVerdict: Sendable, Equatable {
    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    /// Shares its identity with an existing profile and carries more history.
    case continuation(chatOverlap: Double, uidOverlap: Double, newMessages: Int)
    /// Looks like the same account, but the two copies share almost nothing (a migration,
    /// a pruned backup, or an Android → iPhone move).
    case related(chatOverlap: Double, uidOverlap: Double)
    /// A different account, or a different person's phone.
    case different(chatOverlap: Double, uidOverlap: Double)
    /// No existing profile to compare against.
    case first

    public var isContinuation: Bool { if case .continuation = self { return true }; return false }

    /// When the evidence is thin, keep histories apart: merging two people's archives is
    /// hard to undo, and a separate profile costs nothing.
    public var recommendsSeparate: Bool {
        switch self {
        case .continuation, .first: return false
        case .related, .different: return true
        }
    }

    public var detail: String {
        switch self {
        case .first:
            return "This is the first backup in this archive."
        case let .continuation(chats, uids, new):
            return "Same history as before: \(Self.pct(chats)) of conversations match and \(Self.pct(uids)) of sampled messages are already here, with \(new.formatted()) new."
        case let .related(chats, uids):
            return "\(Self.pct(chats)) of conversations match, but only \(Self.pct(uids)) of sampled messages do — likely the same account from a different phone or platform."
        case let .different(chats, uids):
            return "Only \(Self.pct(chats)) of conversations and \(Self.pct(uids)) of sampled messages match. This looks like a different account."
        }
    }
}

public enum ProfileMatcher {
    /// Jaccard-ish overlap, normalised by the smaller side so a much newer backup still
    /// scores as a continuation rather than being punished for having more conversations.
    static func overlap(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let sa = Set(a), sb = Set(b)
        let shared = sa.intersection(sb).count
        return Double(shared) / Double(min(sa.count, sb.count))
    }

    public static func compare(_ identity: BackupIdentity, to profiles: [VaultProfile]) -> (profile: VaultProfile?, verdict: ProfileVerdict) {
        guard !profiles.isEmpty else { return (nil, .first) }
        var best: (VaultProfile, Double, Double, Double)?
        for p in profiles {
            let chats = overlap(identity.chatPrint, p.chatPrint)
            let uids = overlap(identity.uidPrint, p.uidPrint)
            let direct = overlap(identity.directPrint, p.directPrint)
            let score = direct * 0.5 + chats * 0.2 + uids * 0.3
            if best == nil || score > best!.1 * 0.5 + best!.2 * 0.2 + best!.3 * 0.3 {
                best = (p, chats, uids, direct)
            }
        }
        guard let (profile, chats, uids, direct) = best else { return (nil, .first) }
        if uids >= 0.5 || (direct >= 0.6 && uids >= 0.2) {
            let new = max(0, identity.messages - profile.messages)
            return (profile, .continuation(chatOverlap: chats, uidOverlap: uids, newMessages: new))
        }
        // Private conversations are the tell. Two phones belonging to different people can
        // share every group; they will not share their one-to-one chats.
        if direct < 0.25 {
            return (profile, .different(chatOverlap: chats, uidOverlap: uids))
        }
        return (profile, .related(chatOverlap: chats, uidOverlap: uids))
    }
}

// MARK: - Storage

public enum ProfilesStore {
    static let name = "profiles.json"

    public static func load(in vault: Vault) -> [VaultProfile] {
        guard let data = try? vault.readConfig(name), !data.isEmpty else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([VaultProfile].self, from: data)) ?? []
    }

    public static func save(_ profiles: [VaultProfile], in vault: Vault) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try vault.writeConfig(try encoder.encode(profiles), name: name)
    }

    @discardableResult
    public static func upsert(_ identity: BackupIdentity, named name: String, in vault: Vault) throws -> VaultProfile {
        var profiles = load(in: vault)
        let (match, verdict) = ProfileMatcher.compare(identity, to: profiles)
        if let match, verdict.isContinuation, let i = profiles.firstIndex(where: { $0.id == match.id }) {
            profiles[i].absorb(identity)
            try save(profiles, in: vault)
            return profiles[i]
        }
        let profile = VaultProfile(name: name, identity: identity)
        profiles.append(profile)
        try save(profiles, in: vault)
        return profile
    }
}

// MARK: - Reading a backup

public enum BackupIdentityReader {
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads only what a fingerprint needs: counts, span, chat JIDs and a sample of message
    /// keys. One pass over indexes, no message text and no media.
    public static func read(msgstore path: String, source: String, sample: Int = 500) throws -> BackupIdentity {
        let db = try SQLiteDB(path: path, readOnly: true)
        var messages = 0
        var minTs = Int64.max, maxTs = Int64.min
        try? db.query("SELECT count(*), coalesce(min(timestamp),0), coalesce(max(timestamp),0) FROM message") { r in
            messages = Int(r.int(0)); minTs = r.int(1); maxTs = r.int(2)
        }
        var chats: [(id: Int64, jid: String, server: String)] = []
        try? db.query("SELECT c._id, coalesce(j.raw_string,''), coalesce(j.server,'') FROM chat c LEFT JOIN jid j ON j._id = c.jid_row_id") { r in
            chats.append((r.int(0), r.text(1) ?? "", r.text(2) ?? ""))
        }
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0.jid) })

        var uids: [String] = []
        try? db.query("""
            SELECT chat_row_id, coalesce(key_id,''), from_me FROM message
            WHERE key_id IS NOT NULL AND key_id <> '' ORDER BY _id DESC LIMIT \(max(1, sample))
            """) { r in
            let jid = byID[r.int(0)] ?? ""
            uids.append(hash("\(jid)|\(r.text(1) ?? "")|\(r.int(2))"))
        }

        let first = minTs == Int64.max ? nil : BackupIdentityReader.date(minTs)
        let last = maxTs == Int64.min ? nil : BackupIdentityReader.date(maxTs)
        return BackupIdentity(source: source, chats: chats.count, messages: messages,
                              first: first, last: last,
                              chatPrint: chats.map { hash($0.jid) }.sorted(),
                              directPrint: chats.filter { $0.server == "s.whatsapp.net" || $0.server == "lid" }.map { hash($0.jid) }.sorted(),
                              uidPrint: uids)
    }
}
