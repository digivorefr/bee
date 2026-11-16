import Foundation
import Testing
@testable import BeeCore

/// Records what was sent and answers with a canned response.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ResolvedRequest] = []
    private let handler: @Sendable (ResolvedRequest) throws -> HTTPResponse

    init(handler: @escaping @Sendable (ResolvedRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    var requests: [ResolvedRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        return try handler(request)
    }
}

private func jsonResponse(_ body: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(
        statusCode: status, statusText: "OK",
        headers: [HeaderEntry(name: "Content-Type", value: "application/json")],
        body: Data(body.utf8), duration: 0.05
    )
}

@Suite struct RequestRunnerTests {
    private let secret = "s3cr3t-token-value"

    private func workspace(request: RequestItem, collection: Collection? = nil) -> (Workspace, UUID?) {
        let environment = Environment(name: "Staging", variables: [
            Variable(name: "baseUrl", value: "https://api.example.test"),
            Variable(name: "apiToken", value: secret, isSecret: true),
            Variable(name: "accessToken", value: "", isSecret: true),
        ])
        var collection = collection ?? Collection(name: "API")
        collection.items.append(.request(request))
        let workspace = Workspace(
            collections: [collection], environments: [environment], activeEnvironmentID: environment.id
        )
        return (workspace, collection.id)
    }

    private func run(
        _ request: RequestItem, collection: Collection? = nil, transport: RecordingTransport
    ) async -> (RunOutcome, Workspace, UUID?) {
        let (workspace, collectionID) = workspace(request: request, collection: collection)
        let runner = RequestRunner(transport: transport, scripts: JSScriptEngine())
        let outcome = await runner.run(RunInput(
            item: request, collectionID: collectionID, workspace: workspace, settings: AppSettings()
        ))
        return (outcome, workspace, collectionID)
    }

    @Test func resolvesVariablesAndSendsTheSecretOnTheWireOnly() async throws {
        var request = RequestItem(name: "Me", url: "{{baseUrl}}/me")
        request.headers = [KeyValue(key: "X-Api-Token", value: "{{apiToken}}", isSecret: true)]
        let transport = RecordingTransport { _ in jsonResponse("{}") }

        let (outcome, _, _) = await run(request, transport: transport)

        let sent = try #require(transport.requests.first)
        #expect(sent.url.absoluteString == "https://api.example.test/me")
        #expect(sent.headers.contains(HeaderEntry(name: "X-Api-Token", value: secret)))
        #expect(outcome.response?.statusCode == 200)

        // Nothing meant for display or disk carries the value.
        let shown = try #require(outcome.sentRequest)
        #expect(!shown.headers.contains { $0.value.contains(secret) })
        let history = String(decoding: try JSONEncoder().encode(outcome.historyEntry), as: UTF8.self)
        #expect(!history.contains(secret))
    }

    @Test func aShortSecretInThePathNeverReachesWhatIsShownOrKept() async throws {
        var request = RequestItem(name: "Reset", url: "{{baseUrl}}/reset/:pin/users/:user")
        request.pathVariables = [KeyValue(key: "pin", value: "123", isSecret: true), KeyValue(key: "user", value: "ada")]
        request.queryParams = [KeyValue(key: "otp", value: "45", isSecret: true)]
        let transport = RecordingTransport { _ in jsonResponse("{}") }

        let (outcome, _, _) = await run(request, transport: transport)

        #expect(transport.requests.first?.url.absoluteString == "https://api.example.test/reset/123/users/ada?otp=45")
        #expect(outcome.sentRequest?.url == "https://api.example.test/reset/••••••/users/ada?otp=••••••")
        #expect(outcome.historyEntry.resolvedURL == "https://api.example.test/reset/••••••/users/ada?otp=••••••")
        let history = String(decoding: try JSONEncoder().encode(outcome.historyEntry), as: UTF8.self)
        // Exact fields: random identifiers may hold the same digits.
        #expect(!history.contains("\"value\":\"123\""))
        #expect(!history.contains("\"value\":\"45\""))
        #expect(!history.contains("reset/123"))
        #expect(!history.contains("otp=45"))
    }

    @Test func consoleAndTestsAreRedacted() async {
        var request = RequestItem(name: "Leaky", url: "{{baseUrl}}/leak")
        request.postResponseScript = """
        console.log("token is " + bee.environment.get("apiToken"));
        bee.test("uses " + bee.environment.get("apiToken"), () => { throw new Error("bad " + bee.environment.get("apiToken")); });
        """
        let transport = RecordingTransport { _ in jsonResponse("{}") }

        let (outcome, _, _) = await run(request, transport: transport)

        #expect(outcome.console.count == 1)
        #expect(outcome.tests.count == 1)
        let everything = outcome.console.map(\.message) + outcome.tests.map(\.name) + outcome.tests.compactMap(\.message)
        #expect(!everything.contains { $0.contains(secret) })
        #expect(everything.contains { $0.contains(Redactor.mask) })
    }

    @Test func postResponseScriptStoresATokenAsASecret() async throws {
        var request = RequestItem(name: "Login", method: .post, url: "{{baseUrl}}/login")
        request.postResponseScript = """
        const body = bee.response.json();
        bee.environment.set("accessToken", body.token);
        console.log("stored " + body.token);
        bee.test("has a token", () => bee.expect(body.token).to.be.a("string"));
        """
        let transport = RecordingTransport { _ in jsonResponse(#"{"token":"fresh-token-12345"}"#) }

        let (outcome, workspace, collectionID) = await run(request, transport: transport)

        #expect(outcome.tests.map(\.passed) == [true])
        #expect(outcome.variableChanges == [
            VariableChange(scope: .environment, name: "accessToken", value: "fresh-token-12345", isSecret: true),
        ])
        // The freshly stored token is a secret from now on: the console line is masked.
        #expect(!outcome.console.contains { $0.message.contains("fresh-token-12345") })

        var updated = workspace
        updated.apply(outcome.variableChanges, collectionID: collectionID)
        let variable = try #require(updated.activeEnvironment?.variables.first { $0.name == "accessToken" })
        #expect(variable.value == "fresh-token-12345")
        #expect(variable.isSecret)
        let encoded = String(decoding: try JSONEncoder().encode(updated), as: UTF8.self)
        #expect(!encoded.contains("fresh-token-12345"))
    }

    @Test func scriptsRunOutermostFirstAndCanRewriteTheRequest() async throws {
        var request = RequestItem(name: "Ordered", url: "{{baseUrl}}/ordered")
        request.preRequestScript = """
        bee.request.headers.upsert({ key: "X-Order", value: bee.variables.get("order") + ",request" });
        """
        var collection = Collection(name: "API")
        collection.preRequestScript = """
        bee.variables.set("order", "collection");
        """
        let transport = RecordingTransport { _ in jsonResponse("{}") }

        let (outcome, _, _) = await run(request, collection: collection, transport: transport)

        #expect(outcome.errorMessage == nil)
        let sent = try #require(transport.requests.first)
        #expect(sent.headers.contains(HeaderEntry(name: "X-Order", value: "collection,request")))
    }

    @Test func inheritedBearerAuthorizationIsSentAndMasked() async throws {
        let request = RequestItem(name: "Inherits", url: "{{baseUrl}}/secure")
        var collection = Collection(name: "API")
        collection.auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{apiToken}}"))
        let transport = RecordingTransport { _ in jsonResponse("{}") }

        let (outcome, _, _) = await run(request, collection: collection, transport: transport)

        let sent = try #require(transport.requests.first)
        #expect(sent.headers.contains(HeaderEntry(name: "Authorization", value: "Bearer \(secret)")))
        let shown = try #require(outcome.sentRequest)
        #expect(!shown.headers.contains { $0.value.contains(secret) })
    }

    @Test func failingPreRequestScriptStopsTheSend() async {
        var request = RequestItem(name: "Broken", url: "{{baseUrl}}/never")
        request.preRequestScript = "throw new Error('nope');"
        let transport = RecordingTransport { _ in jsonResponse("{}") }

        let (outcome, _, _) = await run(request, transport: transport)

        #expect(transport.requests.isEmpty)
        #expect(outcome.response == nil)
        #expect(outcome.errorMessage?.contains("nope") == true)
    }

    @Test func transportErrorIsReportedAndRecorded() async {
        let request = RequestItem(name: "Down", url: "{{baseUrl}}/down")
        let transport = RecordingTransport { _ in throw TransportError.cannotConnect("Could not connect to the server.") }

        let (outcome, _, _) = await run(request, transport: transport)

        #expect(outcome.response == nil)
        #expect(outcome.errorMessage != nil)
        #expect(outcome.historyEntry.statusCode == nil)
        #expect(outcome.historyEntry.errorMessage != nil)
    }

    @Test func unknownVariablesAreReported() async {
        let request = RequestItem(name: "Unknown", url: "{{baseUrl}}/{{missing}}")
        let transport = RecordingTransport { _ in jsonResponse("{}") }

        let (outcome, _, _) = await run(request, transport: transport)

        #expect(outcome.unresolvedVariables == ["missing"])
    }
}

@Suite struct RunnerSecretHardeningTests {
    private func run(_ request: RequestItem, variables: [Variable]) async throws -> (RunOutcome, ResolvedRequest) {
        let environment = Environment(name: "Staging", variables: variables)
        let workspace = Workspace(
            collections: [Collection(name: "API", items: [.request(request)])],
            environments: [environment], activeEnvironmentID: environment.id
        )
        let transport = RecordingTransport { _ in
            HTTPResponse(statusCode: 200, statusText: "OK", body: Data("{}".utf8))
        }
        let outcome = await RequestRunner(transport: transport, scripts: JSScriptEngine()).run(RunInput(
            item: request, collectionID: workspace.collections[0].id, workspace: workspace, settings: AppSettings()
        ))
        return (outcome, try #require(transport.requests.first))
    }

    @Test func secretHoldingAPlaceholderIsMaskedInItsRenderedForm() async throws {
        var request = RequestItem(name: "Nested", url: "https://api.example.test/items")
        request.queryParams = [KeyValue(key: "api_key", value: "{{apiKey}}")]
        let (outcome, sent) = try await run(request, variables: [
            Variable(name: "tenant", value: "acme"),
            Variable(name: "apiKey", value: "sk-{{tenant}}-9f8a7b6c", isSecret: true),
        ])
        #expect(sent.url.absoluteString.contains("sk-acme-9f8a7b6c"))
        #expect(!outcome.historyEntry.resolvedURL.contains("9f8a7b6c"))
        #expect(outcome.sentRequest?.url.contains("9f8a7b6c") == false)
    }

    @Test func secretWithSurroundingSpaceIsMaskedOnceTrimmed() async throws {
        var request = RequestItem(name: "Trimmed", url: "https://api.example.test/items")
        request.headers = [KeyValue(key: "X-Thing", value: "{{padded}}")]
        let (outcome, _) = try await run(request, variables: [
            Variable(name: "padded", value: "padded-secret-value ", isSecret: true),
        ])
        #expect(outcome.sentRequest?.headers.contains { $0.value.contains("padded-secret-value") } == false)
    }

    @Test func copyingASecretIntoAPlainVariableMakesItSecret() async throws {
        var request = RequestItem(name: "Copy", url: "https://api.example.test/items")
        request.postResponseScript = #"bee.environment.set("copy", bee.environment.get("apiToken"));"#
        let (outcome, _) = try await run(request, variables: [
            Variable(name: "apiToken", value: "s3cr3t-token-value", isSecret: true),
        ])
        #expect(outcome.variableChanges == [
            VariableChange(scope: .environment, name: "copy", value: "s3cr3t-token-value", isSecret: true),
        ])
    }

    @Test func aSecretValueReplacedDuringTheRunStaysMasked() async throws {
        var request = RequestItem(name: "Rotating", url: "https://api.example.test/items")
        request.postResponseScript = """
        bee.environment.set("rotating", "first-secret-value", { secret: true });
        console.log("was first-secret-value");
        bee.environment.set("rotating", "second-secret-value");
        """
        let (outcome, _) = try await run(request, variables: [])
        #expect(!outcome.console.contains { $0.message.contains("first-secret-value") })
        #expect(outcome.redactor.redact("echo second-secret-value") == "echo \(Redactor.mask)")
    }
}

@Suite struct CredentialHeuristicsTests {
    @Test func shortCredentialWordsMatchAsWholeWordsOnly() {
        for name in ["jwt", "userJwt", "csrf_token", "session_sid", "otp", "X-Sig", "db_pass", "apiKey"] {
            #expect(CredentialHeuristics.looksSensitive(name: name), "\(name) should look sensitive")
        }
        for name in ["baseUrl", "sidebar", "design", "passenger", "userName", "considered", "hotpath"] {
            #expect(!CredentialHeuristics.looksSensitive(name: name), "\(name) should not look sensitive")
        }
    }
}
