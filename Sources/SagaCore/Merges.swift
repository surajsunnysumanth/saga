import Foundation

/// People who are really one person (new phone number, old number deleted from contacts). Stored in the vault
/// (`config/merges.json`) and applied on every library rebuild, so nothing is rewritten and a merge can always be undone.
public struct PersonMerge: Codable, Identifiable, Hashable, Sendable {
    public var id: String { keys.sorted().joined(separator: "+") }
    public var keys: [String]          // person keys; keys[0] is the one the group is shown as
    public var name: String            // display name for the merged person
    public init(keys: [String], name: String) { self.keys = keys; self.name = name }
}

public enum MergeWriteError: LocalizedError {
    case notPersisted(keys: [String])
    public var errorDescription: String? {
        switch self {
        case .notPersisted(let keys):
            return "The merge was not saved (older file may be read-only or the vault is locked): \(keys.count) entries."
        }
    }
}

public enum MergeConfig {
    static let name = "merges.json"
    /// Lenient read for display; mutators use `loadChecked`.
    public static func load(_ v: Vault) -> [PersonMerge] { (try? loadChecked(v)) ?? [] }
    public static func loadChecked(_ v: Vault) throws -> [PersonMerge] {
        guard let d = try v.readConfig(name) else { return [] }
        guard let o = try? JSONDecoder().decode([String: [PersonMerge]].self, from: d) else {
            if v.protection == .encrypted { throw VaultEncryptionError.invalidMetadata }
            return []
        }
        return o["merges"] ?? []
    }
    public static func save(_ m: [PersonMerge], to v: Vault) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try v.writeConfig(try e.encode(["merges": m.filter { $0.keys.count > 1 }]), name: name)
    }
    /// Adds a merge; any existing group sharing a key is folded in. `keys[0]` becomes the primary.
    public static func add(keys: [String], name: String, to v: Vault) throws {
        var all = try loadChecked(v); var union = keys
        for g in all where !Set(g.keys).isDisjoint(with: keys) { for k in g.keys where !union.contains(k) { union.append(k) } }
        all.removeAll { !Set($0.keys).isDisjoint(with: union) }
        all.append(PersonMerge(keys: union, name: name))
        try save(all, to: v)
        // A merge the user approved must survive a restart. Verify it actually landed rather than
        // assuming the write worked: a silent no-op here looks exactly like "the app forgot my merge".
        let written = try loadChecked(v)
        guard written.contains(where: { $0.keys.sorted() == union.sorted() }) else {
            throw MergeWriteError.notPersisted(keys: union)
        }
    }
    public static func remove(_ m: PersonMerge, from v: Vault) throws { try save(loadChecked(v).filter { $0.id != m.id }, to: v) }
}

/// People the archive thinks are one person, with the evidence behind it. Suggestions never merge anything:
/// the user still confirms. See `MergeSuggestions.swift` for the engine.
public struct MergeSuggestion: Identifiable, Sendable {
    /// Stable identity: the sorted member keys. Renaming a person or reordering the rows doesn't change it.
    public var id: String { people.map(\.key).sorted().joined(separator: "+") }
    public let name: String
    public let people: [PersonRow]
    public let reasons: [MergeReason]
    public let confidence: MergeConfidence
    public init(name: String, people: [PersonRow], reasons: [MergeReason] = [], confidence: MergeConfidence = .low) {
        self.name = name; self.people = people; self.reasons = reasons; self.confidence = confidence
    }

    /// Busiest person first, then key order, so every screen and test sees the same order.
    static func personOrder(_ a: PersonRow, _ b: PersonRow) -> Bool {
        a.received != b.received ? a.received > b.received : a.key < b.key
    }

    /// Fallback labels the resolver invents for people with no name ("+9198…", "Unknown (1234)"). They must never be
    /// treated as evidence that two people share a name.
    static func isPlaceholderName(_ name: String) -> Bool {
        name.isEmpty || name.hasPrefix("+") || name.hasPrefix("Unknown (")
    }
}
