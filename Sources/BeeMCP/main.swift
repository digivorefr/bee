import BeeCore
import Darwin
import Foundation

// bee-mcp: the relay an AI agent's program starts to talk to Bee. It speaks MCP on its standard streams
// and hands every tool call to the running application over Bee's private socket. It reads no file of
// Bee's and holds no secret: what an agent may see or do is decided, and done, by the application.

// A program that stops reading must not kill the relay on its next write.
signal(SIGPIPE, SIG_IGN)

/// Where the application listens: its data folder, which only this user can open.
func resolveSocketPath() -> String {
    #if DEBUG
    if let override = ProcessInfo.processInfo.environment["BEE_AGENT_SOCKET"], !override.isEmpty { return override }
    #endif
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return LocalSocket.path(inDataDirectory: support.appendingPathComponent("Bee", isDirectory: true))
}

/// The calls the application has not answered yet. A call the program gives up on is dropped: its
/// connection is cut, so Bee stops asking the person about it and sends nothing for it.
final class PendingCalls: @unchecked Sendable {
    private let lock = NSLock()
    private let output = NSLock()
    private var active: Set<JSONValue> = []
    private var cancelled: Set<JSONValue> = []
    private var sockets: [JSONValue: Int32] = [:]

    func start(_ id: JSONValue) {
        lock.withLock { _ = active.insert(id) }
    }

    /// Ties the connection to the call. False when the call was given up meanwhile.
    func attach(_ socket: Int32, to id: JSONValue) -> Bool {
        lock.withLock {
            guard !cancelled.contains(id) else { return false }
            sockets[id] = socket
            return true
        }
    }

    func cancel(_ id: JSONValue) {
        lock.withLock {
            guard active.contains(id) else { return }
            cancelled.insert(id)
            if let socket = sockets[id] { shutdown(socket, SHUT_RDWR) }
        }
    }

    /// Forgets the call and closes its connection. True when it was given up: nothing is answered then.
    /// The connection is closed here, with its number taken out of the list in the same breath: a call
    /// given up never cuts the connection another call was given the same number for.
    func end(_ id: JSONValue) -> Bool {
        lock.withLock {
            active.remove(id)
            if let socket = sockets.removeValue(forKey: id) { close(socket) }
            return cancelled.remove(id) != nil
        }
    }

    func write(_ line: String) {
        output.withLock { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    }
}

/// Hands a call to the application and waits for its answer. `nil` when the call was given up first.
func ask(_ call: AgentCall, at socketPath: String, attach: (Int32) -> Bool) -> AgentReply? {
    guard let descriptor = LocalSocket.connect(to: socketPath) else {
        return AgentReply(
            id: call.id, text: "Bee is not running, or agents are not allowed in it. Open Bee, then turn on Settings › Agents.",
            isError: true
        )
    }
    // Once tied to the call, the connection is closed with it (see `PendingCalls.end`).
    guard attach(descriptor) else {
        close(descriptor)
        return nil
    }
    guard let data = try? JSONEncoder().encode(call), LocalSocket.writeLine(String(decoding: data, as: UTF8.self), to: descriptor),
          let line = LocalSocket.readLine(from: descriptor),
          let reply = try? JSONDecoder().decode(AgentReply.self, from: Data(line.utf8))
    else {
        return AgentReply(id: call.id, text: "Bee closed the connection before answering.", isError: true)
    }
    return reply
}

let socketPath = resolveSocketPath()
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
let calls = PendingCalls()
var relay = MCPRelay(serverVersion: version)
// Each call waits for Bee on a thread of its own: the relay goes on answering pings and hearing a
// program that gives up while the person is being asked.
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    switch relay.step(for: line) {
    case .none:
        break
    case .answer(let text):
        calls.write(text)
    case .cancel(let id):
        calls.cancel(id)
    case .call(let id, let call):
        calls.start(id)
        Thread.detachNewThread { [calls, socketPath] in
            let reply = ask(call, at: socketPath) { calls.attach($0, to: id) }
            if !calls.end(id), let reply { calls.write(MCPRelay.answer(to: id, with: reply)) }
        }
    }
}
