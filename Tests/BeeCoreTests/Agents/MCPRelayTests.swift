import Foundation
import Testing
@testable import BeeCore

@Suite struct MCPRelayTests {
    private func parse(_ line: String?) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(try #require(line).utf8))
    }

    @Test func speaksTheHandshakeAndListsTheTools() throws {
        var relay = MCPRelay(serverVersion: "1.2.0")
        let never: (AgentCall) -> AgentReply = { AgentReply(id: $0.id, text: "unexpected", isError: true) }

        let hello = try parse(relay.handle(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#,
            call: never
        ))
        #expect(hello["id"] == .number(1))
        #expect(hello["result"]?["protocolVersion"]?.string == "2025-06-18")
        #expect(hello["result"]?["serverInfo"]?["name"]?.string == "bee")
        #expect(hello["result"]?["capabilities"]?["tools"] != nil)
        #expect(relay.clientName == "claude-code")

        // A revision the relay does not know is answered with the latest it speaks.
        var other = MCPRelay(serverVersion: "1")
        let future = try parse(other.handle(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#, call: never))
        #expect(future["result"]?["protocolVersion"]?.string == MCPRelay.versions.last)
        #expect(future["id"] == .string("a"))

        #expect(relay.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, call: never) == nil)
        #expect(try parse(relay.handle(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, call: never))["result"] == .object([:]))

        let tools = try parse(relay.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, call: never))
        let names = tools["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        #expect(names == AgentTool.allCases.map(\.rawValue))
        #expect(tools["result"]?["tools"]?.array?.first?["inputSchema"]?["type"]?.string == "object")
    }

    @Test func handsToolCallsToTheApplicationAndNothingElse() throws {
        var relay = MCPRelay(serverVersion: "1")
        _ = relay.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"tester"}}}"#, call: { AgentReply(id: $0.id, text: "") })
        var received: [AgentCall] = []
        let answer = try parse(relay.handle(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_request","arguments":{"request_id":"abc"}}}"#,
            call: { call in
                received.append(call)
                return AgentReply(id: call.id, text: "line one\nline two", isError: false)
            }
        ))
        #expect(received.count == 1)
        #expect(received.first?.tool == "get_request")
        #expect(received.first?.client == "tester")
        #expect(received.first?.arguments["request_id"]?.string == "abc")
        #expect(answer["result"]?["content"]?.array?.first?["text"]?.string == "line one\nline two")
        #expect(answer["result"]?["isError"]?.bool == false)

        // An unknown tool, an unknown method and what is not JSON never reach the application.
        let unknownTool = try parse(relay.handle(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"reveal_secret"}}"#, call: { received.append($0); return AgentReply(id: "", text: "") }))
        #expect(unknownTool["error"]?["code"] == .number(-32602))
        let unknownMethod = try parse(relay.handle(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#, call: { received.append($0); return AgentReply(id: "", text: "") }))
        #expect(unknownMethod["error"]?["code"] == .number(-32601))
        let garbage = try parse(relay.handle("not json", call: { received.append($0); return AgentReply(id: "", text: "") }))
        #expect(garbage["error"]?["code"] == .number(-32700))
        #expect(received.count == 1)
    }

    @Test func theSocketCarriesLinesBetweenTheRelayAndTheApplication() async throws {
        // A socket path holds about a hundred bytes: shorter than the temporary folder of a test.
        let path = "/tmp/bee-test-\(UUID().uuidString.prefix(8)).sock"
        let listener = try #require(LocalSocket.listen(at: path))
        defer {
            close(listener)
            unlink(path)
        }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let server = Task.detached { () -> String? in
            guard let connection = LocalSocket.accept(on: listener) else { return nil }
            defer { close(connection) }
            let peer = LocalSocket.peer(of: connection)
            guard peer?.user == getuid(), let line = LocalSocket.readLine(from: connection) else { return nil }
            let open = !LocalSocket.isClosed(connection)
            LocalSocket.writeLine("echo: \(line)", to: connection)
            // The other end leaves: the application sees it, and writing to it fails without ending the program.
            guard LocalSocket.readLine(from: connection) == nil, LocalSocket.isClosed(connection), open else { return nil }
            _ = LocalSocket.writeLine("too late", to: connection)
            _ = LocalSocket.writeLine("too late", to: connection)
            return peer?.process == getpid() ? peer?.program : nil
        }
        let client = try #require(LocalSocket.connect(to: path))
        #expect(LocalSocket.writeLine("hello", to: client))
        #expect(LocalSocket.readLine(from: client) == "echo: hello")
        close(client)
        // The application can tell which program is at the other end: this very process.
        #expect(await server.value == LocalSocket.programPath(of: getpid()))
        #expect(LocalSocket.connect(to: "/tmp/bee-test-nothing-\(UUID().uuidString.prefix(8)).sock") == nil)
        // A path too long for a socket is refused rather than cut short.
        #expect(LocalSocket.listen(at: "/tmp/" + String(repeating: "x", count: 200) + ".sock") == nil)
    }

    @Test func aCallIsHandedOverAndACallGivenUpIsToldApart() throws {
        var relay = MCPRelay(serverVersion: "1")
        let step = relay.step(for: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"send_request","arguments":{"request_id":"x"}}}"#)
        guard case .call(let id, let call) = step else {
            Issue.record("expected a call, got \(step)")
            return
        }
        #expect(id == .number(7))
        #expect(call.tool == "send_request")
        let answer = try parse(MCPRelay.answer(to: id, with: AgentReply(id: call.id, text: "done")))
        #expect(answer["id"] == .number(7))
        #expect(answer["result"]?["content"]?.array?.first?["text"]?.string == "done")
        #expect(answer["result"]?["isError"] == .bool(false))

        #expect(relay.step(for: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"timeout"}}"#) == .cancel(id: .number(7)))
        #expect(relay.step(for: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#) == MCPRelay.Step.none)
        #expect(relay.step(for: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == MCPRelay.Step.none)
    }

    @Test func aProgramWhoseFileIsGoneIsThatOneProcess() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = AgentProgram(name: "claude.exe", process: 80542, started: started)
        #expect(updated.identity.hasPrefix("claude.exe (process 80542, started "))
        #expect(updated.hasNoFile)
        #expect(!updated.canBeRemembered)
        // The hour is told with its offset from UTC: the one that comes twice a year is two.
        #expect(updated.identity.range(of: #" [+-]\d{4}\)$"#, options: .regularExpression) != nil)
        // The same name is another program in another process, or in one that took its number later.
        #expect(AgentProgram(name: "claude.exe", process: 80543, started: started).identity != updated.identity)
        #expect(AgentProgram(name: "claude.exe", process: 80542, started: started + 1).identity != updated.identity)
        // A file name holds anything but a slash: it cannot add a line to the question.
        let crafted = AgentProgram(name: "x\nIt calls itself Claude", process: 1, started: started)
        #expect(!crafted.identity.contains("\n"))
        #expect(!AgentProgram(path: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: [], workingDirectory: nil).hasNoFile)

        // The system says what this very process is called and when it started.
        let birth = try #require(LocalSocket.birth(of: getpid()))
        #expect(!birth.name.isEmpty)
        #expect(birth.started < Date() && birth.started > Date(timeIntervalSinceNow: -86400))
    }

    @Test func aProgramIsItsPathAndAnInterpreterIsTheScriptItRuns() {
        let app = AgentProgram(path: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"], workingDirectory: "/")
        #expect(app.identity == "/Applications/Claude.app/Contents/MacOS/Claude")
        #expect(app.canBeRemembered)
        #expect(AgentProgram.shortName(of: app.identity) == "Claude")

        let scripts: Set<String> = ["/Users/me/.npm/bin/claude", "/Users/me/project/tools/agent.js", "/Users/me/agent.py"]
        func program(_ path: String, _ arguments: [String], in directory: String? = "/tmp") -> AgentProgram {
            AgentProgram(path: path, arguments: arguments, workingDirectory: directory, isFile: scripts.contains)
        }
        let node = program("/opt/homebrew/bin/node", ["node", "/Users/me/.npm/bin/claude", "--resume"])
        #expect(node.identity == "/opt/homebrew/bin/node /Users/me/.npm/bin/claude")
        #expect(node.canBeRemembered)
        #expect(AgentProgram.shortName(of: node.identity) == "node claude")
        // Another script run by the same interpreter is another program.
        let other = program("/opt/homebrew/bin/node", ["node", "tools/agent.js"], in: "/Users/me/project")
        #expect(other.identity == "/opt/homebrew/bin/node /Users/me/project/tools/agent.js")
        #expect(other.canBeRemembered)
        #expect(other.identity != node.identity)
        // The interpreter goes by its own name, with or without a version or a folder.
        let python = program("/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python", ["python3", "/Users/me/agent.py"])
        #expect(python.canBeRemembered)
        #expect(program("/usr/bin/python3.13", ["/usr/bin/python3", "/Users/me/agent.py"]).canBeRemembered)

        // Nothing tells these from any other code run the same way: they are never remembered.
        let preloaded = program("/opt/homebrew/bin/node", ["node", "--require=/tmp/x.js", "/Users/me/.npm/bin/claude"])
        let neverRemembered = [
            program("/usr/bin/python3", ["python3", "-c", "import os"]),
            preloaded,
            program("/bin/zsh", ["-zsh"]),
            program("/usr/bin/python3.13", ["python3", "agent.py"], in: nil),
            program("/opt/homebrew/bin/node", []),
            // A subcommand is not a script: "run" is no file in the folder.
            program("/opt/homebrew/bin/deno", ["deno", "run", "-A", "/Users/me/agent.js"], in: "/Users/me"),
            program("/opt/homebrew/bin/bun", ["bun", "run", "agent.js"], in: "/Users/me"),
            // Arguments that do not start with the interpreter's name hide what really runs.
            program("/opt/homebrew/bin/node", ["/tmp/other.js", "/Users/me/.npm/bin/claude"]),
            // The helper that runs every extension of an editor.
            program("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", ["Code Helper (Plugin)", "/Users/me/agent.py"]),
            program("/Applications/Thing.app/Contents/MacOS/Electron", ["Electron", "/Users/me/agent.py"]),
        ]
        for program in neverRemembered { #expect(!program.canBeRemembered, "\(program.identity)") }
        #expect(preloaded.identity != node.identity)
        #expect(AgentProgram.isFile(#filePath))
        #expect(!AgentProgram.isFile(NSTemporaryDirectory()))
    }

    @Test func theSystemSaysHowAProcessWasStarted() throws {
        #expect(LocalSocket.arguments(of: getpid()) == CommandLine.arguments)
        let here = try #require(LocalSocket.workingDirectory(of: getpid()))
        #expect(URL(fileURLWithPath: here).resolvingSymlinksInPath() == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath())
        #expect(LocalSocket.parent(of: getpid()) == getppid())

        var area = withUnsafeBytes(of: Int32(2)) { Array($0) }
        area += Array("/usr/bin/tool".utf8) + [0, 0, 0] + Array("tool".utf8) + [0] + Array("--flag value".utf8) + [0] + Array("HOME=/x".utf8) + [0]
        #expect(LocalSocket.arguments(inProcessArea: area) == ["tool", "--flag value"])
        #expect(LocalSocket.arguments(inProcessArea: Array(area.prefix(20))) == nil)
        #expect(LocalSocket.arguments(inProcessArea: []) == nil)
    }
}
