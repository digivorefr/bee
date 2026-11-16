import Foundation
import Synchronization

/// Finished `sendRequest` exchanges handed from transport tasks to the JavaScript thread, which sleeps
/// on it between events.
final class CompletionQueue: Sendable {
    struct Completion: Sendable {
        let id: Int
        let result: Result<HTTPResponse, any Error>
    }

    private let items = Mutex<[Completion]>([])
    private let signal = DispatchSemaphore(value: 0)

    func push(id: Int, result: Result<HTTPResponse, any Error>) {
        items.withLock { $0.append(Completion(id: id, result: result)) }
        signal.signal()
    }

    /// Wakes the waiting thread without delivering anything (cancellation).
    func wake() {
        signal.signal()
    }

    func drain() -> [Completion] {
        items.withLock { items in
            defer { items.removeAll() }
            return items
        }
    }

    /// Blocks until `push`, `wake` or the monotonic `deadline` (nanoseconds, `DispatchTime` uptime).
    func wait(untilUptime deadline: UInt64) {
        _ = signal.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
    }
}
