import Foundation

/// Why an exchange failed. The payloads are short human messages, shown to the person as they are;
/// they never contain the path, query or any other part of the request.
public enum TransportError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case timedOut
    case cannotFindHost(String)
    case cannotConnect(String)
    case secureConnectionFailed(String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "The request was cancelled."
        case .timedOut: "The request timed out."
        case .cannotFindHost(let message), .cannotConnect(let message),
             .secureConnectionFailed(let message), .other(let message):
            message
        }
    }

    /// Maps what URLSession threw. `host` and `port` come from the request and only label the message.
    static func from(_ error: any Error, host: String, port: Int?) -> TransportError {
        if let transport = error as? TransportError { return transport }
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .other(error.localizedDescription) }
        let endpoint = port.map { "\(host):\($0)" } ?? host
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .cannotFindHost, .dnsLookupFailed:
            return .cannotFindHost("Cannot find the host “\(host)”. Check the address and your network connection.")
        case .cannotConnectToHost:
            return .cannotConnect("Cannot connect to \(endpoint). Is the server running?")
        case .networkConnectionLost:
            return .cannotConnect("The connection to \(endpoint) was lost.")
        case .notConnectedToInternet:
            return .cannotConnect("No internet connection.")
        case .secureConnectionFailed:
            return .secureConnectionFailed("The secure connection to \(host) failed.")
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid:
            return .secureConnectionFailed(
                "The certificate of \(host) is not trusted. Turn off TLS verification in the request settings to send anyway."
            )
        case .clientCertificateRequired, .clientCertificateRejected:
            return .secureConnectionFailed("\(host) requires a client certificate.")
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData:
            return .other("The server sent a response that could not be read.")
        default:
            return .other(urlError.localizedDescription)
        }
    }
}
