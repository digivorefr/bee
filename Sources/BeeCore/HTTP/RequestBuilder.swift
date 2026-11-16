import Foundation
import UniformTypeIdentifiers

public enum RequestBuildError: Error, Equatable, Sendable, LocalizedError {
    case emptyURL
    /// The address that cannot be parsed (in template form when it expanded a secret).
    case invalidURL(String)
    /// The path that does not exist or cannot be read.
    case fileNotFound(String)
    /// Why the GraphQL variables are rejected.
    case invalidGraphQLVariables(String)

    public var errorDescription: String? {
        switch self {
        case .emptyURL: "The request has no URL."
        case .invalidURL(let url): "Invalid URL: \(url)"
        case .fileNotFound(let path): "File not found: \(path)"
        case .invalidGraphQLVariables(let reason): "Invalid GraphQL variables: \(reason)"
        }
    }
}

public struct BuildOutput: Sendable {
    /// The request with every placeholder replaced. Holds real secret values: never persist or log it.
    public var request: ResolvedRequest
    /// Distinct names that stayed unresolved in the parts that are sent, in order of first appearance.
    public var unresolvedVariables: [String]

    public init(request: ResolvedRequest, unresolvedVariables: [String] = []) {
        self.request = request
        self.unresolvedVariables = unresolvedVariables
    }
}

/// Turns a `RequestItem` in template form into the `ResolvedRequest` that goes on the wire.
public enum RequestBuilder {
    /// The authorization that applies: the item's own unless `.inherit`, then the nearest enclosing folder
    /// (innermost first) that is not `.inherit`, then the collection's; `.inherit` at the top means none.
    /// `folders` lists the enclosing folders outermost first, as `Collection.ancestry(of:)` returns them.
    public static func effectiveAuth(for item: RequestItem, folders: [Folder], collection: Collection?) -> AuthConfig {
        let candidates = [item.auth] + folders.reversed().map(\.auth) + (collection.map { [$0.auth] } ?? [])
        return candidates.first { $0.kind != .inherit } ?? AuthConfig(kind: .none)
    }

    /// Renders and assembles the request. `auth` is the effective authorization (see ``effectiveAuth(for:folders:collection:)``).
    public static func build(
        item: RequestItem, auth: AuthConfig, context: VariableContext, settings: AppSettings
    ) throws(RequestBuildError) -> BuildOutput {
        var renderer = Renderer(context: context)

        // Address, with each `:name` segment replaced by its value
        let renderedURL = renderer.renderAddress(item.url, pathVariables: item.pathVariables)
        let address = renderedURL.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw .emptyURL }

        // Query rows, then an API key sent as a query parameter
        var query: [(key: String, value: String)] = []
        for row in item.queryParams where row.isEnabled {
            let key = renderer.render(row.key).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            query.append((key, renderer.render(row.value).text))
        }

        // Headers the person set, then the ones derived from the authorization and the body
        var headers: [HeaderEntry] = []
        for row in item.headers where row.isEnabled {
            let name = cleanHeader(renderer.render(row.key).text)
            guard !name.isEmpty else { continue }
            headers.append(HeaderEntry(name: name, value: cleanHeader(renderer.render(row.value).text)))
        }
        func addHeaderIfAbsent(_ name: String, _ value: String) {
            guard !headers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            headers.append(HeaderEntry(name: name, value: value))
        }

        switch auth.kind {
        case .inherit, .none:
            break
        case .bearer:
            let token = cleanHeader(renderer.render(auth.bearerToken.value).text)
            if !token.isEmpty { addHeaderIfAbsent("Authorization", "Bearer \(token)") }
        case .basic:
            let user = renderer.render(auth.basicUsername).text
            let password = renderer.render(auth.basicPassword.value).text
            if !user.isEmpty || !password.isEmpty {
                addHeaderIfAbsent("Authorization", "Basic " + Data("\(user):\(password)".utf8).base64EncodedString())
            }
        case .apiKey:
            let name = cleanHeader(renderer.render(auth.apiKeyName).text)
            let value = renderer.render(auth.apiKeyValue.value).text
            if !name.isEmpty, !value.isEmpty {
                switch auth.apiKeyLocation {
                case .header: addHeaderIfAbsent(name, cleanHeader(value))
                case .query: if !query.contains(where: { $0.key == name }) { query.append((name, value)) }
                }
            }
        }

        let body = try makeBody(item.body, renderer: &renderer)
        if let contentType = body.contentType { addHeaderIfAbsent("Content-Type", contentType) }
        addHeaderIfAbsent("User-Agent", "Bee/1.0")
        addHeaderIfAbsent("Accept", "*/*")

        let url = try makeURL(address: address, query: query, usedSecret: renderedURL.usedSecret, template: item.url)
        let request = ResolvedRequest(
            method: item.method.rawValue, url: url, headers: headers, body: body.body,
            timeout: item.settings.timeout ?? settings.timeout,
            followRedirects: item.settings.followRedirects ?? settings.followRedirects,
            verifyTLS: item.settings.verifyTLS ?? settings.verifyTLS
        )
        return BuildOutput(request: request, unresolvedVariables: renderer.unresolved)
    }

    // MARK: Rendering

    private struct Renderer {
        let context: VariableContext
        private(set) var unresolved: [String] = []

        init(context: VariableContext) { self.context = context }

        mutating func render(_ template: String) -> RenderResult {
            record(TemplateEngine.render(template, in: context))
        }

        mutating func renderAddress(_ address: String, pathVariables: [KeyValue]) -> RenderResult {
            record(PathVariables.render(address, rows: pathVariables, in: context))
        }

        private mutating func record(_ result: RenderResult) -> RenderResult {
            for name in result.unresolved where !unresolved.contains(name) { unresolved.append(name) }
            return result
        }
    }

    /// A header name or value on one line, without surrounding whitespace.
    private static func cleanHeader(_ text: String) -> String {
        text.filter { $0 != "\r" && $0 != "\n" && $0 != "\r\n" }.trimmingCharacters(in: .whitespaces)
    }

    // MARK: URL

    private static func makeURL(
        address: String, query: [(key: String, value: String)], usedSecret: Bool, template: String
    ) throws(RequestBuildError) -> URL {
        var full = hasScheme(address) ? address : (prefersPlainHTTP(address) ? "http://" : "https://") + address
        if !query.isEmpty {
            let encoded = query.map { "\(PercentCoding.encodeQuery($0.key))=\(PercentCoding.encodeQuery($0.value))" }
            var fragment = ""
            if let hash = full.firstIndex(of: "#") {
                fragment = String(full[hash...])
                full = String(full[..<hash])
            }
            let separator = if !full.contains("?") { "?" } else if full.hasSuffix("?") || full.hasSuffix("&") { "" } else { "&" }
            full += separator + encoded.joined(separator: "&") + fragment
        }
        // An unresolved placeholder stays in the address: encode its braces so it is reported, not rejected.
        let encodedBraces = full.replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
        guard let url = URL(string: encodedBraces),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: true), !host.isEmpty
        else {
            throw .invalidURL(usedSecret ? template : address)
        }
        return url
    }

    private static func hasScheme(_ address: String) -> Bool {
        guard let range = address.range(of: "://"), range.lowerBound > address.startIndex else { return false }
        let scheme = address[..<range.lowerBound]
        return scheme.first?.isLetter == true
            && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
    }

    /// True for hosts that rarely speak TLS: loopback, `.local`, `.localhost` and private-range addresses.
    private static func prefersPlainHTTP(_ address: String) -> Bool {
        var authority = address.prefix { !"/?#".contains($0) }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        let host: Substring
        if authority.hasPrefix("[") {
            host = authority.prefix { $0 != "]" }.dropFirst()
            return isPrivateIPv6(host.lowercased())
        }
        host = authority.prefix { $0 != ":" }
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".localhost") { return true }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4, case let values = octets.compactMap({ $0 }), values.count == 4,
              values.allSatisfy({ (0...255).contains($0) })
        else { return false }
        switch (values[0], values[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        if host == "::1" { return true }
        guard let first = host.split(separator: ":", omittingEmptySubsequences: false).first,
              let group = UInt16(first, radix: 16)
        else { return false }
        return group & 0xFE00 == 0xFC00 || group & 0xFFC0 == 0xFE80
    }

    // MARK: Body

    private struct BuiltBody {
        var body: ResolvedBody = .none
        var contentType: String?
    }

    private static func makeBody(_ body: RequestBody, renderer: inout Renderer) throws(RequestBuildError) -> BuiltBody {
        switch body.mode {
        case .none:
            return BuiltBody()
        case .raw:
            let text = renderer.render(body.raw).text
            return BuiltBody(body: .data(Data(text.utf8)), contentType: body.rawLanguage.contentType)
        case .urlEncoded:
            var fields: [String] = []
            for row in body.urlEncoded where row.isEnabled {
                let key = renderer.render(row.key).text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                fields.append("\(PercentCoding.encodeForm(key))=\(PercentCoding.encodeForm(renderer.render(row.value).text))")
            }
            return BuiltBody(
                body: .data(Data(fields.joined(separator: "&").utf8)), contentType: "application/x-www-form-urlencoded"
            )
        case .formData:
            return try makeMultipart(body.formData, renderer: &renderer)
        case .binary:
            let (path, url) = try existingFile(template: body.binaryPath, renderer: &renderer)
            return BuiltBody(body: .file(url), contentType: mimeType(forPath: path))
        case .graphQL:
            let query = renderer.render(body.graphQLQuery).text
            let variables = try graphQLVariables(renderer.render(body.graphQLVariables).text)
            let json = "{\"query\":\(jsonString(query)),\"variables\":\(variables)}"
            return BuiltBody(body: .data(Data(json.utf8)), contentType: "application/json")
        }
    }

    /// Validates the variables text as a JSON object and returns it as written (`{}` when blank).
    private static func graphQLVariables(_ text: String) throws(RequestBuildError) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "{}" }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed) else {
            throw .invalidGraphQLVariables("the text is not valid JSON")
        }
        guard parsed is NSDictionary else { throw .invalidGraphQLVariables("the value must be a JSON object") }
        return trimmed
    }

    static func jsonString(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func makeMultipart(_ fields: [FormField], renderer: inout Renderer) throws(RequestBuildError) -> BuiltBody {
        let boundary = "----BeeFormBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }

        for field in fields where field.isEnabled {
            let name = renderer.render(field.key).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let explicitType = cleanHeader(renderer.render(field.contentType).text)
            append("--\(boundary)\r\n")
            switch field.kind {
            case .text:
                append("Content-Disposition: form-data; name=\"\(quoted(name))\"\r\n")
                if !explicitType.isEmpty { append("Content-Type: \(explicitType)\r\n") }
                append("\r\n")
                append(renderer.render(field.value).text)
            case .file:
                let (path, url) = try existingFile(template: field.value, renderer: &renderer)
                guard let bytes = try? Data(contentsOf: url) else { throw .fileNotFound(path) }
                let filename = url.lastPathComponent
                append("Content-Disposition: form-data; name=\"\(quoted(name))\"; filename=\"\(quoted(filename))\"\r\n")
                append("Content-Type: \(explicitType.isEmpty ? mimeType(forPath: path) : explicitType)\r\n\r\n")
                data.append(bytes)
            }
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return BuiltBody(body: .data(data), contentType: "multipart/form-data; boundary=\(boundary)")
    }

    /// Escapes a name for a quoted `Content-Disposition` parameter.
    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Renders a file path and checks that it names a readable regular file.
    private static func existingFile(template: String, renderer: inout Renderer) throws(RequestBuildError) -> (path: String, url: URL) {
        let rendered = renderer.render(template)
        let path = (rendered.text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path)
        else {
            throw .fileNotFound(rendered.usedSecret ? template : path)
        }
        return (path, URL(fileURLWithPath: path))
    }

    /// The media type for a file name, `application/octet-stream` when the extension tells nothing.
    static func mimeType(forPath path: String) -> String {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension),
              let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }
}
