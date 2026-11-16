import Foundation
import Testing
@testable import BeeCore

/// A vault that reads fine and refuses every write.
private final class ReadOnlyVault: SecretVault {
    func secret(for id: UUID) throws -> String? { nil }
    func setSecret(_ value: String?, for id: UUID) throws { throw VaultError.io("read-only") }
    func replaceAll(_ secrets: [UUID: String]) throws { throw VaultError.io("read-only") }
    func allSecrets() throws -> [UUID: String] { [:] }
}

@Suite struct WorkspaceStoreTests {
    private static let secrets = [
        "sk-env-variable", "sk-collection-variable", "sk-header-row", "sk-query-row", "sk-bearer-token",
        "sk-basic-password", "sk-api-key-value", "sk-form-field", "sk-urlencoded-row", "sk-global", "sk-scratch",
    ]

    /// A workspace with a secret in every kind of slot.
    private static func makeWorkspace() -> Workspace {
        var login = RequestItem(name: "Login", method: .post, url: "{{baseUrl}}/login")
        login.headers = [KeyValue(key: "X-Api-Key", value: "sk-header-row", isSecret: true), KeyValue(key: "Accept", value: "*/*")]
        login.queryParams = [KeyValue(key: "token", value: "sk-query-row", isSecret: true)]
        login.auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "sk-bearer-token"))
        login.body.mode = .formData
        login.body.formData = [FormField(key: "password", value: "sk-form-field", isSecret: true)]
        login.body.urlEncoded = [KeyValue(key: "secret", value: "sk-urlencoded-row", isSecret: true)]
        let folder = Folder(
            name: "Auth", items: [.request(login)],
            auth: AuthConfig(kind: .basic, basicUsername: "bee", basicPassword: SecretField(value: "sk-basic-password"))
        )
        let api = Collection(
            name: "API", items: [.folder(folder)],
            variables: [Variable(name: "collectionKey", value: "sk-collection-variable", isSecret: true)],
            auth: AuthConfig(kind: .apiKey, apiKeyName: "X-Key", apiKeyValue: SecretField(value: "sk-api-key-value"))
        )
        let other = Collection(name: "Other", items: [.request(RequestItem(name: "Ping", url: "{{baseUrl}}/ping"))])
        let production = Environment(name: "Production", variables: [
            Variable(name: "baseUrl", value: "https://api.example.com"),
            Variable(name: "apiToken", value: "sk-env-variable", isSecret: true),
        ])
        var scratch = RequestItem(name: "Scratch", url: "https://example.com")
        scratch.headers = [KeyValue(key: "Cookie", value: "sk-scratch", isSecret: true)]
        return Workspace(
            collections: [api, other], environments: [production, Environment(name: "Empty")],
            globals: [Variable(name: "globalToken", value: "sk-global", isSecret: true)],
            activeEnvironmentID: production.id, scratchRequests: [scratch]
        )
    }

    private static func withoutSecrets(_ workspace: Workspace) -> Workspace {
        var copy = workspace
        copy.forEachSecret { _, value in value = "" }
        return copy
    }

    @Test func roundTripHydratesSecrets() async throws {
        let directory = try TemporaryDirectory()
        let provider = InMemoryKeyProvider()
        let workspace = Self.makeWorkspace()
        #expect(workspace.secretValues().sorted() == Self.secrets.sorted())

        let empty = await WorkspaceStore(
            directory: directory.url, vault: EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: provider)
        ).load()
        #expect(empty.isFirstLaunch)
        #expect(empty.workspace == Workspace())
        #expect(empty.vaultState == .unlocked)

        let store = WorkspaceStore(
            directory: directory.url, vault: EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: provider)
        )
        try await store.save(workspace)

        let reopened = WorkspaceStore(
            directory: directory.url, vault: EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: provider)
        )
        let loaded = await reopened.load()
        #expect(loaded.workspace == workspace)
        #expect(loaded.vaultState == .unlocked)
        #expect(loaded.warnings.isEmpty)
        #expect(!loaded.isFirstLaunch)
    }

    @Test func noFileHoldsASecretValue() async throws {
        let directory = try TemporaryDirectory()
        let vault = EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: makeKeyProvider())
        let store = WorkspaceStore(directory: directory.url, vault: vault)
        let workspace = Self.makeWorkspace()
        try await store.save(workspace)
        let request = try #require(workspace.collections[0].allRequests.first)
        try await store.appendHistory(HistoryEntry(request: request, resolvedURL: "https://api.example.com/login"), limit: 10)
        try await store.saveSettings(AppSettings())

        let files = directory.allFiles()
        #expect(files.map(\.lastPathComponent).contains("secrets.vault"))
        #expect(files.count == 8)
        for file in files {
            let data = try Data(contentsOf: file)
            for secret in Self.secrets {
                #expect(!data.contains(secret), "\(file.lastPathComponent) holds \(secret)")
                #expect(!data.contains(Data(secret.utf8).base64EncodedString()))
            }
            #expect(try permissions(of: file) == 0o600)
        }
        for folder in [directory.url, directory.url.appendingPathComponent("collections"), directory.url.appendingPathComponent("environments")] {
            #expect(try permissions(of: folder) == 0o700)
        }
        #expect(try vault.allSecrets().values.sorted() == Self.secrets.sorted())
    }

    @Test func lockedVaultIsNeverOverwritten() async throws {
        let directory = try TemporaryDirectory()
        let vaultFile = directory.file("secrets.vault")
        let provider = InMemoryKeyProvider()
        let workspace = Self.makeWorkspace()
        try await WorkspaceStore(directory: directory.url, vault: EncryptedFileVault(fileURL: vaultFile, keyProvider: provider))
            .save(workspace)
        let key = try #require(try provider.loadKey())
        let sealed = try Data(contentsOf: vaultFile)
        try provider.deleteKey()

        let store = WorkspaceStore(directory: directory.url, vault: EncryptedFileVault(fileURL: vaultFile, keyProvider: provider))
        let loaded = await store.load()
        guard case .locked(let reason) = loaded.vaultState else {
            Issue.record("Expected a locked vault")
            return
        }
        #expect(!reason.isEmpty)
        #expect(loaded.workspace == Self.withoutSecrets(workspace))
        #expect(loaded.workspace.secretValues().isEmpty)

        // Saving while locked updates the JSON and leaves the vault alone.
        var edited = loaded.workspace
        edited.collections[0].name = "Renamed"
        edited.globals[0].value = "sk-typed-while-locked"
        try await store.save(edited)
        #expect(try Data(contentsOf: vaultFile) == sealed)
        #expect(try provider.loadKey() == nil)
        let collectionFile = directory.url.appendingPathComponent("collections/\(workspace.collections[0].id.uuidString).json")
        #expect(try Data(contentsOf: collectionFile).contains("Renamed"))

        // Still locked: nothing changes.
        let stillLocked = await store.unlockVault(hydrating: edited)
        #expect(stillLocked.workspace == edited)
        #expect(stillLocked.state != .unlocked)

        // The key is back: secrets are hydrated, the value typed while locked is kept.
        try provider.storeKey(key)
        let unlocked = await store.unlockVault(hydrating: edited)
        #expect(unlocked.state == .unlocked)
        #expect(await store.vaultState == .unlocked)
        var expected = workspace
        expected.collections[0].name = "Renamed"
        expected.globals[0].value = "sk-typed-while-locked"
        #expect(unlocked.workspace == expected)

        try await store.save(unlocked.workspace)
        let reloaded = await WorkspaceStore(directory: directory.url, vault: EncryptedFileVault(fileURL: vaultFile, keyProvider: provider)).load()
        #expect(reloaded.workspace == expected)
    }

    @Test func vaultFailureThrowsAfterJSONWasWritten() async throws {
        let directory = try TemporaryDirectory()
        let store = WorkspaceStore(directory: directory.url, vault: ReadOnlyVault())
        let workspace = Self.makeWorkspace()
        await #expect(throws: VaultError.io("read-only")) { try await store.save(workspace) }
        #expect(FileManager.default.fileExists(atPath: directory.file("workspace.json").path))
        #expect(directory.allFiles().count == 5)
    }

    @Test func deletedCollectionRemovesItsFileAndSecrets() async throws {
        let directory = try TemporaryDirectory()
        let vault = InMemoryVault()
        let store = WorkspaceStore(directory: directory.url, vault: vault)
        var workspace = Self.makeWorkspace()
        try await store.save(workspace)
        let removed = workspace.collections.removeFirst()
        workspace.environments.removeLast()
        try await store.save(workspace)

        let names = directory.allFiles().map(\.lastPathComponent)
        #expect(!names.contains("\(removed.id.uuidString).json"))
        #expect(names.count == 3)
        #expect(Set(try vault.allSecrets().keys).isDisjoint(with: Set(removed.secretSlots().keys)))
        #expect(await store.load().workspace == workspace)
    }

    @Test func corruptFileIsMovedAsideAndTheRestLoads() async throws {
        let directory = try TemporaryDirectory()
        let vault = InMemoryVault()
        let store = WorkspaceStore(directory: directory.url, vault: vault)
        let workspace = Self.makeWorkspace()
        try await store.save(workspace)
        let broken = workspace.collections[0]
        let brokenFile = directory.url.appendingPathComponent("collections/\(broken.id.uuidString).json")
        let original = try String(contentsOf: brokenFile, encoding: .utf8)
        try Data(String(original.dropLast(40)).utf8).write(to: brokenFile)

        let loaded = await store.load()
        #expect(loaded.workspace.collections == [workspace.collections[1]])
        #expect(loaded.workspace.environments == workspace.environments)
        #expect(loaded.warnings.count == 1)
        #expect(loaded.warnings[0].contains(".corrupt-"))
        #expect(!FileManager.default.fileExists(atPath: brokenFile.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: brokenFile.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("\(broken.id.uuidString).json.corrupt-") })

        // The secrets of the file moved aside survive the next save, so a repaired file gets them back.
        try await store.save(loaded.workspace)
        let kept = try vault.allSecrets()
        #expect(kept[broken.auth.apiKeyValue.id] == "sk-api-key-value")
    }

    @Test func unchangedSaveRewritesNothing() async throws {
        let directory = try TemporaryDirectory()
        let vault = EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: makeKeyProvider())
        let store = WorkspaceStore(directory: directory.url, vault: vault)
        var workspace = Self.makeWorkspace()
        try await store.save(workspace)
        let before = try directory.fileIdentities()

        try await store.save(workspace)
        #expect(try directory.fileIdentities() == before)

        // Only the file of the edited collection is rewritten.
        workspace.collections[1].name = "Other, renamed"
        try await store.save(workspace)
        let after = try directory.fileIdentities()
        let changed = after.filter { before[$0.key] != $0.value }.keys
        #expect(Array(changed) == ["collections/\(workspace.collections[1].id.uuidString).json"])
    }

    @Test func historyIsCappedNewestFirst() async throws {
        let directory = try TemporaryDirectory()
        let store = WorkspaceStore(directory: directory.url, vault: InMemoryVault())
        let entries = (0..<5).map { index in
            HistoryEntry(
                date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                request: RequestItem(name: "Request \(index)"), resolvedURL: "https://example.com/\(index)", statusCode: 200
            )
        }
        for entry in entries { try await store.appendHistory(entry, limit: 3) }
        #expect(await store.loadHistory().map(\.id) == [entries[4].id, entries[3].id, entries[2].id])

        let reopened = WorkspaceStore(directory: directory.url, vault: InMemoryVault())
        #expect(await reopened.loadHistory() == [entries[4], entries[3], entries[2]])
        try await reopened.removeHistory(id: entries[3].id)
        #expect(await reopened.loadHistory().map(\.id) == [entries[4].id, entries[2].id])
        try await reopened.clearHistory()
        #expect(await reopened.loadHistory().isEmpty)
        #expect(await WorkspaceStore(directory: directory.url, vault: InMemoryVault()).loadHistory().isEmpty)
    }

    @Test func settingsRoundTrip() async throws {
        let directory = try TemporaryDirectory()
        let store = WorkspaceStore(directory: directory.url, vault: InMemoryVault())
        #expect(await store.loadSettings() == AppSettings())
        let settings = AppSettings(timeout: 12, followRedirects: false, historyLimit: 50, responseLayout: .beside)
        try await store.saveSettings(settings)
        #expect(await WorkspaceStore(directory: directory.url, vault: InMemoryVault()).loadSettings() == settings)
    }
}
