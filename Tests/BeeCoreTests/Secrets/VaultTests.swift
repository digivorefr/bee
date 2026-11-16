import Foundation
import Security
import Testing
@testable import BeeCore

@Suite struct EncryptedFileVaultTests {
    private let secretValue = "s3cr3t-plaintext-value"

    @Test func roundTripAcrossInstances() throws {
        let directory = try TemporaryDirectory()
        let provider = InMemoryKeyProvider()
        let first = UUID()
        let second = UUID()
        let vault = EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: provider)
        try vault.setSecret(secretValue, for: first)
        try vault.setSecret("other-value", for: second)

        // The key was generated on first use and handed to the provider.
        #expect(try provider.loadKey()?.count == 32)

        let reopened = EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: provider)
        #expect(!reopened.isUnlocked)
        #expect(try reopened.secret(for: first) == secretValue)
        #expect(try reopened.allSecrets() == [first: secretValue, second: "other-value"])
        #expect(reopened.isUnlocked)
    }

    @Test func fileNeverHoldsPlaintext() throws {
        let directory = try TemporaryDirectory()
        let vault = EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: makeKeyProvider())
        let id = UUID()
        try vault.setSecret(secretValue, for: id)

        let data = try Data(contentsOf: directory.file("secrets.vault"))
        #expect(!data.contains(secretValue))
        #expect(!data.contains(Data(secretValue.utf8).base64EncodedString()))
        #expect(!data.contains(id.uuidString))
        #expect(data.contains("AES-256-GCM"))
        #expect(data.contains("\"sealed\""))
    }

    @Test func wrongKeyIsCorrupted() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("secrets.vault")
        try EncryptedFileVault(fileURL: url, keyProvider: makeKeyProvider()).setSecret(secretValue, for: UUID())
        let before = try Data(contentsOf: url)

        let other = EncryptedFileVault(fileURL: url, keyProvider: makeKeyProvider())
        #expect(throws: VaultError.corrupted) { try other.unlock() }
        #expect(!other.isUnlocked)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func existingFileWithoutKeyIsKeyMissingAndUntouched() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("secrets.vault")
        let provider = InMemoryKeyProvider()
        try EncryptedFileVault(fileURL: url, keyProvider: provider).setSecret(secretValue, for: UUID())
        let before = try Data(contentsOf: url)
        try provider.deleteKey()

        let vault = EncryptedFileVault(fileURL: url, keyProvider: provider)
        #expect(throws: VaultError.keyMissing) { try vault.unlock() }
        #expect(throws: VaultError.keyMissing) { try vault.setSecret("new", for: UUID()) }
        #expect(throws: VaultError.keyMissing) { try vault.replaceAll([:]) }
        // No key was generated over the existing vault, and the file is intact.
        #expect(try provider.loadKey() == nil)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func tamperedFileIsCorrupted() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("secrets.vault")
        let provider = makeKeyProvider()
        try EncryptedFileVault(fileURL: url, keyProvider: provider).setSecret(secretValue, for: UUID())

        // Flip one character of the sealed payload.
        var text = try String(contentsOf: url, encoding: .utf8)
        let marker = try #require(text.range(of: "\"sealed\" : \""))
        let target = text.index(marker.upperBound, offsetBy: 20)
        text.replaceSubrange(target...target, with: text[target] == "A" ? "B" : "A")
        try Data(text.utf8).write(to: url)
        let tampered = try Data(contentsOf: url)

        let vault = EncryptedFileVault(fileURL: url, keyProvider: provider)
        #expect(throws: VaultError.corrupted) { try vault.allSecrets() }
        #expect(try Data(contentsOf: url) == tampered)

        // An unreadable envelope is reported, never reset.
        try Data("not a vault".utf8).write(to: url)
        #expect(throws: VaultError.corrupted) { try vault.unlock() }
        #expect(try Data(contentsOf: url) == Data("not a vault".utf8))
    }

    @Test func relabelledEnvelopeIsCorrupted() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("secrets.vault")
        let provider = makeKeyProvider()
        try EncryptedFileVault(fileURL: url, keyProvider: provider).setSecret(secretValue, for: UUID())
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        try Data(text.utf8).write(to: url)
        #expect(throws: VaultError.corrupted) {
            try EncryptedFileVault(fileURL: url, keyProvider: provider).unlock()
        }
    }

    @Test func fileAndDirectoryPermissions() throws {
        let directory = try TemporaryDirectory()
        let folder = directory.url.appendingPathComponent("data", isDirectory: true)
        let url = folder.appendingPathComponent("secrets.vault")
        try EncryptedFileVault(fileURL: url, keyProvider: makeKeyProvider()).setSecret(secretValue, for: UUID())
        #expect(try permissions(of: url) == 0o600)
        #expect(try permissions(of: folder) == 0o700)
        // No temporary file is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["secrets.vault"])
    }

    @Test func lockForgetsThenReadsUnlockAgain() throws {
        let directory = try TemporaryDirectory()
        let vault = EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: makeKeyProvider())
        let id = UUID()
        try vault.setSecret(secretValue, for: id)
        #expect(vault.isUnlocked)
        vault.lock()
        #expect(!vault.isUnlocked)
        #expect(try vault.secret(for: id) == secretValue)
        #expect(vault.isUnlocked)
        try vault.unlock()
        #expect(vault.isUnlocked)
    }

    @Test func removalOrphansAndUnchangedWrites() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("secrets.vault")
        let vault = EncryptedFileVault(fileURL: url, keyProvider: makeKeyProvider())
        let kept = UUID()
        let dropped = UUID()
        try vault.setSecret("kept-value", for: kept)
        try vault.setSecret("dropped-value", for: dropped)

        try vault.replaceAll([kept: "kept-value", UUID(): ""])
        #expect(try vault.allSecrets() == [kept: "kept-value"])

        // Same content: the file is not rewritten.
        let identity = try fileIdentity(url)
        try vault.replaceAll([kept: "kept-value"])
        try vault.setSecret("kept-value", for: kept)
        try vault.setSecret(nil, for: dropped)
        #expect(try fileIdentity(url) == identity)

        // Same plaintext sealed twice gives different bytes: the nonce is fresh on every write.
        let sealedOnce = try Data(contentsOf: url)
        try vault.setSecret("changed", for: kept)
        try vault.setSecret("kept-value", for: kept)
        #expect(try Data(contentsOf: url) != sealedOnce)

        try vault.setSecret("", for: kept)
        #expect(try vault.allSecrets().isEmpty)
    }

    @Test func concurrentAccess() throws {
        let directory = try TemporaryDirectory()
        let provider = InMemoryKeyProvider()
        let url = directory.file("secrets.vault")
        let vault = EncryptedFileVault(fileURL: url, keyProvider: provider)
        let ids = (0..<40).map { _ in UUID() }
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            try? vault.setSecret("value-\(index)", for: ids[index])
            _ = try? vault.allSecrets()
            if index % 10 == 0 { vault.lock() }
        }
        let expected = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, "value-\($0)") })
        #expect(try vault.allSecrets() == expected)
        #expect(try EncryptedFileVault(fileURL: url, keyProvider: provider).allSecrets() == expected)
    }
}

@Suite struct KeyProviderTests {
    @Test func inMemoryProviderStoresAndDeletes() throws {
        let provider = InMemoryKeyProvider()
        #expect(try provider.loadKey() == nil)
        try provider.storeKey(Data([1, 2, 3]))
        #expect(try provider.loadKey() == Data([1, 2, 3]))
        try provider.deleteKey()
        #expect(try provider.loadKey() == nil)
    }

    /// Pure status mapping: no Keychain call is made.
    @Test func keychainStatusMapping() {
        #expect(KeychainKeyProvider.error(for: errSecUserCanceled) == .accessDenied)
        #expect(KeychainKeyProvider.error(for: errSecAuthFailed) == .accessDenied)
        guard case .keychain(let status, let message) = KeychainKeyProvider.error(for: errSecDuplicateItem) else {
            Issue.record("Expected a keychain error")
            return
        }
        #expect(status == errSecDuplicateItem)
        #expect(!message.isEmpty)
    }

    @Test func inMemoryVaultSemantics() throws {
        let vault = InMemoryVault()
        let id = UUID()
        try vault.setSecret("value", for: id)
        #expect(try vault.secret(for: id) == "value")
        try vault.replaceAll([UUID(): ""])
        #expect(try vault.allSecrets().isEmpty)
    }
}
