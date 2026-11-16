import Foundation

// The seams between the modules of BeeCore. Each module implements its side; the runner and the
// application depend on these protocols only, so every part is testable with in-memory doubles.

// MARK: - Secrets

/// Stores secret values by slot id, encrypted at rest. Implementations are thread-safe.
public protocol SecretVault: AnyObject, Sendable {
    func secret(for id: UUID) throws -> String?
    /// `nil` or an empty string removes the entry.
    func setSecret(_ value: String?, for id: UUID) throws
    /// Replaces the whole content atomically; entries absent from `secrets` are dropped.
    func replaceAll(_ secrets: [UUID: String]) throws
    func allSecrets() throws -> [UUID: String]
}

/// Holds the 256-bit key that encrypts the vault. The production implementation is the macOS Keychain.
public protocol VaultKeyProvider: Sendable {
    /// The stored key, or `nil` when none exists yet.
    func loadKey() throws -> Data?
    func storeKey(_ key: Data) throws
    func deleteKey() throws
}

// MARK: - HTTP

public protocol HTTPTransport: Sendable {
    /// Performs the exchange. Honours task cancellation.
    func send(_ request: ResolvedRequest) async throws -> HTTPResponse
}

// MARK: - Scripts

public enum ScriptPhase: String, Sendable {
    case preRequest
    case postResponse
}

public struct ScriptSource: Hashable, Sendable {
    /// Shown as the source of console lines and errors, e.g. "Collection · Pre-request".
    public var label: String
    public var code: String

    public init(label: String, code: String) {
        self.label = label
        self.code = code
    }
}

/// The request as scripts see and may rewrite it before it is sent (still in template form).
public struct ScriptRequest: Hashable, Sendable {
    public var method: String
    public var url: String
    public var headers: [HeaderEntry]
    /// Raw body text when the body is textual; `nil` otherwise.
    public var body: String?

    public init(method: String, url: String, headers: [HeaderEntry] = [], body: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct ScriptResponse: Hashable, Sendable {
    public var code: Int
    public var status: String
    public var headers: [HeaderEntry]
    public var body: Data
    /// Milliseconds.
    public var responseTime: Double

    public init(code: Int, status: String, headers: [HeaderEntry] = [], body: Data = Data(), responseTime: Double = 0) {
        self.code = code
        self.status = status
        self.headers = headers
        self.body = body
        self.responseTime = responseTime
    }
}

public struct ScriptVariable: Hashable, Sendable {
    public var name: String
    public var value: String
    public var isSecret: Bool

    public init(name: String, value: String, isSecret: Bool = false) {
        self.name = name
        self.value = value
        self.isSecret = isSecret
    }
}

/// A snapshot of every variable scope handed to scripts; scripts return it modified.
public struct ScriptScopes: Hashable, Sendable {
    public var locals: [String: String]
    public var environment: [ScriptVariable]
    public var collection: [ScriptVariable]
    public var globals: [ScriptVariable]
    /// `nil` when no environment is active; environment writes then fail with a clear script error.
    public var environmentName: String?

    public init(
        locals: [String: String] = [:], environment: [ScriptVariable] = [], collection: [ScriptVariable] = [],
        globals: [ScriptVariable] = [], environmentName: String? = nil
    ) {
        self.locals = locals
        self.environment = environment
        self.collection = collection
        self.globals = globals
        self.environmentName = environmentName
    }
}

public struct ScriptInput: Sendable {
    public var phase: ScriptPhase
    /// Run in order (collection, folders outermost first, request) inside one shared context.
    public var sources: [ScriptSource]
    public var request: ScriptRequest
    /// Present in the post-response phase only.
    public var response: ScriptResponse?
    public var scopes: ScriptScopes
    public var requestName: String

    public init(
        phase: ScriptPhase, sources: [ScriptSource], request: ScriptRequest, response: ScriptResponse? = nil,
        scopes: ScriptScopes = ScriptScopes(), requestName: String = ""
    ) {
        self.phase = phase
        self.sources = sources
        self.request = request
        self.response = response
        self.scopes = scopes
        self.requestName = requestName
    }
}

public struct ScriptFailure: Hashable, Sendable, Error {
    /// Label of the source that failed.
    public var source: String
    public var message: String
    public var line: Int?

    public init(source: String, message: String, line: Int? = nil) {
        self.source = source
        self.message = message
        self.line = line
    }
}

public struct ScriptOutput: Sendable {
    /// The request after pre-request scripts (unchanged in the post-response phase).
    public var request: ScriptRequest
    public var scopes: ScriptScopes
    public var tests: [TestResult]
    /// Raw console lines: the caller redacts secret values before showing or keeping them.
    public var console: [ConsoleEntry]
    /// Set when a script threw or timed out; later sources are not run.
    public var failure: ScriptFailure?
    /// Every value a script wrote into a secret variable during the run, including values it
    /// overwrote later: all of them must be masked.
    public var secretValuesWritten: [String]

    public init(
        request: ScriptRequest, scopes: ScriptScopes, tests: [TestResult] = [],
        console: [ConsoleEntry] = [], failure: ScriptFailure? = nil, secretValuesWritten: [String] = []
    ) {
        self.request = request
        self.scopes = scopes
        self.tests = tests
        self.console = console
        self.failure = failure
        self.secretValuesWritten = secretValuesWritten
    }
}

public protocol ScriptRunning: Sendable {
    func run(_ input: ScriptInput) async -> ScriptOutput
}
