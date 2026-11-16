import Foundation

/// What one send needs: the request as edited, where it lives, and a snapshot of the workspace.
public struct RunInput: Sendable {
    public var item: RequestItem
    /// The collection the request belongs to; `nil` for a one-off request.
    public var collectionID: UUID?
    public var workspace: Workspace
    public var settings: AppSettings

    public init(item: RequestItem, collectionID: UUID?, workspace: Workspace, settings: AppSettings) {
        self.item = item
        self.collectionID = collectionID
        self.workspace = workspace
        self.settings = settings
    }
}

/// The request that went on the wire, safe to show and keep: every secret value is masked.
public struct SentRequest: Hashable, Sendable {
    public var method: String
    public var url: String
    public var headers: [HeaderEntry]
    /// Text of the body when it is textual and reasonably small; `nil` otherwise.
    public var bodyPreview: String?

    public init(method: String, url: String, headers: [HeaderEntry], bodyPreview: String?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.bodyPreview = bodyPreview
    }
}

public struct RunOutcome: Sendable {
    public var response: HTTPResponse?
    /// Why there is no response (script failure, invalid request, network error), ready to show.
    public var errorMessage: String?
    public var wasCancelled: Bool
    public var tests: [TestResult]
    /// Console lines of both script phases, secrets masked.
    public var console: [ConsoleEntry]
    public var sentRequest: SentRequest?
    public var unresolvedVariables: [String]
    /// Changes scripts made to variables, to apply with `Workspace.apply(_:collectionID:)`.
    public var variableChanges: [VariableChange]
    public var historyEntry: HistoryEntry
    /// Masks every secret known to this run. Apply it to anything shown from the response
    /// (a server may echo a credential back).
    public var redactor: Redactor
}

/// Runs one request end to end: pre-request scripts, variable resolution, the exchange,
/// post-response scripts. Stateless and safe to use from several tasks.
public final class RequestRunner: Sendable {
    private let transport: any HTTPTransport
    private let scripts: any ScriptRunning

    private static let bodyPreviewLimit = 256 * 1024

    public init(transport: any HTTPTransport, scripts: any ScriptRunning) {
        self.transport = transport
        self.scripts = scripts
    }

    public func run(_ input: RunInput) async -> RunOutcome {
        let workspace = input.workspace
        let collection = input.collectionID.flatMap { id in workspace.collections.first { $0.id == id } }
        let folders = collection?.ancestry(of: input.item.id) ?? []
        let environment = workspace.activeEnvironment

        let initialScopes = ScriptScopes(
            environment: Self.scriptVariables(environment?.variables ?? []),
            collection: Self.scriptVariables(collection?.variables ?? []),
            globals: Self.scriptVariables(workspace.globals),
            environmentName: environment?.name
        )
        var scopes = initialScopes
        var item = input.item
        var tests: [TestResult] = []
        var console: [ConsoleEntry] = []
        var response: HTTPResponse?
        var errorMessage: String?
        var wasCancelled = false
        var resolved: ResolvedRequest?
        var unresolved: [String] = []
        // Every scope snapshot and every value written to a secret, so masking covers values a
        // script replaced during the run.
        var scopeSnapshots = [initialScopes]
        var secretsWritten: [String] = []

        // 1. Pre-request scripts, outermost first.
        let preSources = Self.sources(
            collection: collection, folders: folders, item: item, phase: .preRequest
        )
        if !preSources.isEmpty {
            let before = Self.scriptRequest(for: item)
            let output = await scripts.run(ScriptInput(
                phase: .preRequest, sources: preSources, request: before, scopes: scopes, requestName: item.name
            ))
            scopes = output.scopes
            scopeSnapshots.append(output.scopes)
            secretsWritten += output.secretValuesWritten
            tests += output.tests
            console += output.console
            Self.apply(output.request, replacing: before, to: &item)
            if let failure = output.failure {
                errorMessage = Self.describe(failure, phase: "Pre-request script")
            }
        }

        // 2. Resolve and send.
        if errorMessage == nil, !Task.isCancelled {
            let context = VariableContext(
                locals: scopes.locals,
                environment: Self.variables(scopes.environment),
                collection: Self.variables(scopes.collection),
                globals: Self.variables(scopes.globals)
            )
            let auth = RequestBuilder.effectiveAuth(for: item, folders: folders, collection: collection)
            do {
                let built = try RequestBuilder.build(item: item, auth: auth, context: context, settings: input.settings)
                resolved = built.request
                unresolved = built.unresolvedVariables
                response = try await transport.send(built.request)
            } catch let error as TransportError {
                wasCancelled = error == .cancelled
                errorMessage = error.localizedDescription
            } catch is CancellationError {
                wasCancelled = true
                errorMessage = "The request was cancelled."
            } catch {
                errorMessage = error.localizedDescription
            }
        } else if errorMessage == nil {
            wasCancelled = true
            errorMessage = "The request was cancelled."
        }

        // 3. Post-response scripts.
        if let response {
            let postSources = Self.sources(
                collection: collection, folders: folders, item: item, phase: .postResponse
            )
            if !postSources.isEmpty {
                let output = await scripts.run(ScriptInput(
                    phase: .postResponse, sources: postSources, request: Self.scriptRequest(for: item),
                    response: ScriptResponse(
                        code: response.statusCode, status: response.statusText, headers: response.headers,
                        body: response.body, responseTime: response.duration * 1000
                    ),
                    scopes: scopes, requestName: item.name
                ))
                scopes = output.scopes
                scopeSnapshots.append(output.scopes)
                secretsWritten += output.secretValuesWritten
                tests += output.tests
                console += output.console
                if let failure = output.failure {
                    console.append(ConsoleEntry(
                        level: .error, message: Self.describe(failure, phase: "Post-response script"),
                        source: failure.source
                    ))
                }
            }
        }

        // 4. Mask every secret before anything is shown or kept.
        let redactor = Redactor(secrets: Self.secrets(
            workspace: workspace, snapshots: scopeSnapshots, written: secretsWritten, resolved: resolved
        ))
        console = console.map { entry in
            var entry = entry
            entry.message = redactor.redact(entry.message)
            return entry
        }
        tests = tests.map { test in
            var test = test
            test.name = redactor.redact(test.name)
            test.message = test.message.map(redactor.redact)
            return test
        }
        let sent = resolved.map { Self.sentRequest($0, redactor: redactor) }
        let history = HistoryEntry(
            request: input.item,
            sourceRequestID: collection == nil ? nil : input.item.id,
            collectionName: collection?.name,
            environmentName: environment?.name,
            resolvedURL: sent?.url ?? redactor.redact(input.item.url),
            statusCode: response?.statusCode,
            statusText: response?.statusText,
            duration: response?.duration,
            size: response?.size,
            errorMessage: errorMessage.map(redactor.redact)
        )

        return RunOutcome(
            response: response,
            errorMessage: errorMessage.map(redactor.redact),
            wasCancelled: wasCancelled,
            tests: tests,
            console: console,
            sentRequest: sent,
            unresolvedVariables: unresolved,
            // A plain variable that received a secret value becomes a secret itself.
            variableChanges: Self.changes(from: initialScopes, to: scopes).map { change in
                var change = change
                if let value = change.value, !change.isSecret, redactor.redact(value) != value {
                    change.isSecret = true
                }
                return change
            },
            historyEntry: history,
            redactor: redactor
        )
    }

    // MARK: - Scripts plumbing

    private static func sources(
        collection: Collection?, folders: [Folder], item: RequestItem, phase: ScriptPhase
    ) -> [ScriptSource] {
        let phaseName = phase == .preRequest ? "Pre-request" : "Post-response"
        var candidates: [(String, String)] = []
        if let collection {
            candidates.append((collection.name, phase == .preRequest ? collection.preRequestScript : collection.postResponseScript))
        }
        for folder in folders {
            candidates.append((folder.name, phase == .preRequest ? folder.preRequestScript : folder.postResponseScript))
        }
        candidates.append((item.name, phase == .preRequest ? item.preRequestScript : item.postResponseScript))
        return candidates
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ScriptSource(label: "\(phaseName) · \($0.0)", code: $0.1) }
    }

    /// The request in template form as scripts see it. Scripts are the person's own code and may read
    /// templates of secret rows; real values only reach them through the variable API.
    private static func scriptRequest(for item: RequestItem) -> ScriptRequest {
        let query = item.queryParams
            .filter { $0.isEnabled && !$0.key.isEmpty }
            .map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let url = query.isEmpty ? item.url : item.url + (item.url.contains("?") ? "&" : "?") + query
        let headers = item.headers
            .filter { $0.isEnabled && !$0.key.isEmpty }
            .map { HeaderEntry(name: $0.key, value: $0.value) }
        return ScriptRequest(
            method: item.method.rawValue, url: url, headers: headers,
            body: item.body.mode == .raw ? item.body.raw : nil
        )
    }

    /// Writes what a pre-request script changed back into the request, touching only what changed.
    private static func apply(_ after: ScriptRequest, replacing before: ScriptRequest, to item: inout RequestItem) {
        if after.method != before.method, let method = HTTPMethod(rawValue: after.method.uppercased()) {
            item.method = method
        }
        if after.url != before.url {
            let parts = URLTemplate.split(after.url)
            item.url = parts.base
            item.queryParams = parts.params
        }
        if after.headers != before.headers {
            var remaining = item.headers.filter { $0.isEnabled && !$0.key.isEmpty }
            item.headers = after.headers.map { header in
                if let index = remaining.firstIndex(where: { $0.key == header.name && $0.value == header.value }) {
                    return remaining.remove(at: index)
                }
                return KeyValue(
                    key: header.name, value: header.value,
                    isSecret: CredentialHeuristics.looksSensitive(name: header.name)
                )
            }
        }
        if after.body != before.body {
            if let body = after.body {
                item.body.mode = .raw
                item.body.raw = body
            } else {
                item.body.mode = .none
            }
        }
    }

    private static func describe(_ failure: ScriptFailure, phase: String) -> String {
        let location = failure.line.map { " (line \($0))" } ?? ""
        return "\(phase) failed\(location): \(failure.message)"
    }

    // MARK: - Variables plumbing

    private static func scriptVariables(_ variables: [Variable]) -> [ScriptVariable] {
        var result: [ScriptVariable] = []
        for variable in variables where variable.isEnabled && !variable.name.isEmpty {
            let entry = ScriptVariable(name: variable.name, value: variable.value, isSecret: variable.isSecret)
            if let index = result.firstIndex(where: { $0.name == variable.name }) {
                result[index] = entry
            } else {
                result.append(entry)
            }
        }
        return result
    }

    private static func variables(_ variables: [ScriptVariable]) -> [Variable] {
        variables.map { Variable(name: $0.name, value: $0.value, isSecret: $0.isSecret) }
    }

    private static func changes(from before: ScriptScopes, to after: ScriptScopes) -> [VariableChange] {
        func diff(_ kind: VariableScopeKind, _ old: [ScriptVariable], _ new: [ScriptVariable]) -> [VariableChange] {
            var result: [VariableChange] = []
            for variable in new where old.first(where: { $0.name == variable.name }) != variable {
                result.append(VariableChange(scope: kind, name: variable.name, value: variable.value, isSecret: variable.isSecret))
            }
            for variable in old where !new.contains(where: { $0.name == variable.name }) {
                result.append(VariableChange(scope: kind, name: variable.name, value: nil))
            }
            return result
        }
        return diff(.environment, before.environment, after.environment)
            + diff(.collection, before.collection, after.collection)
            + diff(.global, before.globals, after.globals)
    }

    // MARK: - Redaction

    private static func secrets(
        workspace: Workspace, snapshots: [ScriptScopes], written: [String], resolved: ResolvedRequest?
    ) -> [String] {
        var values = workspace.secretValues() + written
        for scopes in snapshots {
            for variable in scopes.environment + scopes.collection + scopes.globals where variable.isSecret {
                values.append(variable.value)
            }
        }
        // A secret may itself hold placeholders (`sk-{{tenant}}-…`): what goes on the wire is its
        // rendered form, in any of the contexts the run went through.
        for scopes in snapshots {
            let context = VariableContext(
                locals: scopes.locals, environment: variables(scopes.environment),
                collection: variables(scopes.collection), globals: variables(scopes.globals)
            )
            for value in values where value.contains("{{") {
                values.append(TemplateEngine.render(value, in: context).text)
            }
        }
        // The builder trims addresses and header values; servers often echo values HTML-escaped.
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != value { values.append(trimmed) }
            let escaped = trimmed
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            if escaped != trimmed { values.append(escaped) }
        }
        // Defence in depth: a header that looks like a credential is masked even when nobody marked it secret.
        for header in resolved?.headers ?? [] where CredentialHeuristics.looksSensitive(name: header.name) {
            values.append(header.value)
            let parts = header.value.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { values.append(String(parts[1])) }
        }
        return values
    }

    private static func sentRequest(_ request: ResolvedRequest, redactor: Redactor) -> SentRequest {
        var preview: String?
        if case .data(let data) = request.body, data.count <= bodyPreviewLimit,
           let text = String(data: data, encoding: .utf8) {
            preview = redactor.redact(text)
        }
        return SentRequest(
            method: request.method,
            url: redactor.redact(request.url.absoluteString),
            headers: request.headers.map { HeaderEntry(name: $0.name, value: redactor.redact($0.value)) },
            bodyPreview: preview
        )
    }
}

// MARK: - Applying script changes to the live workspace

public extension Workspace {
    /// Applies what scripts changed. Environment changes go to the active environment, collection
    /// changes to the given collection; a change whose target is missing is ignored.
    mutating func apply(_ changes: [VariableChange], collectionID: UUID?) {
        for change in changes {
            switch change.scope {
            case .local:
                continue
            case .global:
                Self.apply(change, to: &globals)
            case .environment:
                guard let index = environments.firstIndex(where: { $0.id == activeEnvironmentID }) else { continue }
                Self.apply(change, to: &environments[index].variables)
            case .collection:
                guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { continue }
                Self.apply(change, to: &collections[index].variables)
            }
        }
    }

    private static func apply(_ change: VariableChange, to variables: inout [Variable]) {
        guard let value = change.value else {
            variables.removeAll { $0.name == change.name }
            return
        }
        if let index = variables.lastIndex(where: { $0.name == change.name && $0.isEnabled }) {
            variables[index].value = value
            // A script may make a variable secret, never the reverse.
            if change.isSecret { variables[index].isSecret = true }
        } else {
            variables.append(Variable(name: change.name, value: value, isSecret: change.isSecret))
        }
    }
}
