import Foundation

/// The owner's address book, exported from Android over ADB.
///
/// This is the only identity evidence in the archive that is not an inference: if two numbers sit
/// under one saved contact, they are one person because the owner said so. Read from
/// `config/phone-contacts.json` so it travels with the vault.
public struct PhoneContact: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let numbers: [String]

    /// Person keys are the last ten digits of a number, so the same rule applies here — literally the same
    /// function the JID path uses (`normalizePhone`), not a second copy of it. A saved number written
    /// `098000 00101`, `+91 98000 00101` or `919800000101` therefore all reduce to `9800000101`, which is what
    /// a chat's JID reduces to. Numbers too short to be a person key are dropped rather than keyed as-is.
    public var keys: [String] {
        numbers.map(normalizePhone).filter { $0.count == 10 }
    }
}

public enum PhoneContacts {
    public static let fileName = "phone-contacts.json"

    private struct File: Codable { let contacts: [PhoneContact] }

    public static func load(in vault: Vault) -> [PhoneContact] {
        guard let data = try? vault.readConfig(fileName),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.contacts
    }

    /// Saved names by person key. A name only wins when every number under that contact agrees on it,
    /// so a conflicted contact cannot make a chat change identity between rebuilds.
    public static func names(in vault: Vault) -> [String: String] {
        var out: [String: String] = [:]
        var conflicted: Set<String> = []
        for contact in load(in: vault) {
            let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for key in Set(contact.keys) {
                if let existing = out[key], existing != name { conflicted.insert(key) }
                out[key] = name
            }
        }
        for key in conflicted { out.removeValue(forKey: key) }
        return out
    }

    /// Contacts that hold more than one number: a merge the owner has already made in their address book.
    public static func groups(in vault: Vault) -> [(name: String, keys: [String])] {
        load(in: vault).compactMap { c in
            let keys = Array(Set(c.keys)).sorted()
            return keys.count > 1 ? (c.name, keys) : nil
        }
    }
}
