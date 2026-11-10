import Foundation

/// Chats the owner has looked at and decided are not people: shops, delivery bots, newsletters that
/// slipped through, a wrong number. They stop appearing in the Unnamed list. Nothing is deleted and no
/// message is touched — the chat stays in the archive exactly as it was, and restoring brings the row back.
///
/// Stored in `config/unnamed-ignores.json` as `{"ignored":["<chat jid>", …]}`. Keyed by the full chat JID,
/// which survives a rebuild (chat ids do not), and read-only for the index: no rebuild is needed to ignore
/// or restore, because the list is filtered when it is queried.
public enum UnnamedIgnores {
    public static let fileName = "unnamed-ignores.json"

    public static func normalized(_ jids: [String]) -> [String] {
        Array(Set(jids.filter { !$0.isEmpty })).sorted()
    }

    /// Lenient read for display: a damaged file means "nothing ignored", and is never rewritten by this call.
    public static func load(_ vault: Vault) -> [String] { (try? loadChecked(vault)) ?? [] }

    /// Strict read for mutators, so a damaged file is reported instead of being silently replaced.
    public static func loadChecked(_ vault: Vault) throws -> [String] {
        guard let data = try vault.readConfig(fileName) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["ignored"] as? [String] else { throw UnnamedIgnoreError.invalidList }
        return normalized(raw)
    }

    public static func save(_ jids: [String], to vault: Vault) throws {
        let data = try JSONSerialization.data(withJSONObject: ["ignored": normalized(jids)],
                                              options: [.prettyPrinted, .sortedKeys])
        try vault.writeConfig(data, name: fileName)
    }

    public static func add(_ jid: String, to vault: Vault) throws {
        guard !jid.isEmpty else { return }
        var all = try loadChecked(vault)
        guard !all.contains(jid) else { return }
        all.append(jid)
        try save(all, to: vault)
        guard try loadChecked(vault).contains(jid) else { throw UnnamedIgnoreError.notPersisted }
    }

    public static func remove(_ jid: String, from vault: Vault) throws {
        let kept = try loadChecked(vault).filter { $0 != jid }
        try save(kept, to: vault)
    }
}

public enum UnnamedIgnoreError: Error, LocalizedError {
    case invalidList
    case notPersisted

    public var errorDescription: String? {
        switch self {
        case .invalidList: "The hidden-chats file in your archive is damaged."
        case .notPersisted: "That chat could not be hidden."
        }
    }
}
