import Foundation
import Testing
@testable import BeeCore

@Suite struct LockedSnapshotTests {
    @Test func aSnapshotTakenWhileLockedNeverReachesTheVault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bee-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = InMemoryVault()
        let store = WorkspaceStore(directory: directory, vault: vault)

        let environment = Environment(name: "Production", variables: [
            Variable(name: "apiToken", value: "keep-me-safe", isSecret: true),
        ])
        let workspace = Workspace(environments: [environment], activeEnvironmentID: environment.id)
        try await store.save(workspace)
        #expect(try vault.allSecrets().values.contains("keep-me-safe"))

        // The same workspace as it looks when loaded without its secrets.
        var blank = workspace
        blank.forEachSecret { _, value in value = "" }
        try await store.save(blank, secretsHydrated: false)

        #expect(try vault.allSecrets().values.contains("keep-me-safe"))
    }
}
