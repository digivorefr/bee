import Foundation
@testable import BeeCore

/// A scratch directory removed on `cleanup()`; tests call it in a `defer`.
struct HTTPTestScratch {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bee-http-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes a file and returns its absolute path.
    func write(_ name: String, _ content: String) -> String {
        write(name, Data(content.utf8))
    }

    func write(_ name: String, _ content: Data) -> String {
        let url = directory.appendingPathComponent(name)
        try? content.write(to: url)
        return url.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension ResolvedRequest {
    /// The first header with the name, case-insensitively.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var bodyText: String? {
        if case .data(let data) = body { return String(decoding: data, as: UTF8.self) }
        return nil
    }
}
