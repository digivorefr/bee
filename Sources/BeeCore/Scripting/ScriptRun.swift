import Foundation
import Synchronization

/// One execution of a script input: owns the dedicated thread, the watchdog and the hand-over of the
/// result to the awaiting caller.
final class ScriptRun: Sendable {
    private struct Handover {
        var continuation: CheckedContinuation<ScriptOutput, Never>?
        var output: ScriptOutput?
        var watchdog: Task<Void, Never>?
    }

    private let input: ScriptInput
    private let sources: [ScriptSource]
    private let transport: (any HTTPTransport)?
    private let timeout: TimeInterval
    private let deadline: UInt64
    private let usesExecutionTimeLimit: Bool
    private let state: ScriptRunState
    private let handover = Mutex(Handover())

    init(
        input: ScriptInput, sources: [ScriptSource], transport: (any HTTPTransport)?,
        timeout: TimeInterval, usesExecutionTimeLimit: Bool
    ) {
        self.input = input
        self.sources = sources
        self.transport = transport
        self.timeout = timeout
        self.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        self.usesExecutionTimeLimit = usesExecutionTimeLimit && ExecutionTimeLimit.isAvailable
        self.state = ScriptRunState(input: input)
    }

    func start(_ continuation: CheckedContinuation<ScriptOutput, Never>) {
        let finished: ScriptOutput? = handover.withLock { handover in
            if let output = handover.output { return output }
            handover.continuation = continuation
            return nil
        }
        if let finished {
            continuation.resume(returning: finished)
            return
        }

        // Without JavaScriptCore's own limit only the watchdog can end a runaway script, so it fires at the
        // deadline; otherwise it is a backstop that leaves the limit and the run loop time to finish first.
        let watchdogDelay = timeout + (usesExecutionTimeLimit ? 1 : 0.05)
        let watchdog = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(watchdogDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finish(state.snapshot(failure: .timeout(source: state.sourceLabel, seconds: timeout)))
        }
        handover.withLock { $0.watchdog = watchdog }

        let thread = Thread { [self] in execute() }
        thread.name = "bee.script"
        thread.qualityOfService = .userInitiated
        // JavaScriptCore recurses on the native stack; give deep scripts room before RangeError.
        thread.stackSize = 8 << 20
        thread.start()
    }

    func cancel() {
        state.cancel()
        finish(state.snapshot(failure: ScriptFailure(source: state.sourceLabel, message: "Script cancelled")))
    }

    /// Runs on the dedicated thread. The runtime (VM, context, JS handles) is gone before the caller resumes.
    private func execute() {
        let output = autoreleasepool {
            guard let runtime = ScriptRuntime(
                input: input, sources: sources, state: state, transport: transport, timeout: timeout,
                deadline: deadline, usesExecutionTimeLimit: usesExecutionTimeLimit
            ) else {
                return state.snapshot(failure: ScriptFailure(
                    source: sources.first?.label ?? "", message: "Unable to create a JavaScript context"
                ))
            }
            return runtime.run()
        }
        finish(output)
    }

    /// Delivers the first result only; later calls (a late thread, a cancel after completion) are no-ops.
    private func finish(_ output: ScriptOutput) {
        let (continuation, watchdog) = handover.withLock { handover in
            guard handover.output == nil else {
                return (nil as CheckedContinuation<ScriptOutput, Never>?, nil as Task<Void, Never>?)
            }
            handover.output = output
            defer {
                handover.continuation = nil
                handover.watchdog = nil
            }
            return (handover.continuation, handover.watchdog)
        }
        watchdog?.cancel()
        continuation?.resume(returning: output)
    }
}
