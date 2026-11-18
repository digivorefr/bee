import Foundation

// MARK: - Wire-level request

public struct HeaderEntry: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum ResolvedBody: Hashable, Sendable {
    case none
    case data(Data)
    /// Streamed from disk (binary mode).
    case file(URL)
}

/// A request with every placeholder replaced, ready for the transport. Holds real secret values:
/// never persist it, never log it. Use `Redactor` before showing any part of it.
public struct ResolvedRequest: Hashable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [HeaderEntry]
    public var body: ResolvedBody
    public var timeout: TimeInterval
    public var followRedirects: Bool
    public var verifyTLS: Bool

    public init(
        method: String, url: URL, headers: [HeaderEntry] = [], body: ResolvedBody = .none,
        timeout: TimeInterval = 30, followRedirects: Bool = true, verifyTLS: Bool = true
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.followRedirects = followRedirects
        self.verifyTLS = verifyTLS
    }
}

// MARK: - Response

/// Durations in seconds; `nil` when the phase did not happen (reused connection) or is unknown.
public struct ResponseTimings: Hashable, Sendable, Codable {
    public var dns: TimeInterval?
    public var connect: TimeInterval?
    public var tls: TimeInterval?
    /// From request sent to first response byte.
    public var firstByte: TimeInterval?
    public var download: TimeInterval?

    public init(
        dns: TimeInterval? = nil, connect: TimeInterval? = nil, tls: TimeInterval? = nil,
        firstByte: TimeInterval? = nil, download: TimeInterval? = nil
    ) {
        self.dns = dns
        self.connect = connect
        self.tls = tls
        self.firstByte = firstByte
        self.download = download
    }
}

public struct HTTPResponse: Hashable, Sendable {
    public var statusCode: Int
    /// Reason phrase, e.g. "OK", "Not Found".
    public var statusText: String
    /// e.g. "HTTP/2".
    public var httpVersion: String
    public var headers: [HeaderEntry]
    public var body: Data
    /// Total wall-clock duration in seconds.
    public var duration: TimeInterval
    public var timings: ResponseTimings
    public var finalURL: URL?
    public var remoteAddress: String?

    public init(
        statusCode: Int, statusText: String = "", httpVersion: String = "", headers: [HeaderEntry] = [],
        body: Data = Data(), duration: TimeInterval = 0, timings: ResponseTimings = ResponseTimings(),
        finalURL: URL? = nil, remoteAddress: String? = nil
    ) {
        self.statusCode = statusCode
        self.statusText = statusText
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.duration = duration
        self.timings = timings
        self.finalURL = finalURL
        self.remoteAddress = remoteAddress
    }

    public var size: Int { body.count }

    /// First header value with the given name, case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Media type without parameters, lowercased, e.g. "application/json".
    public var mimeType: String? {
        header("Content-Type")?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    public var isJSON: Bool {
        guard let mimeType else { return false }
        return mimeType == "application/json" || mimeType.hasSuffix("+json")
    }

    /// The body decoded as text (UTF-8, then Latin-1 as a lossless fallback).
    public var text: String {
        String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }
}

// MARK: - Tests and console

public struct TestResult: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var passed: Bool
    /// Failure reason; `nil` when the test passed.
    public var message: String?

    public init(id: UUID = UUID(), name: String, passed: Bool, message: String? = nil) {
        self.id = id
        self.name = name
        self.passed = passed
        self.message = message
    }
}

public enum ConsoleLevel: String, Sendable, Codable, CaseIterable {
    case log, info, warn, error
}

public struct ConsoleEntry: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var level: ConsoleLevel
    public var message: String
    /// Where the line comes from, e.g. "Pre-request · Get user".
    public var source: String

    public init(id: UUID = UUID(), date: Date = Date(), level: ConsoleLevel, message: String, source: String = "") {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
        self.source = source
    }
}

// MARK: - Variables at run time

public enum VariableScopeKind: String, Sendable, Codable, CaseIterable {
    /// Set by a script for the current run only.
    case local
    case environment
    case collection
    case global
}

public struct VariableLookup: Hashable, Sendable {
    public var value: String
    public var scope: VariableScopeKind
    public var isSecret: Bool

    public init(value: String, scope: VariableScopeKind, isSecret: Bool) {
        self.value = value
        self.scope = scope
        self.isSecret = isSecret
    }
}

/// The variables visible to one request. Precedence: local, environment, collection, global.
public struct VariableContext: Sendable {
    public var locals: [String: String]
    public var environment: [Variable]
    public var collection: [Variable]
    public var globals: [Variable]

    public init(
        locals: [String: String] = [:], environment: [Variable] = [],
        collection: [Variable] = [], globals: [Variable] = []
    ) {
        self.locals = locals
        self.environment = environment
        self.collection = collection
        self.globals = globals
    }

    public func lookup(_ name: String) -> VariableLookup? {
        if let value = locals[name] {
            return VariableLookup(value: value, scope: .local, isSecret: false)
        }
        let scopes: [(VariableScopeKind, [Variable])] = [
            (.environment, environment), (.collection, collection), (.global, globals),
        ]
        for (kind, variables) in scopes {
            // The last enabled definition of a name wins inside a scope.
            if let match = variables.last(where: { $0.isEnabled && $0.name == name }) {
                return VariableLookup(value: match.value, scope: kind, isSecret: match.isSecret)
            }
        }
        return nil
    }

    /// Every distinct visible name, sorted, for completion.
    public var names: [String] {
        var all = Set(locals.keys)
        for variable in environment + collection + globals where variable.isEnabled && !variable.name.isEmpty {
            all.insert(variable.name)
        }
        return all.sorted()
    }
}

/// A change a script made to a variable, to apply to the live workspace after the run.
public struct VariableChange: Hashable, Sendable {
    public var scope: VariableScopeKind
    public var name: String
    /// `nil` removes the variable.
    public var value: String?
    public var isSecret: Bool

    public init(scope: VariableScopeKind, name: String, value: String?, isSecret: Bool = false) {
        self.scope = scope
        self.name = name
        self.value = value
        self.isSecret = isSecret
    }
}

// MARK: - Settings

public enum ResponseLayout: String, Sendable, Codable, CaseIterable {
    case below, beside
}

public struct AppSettings: Hashable, Sendable, Codable {
    public var timeout: TimeInterval
    public var followRedirects: Bool
    public var verifyTLS: Bool
    /// Ask for Touch ID or the account password before a secret is revealed or copied.
    public var requireAuthenticationToReveal: Bool
    public var historyLimit: Int
    public var responseLayout: ResponseLayout
    /// The version of Bee that last ran with these settings; `nil` before the first run. Tells an update.
    public var lastRunVersion: String?
    /// Ask once a day whether a newer version is published.
    public var checksForUpdates: Bool
    /// When the last such question was answered.
    public var lastUpdateCheck: Date?
    /// The folder where each collection has its file; `nil` for the usual one (`~/Documents/Bee`).
    public var collectionsFolder: String?
    /// Let AI agents reach Bee through its MCP relay. Off unless the person turns it on.
    public var agentsEnabled: Bool
    /// The most an agent may do.
    public var agentAccess: AgentAccess
    /// The collections agents may see. None unless the person picks some.
    public var agentCollections: [UUID]
    /// The programs the person allowed to connect, by path.
    public var agentPrograms: [String]

    public init(
        timeout: TimeInterval = 30, followRedirects: Bool = true, verifyTLS: Bool = true,
        requireAuthenticationToReveal: Bool = true, historyLimit: Int = 200,
        responseLayout: ResponseLayout = .beside, lastRunVersion: String? = nil,
        checksForUpdates: Bool = true, lastUpdateCheck: Date? = nil, collectionsFolder: String? = nil,
        agentsEnabled: Bool = false, agentAccess: AgentAccess = .read, agentCollections: [UUID] = [],
        agentPrograms: [String] = []
    ) {
        self.timeout = timeout
        self.followRedirects = followRedirects
        self.verifyTLS = verifyTLS
        self.requireAuthenticationToReveal = requireAuthenticationToReveal
        self.historyLimit = historyLimit
        self.responseLayout = responseLayout
        self.lastRunVersion = lastRunVersion
        self.checksForUpdates = checksForUpdates
        self.lastUpdateCheck = lastUpdateCheck
        self.collectionsFolder = collectionsFolder
        self.agentsEnabled = agentsEnabled
        self.agentAccess = agentAccess
        self.agentCollections = agentCollections
        self.agentPrograms = agentPrograms
    }

    private enum CodingKeys: String, CodingKey {
        case timeout, followRedirects, verifyTLS, requireAuthenticationToReveal, historyLimit, responseLayout
        case lastRunVersion, checksForUpdates, lastUpdateCheck, collectionsFolder
        case agentsEnabled, agentAccess, agentCollections, agentPrograms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? defaults.timeout
        followRedirects = try container.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? defaults.followRedirects
        verifyTLS = try container.decodeIfPresent(Bool.self, forKey: .verifyTLS) ?? defaults.verifyTLS
        requireAuthenticationToReveal = try container.decodeIfPresent(Bool.self, forKey: .requireAuthenticationToReveal)
            ?? defaults.requireAuthenticationToReveal
        historyLimit = try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? defaults.historyLimit
        responseLayout = try container.decodeIfPresent(ResponseLayout.self, forKey: .responseLayout) ?? defaults.responseLayout
        lastRunVersion = try container.decodeIfPresent(String.self, forKey: .lastRunVersion)
        checksForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? defaults.checksForUpdates
        lastUpdateCheck = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        collectionsFolder = try container.decodeIfPresent(String.self, forKey: .collectionsFolder)
        agentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentsEnabled) ?? false
        agentAccess = (try? container.decodeIfPresent(AgentAccess.self, forKey: .agentAccess)) ?? .read
        agentCollections = try container.decodeIfPresent([UUID].self, forKey: .agentCollections) ?? []
        agentPrograms = try container.decodeIfPresent([String].self, forKey: .agentPrograms) ?? []
    }
}

// MARK: - History

/// What was sent, safe to persist: the request in template form (secret values are never encoded)
/// and facts about the exchange with every secret value redacted.
public struct HistoryEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var date: Date
    public var request: RequestItem
    /// The saved request this entry was sent from, when there is one.
    public var sourceRequestID: UUID?
    public var collectionName: String?
    public var environmentName: String?
    /// The address actually called, secrets redacted.
    public var resolvedURL: String
    public var statusCode: Int?
    public var statusText: String?
    public var duration: TimeInterval?
    public var size: Int?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(), date: Date = Date(), request: RequestItem, sourceRequestID: UUID? = nil,
        collectionName: String? = nil, environmentName: String? = nil, resolvedURL: String = "",
        statusCode: Int? = nil, statusText: String? = nil, duration: TimeInterval? = nil,
        size: Int? = nil, errorMessage: String? = nil
    ) {
        self.id = id
        self.date = date
        self.request = request
        self.sourceRequestID = sourceRequestID
        self.collectionName = collectionName
        self.environmentName = environmentName
        self.resolvedURL = resolvedURL
        self.statusCode = statusCode
        self.statusText = statusText
        self.duration = duration
        self.size = size
        self.errorMessage = errorMessage
    }
}
