import Foundation
import Testing
@testable import BeeCore

/// Exercises the real macOS Keychain with a throwaway service name. Off by default (a Keychain prompt
/// would block automated runs): run with `BEE_KEYCHAIN_SELFTEST=1 swift test --filter KeychainSelfTest`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BEE_KEYCHAIN_SELFTEST"] == "1"))
struct KeychainSelfTest {
    @Test func storesLoadsAndDeletesAKey() throws {
        let provider = KeychainKeyProvider(service: "com.digivore.bee.vault.selftest", account: "selftest-\(UUID().uuidString)")
        defer { try? provider.deleteKey() }
        #expect(try provider.loadKey() == nil)

        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try provider.storeKey(key)
        #expect(try provider.loadKey() == key)

        // A second store never replaces the key.
        #expect(throws: VaultError.self) { try provider.storeKey(Data(repeating: 1, count: 32)) }
        #expect(try provider.loadKey() == key)

        try provider.deleteKey()
        #expect(try provider.loadKey() == nil)
    }

    @Test func vaultRoundTripsThroughTheKeychain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bee-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = KeychainKeyProvider(service: "com.digivore.bee.vault.selftest", account: "vault-\(UUID().uuidString)")
        defer { try? provider.deleteKey() }
        let file = directory.appendingPathComponent("secrets.vault")
        let id = UUID()

        let vault = EncryptedFileVault(fileURL: file, keyProvider: provider)
        try vault.setSecret("keychain-backed-secret", for: id)
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("keychain-backed-secret"))

        let reopened = EncryptedFileVault(fileURL: file, keyProvider: provider)
        #expect(try reopened.secret(for: id) == "keychain-backed-secret")
    }
}
