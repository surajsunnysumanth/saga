import Foundation
import Security
import CryptoKit

/// Low-level key store, injectable so tests never touch the real Keychain.
public protocol VaultKeyStore: Sendable {
    /// nil = no item. Throws for any other failure (denied, locked, unavailable).
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func remove(account: String) throws
}

public struct SystemVaultKeyStore: VaultKeyStore {
    public static let service = "app.saga.vault-key"      // distinct from crypt15 backup-key service "app.saga.backup-key"
    public init() {}
    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
    }
    public func read(account: String) throws -> Data? {
        var q = base(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let d = out as? Data else { throw VaultEncryptionError.keychainUnavailable }
        return d
    }
    public func write(_ data: Data, account: String) throws {
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var s = SecItemAdd(add as CFDictionary, nil)
        if s == errSecDuplicateItem {
            s = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard s == errSecSuccess else { throw VaultEncryptionError.keychainUnavailable }
    }
    public func remove(account: String) throws {
        let s = SecItemDelete(base(account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw VaultEncryptionError.keychainUnavailable }
    }
}

/// "Remember on this Mac": stores the data-key capability (never the passphrase or recovery code).
public enum VaultKeychain {
    private struct Blob: Codable { var v: Int; var id: String; var key: Data }

    public static func load(vaultID: String, store: VaultKeyStore = SystemVaultKeyStore()) throws -> VaultUnlockContext? {
        guard let d = try store.read(account: vaultID) else { return nil }
        guard let b = try? JSONDecoder().decode(Blob.self, from: d), b.v == 1, b.key.count == 32 else { throw VaultEncryptionError.keychainUnavailable }
        guard b.id == vaultID else { throw VaultEncryptionError.wrongVault }
        return VaultUnlockContext(vaultID: vaultID, key: SymmetricKey(data: b.key))
    }

    public static func save(_ context: VaultUnlockContext, store: VaultKeyStore = SystemVaultKeyStore()) throws {
        let blob = Blob(v: 1, id: context.vaultID, key: VaultCrypto.keyData(context.key))
        guard let d = try? JSONEncoder().encode(blob) else { throw VaultEncryptionError.keychainUnavailable }
        try store.write(d, account: context.vaultID)
    }

    /// Forgets only the item for this vault.
    public static func delete(vaultID: String, store: VaultKeyStore = SystemVaultKeyStore()) throws {
        try store.remove(account: vaultID)
    }
}
