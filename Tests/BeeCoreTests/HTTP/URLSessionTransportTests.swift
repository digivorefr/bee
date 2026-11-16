import Foundation
import Testing
@testable import BeeCore

@Suite struct URLSessionTransportTests {
    // MARK: Helpers

    private func withServer<T>(_ body: (LoopbackServer) async throws -> T) async throws -> T {
        let server = try await LoopbackServer.start()
        do {
            let result = try await body(server)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    private func request(
        _ server: LoopbackServer, _ path: String, method: String = "GET", headers: [HeaderEntry] = [],
        body: ResolvedBody = .none, timeout: TimeInterval = 10, followRedirects: Bool = true
    ) throws -> ResolvedRequest {
        let url = try #require(URL(string: server.baseURL.absoluteString + path))
        return ResolvedRequest(method: method, url: url, headers: headers, body: body, timeout: timeout, followRedirects: followRedirects)
    }

    private func echo(_ response: HTTPResponse) throws -> EchoedRequest {
        try JSONDecoder().decode(EchoedRequest.self, from: response.body)
    }

    // MARK: Exchanges

    @Test func getReturnsStatusHeadersBodyAndMetadata() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            let response = try await transport.send(request(server, "/echo?x=1", headers: [HeaderEntry(name: "X-Trace", value: "abc")]))
            #expect(response.statusCode == 200)
            #expect(response.statusText == "OK")
            #expect(response.isJSON)
            #expect(response.header("content-type") == "application/json")
            #expect(response.finalURL?.path == "/echo")
            #expect(response.httpVersion == "HTTP/1.1")
            #expect(response.remoteAddress == "127.0.0.1:\(server.port)")
            #expect(response.duration > 0)

            let echoed = try echo(response)
            #expect(echoed.method == "GET")
            #expect(echoed.target == "/echo?x=1")
            #expect(echoed.headers["x-trace"] == "abc")
            #expect(echoed.bodyData.isEmpty)

            // First connection, plain HTTP: no TLS phase, a measured connect and first byte.
            #expect(response.timings.tls == nil)
            #expect(response.timings.connect != nil)
            #expect(response.timings.firstByte != nil)
            #expect(response.timings.download != nil)
        }
    }

    @Test func explicitHeadersReachTheServerUnchanged() async throws {
        try await withServer { server in
            let headers = [HeaderEntry(name: "User-Agent", value: "custom/9"), HeaderEntry(name: "Accept", value: "text/csv"),
                           HeaderEntry(name: "Authorization", value: "Bearer abc")]
            let echoed = try await echo(URLSessionTransport().send(request(server, "/echo", headers: headers)))
            #expect(echoed.headers["user-agent"] == "custom/9")
            #expect(echoed.headers["accept"] == "text/csv")
            #expect(echoed.headers["authorization"] == "Bearer abc")
        }
    }

    @Test func postSendsItsBody() async throws {
        try await withServer { server in
            let body = Data("{\"hello\":\"wörld\"}".utf8)
            let headers = [HeaderEntry(name: "Content-Type", value: "application/json")]
            let response = try await URLSessionTransport().send(request(server, "/echo", method: "POST", headers: headers, body: .data(body)))
            let echoed = try echo(response)
            #expect(echoed.method == "POST")
            #expect(echoed.bodyData == body)
            #expect(echoed.headers["content-type"] == "application/json")
            #expect(echoed.headers["content-length"] == "\(body.count)")
        }
    }

    @Test func requestBuiltByTheBuilderRoundTrips() async throws {
        try await withServer { server in
            var item = RequestItem(method: .post, url: server.baseURL.absoluteString + "/echo", queryParams: [KeyValue(key: "q", value: "a b&c")])
            item.body = RequestBody(mode: .urlEncoded, urlEncoded: [KeyValue(key: "name", value: "Jane Doe")])
            let built = try RequestBuilder.build(item: item, auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "tok")), context: VariableContext(), settings: AppSettings())
            let echoed = try await echo(URLSessionTransport().send(built.request))
            #expect(echoed.target == "/echo?q=a%20b%26c")
            #expect(String(decoding: echoed.bodyData, as: UTF8.self) == "name=Jane+Doe")
            #expect(echoed.headers["authorization"] == "Bearer tok")
            #expect(echoed.headers["content-type"] == "application/x-www-form-urlencoded")
            #expect(echoed.headers["user-agent"] == "Bee/1.0")
        }
    }

    @Test func otherMethodsAndEmptyBodies() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            for method in ["PUT", "PATCH", "DELETE", "OPTIONS"] {
                let echoed = try await echo(transport.send(request(server, "/echo", method: method)))
                #expect(echoed.method == method)
            }
            let head = try await transport.send(request(server, "/echo", method: "HEAD"))
            #expect(head.statusCode == 200)
            #expect(head.body.isEmpty)
        }
    }

    @Test func fileBodiesAreStreamedFromDisk() async throws {
        let scratch = HTTPTestScratch()
        defer { scratch.cleanup() }
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let path = scratch.write("upload.bin", payload)
        try await withServer { server in
            let response = try await URLSessionTransport().send(request(
                server, "/echo", method: "PUT", headers: [HeaderEntry(name: "Content-Type", value: "application/octet-stream")],
                body: .file(URL(fileURLWithPath: path))
            ))
            let echoed = try echo(response)
            #expect(echoed.method == "PUT")
            #expect(echoed.bodyData == payload)
            #expect(echoed.headers["content-type"] == "application/octet-stream")
        }
    }

    @Test func aMissingUploadFileFailsCleanly() async throws {
        try await withServer { server in
            let missing = URL(fileURLWithPath: "/definitely/not/here.bin")
            await #expect(throws: TransportError.other("The file to upload does not exist or cannot be read.")) {
                try await URLSessionTransport().send(request(server, "/echo", method: "PUT", body: .file(missing)))
            }
        }
    }

    @Test func statusCodesAreMappedToReasonPhrases() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            for (code, text) in [(201, "Created"), (404, "Not Found"), (418, "I'm a teapot"), (503, "Service Unavailable"), (299, "")] {
                let response = try await transport.send(request(server, "/status?code=\(code)"))
                #expect(response.statusCode == code)
                #expect(response.statusText == text)
            }
        }
    }

    // MARK: Redirects

    @Test func redirectsAreFollowedByDefault() async throws {
        try await withServer { server in
            let response = try await URLSessionTransport().send(request(server, "/redirect?to=/echo?hop=1"))
            #expect(response.statusCode == 200)
            #expect(response.finalURL?.path == "/echo")
            #expect(response.finalURL?.query == "hop=1")
            #expect(try echo(response).target == "/echo?hop=1")
        }
    }

    @Test func redirectsAreReturnedWhenNotFollowed() async throws {
        try await withServer { server in
            let response = try await URLSessionTransport().send(request(server, "/redirect?to=/echo", followRedirects: false))
            #expect(response.statusCode == 302)
            #expect(response.statusText == "Found")
            #expect(response.header("Location") == "/echo")
            #expect(response.text == "moved")
            #expect(response.finalURL?.path == "/redirect")
        }
    }

    @Test func redirectChoiceIsPerRequest() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            let stopped = try await transport.send(request(server, "/redirect", followRedirects: false))
            let followed = try await transport.send(request(server, "/redirect"))
            #expect(stopped.statusCode == 302)
            #expect(followed.statusCode == 200)
        }
    }

    // MARK: TLS

    private func withTLSServer<T>(_ body: (LoopbackServer) async throws -> T) async throws -> T {
        let server = try await LoopbackServer.start(tls: try LoopbackIdentity.make())
        do {
            let result = try await body(server)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func untrustedCertificatesAreRejectedByDefault() async throws {
        try await withTLSServer { server in
            var pending = try request(server, "/echo", timeout: 5)
            pending.verifyTLS = true
            do {
                _ = try await URLSessionTransport().send(pending)
                Issue.record("expected the certificate to be rejected")
            } catch let error as TransportError {
                guard case .secureConnectionFailed(let message) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(message.contains("127.0.0.1"))
            }
        }
    }

    @Test func untrustedCertificatesAreAcceptedOnlyWhenVerificationIsOff() async throws {
        try await withTLSServer { server in
            let transport = URLSessionTransport()
            var pending = try request(server, "/echo", timeout: 5)
            pending.verifyTLS = false
            let response = try await transport.send(pending)
            #expect(response.statusCode == 200)
            #expect(try echo(response).method == "GET")
            #expect(response.timings.tls != nil)

            // The choice belongs to the request: an exception granted before never carries over.
            pending.verifyTLS = true
            await #expect(throws: TransportError.self) { try await transport.send(pending) }
        }
    }

    @Test func cookiesAreSharedWhetherOrNotTLSIsVerified() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            var setter = try request(server, "/cookie")
            setter.verifyTLS = false
            _ = try await transport.send(setter)
            let seen = try await echo(transport.send(request(server, "/echo")))
            #expect(seen.headers["cookie"] == "sid=abc123")
            transport.clearCookies()
            var unverified = try request(server, "/echo")
            unverified.verifyTLS = false
            #expect(try await echo(transport.send(unverified)).headers["cookie"] == nil)
        }
    }

    // MARK: Failures

    @Test func slowAnswersTimeOut() async throws {
        try await withServer { server in
            let started = ContinuousClock.now
            await #expect(throws: TransportError.timedOut) {
                try await URLSessionTransport().send(request(server, "/delay?ms=5000", timeout: 0.3))
            }
            #expect(started.duration(to: .now) < .seconds(4))
        }
    }

    @Test func cancellingTheTaskCancelsTheExchange() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            let pending = try request(server, "/delay?ms=5000")
            let task = Task { try await transport.send(pending) }
            try await Task.sleep(for: .milliseconds(200))
            let started = ContinuousClock.now
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("expected the exchange to be cancelled")
            } catch {
                #expect(error as? TransportError == .cancelled)
            }
            #expect(started.duration(to: .now) < .seconds(3))
        }
    }

    @Test func aTaskCancelledBeforeSendingNeverConnects() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            let pending = try request(server, "/echo")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await transport.send(pending)
            }
            do {
                _ = try await task.value
                Issue.record("expected the exchange to be cancelled")
            } catch {
                #expect(error as? TransportError == .cancelled)
            }
        }
    }

    @Test func refusedConnectionsAreReported() async throws {
        let server = try await LoopbackServer.start()
        let url = try #require(URL(string: server.baseURL.absoluteString + "/echo"))
        let port = server.port
        await server.stop()
        do {
            _ = try await URLSessionTransport().send(ResolvedRequest(method: "GET", url: url, timeout: 5))
            Issue.record("expected a connection failure")
        } catch let error as TransportError {
            guard case .cannotConnect(let message) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(message.contains("127.0.0.1:\(port)"))
            #expect(error.errorDescription == message)
        }
    }

    // MARK: Cookies

    @Test func cookiesLiveAcrossSendsAndClearCookiesForgetsThem() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            let before = try await echo(transport.send(request(server, "/echo")))
            #expect(before.headers["cookie"] == nil)

            _ = try await transport.send(request(server, "/cookie"))
            let after = try await echo(transport.send(request(server, "/echo")))
            #expect(after.headers["cookie"] == "sid=abc123")

            transport.clearCookies()
            let cleared = try await echo(transport.send(request(server, "/echo")))
            #expect(cleared.headers["cookie"] == nil)
        }
    }

    @Test func cookiesAreNotSharedBetweenTransports() async throws {
        try await withServer { server in
            let first = URLSessionTransport()
            let second = URLSessionTransport()
            _ = try await first.send(request(server, "/cookie"))
            let seenByFirst = try await echo(first.send(request(server, "/echo")))
            let seenBySecond = try await echo(second.send(request(server, "/echo")))
            #expect(seenByFirst.headers["cookie"] == "sid=abc123")
            #expect(seenBySecond.headers["cookie"] == nil)
        }
    }

    @Test func cookiesFollowRedirectsToo() async throws {
        try await withServer { server in
            let transport = URLSessionTransport()
            _ = try await transport.send(request(server, "/cookie"))
            let followed = try await echo(transport.send(request(server, "/redirect?to=/echo")))
            #expect(followed.headers["cookie"] == "sid=abc123")
        }
    }

    // MARK: Mapping helpers

    @Test func reasonPhrasesCoverTheStandardCodes() {
        #expect(HTTPStatusText.phrase(for: 200) == "OK")
        #expect(HTTPStatusText.phrase(for: 301) == "Moved Permanently")
        #expect(HTTPStatusText.phrase(for: 404) == "Not Found")
        #expect(HTTPStatusText.phrase(for: 418) == "I'm a teapot")
        #expect(HTTPStatusText.phrase(for: 500) == "Internal Server Error")
        #expect(HTTPStatusText.phrase(for: 299) == "")
        #expect(HTTPStatusText.phrase(for: 0) == "")
        for code in [100, 101, 204, 206, 304, 307, 308, 401, 403, 409, 422, 429, 502, 504] {
            #expect(!HTTPStatusText.phrase(for: code).isEmpty)
        }
    }

    @Test(arguments: [
        ("h2", "HTTP/2"), ("h3", "HTTP/3"), ("http/1.1", "HTTP/1.1"), ("http/1.0", "HTTP/1.0"), ("HTTP/1.1", "HTTP/1.1"),
        ("spdy/3", "spdy/3"), ("", ""),
    ])
    func protocolNamesBecomeVersions(name: String, expected: String) {
        #expect(URLSessionTransport.httpVersion(fromProtocolName: name) == expected)
        #expect(URLSessionTransport.httpVersion(fromProtocolName: nil) == "")
    }

    @Test func timingsExcludeTLSFromConnect() {
        let origin = Date(timeIntervalSince1970: 1_000)
        func at(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }
        var dates = TransactionDates()
        dates.domainLookupStart = at(0); dates.domainLookupEnd = at(0.010)
        dates.connectStart = at(0.010); dates.connectEnd = at(0.100)
        dates.secureConnectionStart = at(0.040); dates.secureConnectionEnd = at(0.100)
        dates.requestStart = at(0.100); dates.requestEnd = at(0.110)
        dates.responseStart = at(0.150); dates.responseEnd = at(0.200)
        let timings = dates.timings
        #expect(abs((timings.dns ?? -1) - 0.010) < 1e-6)
        #expect(abs((timings.tls ?? -1) - 0.060) < 1e-6)
        #expect(abs((timings.connect ?? -1) - 0.030) < 1e-6)
        #expect(abs((timings.firstByte ?? -1) - 0.040) < 1e-6)
        #expect(abs((timings.download ?? -1) - 0.050) < 1e-6)
    }

    @Test func reusedConnectionsHaveNoConnectionPhases() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var dates = TransactionDates()
        dates.requestStart = origin; dates.requestEnd = origin.addingTimeInterval(0.001)
        dates.responseStart = origin.addingTimeInterval(0.021); dates.responseEnd = origin.addingTimeInterval(0.022)
        let timings = dates.timings
        #expect(timings.dns == nil && timings.connect == nil && timings.tls == nil)
        #expect(abs((timings.firstByte ?? -1) - 0.020) < 1e-6)
        #expect(TransactionDates().timings == ResponseTimings())
    }

    @Test func urlErrorsBecomeHumanMessages() {
        func map(_ code: URLError.Code) -> TransportError {
            TransportError.from(URLError(code), host: "example.test", port: 8443)
        }
        #expect(map(.cancelled) == .cancelled)
        #expect(map(.timedOut) == .timedOut)
        for code in [URLError.Code.cannotFindHost, .dnsLookupFailed] {
            guard case .cannotFindHost(let message) = map(code) else { Issue.record("cannotFindHost expected"); continue }
            #expect(message.contains("example.test"))
        }
        for code in [URLError.Code.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet] {
            guard case .cannotConnect = map(code) else { Issue.record("cannotConnect expected for \(code)"); continue }
        }
        guard case .cannotConnect(let refused) = map(.cannotConnectToHost) else { return }
        #expect(refused.contains("example.test:8443"))
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRequired] {
            guard case .secureConnectionFailed = map(code) else { Issue.record("secureConnectionFailed expected for \(code)"); continue }
        }
        guard case .other = map(.badURL) else { Issue.record("other expected"); return }
        #expect(TransportError.from(CancellationError(), host: "h", port: nil) == .cancelled)
        #expect(TransportError.cancelled.errorDescription != nil && TransportError.timedOut.errorDescription != nil)
    }

    @Test func messagesNeverCarryThePathOrQuery() {
        let url = URL(string: "https://example.test/secret/path?token=hunter2")
        let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url as Any])
        let mapped = TransportError.from(error, host: "example.test", port: nil)
        #expect(mapped.errorDescription?.contains("hunter2") == false)
        #expect(mapped.errorDescription?.contains("/secret") == false)
    }
}
