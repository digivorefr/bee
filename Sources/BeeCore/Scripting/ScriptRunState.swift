import Foundation
import Synchronization

/// Everything a run produces: variable scopes, the request being rewritten, tests and console lines.
/// The JavaScript thread mutates it through the host functions; it is lock-protected so a watchdog or a
/// cancellation can snapshot it from another thread while a script is still running.
final class ScriptRunState: Sendable {
    enum Scope: String {
        case locals, environment, collection, globals
    }

    private struct TestRecord {
        var id = UUID()
        var name: String
        var outcome: Outcome?

        struct Outcome {
            var passed: Bool
            var message: String?
        }
    }

    private struct Storage {
        var request: ScriptRequest
        var scopes: ScriptScopes
        var tests: [TestRecord] = []
        var console: [ConsoleEntry] = []
        var sourceLabel = ""
        var pendingTests = 0
        /// Every value written into a secret variable, including those overwritten later.
        var secretValuesWritten: [String] = []
    }

    private let storage: Mutex<Storage>
    private let cancelled = Mutex(false)
    private let phase: ScriptPhase
    private let originalRequest: ScriptRequest

    init(input: ScriptInput) {
        phase = input.phase
        originalRequest = input.request
        storage = Mutex(Storage(request: input.request, scopes: input.scopes))
    }

    // MARK: Run control

    var sourceLabel: String {
        get { storage.withLock { $0.sourceLabel } }
        set { storage.withLock { $0.sourceLabel = newValue } }
    }

    var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }

    /// Request rewrites are honoured in the pre-request phase only.
    var allowsRequestChanges: Bool { phase == .preRequest }

    var environmentName: String? { storage.withLock { $0.scopes.environmentName } }

    var currentRequest: ScriptRequest { storage.withLock { $0.request } }

    func replaceRequest(_ request: ScriptRequest) {
        guard allowsRequestChanges else { return }
        storage.withLock { $0.request = request }
    }

    // MARK: Variables

    func value(of scope: Scope, name: String) -> String? {
        storage.withLock { storage in
            switch scope {
            case .locals: storage.scopes.locals[name]
            case .environment: storage.scopes.environment.last { $0.name == name }?.value
            case .collection: storage.scopes.collection.last { $0.name == name }?.value
            case .globals: storage.scopes.globals.last { $0.name == name }?.value
            }
        }
    }

    /// Stores `value`. For the three persistent scopes `secret` is the script's explicit choice:
    /// an existing secret is never downgraded and a new variable falls back to the name heuristic.
    func set(_ scope: Scope, name: String, value: String, secret: Bool?) {
        storage.withLock { storage in
            switch scope {
            case .locals: storage.scopes.locals[name] = value
            case .environment:
                if Self.upsert(&storage.scopes.environment, name, value, secret) { storage.secretValuesWritten.append(value) }
            case .collection:
                if Self.upsert(&storage.scopes.collection, name, value, secret) { storage.secretValuesWritten.append(value) }
            case .globals:
                if Self.upsert(&storage.scopes.globals, name, value, secret) { storage.secretValuesWritten.append(value) }
            }
        }
    }

    func unset(_ scope: Scope, name: String) {
        storage.withLock { storage in
            switch scope {
            case .locals: storage.scopes.locals[name] = nil
            case .environment: storage.scopes.environment.removeAll { $0.name == name }
            case .collection: storage.scopes.collection.removeAll { $0.name == name }
            case .globals: storage.scopes.globals.removeAll { $0.name == name }
            }
        }
    }

    func clear(_ scope: Scope) {
        storage.withLock { storage in
            switch scope {
            case .locals: storage.scopes.locals = [:]
            case .environment: storage.scopes.environment = []
            case .collection: storage.scopes.collection = []
            case .globals: storage.scopes.globals = []
            }
        }
    }

    /// `[name, value]` pairs in storage order (sorted by name for the unordered locals).
    func entries(of scope: Scope) -> [[String]] {
        storage.withLock { storage in
            switch scope {
            case .locals: storage.scopes.locals.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
            case .environment: storage.scopes.environment.map { [$0.name, $0.value] }
            case .collection: storage.scopes.collection.map { [$0.name, $0.value] }
            case .globals: storage.scopes.globals.map { [$0.name, $0.value] }
            }
        }
    }

    /// Returns true when the variable is secret after the write.
    private static func upsert(
        _ variables: inout [ScriptVariable], _ name: String, _ value: String, _ secret: Bool?
    ) -> Bool {
        if let index = variables.lastIndex(where: { $0.name == name }) {
            variables[index].value = value
            if secret == true { variables[index].isSecret = true }
            return variables[index].isSecret
        }
        let isSecret = secret ?? CredentialHeuristics.looksSensitive(name: name)
        variables.append(ScriptVariable(name: name, value: value, isSecret: isSecret))
        return isSecret
    }

    // MARK: Tests

    var hasPendingTests: Bool { storage.withLock { $0.pendingTests > 0 } }

    /// Registers a test in call order and returns its index; async tests report their outcome later.
    func beginTest(name: String) -> Int {
        storage.withLock { storage in
            storage.tests.append(TestRecord(name: name))
            storage.pendingTests += 1
            return storage.tests.count - 1
        }
    }

    func endTest(index: Int, passed: Bool, message: String?) {
        storage.withLock { storage in
            guard storage.tests.indices.contains(index), storage.tests[index].outcome == nil else { return }
            storage.tests[index].outcome = TestRecord.Outcome(passed: passed, message: passed ? nil : message)
            storage.pendingTests -= 1
        }
    }

    // MARK: Console

    func log(level: ConsoleLevel, message: String) {
        storage.withLock { storage in
            storage.console.append(
                ConsoleEntry(level: level, message: message, source: storage.sourceLabel)
            )
        }
    }

    // MARK: Output

    func snapshot(failure: ScriptFailure?) -> ScriptOutput {
        storage.withLock { storage in
            let tests = storage.tests.map { record in
                TestResult(
                    id: record.id, name: record.name,
                    passed: record.outcome?.passed ?? false,
                    message: record.outcome.map(\.message) ?? "Test did not complete"
                )
            }
            return ScriptOutput(
                request: allowsRequestChanges ? storage.request : originalRequest,
                scopes: storage.scopes, tests: tests, console: storage.console, failure: failure,
                secretValuesWritten: storage.secretValuesWritten
            )
        }
    }
}

extension ScriptFailure {
    /// `Script timed out after 10 s`, using the configured limit.
    static func timeout(source: String, seconds: TimeInterval) -> ScriptFailure {
        ScriptFailure(source: source, message: "Script timed out after \(String(format: "%g", seconds)) s")
    }
}
