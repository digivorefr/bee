import Foundation
import JavaScriptCore

/// Drives one JavaScriptCore context on the dedicated script thread: evaluates each source, then runs the
/// event loop (timers, `sendRequest` completions, promise jobs) until the source has fully settled.
/// Not thread-safe by design: everything except `state` and `completions` is touched by that thread only.
final class ScriptRuntime {
    enum Settlement {
        case fulfilled
        case rejected(JSValue)
    }

    private struct EntryPoints {
        let trackSource: JSValue
        let fireTimer: JSValue
        let completeRequest: JSValue
        let describeError: JSValue
    }

    private enum Step {
        case keepGoing
        case finished
        case failed(ScriptFailure)
    }

    let input: ScriptInput
    let state: ScriptRunState
    let transport: (any HTTPTransport)?
    let completions = CompletionQueue()
    let context: JSContext

    private let sources: [ScriptSource]
    private let timeout: TimeInterval
    private let deadline: UInt64
    private let usesExecutionTimeLimit: Bool
    private let timeoutFlag = TimeoutFlag()
    private var entryPoints: EntryPoints?
    private var raisedException: JSValue?

    // Event-loop bookkeeping, written by the host functions.
    var settlement: Settlement?
    /// Timer id to the monotonic time (nanoseconds) it is due.
    var timers: [Int: UInt64] = [:]
    /// Requests started but not yet delivered to the script, including ones that failed before sending.
    var pendingRequests: Set<Int> = []
    var requestTasks: [Int: Task<Void, Never>] = [:]
    var requestCounter = 0

    init?(
        input: ScriptInput, sources: [ScriptSource], state: ScriptRunState, transport: (any HTTPTransport)?,
        timeout: TimeInterval, deadline: UInt64, usesExecutionTimeLimit: Bool
    ) {
        guard let machine = JSVirtualMachine(), let context = JSContext(virtualMachine: machine) else { return nil }
        self.context = context
        self.input = input
        self.sources = sources
        self.state = state
        self.transport = transport
        self.timeout = timeout
        self.deadline = deadline
        self.usesExecutionTimeLimit = usesExecutionTimeLimit
    }

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // MARK: Run

    func run() -> ScriptOutput {
        var failure: ScriptFailure?
        if install() {
            for (index, source) in sources.enumerated() {
                state.sourceLabel = source.label
                failure = execute(source, index: index)
                if failure != nil { break }
            }
        } else {
            failure = ScriptFailure(source: sources[0].label, message: "Unable to start the script runtime")
        }
        for task in requestTasks.values { task.cancel() }
        requestTasks = [:]
        pendingRequests = []
        return state.snapshot(failure: failure)
    }

    private func install() -> Bool {
        context.exceptionHandler = { [unowned self] _, exception in
            raisedException = exception
        }
        let host = makeHostObject()
        context.setObject(host, forKeyedSubscript: "__host" as NSString)
        let prelude = context.evaluateScript(ScriptPrelude.source, withSourceURL: URL(string: ScriptPrelude.sourceURL))
        raisedException = nil
        guard let prelude, prelude.isObject,
              let trackSource = prelude.forProperty("trackSource"),
              let fireTimer = prelude.forProperty("fireTimer"),
              let completeRequest = prelude.forProperty("completeRequest"),
              let describeError = prelude.forProperty("describeError")
        else { return false }
        entryPoints = EntryPoints(
            trackSource: trackSource, fireTimer: fireTimer, completeRequest: completeRequest,
            describeError: describeError
        )
        return true
    }

    /// Runs one source to completion. The wrapper keeps the person's first line on line 1 of the
    /// evaluated text so reported line numbers match their code.
    private func execute(_ source: ScriptSource, index: Int) -> ScriptFailure? {
        let url = "bee-script-\(index + 1)"
        settlement = nil
        let wrapped = "(async () => {" + source.code + "\n})()"
        var promise: JSValue?
        enter { promise = context.evaluateScript(wrapped, withSourceURL: URL(string: url)) }
        if let failure = failureAfterEntry(url: url) { return failure }
        guard let entryPoints, let promise else {
            return ScriptFailure(source: source.label, message: "The script did not start")
        }
        enter { _ = entryPoints.trackSource.call(withArguments: [promise]) }
        if let failure = failureAfterEntry(url: url) { return failure }
        return drive(url: url)
    }

    // MARK: Event loop

    private func drive(url: String) -> ScriptFailure? {
        while true {
            let step = autoreleasepool { step(url: url) }
            switch step {
            case .keepGoing: continue
            case .finished: return nil
            case .failed(let failure): return failure
            }
        }
    }

    private func step(url: String) -> Step {
        guard let entryPoints else { return .failed(ScriptFailure(source: state.sourceLabel, message: "Script runtime missing")) }
        if state.isCancelled {
            return .failed(ScriptFailure(source: state.sourceLabel, message: "Script cancelled"))
        }

        let now = Self.now()
        let dueTimers = timers.filter { $0.value <= now }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        for (id, _) in dueTimers {
            timers[id] = nil
            enter { _ = entryPoints.fireTimer.call(withArguments: [id]) }
            if let failure = failureAfterEntry(url: url) { return .failed(failure) }
        }

        for completion in completions.drain() {
            pendingRequests.remove(completion.id)
            requestTasks[completion.id] = nil
            let arguments: [Any]
            switch completion.result {
            case .success(let response): arguments = [completion.id, true, Self.payload(for: response)]
            case .failure(let error): arguments = [completion.id, false, error.localizedDescription]
            }
            enter { _ = entryPoints.completeRequest.call(withArguments: arguments) }
            if let failure = failureAfterEntry(url: url) { return .failed(failure) }
        }

        if case .fulfilled? = settlement, timers.isEmpty, pendingRequests.isEmpty, !state.hasPendingTests {
            return .finished
        }
        if Self.now() >= deadline {
            return .failed(.timeout(source: state.sourceLabel, seconds: timeout))
        }
        if timers.isEmpty && pendingRequests.isEmpty {
            // Nothing is left that could resolve the pending promise.
            return .failed(ScriptFailure(
                source: state.sourceLabel,
                message: "Script never finished: a promise is pending and no timer or request can settle it"
            ))
        }
        completions.wait(untilUptime: min(timers.values.min() ?? deadline, deadline))
        return .keepGoing
    }

    /// Re-arms JavaScriptCore's time limit with what is left of the run, then calls into JavaScript.
    private func enter(_ body: () -> Void) {
        if usesExecutionTimeLimit {
            let now = Self.now()
            let remaining = Double(deadline > now ? deadline - now : 0) / 1_000_000_000
            ExecutionTimeLimit.arm(context, seconds: remaining, flag: timeoutFlag)
        }
        body()
    }

    /// The failure a call into JavaScript caused, if any: the time limit, an uncaught exception, or a
    /// source promise that rejected as a result of the microtasks that ran on the way out.
    private func failureAfterEntry(url: String) -> ScriptFailure? {
        if timeoutFlag.isTripped {
            raisedException = nil
            return .timeout(source: state.sourceLabel, seconds: timeout)
        }
        if let exception = raisedException {
            raisedException = nil
            return failure(describing: exception, url: url)
        }
        if case .rejected(let error)? = settlement {
            return failure(describing: error, url: url)
        }
        return nil
    }

    private func failure(describing error: JSValue, url: String) -> ScriptFailure {
        var message = error.toString() ?? "Unknown error"
        var line: Int?
        if let entryPoints,
           let described = entryPoints.describeError.call(withArguments: [error, url]), described.isObject {
            if let text = described.forProperty("message"), text.isString, let string = text.toString() {
                message = string
            }
            if let number = described.forProperty("line"), number.isNumber, number.toInt32() > 0 {
                line = Int(number.toInt32())
            }
            raisedException = nil
        }
        return ScriptFailure(source: state.sourceLabel, message: message, line: line)
    }
}
