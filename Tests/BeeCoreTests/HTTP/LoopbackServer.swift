import Foundation
import Network
import Synchronization
@testable import BeeCore

/// A request as the loopback server received it.
struct LoopbackRequest: Sendable {
    var method: String
    var target: String
    var headers: [(name: String, value: String)]
    var body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    func queryValue(_ name: String) -> String? {
        let query = target.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.first == Substring(name) { return parts.count > 1 ? String(parts[1]) : "" }
        }
        return nil
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// What `/echo` answers with, for tests to decode.
struct EchoedRequest: Decodable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: String

    var bodyData: Data { Data(base64Encoded: body) ?? Data() }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 (random port) for transport tests. Every answer closes the connection.
///
/// Routes: `/echo` (JSON description of the request), `/redirect?to=PATH&status=CODE` (default `/echo`, 302),
/// `/delay?ms=N` (answers "late" after N ms), `/cookie` (sets `sid=abc123`), `/status?code=N`.
final class LoopbackServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bee.tests.loopback")
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])
    private let readyContinuation = Mutex<CheckedContinuation<Void, any Error>?>(nil)
    private let cancelledContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let isTLS: Bool

    /// The bound port; valid once `start` has returned.
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var baseURL: URL { URL(string: "\(isTLS ? "https" : "http")://127.0.0.1:\(port)")! }

    private init(listener: NWListener, isTLS: Bool) {
        self.listener = listener
        self.isTLS = isTLS
    }

    /// Starts a server; pass `tls` to serve HTTPS with that identity.
    static func start(tls: sec_identity_t? = nil) async throws -> LoopbackServer {
        let parameters: NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, tls)
            parameters = NWParameters(tls: options)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let server = LoopbackServer(listener: try NWListener(using: parameters), isTLS: tls != nil)
        try await server.waitUntilReady()
        return server
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            readyContinuation.withLock { $0 = continuation }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    readyContinuation.withLock { $0?.resume(); $0 = nil }
                case .failed(let error):
                    readyContinuation.withLock { $0?.resume(throwing: error); $0 = nil }
                case .cancelled:
                    cancelledContinuation.withLock { $0?.resume(); $0 = nil }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in accept(connection) }
            listener.start(queue: queue)
        }
    }

    /// Stops listening and drops open connections; returns once the port is released.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancelledContinuation.withLock { $0 = continuation }
            listener.cancel()
        }
        let open = connections.withLock { open -> [NWConnection] in
            defer { open.removeAll() }
            return Array(open.values)
        }
        for connection in open { connection.cancel() }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0[ObjectIdentifier(connection)] = connection }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffered
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                respond(to: request, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                receive(on: connection, buffered: buffer)
            }
        }
    }

    /// The request when `buffer` holds all of it.
    private static func parse(_ buffer: Data) -> LoopbackRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator) else { return nil }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let rest = buffer[headEnd.upperBound...]
        var request = LoopbackRequest(method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: Data())
        if request.header("Transfer-Encoding")?.lowercased() == "chunked" {
            guard let body = decodeChunked(Data(rest)) else { return nil }
            request.body = body
        } else {
            let length = Int(request.header("Content-Length") ?? "0") ?? 0
            guard rest.count >= length else { return nil }
            request.body = Data(rest.prefix(length))
        }
        return request
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var output = Data()
        var rest = data[...]
        let crlf = Data("\r\n".utf8)
        while let lineEnd = rest.range(of: crlf) {
            let sizeText = String(decoding: rest[..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return output }
            guard rest.distance(from: chunkStart, to: rest.endIndex) >= size + 2 else { return nil }
            output.append(rest[chunkStart..<rest.index(chunkStart, offsetBy: size)])
            rest = rest[rest.index(chunkStart, offsetBy: size + 2)...]
        }
        return nil
    }

    // MARK: Routes

    private func respond(to request: LoopbackRequest, on connection: NWConnection) {
        switch request.path {
        case "/echo":
            var headers: [String: String] = [:]
            for (name, value) in request.headers { headers[name.lowercased()] = value }
            let echo = EchoPayload(method: request.method, target: request.target, headers: headers, body: request.body.base64EncodedString())
            let json = (try? JSONEncoder().encode(echo)) ?? Data()
            send(200, headers: ["Content-Type": "application/json"], body: json, on: connection)
        case "/redirect":
            let status = Int(request.queryValue("status") ?? "") ?? 302
            send(status, headers: ["Location": request.queryValue("to") ?? "/echo"], body: Data("moved".utf8), on: connection)
        case "/delay":
            let milliseconds = Int(request.queryValue("ms") ?? "") ?? 0
            queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [self] in
                send(200, headers: [:], body: Data("late".utf8), on: connection)
            }
        case "/cookie":
            send(200, headers: ["Set-Cookie": "sid=abc123; Path=/"], body: Data("cookie set".utf8), on: connection)
        case "/status":
            send(Int(request.queryValue("code") ?? "") ?? 200, headers: [:], body: Data(), on: connection)
        default:
            send(404, headers: [:], body: Data("not found".utf8), on: connection)
        }
    }

    private struct EchoPayload: Encodable {
        var method: String
        var target: String
        var headers: [String: String]
        var body: String
    }

    private func send(_ status: Int, headers: [String: String], body: Data, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(HTTPStatusText.phrase(for: status))\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
