import Foundation
import Synchronization
import Testing
@testable import BeeCore

/// An in-memory `HTTPTransport`: records every request and answers with `handler`.
final class FakeTransport: HTTPTransport {
    typealias Handler = @Sendable (ResolvedRequest) async throws -> HTTPResponse

    private let recorded = Mutex<[ResolvedRequest]>([])
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers every request with the same JSON response.
    convenience init(status: Int = 200, statusText: String = "OK", body: String = "{\"ok\":true}", delay: Duration? = nil) {
        self.init { _ in
            if let delay { try await Task.sleep(for: delay) }
            return HTTPResponse(
                statusCode: status, statusText: statusText,
                headers: [HeaderEntry(name: "Content-Type", value: "application/json"), HeaderEntry(name: "X-Test", value: "yes")],
                body: Data(body.utf8), duration: 0.042
            )
        }
    }

    var requests: [ResolvedRequest] { recorded.withLock { $0 } }

    func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return try await handler(request)
    }
}

struct TransportFailure: LocalizedError {
    var errorDescription: String? { "connection refused" }
}

enum ScriptHarness {
    static let defaultRequest = ScriptRequest(method: "GET", url: "https://example.com/users")

    static func input(
        _ sources: [ScriptSource], phase: ScriptPhase = .preRequest, request: ScriptRequest = defaultRequest,
        response: ScriptResponse? = nil, scopes: ScriptScopes = ScriptScopes(environmentName: "Dev"),
        requestName: String = "Get user"
    ) -> ScriptInput {
        ScriptInput(
            phase: phase, sources: sources, request: request, response: response, scopes: scopes,
            requestName: requestName
        )
    }

    static func run(
        _ code: String, phase: ScriptPhase = .preRequest, request: ScriptRequest = defaultRequest,
        response: ScriptResponse? = nil, scopes: ScriptScopes = ScriptScopes(environmentName: "Dev"),
        transport: (any HTTPTransport)? = nil, timeout: TimeInterval = 10, requestName: String = "Get user"
    ) async -> ScriptOutput {
        await runSources(
            [ScriptSource(label: "Request · Script", code: code)], phase: phase, request: request,
            response: response, scopes: scopes, transport: transport, timeout: timeout, requestName: requestName
        )
    }

    static func runSources(
        _ sources: [ScriptSource], phase: ScriptPhase = .preRequest, request: ScriptRequest = defaultRequest,
        response: ScriptResponse? = nil, scopes: ScriptScopes = ScriptScopes(environmentName: "Dev"),
        transport: (any HTTPTransport)? = nil, timeout: TimeInterval = 10, requestName: String = "Get user"
    ) async -> ScriptOutput {
        let engine = JSScriptEngine(transport: transport, timeout: timeout)
        return await engine.run(input(
            sources, phase: phase, request: request, response: response, scopes: scopes, requestName: requestName
        ))
    }

    /// Evaluates a JavaScript expression and returns what `console.log` printed for it.
    static func evaluate(
        _ expression: String, phase: ScriptPhase = .preRequest, request: ScriptRequest = defaultRequest,
        response: ScriptResponse? = nil, scopes: ScriptScopes = ScriptScopes(environmentName: "Dev")
    ) async -> String? {
        let output = await run(
            "console.log(\(expression))", phase: phase, request: request, response: response, scopes: scopes
        )
        return output.console.first?.message
    }

    static func jsonResponse(
        code: Int = 200, status: String = "OK", body: String = "{\"id\":7,\"name\":\"Ada\"}",
        headers: [HeaderEntry] = [HeaderEntry(name: "Content-Type", value: "application/json")],
        responseTime: Double = 120
    ) -> ScriptResponse {
        ScriptResponse(code: code, status: status, headers: headers, body: Data(body.utf8), responseTime: responseTime)
    }
}

extension ScriptOutput {
    func test(named name: String) -> TestResult? {
        tests.first { $0.name == name }
    }
}

extension ScriptScopes {
    func environmentValue(_ name: String) -> ScriptVariable? { environment.last { $0.name == name } }
    func collectionValue(_ name: String) -> ScriptVariable? { collection.last { $0.name == name } }
    func globalValue(_ name: String) -> ScriptVariable? { globals.last { $0.name == name } }
}
