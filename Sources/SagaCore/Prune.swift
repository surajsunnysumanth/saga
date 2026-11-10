import Foundation

/// A cleanup rule for one chat. Rules live in the vault (`config/prune.json`) and are applied every time the library is rebuilt,
/// so spam stays hidden after new syncs. The messages themselves are never deleted from the vault; remove a rule to bring them back.
public struct PruneRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String { chat }
    public var chat: String                 // chat JID
    public var label: String                // chat name when the rule was made (display only)
    public var hideChat = false             // hide the whole chat
    public var dropMedia = false            // hide photos/videos/files (a caption keeps its text)
    public var dropDuplicates = false       // hide repeats of the same text or the same file
    public var dropLinkOnly = false         // hide messages that are only a link
    public var dropSenders: [String] = []   // person keys whose messages are hidden in this chat
    public var isEmpty: Bool { !hideChat && !dropMedia && !dropDuplicates && !dropLinkOnly && dropSenders.isEmpty }
    public init(chat: String, label: String) { self.chat = chat; self.label = label }

    public var summary: String {
        if hideChat { return "Chat hidden" }
        var p: [String] = []
        if dropMedia { p.append("media") }
        if dropDuplicates { p.append("repeats") }
        if dropLinkOnly { p.append("link-only posts") }
        if !dropSenders.isEmpty { p.append("\(dropSenders.count) sender(s)") }
        return p.isEmpty ? "No effect" : "Hiding " + p.joined(separator: ", ")
    }
}

public enum PruneConfig {
    static let name = "prune.json"
    /// Lenient read for display: any failure shows no rules. Use `loadChecked` before changing anything.
    public static func load(_ vault: Vault) -> [PruneRule] { (try? loadChecked(vault)) ?? [] }
    /// Locked/authentication/I-O failures throw (never an empty list). Malformed JSON throws for encrypted vaults only.
    public static func loadChecked(_ vault: Vault) throws -> [PruneRule] {
        guard let d = try vault.readConfig(name) else { return [] }
        guard let r = try? JSONDecoder().decode([String: [PruneRule]].self, from: d) else {
            if vault.protection == .encrypted { throw VaultEncryptionError.invalidMetadata }
            return []
        }
        return r["rules"] ?? []
    }
    public static func save(_ rules: [PruneRule], to vault: Vault) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try vault.writeConfig(try enc.encode(["rules": rules.filter { !$0.isEmpty }]), name: name)
    }
}

/// Decides, message by message and in time order, what a set of rules hides.
struct Pruner {
    let byChat: [String: PruneRule]
    var seenText = Set<String>(), seenFile = Set<String>()
    init(rules: [PruneRule]) { byChat = Dictionary(rules.map { ($0.chat, $0) }, uniquingKeysWith: { $1 }) }

    func hidesChat(_ jid: String) -> Bool { byChat[jid]?.hideChat == true }

    static func normalise(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    static let linkOnly = try! NSRegularExpression(pattern: #"^(?:https?://\S+|www\.\S+)(?:\s+(?:https?://\S+|www\.\S+))*$"#, options: [.caseInsensitive])
    static func isLinkOnly(_ t: String) -> Bool { linkOnly.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }

    enum Verdict { case keep, keepWithoutMedia, drop }

    mutating func judge(chat: String, text: String?, hasMedia: Bool, fileHash: String?, person: String, fromMe: Bool) -> Verdict {
        guard let r = byChat[chat] else { return .keep }
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromMe, r.dropSenders.contains(person) { return .drop }
        if r.dropLinkOnly, !hasMedia, !t.isEmpty, Self.isLinkOnly(t) { return .drop }
        if r.dropDuplicates {
            if t.count >= 15 { let k = chat + "\u{1}" + Self.normalise(t); if !seenText.insert(k).inserted { return .drop } }
            if hasMedia, let h = fileHash, !h.isEmpty { let k = chat + "\u{1}" + h; if !seenFile.insert(k).inserted { return t.isEmpty ? .drop : .keepWithoutMedia } }
        }
        if r.dropMedia, hasMedia { return t.isEmpty ? .drop : .keepWithoutMedia }
        return .keep
    }
}

/// What a group looks like, so Saga can suggest cleanups. Computed from the built library.
public struct ChatSpamStats: Identifiable, Sendable {
    public var id: Int64 { chatID }
    public let chatID: Int64, jid: String, name: String
    public let messages: Int, mine: Int, mediaOnly: Int, linkOnly: Int, strangers: Int
    public let repeatedText: Int, repeatedFiles: Int
    public var mediaPct: Int { 100 * mediaOnly / max(1, messages) }
    public var linkPct: Int { 100 * linkOnly / max(1, messages) }
    public var repeatPct: Int { 100 * (repeatedText + repeatedFiles) / max(1, messages) }
    public var strangerPct: Int { 100 * strangers / max(1, messages) }
    public var iPost: Bool { mine * 100 >= messages * 2 }          // you write at least 2% of the messages

    /// Suggested rule, or nil if the chat looks normal. A chat you take part in only gets the "repeats" cleanup.
    public var suggestion: PruneRule? {
        var r = PruneRule(chat: jid, label: name)
        if !iPost && mine == 0 && strangerPct >= 60 && messages >= 300 { r.hideChat = true; return r }
        if repeatPct >= 5 { r.dropDuplicates = true }
        if !iPost && mediaPct >= 40 { r.dropMedia = true }
        if !iPost && linkPct >= 25 { r.dropLinkOnly = true }
        return r.isEmpty ? nil : r
    }
    /// Rough count of messages the given rule would hide (used for the preview).
    public func estimate(_ r: PruneRule) -> Int {
        if r.hideChat { return messages }
        var n = 0
        if r.dropMedia { n += mediaOnly }
        else if r.dropDuplicates { n += repeatedText + repeatedFiles }
        if r.dropDuplicates && r.dropMedia { n += repeatedText }
        if r.dropLinkOnly { n += linkOnly }
        return min(n, messages)
    }
}

public enum PruneScan {
    /// Groups with at least `minMessages` messages (or one specific chat, any size), most "spammy" first.
    public static func scan(store: VaultStore, minMessages: Int = 300, onlyChat: Int64? = nil) throws -> [ChatSpamStats] {
        let scope = onlyChat.map { "c.chat_id=\($0)" } ?? "c.is_group=1"
        var base: [Int64: (String, String, Int, Int, Int, Int, Int)] = [:]
        try store.db.query("""
            SELECT c.chat_id, c.jid, c.name, count(*) n, sum(m.from_me) mine,
                   sum(md.msg_id IS NOT NULL AND COALESCE(m.text,'')='') media_only,
                   sum(COALESCE(m.text,'') GLOB 'http*' AND instr(trim(m.text),' ')=0 AND md.msg_id IS NULL) link_only,
                   sum(p.resolved=0 AND m.from_me=0) strangers
            FROM messages m JOIN chats c USING(chat_id) LEFT JOIN media md ON md.msg_id=m.id LEFT JOIN people p ON p.person=m.person
            WHERE \(scope) GROUP BY c.chat_id \(onlyChat == nil ? "HAVING n >= \(minMessages)" : "")
            """) { base[$0.int(0)] = ($0.text(1) ?? "", $0.text(2) ?? "", Int($0.int(3)), Int($0.int(4)), Int($0.int(5)), Int($0.int(6)), Int($0.int(7))) }
        var rt: [Int64: Int] = [:], rf: [Int64: Int] = [:]
        try store.db.query("SELECT chat_id, sum(c-1) FROM (SELECT chat_id, count(*) c FROM messages WHERE length(text)>=15 GROUP BY chat_id, lower(trim(replace(replace(replace(text,'    ',' '),'  ',' '),'  ',' ')))) WHERE c>=2 GROUP BY chat_id") { rt[$0.int(0)] = Int($0.int(1)) }
        try store.db.query("SELECT chat_id, sum(c-1) FROM (SELECT chat_id, count(*) c FROM media WHERE file_hash IS NOT NULL AND file_hash<>'' GROUP BY chat_id, file_hash) WHERE c>=2 GROUP BY chat_id") { rf[$0.int(0)] = Int($0.int(1)) }
        let out = base.map { id, b in
            ChatSpamStats(chatID: id, jid: b.0, name: b.1, messages: b.2, mine: b.3, mediaOnly: b.4, linkOnly: b.5, strangers: b.6, repeatedText: rt[id] ?? 0, repeatedFiles: rf[id] ?? 0)
        }
        return out.sorted { ($0.suggestion.map($0.estimate) ?? 0) > ($1.suggestion.map($1.estimate) ?? 0) }
    }
}
