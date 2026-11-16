import Foundation

// MARK: - Body

public enum BodyMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, raw, urlEncoded, formData, binary, graphQL
    public var id: String { rawValue }
}

public enum RawLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case json, text, xml, html, javascript
    public var id: String { rawValue }

    public var contentType: String {
        switch self {
        case .json: "application/json"
        case .text: "text/plain"
        case .xml: "application/xml"
        case .html: "text/html"
        case .javascript: "application/javascript"
        }
    }
}

/// Holds the content of every body mode at once so switching mode in the editor never loses input.
public struct RequestBody: Hashable, Sendable, Codable, SecretContaining {
    public var mode: BodyMode
    public var raw: String
    public var rawLanguage: RawLanguage
    public var urlEncoded: [KeyValue]
    public var formData: [FormField]
    /// Absolute path of the file sent as-is in `binary` mode.
    public var binaryPath: String
    public var graphQLQuery: String
    /// JSON text of the GraphQL variables object.
    public var graphQLVariables: String

    public init(
        mode: BodyMode = .none, raw: String = "", rawLanguage: RawLanguage = .json,
        urlEncoded: [KeyValue] = [], formData: [FormField] = [], binaryPath: String = "",
        graphQLQuery: String = "", graphQLVariables: String = ""
    ) {
        self.mode = mode
        self.raw = raw
        self.rawLanguage = rawLanguage
        self.urlEncoded = urlEncoded
        self.formData = formData
        self.binaryPath = binaryPath
        self.graphQLQuery = graphQLQuery
        self.graphQLVariables = graphQLVariables
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        urlEncoded.forEachSecret(body)
        formData.forEachSecret(body)
    }
}

// MARK: - Authorization

public enum AuthKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Use the authorization of the nearest parent (folder, then collection).
    case inherit
    case none
    case bearer
    case basic
    case apiKey
    public var id: String { rawValue }
}

public enum APIKeyLocation: String, Codable, Sendable, CaseIterable, Identifiable {
    case header, query
    public var id: String { rawValue }
}

/// Authorization settings. Every credential field is a `SecretField`: it never reaches disk in clear,
/// whether it holds a literal credential or a `{{placeholder}}`.
public struct AuthConfig: Hashable, Sendable, Codable, SecretContaining {
    public var kind: AuthKind
    public var bearerToken: SecretField
    public var basicUsername: String
    public var basicPassword: SecretField
    public var apiKeyName: String
    public var apiKeyValue: SecretField
    public var apiKeyLocation: APIKeyLocation

    public init(
        kind: AuthKind = .inherit, bearerToken: SecretField = SecretField(), basicUsername: String = "",
        basicPassword: SecretField = SecretField(), apiKeyName: String = "",
        apiKeyValue: SecretField = SecretField(), apiKeyLocation: APIKeyLocation = .header
    ) {
        self.kind = kind
        self.bearerToken = bearerToken
        self.basicUsername = basicUsername
        self.basicPassword = basicPassword
        self.apiKeyName = apiKeyName
        self.apiKeyValue = apiKeyValue
        self.apiKeyLocation = apiKeyLocation
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        bearerToken.forEachSecret(body)
        basicPassword.forEachSecret(body)
        apiKeyValue.forEachSecret(body)
    }
}

// MARK: - Per-request settings

/// `nil` means "use the application setting".
public struct RequestSettings: Hashable, Sendable, Codable {
    public var timeout: TimeInterval?
    public var followRedirects: Bool?
    public var verifyTLS: Bool?

    public init(timeout: TimeInterval? = nil, followRedirects: Bool? = nil, verifyTLS: Bool? = nil) {
        self.timeout = timeout
        self.followRedirects = followRedirects
        self.verifyTLS = verifyTLS
    }
}

// MARK: - Request

public struct RequestItem: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    public var id: UUID
    public var name: String
    public var method: HTTPMethod
    /// Address without its query string; may contain `{{placeholders}}` and `:name` path variables.
    /// See `URLTemplate` and `PathVariables`.
    public var url: String
    /// Values of the `:name` segments of `url`, by name. Only rows that say something are kept: a path
    /// variable without a row takes the variable of the same name.
    public var pathVariables: [KeyValue]
    public var queryParams: [KeyValue]
    public var headers: [KeyValue]
    public var auth: AuthConfig
    public var body: RequestBody
    public var preRequestScript: String
    public var postResponseScript: String
    public var settings: RequestSettings
    public var notes: String

    public init(
        id: UUID = UUID(), name: String = "Untitled request", method: HTTPMethod = .get, url: String = "",
        pathVariables: [KeyValue] = [], queryParams: [KeyValue] = [], headers: [KeyValue] = [],
        auth: AuthConfig = AuthConfig(), body: RequestBody = RequestBody(), preRequestScript: String = "",
        postResponseScript: String = "", settings: RequestSettings = RequestSettings(), notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.pathVariables = pathVariables
        self.queryParams = queryParams
        self.headers = headers
        self.auth = auth
        self.body = body
        self.preRequestScript = preRequestScript
        self.postResponseScript = postResponseScript
        self.settings = settings
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, method, url, pathVariables, queryParams, headers, auth, body
        case preRequestScript, postResponseScript, settings, notes
    }

    /// Every field but the identifier may be missing, so a file written by an earlier version still opens.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled request"
        method = try container.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        pathVariables = try container.decodeIfPresent([KeyValue].self, forKey: .pathVariables) ?? []
        queryParams = try container.decodeIfPresent([KeyValue].self, forKey: .queryParams) ?? []
        headers = try container.decodeIfPresent([KeyValue].self, forKey: .headers) ?? []
        auth = try container.decodeIfPresent(AuthConfig.self, forKey: .auth) ?? AuthConfig()
        body = try container.decodeIfPresent(RequestBody.self, forKey: .body) ?? RequestBody()
        preRequestScript = try container.decodeIfPresent(String.self, forKey: .preRequestScript) ?? ""
        postResponseScript = try container.decodeIfPresent(String.self, forKey: .postResponseScript) ?? ""
        settings = try container.decodeIfPresent(RequestSettings.self, forKey: .settings) ?? RequestSettings()
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        pathVariables.forEachSecret(body)
        queryParams.forEachSecret(body)
        headers.forEachSecret(body)
        auth.forEachSecret(body)
        self.body.forEachSecret(body)
    }

    /// A copy with fresh identifiers everywhere (the item, its rows and its secret slots),
    /// so the copy never shares a vault entry with the original. Secret values are kept in memory.
    public func duplicated(name newName: String? = nil) -> RequestItem {
        var copy = self
        copy.id = UUID()
        if let newName { copy.name = newName }
        copy.pathVariables = copy.pathVariables.map { var row = $0; row.id = UUID(); return row }
        copy.queryParams = copy.queryParams.map { var row = $0; row.id = UUID(); return row }
        copy.headers = copy.headers.map { var row = $0; row.id = UUID(); return row }
        copy.body.urlEncoded = copy.body.urlEncoded.map { var row = $0; row.id = UUID(); return row }
        copy.body.formData = copy.body.formData.map { var row = $0; row.id = UUID(); return row }
        copy.auth = copy.auth.duplicated()
        return copy
    }
}

public extension AuthConfig {
    /// A copy whose secret slots have fresh identifiers.
    func duplicated() -> AuthConfig {
        var copy = self
        copy.bearerToken.id = UUID()
        copy.basicPassword.id = UUID()
        copy.apiKeyValue.id = UUID()
        return copy
    }
}
