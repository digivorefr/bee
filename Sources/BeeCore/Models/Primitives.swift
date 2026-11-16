import Foundation

// MARK: - Secret handling contract

/// A type that carries secret slots. A secret slot is a (stable id, in-memory value) pair whose
/// value is NEVER written by `Codable`: it is persisted only in the encrypted vault, keyed by id.
///
/// Persistence splits on save (collect every slot into the vault) and joins on load (hydrate every
/// slot from the vault). Because the leaf types below refuse to encode secret values, no encoder
/// anywhere in the app (workspace files, history, export, clipboard) can leak one.
public protocol SecretContaining {
    /// Calls `body` once per secret slot, in a stable order. `body` may rewrite the value.
    mutating func forEachSecret(_ body: (UUID, inout String) -> Void)
}

public extension SecretContaining {
    /// Every non-empty secret value currently held in memory by the receiver.
    func secretValues() -> [String] {
        var copy = self
        var values: [String] = []
        copy.forEachSecret { _, value in
            if !value.isEmpty { values.append(value) }
        }
        return values
    }

    /// The (id, value) pairs of every secret slot, including empty ones.
    func secretSlots() -> [UUID: String] {
        var copy = self
        var slots: [UUID: String] = [:]
        copy.forEachSecret { id, value in slots[id] = value }
        return slots
    }
}

extension Array: SecretContaining where Element: SecretContaining {
    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        for index in indices { self[index].forEachSecret(body) }
    }
}

/// A single always-secret text field (a password, a token, an API key value).
/// Encodes its `id` only.
public struct SecretField: Hashable, Sendable, Codable, SecretContaining {
    public var id: UUID
    public var value: String

    public init(id: UUID = UUID(), value: String = "") {
        self.id = id
        self.value = value
    }

    private enum CodingKeys: String, CodingKey { case id }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        value = ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        body(id, &value)
    }
}

// MARK: - HTTP method

public enum HTTPMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    public var id: String { rawValue }
}

// MARK: - Key/value rows (query parameters, headers, url-encoded fields)

public struct KeyValue: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    public var id: UUID
    public var key: String
    /// When `isSecret` is true this is held in memory only and persisted in the vault under `id`.
    public var value: String
    public var isEnabled: Bool
    public var isSecret: Bool

    public init(id: UUID = UUID(), key: String = "", value: String = "", isEnabled: Bool = true, isSecret: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.isSecret = isSecret
    }

    private enum CodingKeys: String, CodingKey { case id, key, value, isEnabled, isSecret }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        let stored = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        value = isSecret ? "" : stored
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encode(isSecret ? "" : value, forKey: .value)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isSecret, forKey: .isSecret)
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        if isSecret { body(id, &value) }
    }
}

// MARK: - Multipart form fields

public struct FormField: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    public enum Kind: String, Codable, Sendable, CaseIterable { case text, file }

    public var id: UUID
    public var key: String
    public var kind: Kind
    /// Text value, or an absolute file path when `kind == .file`.
    public var value: String
    /// Optional explicit content type for the part; empty means automatic.
    public var contentType: String
    public var isEnabled: Bool
    public var isSecret: Bool

    public init(
        id: UUID = UUID(), key: String = "", kind: Kind = .text, value: String = "",
        contentType: String = "", isEnabled: Bool = true, isSecret: Bool = false
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.value = value
        self.contentType = contentType
        self.isEnabled = isEnabled
        self.isSecret = isSecret
    }

    private enum CodingKeys: String, CodingKey { case id, key, kind, value, contentType, isEnabled, isSecret }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        let stored = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        value = isSecret ? "" : stored
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encode(kind, forKey: .kind)
        try container.encode(isSecret ? "" : value, forKey: .value)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isSecret, forKey: .isSecret)
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        if isSecret { body(id, &value) }
    }
}

// MARK: - Variables

public struct Variable: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    public var id: UUID
    public var name: String
    /// When `isSecret` is true this is held in memory only and persisted in the vault under `id`.
    public var value: String
    public var isSecret: Bool
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String = "", value: String = "", isSecret: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.isSecret = isSecret
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, name, value, isSecret, isEnabled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let stored = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        value = isSecret ? "" : stored
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isSecret ? "" : value, forKey: .value)
        try container.encode(isSecret, forKey: .isSecret)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        if isSecret { body(id, &value) }
    }
}

// MARK: - Credential heuristics

public enum CredentialHeuristics {
    private static let sensitiveFragments = [
        "token", "secret", "password", "passwd", "pwd", "apikey", "api_key", "api-key",
        "authorization", "auth", "credential", "cookie", "session", "private", "signature", "bearer",
    ]

    /// Short credential words, matched as whole words only ("sid" must not match "side").
    private static let sensitiveWords: Set<String> = ["jwt", "pass", "sig", "otp", "sid", "csrf", "xsrf", "pin", "key"]

    /// True when a variable or header name looks like it holds a credential.
    /// Used to default new values to secret; the person can always override.
    public static func looksSensitive(name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.hasSuffix("key") || lowered.hasSuffix("_key") { return true }
        if sensitiveFragments.contains(where: { lowered.contains($0) }) { return true }
        return words(in: name).contains { sensitiveWords.contains($0) }
    }

    /// The lowercased words of an identifier: split on non-alphanumerics and on camelCase humps.
    private static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLowercase = false
        for character in name {
            let isBoundary = !(character.isLetter || character.isNumber)
            let isHump = character.isUppercase && previousWasLowercase
            if isBoundary || isHump {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
            }
            if !isBoundary { current.append(character) }
            previousWasLowercase = character.isLowercase
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }
}
