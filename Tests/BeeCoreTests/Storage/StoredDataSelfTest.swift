import Foundation
import Testing
@testable import BeeCore

/// Checks that this build still reads a real data directory, without changing it and without printing
/// its content (counts only). Off by default: run with
/// `BEE_DATA_SELFTEST="$HOME/Library/Application Support/Bee" swift test --filter StoredDataSelfTest`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BEE_DATA_SELFTEST"]?.isEmpty == false))
struct StoredDataSelfTest {
    private var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEE_DATA_SELFTEST"] ?? "", isDirectory: true)
    }

    private func documents(in folder: String) throws -> [URL] {
        let url = directory.appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    @Test func everyStoredDocumentDecodes() throws {
        let decoder = StorageCoding.decoder()
        var requests = 0
        var withPathVariables = 0
        let collections = try documents(in: "collections")
        for file in collections {
            let collection = try decoder.decode(Collection.self, from: Data(contentsOf: file))
            requests += collection.allRequests.count
            withPathVariables += collection.allRequests.filter { !PathVariables.names(in: $0.url).isEmpty }.count
        }
        let environments = try documents(in: "environments")
        for file in environments {
            _ = try decoder.decode(Environment.self, from: Data(contentsOf: file))
        }
        var historyCount = 0
        let history = directory.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: history.path) {
            historyCount = try decoder.decode([HistoryEntry].self, from: Data(contentsOf: history)).count
        }
        print(
            "[selftest] \(collections.count) collections, \(requests) requests "
                + "(\(withPathVariables) with path variables), \(environments.count) environments, "
                + "\(historyCount) history entries: all readable"
        )
    }
}
