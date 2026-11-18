import Foundation

/// The MCP side of the relay: reads one JSON-RPC message from an agent's program, answers it, and hands
/// tool calls to the application. It holds no data of its own and no secret: it only translates.
public struct MCPRelay {
    /// The protocol revisions this relay speaks, oldest first.
    public static let versions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    public private(set) var clientName = "An agent"
    private let serverVersion: String

    public init(serverVersion: String) {
        self.serverVersion = serverVersion
    }

    /// What a line received on standard input asks of the relay.
    public enum Step: Equatable, Sendable {
        /// Nothing to answer.
        case none
        /// A line to write on standard output.
        case answer(String)
        /// A tool call to hand to the application; its result is written with ``answer(to:with:)``.
        case call(id: JSONValue, AgentCall)
        /// The program no longer waits for the answer to the request of this id.
        case cancel(id: JSONValue)
    }

    /// Answers one line received on standard input. `nil` when the message asks for no answer.
    public mutating func handle(_ line: String, call: (AgentCall) -> AgentReply) -> String? {
        switch step(for: line) {
        case .none, .cancel: nil
        case .answer(let text): text
        case .call(let id, let asked): Self.answer(to: id, with: call(asked))
        }
    }

    /// The result of a tool call, as the line to write.
    public static func answer(to id: JSONValue, with reply: AgentReply) -> String {
        encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object([
            "content": .array([.object(["type": .string("text"), "text": .string(reply.text)])]),
            "isError": .bool(reply.isError),
        ])]))
    }

    public mutating func step(for line: String) -> Step {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), message.object != nil else {
            return .answer(Self.encode(.object(["jsonrpc": .string("2.0"), "id": .null, "error": Self.error(-32700, "Parse error")])))
        }
        // A message without an id is a notification: nothing is answered.
        guard let id = message["id"], id != .null else {
            if message["method"]?.string == "notifications/cancelled", let asked = message["params"]?["requestId"], asked != .null {
                return .cancel(id: asked)
            }
            return .none
        }
        func reply(_ result: JSONValue) -> Step {
            .answer(Self.encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])))
        }

        switch message["method"]?.string {
        case "initialize":
            if let name = message["params"]?["clientInfo"]?["name"]?.string, !name.isEmpty {
                clientName = String(name.prefix(80))
            }
            let asked = message["params"]?["protocolVersion"]?.string ?? ""
            let version = Self.versions.contains(asked) ? asked : (Self.versions.last ?? asked)
            return reply(.object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("bee"), "title": .string("Bee"), "version": .string(serverVersion)]),
                "instructions": .string(
                    "Bee is the person's API client. You can read the requests of the collections they opened to you, "
                        + "send one as it is written, or propose a change, which they review before anything is changed. "
                        + "Secret values are never given to you; a response may show them masked."
                ),
            ]))
        case "ping":
            return reply(.object([:]))
        case "tools/list":
            return reply(.object(["tools": .array(AgentTool.allCases.map { tool in
                .object([
                    "name": .string(tool.rawValue), "description": .string(tool.summary), "inputSchema": tool.inputSchema,
                ])
            })]))
        case "tools/call":
            guard let name = message["params"]?["name"]?.string, AgentTool(rawValue: name) != nil else {
                return .answer(Self.encode(.object(["jsonrpc": .string("2.0"), "id": id, "error": Self.error(-32602, "Unknown tool")])))
            }
            return .call(id: id, AgentCall(
                id: UUID().uuidString, tool: name, arguments: message["params"]?["arguments"] ?? .object([:]), client: clientName
            ))
        default:
            return .answer(Self.encode(.object(["jsonrpc": .string("2.0"), "id": id, "error": Self.error(-32601, "Method not found")])))
        }
    }

    private static func error(_ code: Int, _ message: String) -> JSONValue {
        .object(["code": .number(Double(code)), "message": .string(message)])
    }

    /// One line, as the stdio transport wants: no line break inside a message.
    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
