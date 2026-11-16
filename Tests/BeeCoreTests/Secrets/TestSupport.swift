import Foundation
@testable import BeeCore

/// A fresh directory under the system temporary directory, removed when the value is released.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeeCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// Every regular file under the directory, hidden ones included.
    func allFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(file) }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Inode number of every file by relative path: an atomically rewritten file gets a new one.
    func fileIdentities() throws -> [String: UInt64] {
        var identities: [String: UInt64] = [:]
        for file in allFiles() {
            let relative = String(file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1))
            identities[relative] = try fileIdentity(file)
        }
        return identities
    }
}

func fileIdentity(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
}

func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

extension Data {
    func contains(_ text: String) -> Bool {
        range(of: Data(text.utf8)) != nil
    }
}

/// A random 256-bit key and the provider that holds it. Never the Keychain.
func makeKeyProvider() -> InMemoryKeyProvider {
    InMemoryKeyProvider(key: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
}
