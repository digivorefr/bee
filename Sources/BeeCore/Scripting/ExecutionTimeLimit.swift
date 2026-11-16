import Foundation
import JavaScriptCore
import Synchronization

/// Set from JavaScriptCore's time-limit callback, which may fire while a script is being unwound.
final class TimeoutFlag: Sendable {
    private let tripped = Mutex(false)

    var isTripped: Bool { tripped.withLock { $0 } }

    func trip() { tripped.withLock { $0 = true } }
}

/// Wraps `JSContextGroupSetExecutionTimeLimit`, which is not in the public JavaScriptCore headers and is
/// therefore resolved with `dlsym`. The limit is measured per entry into the VM, so it is re-armed with
/// the remaining run time before every call into JavaScript.
enum ExecutionTimeLimit {
    private typealias TerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetFunction = @convention(c) (
        JSContextGroupRef?, Double, TerminateCallback?, UnsafeMutableRawPointer?
    ) -> Void

    private static let symbolName = "JSContextGroupSetExecutionTimeLimit"
    private static let frameworkPath = "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"

    private static let setFunction: SetFunction? = {
        // RTLD_DEFAULT is `(void *)-2` on Darwin.
        var symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbolName)
        if symbol == nil, let handle = dlopen(frameworkPath, RTLD_LAZY) {
            symbol = dlsym(handle, symbolName)
        }
        return symbol.map { unsafeBitCast($0, to: SetFunction.self) }
    }()

    private static let onExpiry: TerminateCallback = { _, data in
        guard let data else { return false }
        Unmanaged<TimeoutFlag>.fromOpaque(data).takeUnretainedValue().trip()
        return true
    }

    /// `false` when the running JavaScriptCore does not export the symbol.
    static var isAvailable: Bool { setFunction != nil }

    /// Arms the limit for the next entry into `context`. `flag` must outlive the context.
    static func arm(_ context: JSContext, seconds: TimeInterval, flag: TimeoutFlag) {
        guard let setFunction else { return }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        setFunction(group, max(seconds, 0.001), onExpiry, Unmanaged.passUnretained(flag).toOpaque())
    }
}
