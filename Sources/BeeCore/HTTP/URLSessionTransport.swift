import Foundation
import Synchronization

/// Sends requests with URLSession. Nothing is written to disk: the session is ephemeral, without cache or
/// credential storage, and its cookies live in memory for the life of the transport.
public final class URLSessionTransport: HTTPTransport {
    /// Verifies certificates. Used whenever a request asks for verification.
    private let verifyingSession: URLSession
    /// Accepts any server certificate. URLSession remembers a trust exception it was handed, so requests that
    /// skip verification get a session of their own and can never loosen the verifying one.
    private let unverifiedSession: URLSession
    private let cookieStorage: HTTPCookieStorage?

    public init() {
        let configuration = Self.makeConfiguration()
        cookieStorage = configuration.httpCookieStorage
        verifyingSession = URLSession(configuration: configuration)
        let unverified = Self.makeConfiguration()
        unverified.httpCookieStorage = cookieStorage
        unverifiedSession = URLSession(configuration: unverified)
    }

    deinit {
        verifyingSession.finishTasksAndInvalidate()
        unverifiedSession.finishTasksAndInvalidate()
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return configuration
    }

    /// Forgets every cookie received so far.
    public func clearCookies() {
        guard let cookieStorage else { return }
        for cookie in cookieStorage.cookies ?? [] { cookieStorage.deleteCookie(cookie) }
    }

    public func send(_ request: ResolvedRequest) async throws -> HTTPResponse {
        if Task.isCancelled { throw TransportError.cancelled }
        let urlRequest = Self.makeURLRequest(request)
        let delegate = TaskDelegate(followRedirects: request.followRedirects, verifyTLS: request.verifyTLS)
        let clock = ContinuousClock()
        let started = clock.now
        let session = request.verifyTLS ? verifyingSession : unverifiedSession
        do {
            let (data, response): (Data, URLResponse)
            switch request.body {
            case .file(let file):
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      FileManager.default.isReadableFile(atPath: file.path)
                else {
                    throw TransportError.other("The file to upload does not exist or cannot be read.")
                }
                (data, response) = try await session.upload(for: urlRequest, fromFile: file, delegate: delegate)
            case .none, .data:
                (data, response) = try await session.data(for: urlRequest, delegate: delegate)
            }
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.other("The server did not answer with HTTP.")
            }
            let elapsed = started.duration(to: clock.now).components
            let transaction = delegate.lastTransaction
            return HTTPResponse(
                statusCode: http.statusCode,
                statusText: HTTPStatusText.phrase(for: http.statusCode),
                httpVersion: Self.httpVersion(fromProtocolName: transaction?.networkProtocolName),
                headers: Self.headers(of: http),
                body: data,
                duration: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                timings: transaction.map { TransactionDates($0).timings } ?? ResponseTimings(),
                finalURL: http.url,
                remoteAddress: transaction.flatMap { Self.remoteAddress(of: $0) }
            )
        } catch {
            throw TransportError.from(error, host: request.url.host(percentEncoded: false) ?? "", port: request.url.port)
        }
    }

    // MARK: Request and response mapping

    private static func makeURLRequest(_ request: ResolvedRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout > 0 ? request.timeout : 7 * 24 * 3600
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.httpShouldHandleCookies = true
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }
        if case .data(let data) = request.body, !data.isEmpty { urlRequest.httpBody = data }
        return urlRequest
    }

    private static func headers(of response: HTTPURLResponse) -> [HeaderEntry] {
        response.allHeaderFields
            .compactMap { name, value -> HeaderEntry? in
                guard let name = name as? String else { return nil }
                return HeaderEntry(name: name, value: (value as? String) ?? String(describing: value))
            }
            .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `h2` becomes "HTTP/2", `h3` "HTTP/3", `http/1.1` "HTTP/1.1"; an unknown name is returned as is.
    static func httpVersion(fromProtocolName name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        switch name.lowercased() {
        case "h2", "h2c": return "HTTP/2"
        case "h3": return "HTTP/3"
        case let lowered where lowered.hasPrefix("http/"): return lowered.uppercased()
        default: return name
        }
    }

    private static func remoteAddress(of transaction: URLSessionTaskTransactionMetrics) -> String? {
        guard let address = transaction.remoteAddress else { return nil }
        let host = address.contains(":") ? "[\(address)]" : address
        return transaction.remotePort.map { "\(host):\($0)" } ?? host
    }
}

// MARK: - Per-request behaviour

/// Applies one request's redirect and TLS choices and keeps the metrics of its final transaction.
private final class TaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let followRedirects: Bool
    private let verifyTLS: Bool
    private let metrics = Mutex<URLSessionTaskTransactionMetrics?>(nil)

    init(followRedirects: Bool, verifyTLS: Bool) {
        self.followRedirects = followRedirects
        self.verifyTLS = verifyTLS
    }

    var lastTransaction: URLSessionTaskTransactionMetrics? { metrics.withLock { $0 } }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        followRedirects ? request : nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if !verifyTLS, space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting collected: URLSessionTaskMetrics) {
        let last = collected.transactionMetrics.last
        metrics.withLock { $0 = last }
    }
}

/// The instants of one transaction, converted to phase durations.
struct TransactionDates {
    var domainLookupStart: Date?, domainLookupEnd: Date?
    var connectStart: Date?, connectEnd: Date?
    var secureConnectionStart: Date?, secureConnectionEnd: Date?
    var requestStart: Date?, requestEnd: Date?
    var responseStart: Date?, responseEnd: Date?

    init() {}

    init(_ transaction: URLSessionTaskTransactionMetrics) {
        domainLookupStart = transaction.domainLookupStartDate
        domainLookupEnd = transaction.domainLookupEndDate
        connectStart = transaction.connectStartDate
        connectEnd = transaction.connectEndDate
        secureConnectionStart = transaction.secureConnectionStartDate
        secureConnectionEnd = transaction.secureConnectionEndDate
        requestStart = transaction.requestStartDate
        requestEnd = transaction.requestEndDate
        responseStart = transaction.responseStartDate
        responseEnd = transaction.responseEndDate
    }

    private func interval(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    /// `connect` excludes the TLS handshake, which URLSession counts inside the connection interval.
    var timings: ResponseTimings {
        let tls = interval(secureConnectionStart, secureConnectionEnd)
        let connect = interval(connectStart, connectEnd).map { max(0, $0 - (tls ?? 0)) }
        return ResponseTimings(
            dns: interval(domainLookupStart, domainLookupEnd),
            connect: connect,
            tls: tls,
            firstByte: interval(requestEnd ?? requestStart, responseStart),
            download: interval(responseStart, responseEnd)
        )
    }
}
