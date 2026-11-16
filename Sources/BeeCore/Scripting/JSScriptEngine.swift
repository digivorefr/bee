import Foundation

/// Runs pre-request and post-response scripts on JavaScriptCore.
///
/// Every `run` gets its own `JSVirtualMachine` and `JSContext` on a dedicated thread, so nothing leaks
/// between runs and concurrent calls are independent. Scripts see the `bee` API (also exposed as `pm`).
public final class JSScriptEngine: ScriptRunning {
    private let transport: (any HTTPTransport)?
    private let timeout: TimeInterval
    private let usesExecutionTimeLimit: Bool

    /// - Parameters:
    ///   - transport: backs `bee.sendRequest`; without it that call rejects with a clear error.
    ///   - timeout: wall-clock bound of one `run`, in seconds.
    public convenience init(transport: (any HTTPTransport)? = nil, timeout: TimeInterval = 10) {
        self.init(transport: transport, timeout: timeout, usesExecutionTimeLimit: true)
    }

    /// `usesExecutionTimeLimit: false` forces the watchdog fallback used when JavaScriptCore does not export
    /// its execution-time-limit function; it exists so tests can exercise that path.
    init(transport: (any HTTPTransport)?, timeout: TimeInterval, usesExecutionTimeLimit: Bool) {
        self.transport = transport
        self.timeout = timeout.isFinite ? min(max(timeout, 0.01), 86_400) : 10
        self.usesExecutionTimeLimit = usesExecutionTimeLimit
    }

    public func run(_ input: ScriptInput) async -> ScriptOutput {
        let sources = input.sources.filter {
            !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !sources.isEmpty else {
            return ScriptOutput(request: input.request, scopes: input.scopes)
        }
        let run = ScriptRun(
            input: input, sources: sources, transport: transport, timeout: timeout,
            usesExecutionTimeLimit: usesExecutionTimeLimit
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { run.start($0) }
        } onCancel: {
            run.cancel()
        }
    }
}
