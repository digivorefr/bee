import Foundation

/// Bee's own exchange format: one collection or one environment as JSON.
///
/// An archive holds no secret value by construction: the models never encode them. What travels is
/// the structure, including which fields are secret, for the recipient to fill in.
public enum BeeArchive {
    /// The format version written in the `bee` field.
    static let version = 1

    struct CollectionDocument: Codable {
        var bee: Int
        var kind: String
        var collection: Collection
    }

    struct EnvironmentDocument: Codable {
        var bee: Int
        var kind: String
        var environment: Environment
    }

    /// `{"bee": 1, "kind": "collection", "collection": {…}}`
    public static func data(for collection: Collection) throws -> Data {
        try StorageCoding.encoder().encode(
            CollectionDocument(bee: version, kind: "collection", collection: collection)
        )
    }

    /// `{"bee": 1, "kind": "environment", "environment": {…}}`
    public static func data(for environment: Environment) throws -> Data {
        try StorageCoding.encoder().encode(
            EnvironmentDocument(bee: version, kind: "environment", environment: environment)
        )
    }
}

// MARK: - Fresh identifiers

extension Collection {
    /// A copy with new identifiers everywhere (collection, folders, requests, rows, secret slots),
    /// so it can live next to the original without sharing a file or a vault entry.
    func withFreshIdentifiers() -> Collection {
        var copy = self
        copy.id = UUID()
        copy.variables = copy.variables.map { $0.withFreshIdentifier() }
        copy.auth = copy.auth.duplicated()
        copy.items = copy.items.map { $0.withFreshIdentifiers() }
        return copy
    }
}

extension CollectionNode {
    func withFreshIdentifiers() -> CollectionNode {
        switch self {
        case .folder(var folder):
            folder.id = UUID()
            folder.auth = folder.auth.duplicated()
            folder.items = folder.items.map { $0.withFreshIdentifiers() }
            return .folder(folder)
        case .request(let request):
            return .request(request.duplicated())
        }
    }
}

extension Environment {
    /// A copy with new identifiers for the environment and its variables.
    func withFreshIdentifiers() -> Environment {
        var copy = self
        copy.id = UUID()
        copy.variables = copy.variables.map { $0.withFreshIdentifier() }
        return copy
    }
}

extension Variable {
    func withFreshIdentifier() -> Variable {
        var copy = self
        copy.id = UUID()
        return copy
    }
}
