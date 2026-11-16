import CryptoKit
import Foundation
import Synchronization

/// The production vault: every secret value lives in one file sealed with AES-256-GCM under a key
/// held by a `VaultKeyProvider` (the Keychain in the application).
///
/// File format: a JSON envelope `{"algorithm", "sealed", "version"}` where `sealed` is the Base64 of
/// nonce + ciphertext + tag. The plaintext is a JSON dictionary from slot id to value. Version and
/// algorithm are authenticated, so an envelope edited to claim another format fails to open.
///
/// The key is loaded on first use. It is kept as a `SymmetricKey`, whose storage is zeroed when
/// released; the plain buffers it transits through are wiped as soon as they are consumed.
public final class EncryptedFileVault: SecretVault {
    private struct State {
        var key: SymmetricKey?
        var secrets: [UUID: String] = [:]
    }

    private struct Envelope: Codable {
        var version: Int
        var algorithm: String
        var sealed: Data
    }

    private static let formatVersion = 1
    private static let algorithm = "AES-256-GCM"
    private static let keyByteCount = 32

    private let fileURL: URL
    private let keyProvider: any VaultKeyProvider
    private let state = Mutex(State())

    public init(fileURL: URL, keyProvider: any VaultKeyProvider) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    /// True while the key and the decrypted values are held in memory.
    public var isUnlocked: Bool {
        state.withLock { $0.key != nil }
    }

    /// Loads the key and decrypts the file. Does nothing when already unlocked.
    ///
    /// Without a vault file a missing key is generated and stored. With a vault file a missing key is
    /// `VaultError.keyMissing`: a new key would make the stored secrets unrecoverable.
    public func unlock() throws {
        try state.withLock { state in
            _ = try unlockedKey(&state)
        }
    }

    /// Forgets the key and every decrypted value. The next access unlocks again.
    public func lock() {
        state.withLock { $0 = State() }
    }

    // MARK: SecretVault

    public func secret(for id: UUID) throws -> String? {
        try state.withLock { state in
            _ = try unlockedKey(&state)
            return state.secrets[id]
        }
    }

    public func setSecret(_ value: String?, for id: UUID) throws {
        try state.withLock { state in
            let key = try unlockedKey(&state)
            var updated = state.secrets
            if let value, !value.isEmpty {
                updated[id] = value
            } else {
                updated[id] = nil
            }
            try commit(updated, key: key, to: &state)
        }
    }

    public func replaceAll(_ secrets: [UUID: String]) throws {
        try state.withLock { state in
            let key = try unlockedKey(&state)
            try commit(secrets.filter { !$0.value.isEmpty }, key: key, to: &state)
        }
    }

    public func allSecrets() throws -> [UUID: String] {
        try state.withLock { state in
            _ = try unlockedKey(&state)
            return state.secrets
        }
    }

    // MARK: Key lifecycle

    /// Returns the key, unlocking first when needed. Called with the lock held.
    private func unlockedKey(_ state: inout State) throws -> SymmetricKey {
        if let key = state.key { return key }

        let envelope = try readFile()
        var stored = try keyProvider.loadKey()
        defer { stored?.wipe() }

        let key: SymmetricKey
        var secrets: [UUID: String] = [:]
        if let envelope {
            guard let stored else { throw VaultError.keyMissing }
            guard stored.count == Self.keyByteCount else { throw VaultError.corrupted }
            key = SymmetricKey(data: stored)
            secrets = try Self.open(envelope, with: key)
        } else if let stored, stored.count == Self.keyByteCount {
            key = SymmetricKey(data: stored)
        } else {
            // Nothing is encrypted yet, so a fresh key cannot orphan anything.
            let fresh = SymmetricKey(size: .bits256)
            var exported = fresh.withUnsafeBytes { Data($0) }
            defer { exported.wipe() }
            do {
                try keyProvider.storeKey(exported)
                key = fresh
            } catch {
                // Another instance may have stored its key meanwhile: use that one, never replace it.
                guard var existing = try keyProvider.loadKey(), existing.count == Self.keyByteCount else {
                    throw error
                }
                defer { existing.wipe() }
                key = SymmetricKey(data: existing)
            }
        }
        state.key = key
        state.secrets = secrets
        return key
    }

    // MARK: File

    private func readFile() throws -> Data? {
        do {
            return try SecureFile.read(fileURL)
        } catch {
            throw VaultError.io(error.message)
        }
    }

    /// Writes the new content, then adopts it in memory. Nothing is written when it equals the current content.
    private func commit(_ secrets: [UUID: String], key: SymmetricKey, to state: inout State) throws {
        guard secrets != state.secrets else { return }
        let data = try Self.seal(secrets, with: key)
        do {
            try SecureFile.write(data, to: fileURL)
        } catch {
            throw VaultError.io(error.message)
        }
        state.secrets = secrets
    }

    // MARK: Sealing

    /// Bound to the ciphertext so the envelope cannot be relabelled as another format.
    private static func authenticatedData(version: Int, algorithm: String) -> Data {
        Data("bee.vault/v\(version)/\(algorithm)".utf8)
    }

    private static func seal(_ secrets: [UUID: String], with key: SymmetricKey) throws -> Data {
        let entries = Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.uuidString, $0.value) })
        do {
            var plaintext = try JSONEncoder().encode(entries)
            defer { plaintext.wipe() }
            // No nonce is passed: CryptoKit draws a fresh random one for every seal.
            let box = try AES.GCM.seal(
                plaintext, using: key,
                authenticating: authenticatedData(version: formatVersion, algorithm: algorithm)
            )
            guard let sealed = box.combined else { throw VaultError.io("The vault could not be sealed.") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(Envelope(version: formatVersion, algorithm: algorithm, sealed: sealed))
        } catch let error as VaultError {
            throw error
        } catch {
            throw VaultError.io("The vault could not be sealed.")
        }
    }

    private static func open(_ data: Data, with key: SymmetricKey) throws -> [UUID: String] {
        guard
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.version == formatVersion, envelope.algorithm == algorithm,
            let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
            var plaintext = try? AES.GCM.open(
                box, using: key,
                authenticating: authenticatedData(version: envelope.version, algorithm: envelope.algorithm)
            )
        else { throw VaultError.corrupted }
        defer { plaintext.wipe() }

        guard let entries = try? JSONDecoder().decode([String: String].self, from: plaintext) else {
            throw VaultError.corrupted
        }
        var secrets: [UUID: String] = [:]
        secrets.reserveCapacity(entries.count)
        for (rawID, value) in entries {
            guard let id = UUID(uuidString: rawID) else { throw VaultError.corrupted }
            secrets[id] = value
        }
        return secrets
    }
}

// MARK: - In-memory vault

/// A vault that keeps values in memory only. For tests and previews.
public final class InMemoryVault: SecretVault {
    private let storage: Mutex<[UUID: String]>

    public init(secrets: [UUID: String] = [:]) {
        storage = Mutex(secrets.filter { !$0.value.isEmpty })
    }

    public func secret(for id: UUID) throws -> String? {
        storage.withLock { $0[id] }
    }

    public func setSecret(_ value: String?, for id: UUID) throws {
        storage.withLock { secrets in
            if let value, !value.isEmpty {
                secrets[id] = value
            } else {
                secrets[id] = nil
            }
        }
    }

    public func replaceAll(_ secrets: [UUID: String]) throws {
        let kept = secrets.filter { !$0.value.isEmpty }
        storage.withLock { $0 = kept }
    }

    public func allSecrets() throws -> [UUID: String] {
        storage.withLock { $0 }
    }
}

// MARK: - Wiping

extension Data {
    /// Overwrites the bytes with zeros. Best effort: Foundation copies a buffer that has another owner
    /// before writing, in which case only the copy is cleared.
    mutating func wipe() {
        guard !isEmpty else { return }
        resetBytes(in: startIndex..<endIndex)
    }
}
