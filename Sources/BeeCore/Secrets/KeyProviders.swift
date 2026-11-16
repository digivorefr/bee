import Foundation
import Security
import Synchronization

// MARK: - Keychain

/// Keeps the vault key in the login keychain as a single generic password item.
///
/// One item means at most one Keychain prompt after an application update, whatever the number of secrets.
/// The item lives in the file-based keychain: the application carries no entitlement, so the data
/// protection keychain and access groups are out of reach.
public struct KeychainKeyProvider: VaultKeyProvider {
    public let service: String
    public let account: String

    public init(service: String = "com.digivore.bee.vault", account: String = "master-key") {
        self.service = service
        self.account = account
    }

    public func loadKey() throws -> Data? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.error(for: status) }
        guard let key = result as? Data else {
            throw VaultError.keychain(status: errSecDecode, message: "The vault key item holds no data.")
        }
        return key
    }

    public func storeKey(_ key: Data) throws {
        var attributes = identity
        attributes[kSecValueData as String] = key
        // Honoured by the data protection keychain only; the file-based keychain ignores both and
        // never syncs. Stated anyway so the item stays device-bound wherever it ends up.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecAttrLabel as String] = "Bee Vault Key"
        attributes[kSecAttrDescription as String] = "Encryption key for the credentials saved in Bee"
        attributes[kSecAttrComment as String] =
            "Protects the tokens, passwords and API keys saved in Bee. Without it they cannot be recovered."

        // Never replace an existing key: it may already protect a vault (two instances starting
        // together). The caller reloads the stored key on this error.
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    public func deleteKey() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Maps a Keychain status to the error shown to the person.
    static func error(for status: OSStatus) -> VaultError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .accessDenied
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return .keychain(status: status, message: message)
        }
    }
}

// MARK: - In memory

/// Keeps the vault key in memory only. For tests and previews.
public final class InMemoryKeyProvider: VaultKeyProvider {
    private let storage: Mutex<Data?>

    public init(key: Data? = nil) {
        storage = Mutex(key)
    }

    public func loadKey() throws -> Data? {
        storage.withLock { $0 }
    }

    public func storeKey(_ key: Data) throws {
        storage.withLock { $0 = key }
    }

    public func deleteKey() throws {
        storage.withLock { $0 = nil }
    }
}
