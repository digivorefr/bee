import Foundation

/// Why the secret vault could not be read or written.
public enum VaultError: Error, Equatable, Sendable, LocalizedError {
    /// The person denied or cancelled the Keychain prompt.
    case accessDenied
    /// A vault file exists but the key that encrypts it is gone.
    case keyMissing
    /// The vault file is unreadable or failed authentication (wrong key or altered content).
    case corrupted
    /// The Keychain answered with an unexpected status.
    case keychain(status: Int32, message: String)
    /// A file-system failure.
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Access to the Bee vault key in the Keychain was denied."
        case .keyMissing:
            "The key that protects your saved secrets is missing from the Keychain."
        case .corrupted:
            "The secret vault is damaged or was encrypted with a different key."
        case .keychain(let status, let message):
            "The Keychain reported an error (\(status)): \(message)"
        case .io(let message):
            "The secret vault file could not be accessed: \(message)"
        }
    }
}
