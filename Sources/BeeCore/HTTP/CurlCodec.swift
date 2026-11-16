import Foundation

public enum CurlParseError: Error, Equatable, Sendable, LocalizedError {
    case notACurlCommand
    case missingURL
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notACurlCommand: "The text is not a cURL command."
        case .missingURL: "The cURL command has no URL."
        case .malformed(let reason): "The cURL command is malformed: \(reason)."
        }
    }
}

/// Converts requests to and from cURL commands.
public enum CurlCodec {
    // MARK: - Export

    /// A cURL command for the request in TEMPLATE form, for the clipboard. Placeholders stay as `{{name}}`.
    /// A secret slot (secret row, any auth `SecretField`) is emitted verbatim only when its value consists solely of
    /// placeholders (and whitespace); otherwise it is replaced by `<secret>`. Never emits a literal secret value.
    public static func command(for item: RequestItem, auth: AuthConfig) -> String {
        let placeholder = "<secret>"
        func slot(_ value: String) -> String {
            let blank = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return blank || TemplateEngine.isPlaceholderOnly(value) ? value : placeholder
        }
        func encode(_ text: String) -> String {
            text == placeholder ? text : PercentCoding.mapText(of: text, PercentCoding.encodeQuery)
        }

        // Query: rows, then an API key sent in the query
        var rows = item.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }.map {
            KeyValue(key: encode($0.key), value: encode($0.isSecret ? slot($0.value) : $0.value))
        }
        // Headers: the person's rows win over derived ones
        var headers: [(name: String, value: String)] = item.headers.filter { $0.isEnabled && !$0.key.isEmpty }.map {
            ($0.key, $0.isSecret ? slot($0.value) : $0.value)
        }
        func hasHeader(_ name: String) -> Bool { headers.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

        var options: [String] = []
        switch auth.kind {
        case .inherit, .none:
            break
        case .bearer:
            let token = slot(auth.bearerToken.value)
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasHeader("Authorization") {
                headers.append(("Authorization", "Bearer \(token)"))
            }
        case .basic:
            if (!auth.basicUsername.isEmpty || !auth.basicPassword.value.isEmpty), !hasHeader("Authorization") {
                options.append("-u \(quote("\(auth.basicUsername):\(slot(auth.basicPassword.value))"))")
            }
        case .apiKey:
            let value = slot(auth.apiKeyValue.value)
            if !auth.apiKeyName.isEmpty, !value.isEmpty {
                switch auth.apiKeyLocation {
                case .header:
                    if !hasHeader(auth.apiKeyName) { headers.append((auth.apiKeyName, value)) }
                case .query:
                    rows.append(KeyValue(key: encode(auth.apiKeyName), value: encode(value)))
                }
            }
        }

        // Body
        var bodyOptions: [String] = []
        var derivedContentType: String?
        let body = item.body
        switch body.mode {
        case .none:
            break
        case .raw:
            bodyOptions.append("--data-raw \(quote(body.raw))")
            derivedContentType = body.rawLanguage.contentType
        case .urlEncoded:
            for row in body.urlEncoded where row.isEnabled && !row.key.isEmpty {
                bodyOptions.append("--data-urlencode \(quote("\(row.key)=\(row.isSecret ? slot(row.value) : row.value)"))")
            }
        case .formData:
            for field in body.formData where field.isEnabled && !field.key.isEmpty {
                let value = field.isSecret ? slot(field.value) : field.value
                let type = field.contentType.isEmpty ? "" : ";type=\(field.contentType)"
                switch field.kind {
                case .file:
                    bodyOptions.append("-F \(quote("\(field.key)=@\(value)\(type)"))")
                case .text where value.hasPrefix("@") || value.hasPrefix("<") || value.contains(";"):
                    bodyOptions.append("--form-string \(quote("\(field.key)=\(value)"))")
                case .text:
                    bodyOptions.append("-F \(quote("\(field.key)=\(value)\(type)"))")
                }
            }
        case .binary:
            bodyOptions.append("--data-binary \(quote("@" + body.binaryPath))")
            derivedContentType = RequestBuilder.mimeType(forPath: body.binaryPath)
        case .graphQL:
            let variables = body.graphQLVariables.trimmingCharacters(in: .whitespacesAndNewlines)
            let json = "{\"query\":\(RequestBuilder.jsonString(body.graphQLQuery)),\"variables\":\(variables.isEmpty ? "{}" : variables)}"
            bodyOptions.append("--data-raw \(quote(json))")
            derivedContentType = "application/json"
        }
        if let derivedContentType, !hasHeader("Content-Type") { headers.append(("Content-Type", derivedContentType)) }

        let address = URLTemplate.join(base: item.url, params: rows)
        var first = "curl"
        switch item.method {
        case .head: first += " -I"
        case .get where body.mode != .none: first += " -X GET"
        case .get: break
        default: first += " -X \(item.method.rawValue)"
        }
        first += " \(quote(address))"

        var lines = [first]
        lines += headers.map { "-H \(quote("\($0.name): \($0.value)"))" }
        lines += options
        lines += bodyOptions
        if item.settings.verifyTLS == false { lines.append("-k") }
        if item.settings.followRedirects == true { lines.append("-L") }
        if let timeout = item.settings.timeout, timeout > 0 { lines.append("-m \(formatted(timeout))") }
        return lines.joined(separator: " \\\n  ")
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func formatted(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    // MARK: - Import

    private static let shortOptions: [Character: String] = [
        "X": "request", "H": "header", "d": "data", "F": "form", "u": "user", "A": "user-agent", "b": "cookie",
        "e": "referer", "m": "max-time", "G": "get", "k": "insecure", "L": "location", "I": "head",
        // Take a value this importer does not use.
        "o": "output", "x": "proxy", "T": "upload-file", "w": "write-out", "E": "cert", "K": "config", "r": "range",
        "D": "dump-header", "c": "cookie-jar", "U": "proxy-user", "z": "time-cond", "y": "speed-time",
        "Y": "speed-limit", "t": "telnet-option", "C": "continue-at", "P": "ftp-port", "Q": "quote",
    ]

    private static let valueOptions: Set<String> = [
        "url", "request", "header", "data", "data-raw", "data-binary", "data-ascii", "data-urlencode", "json", "form",
        "form-string", "user", "user-agent", "cookie", "referer", "oauth2-bearer", "max-time", "output", "proxy",
        "upload-file", "write-out", "cert", "key", "cacert", "capath", "config", "range", "dump-header", "cookie-jar",
        "proxy-user", "connect-timeout", "retry", "retry-delay", "retry-max-time", "max-redirs", "resolve", "interface",
        "limit-rate", "keepalive-time", "expect100-timeout", "connect-to", "unix-socket", "ciphers", "tls-max", "pass",
        "cert-type", "key-type", "proxy-header", "local-port", "dns-servers", "aws-sigv4", "time-cond", "speed-time",
        "speed-limit", "telnet-option", "continue-at", "ftp-port", "quote", "variable", "rate",
    ]

    private enum DataPiece {
        case text(String)
        case urlEncoded(String)
        case file(String)
    }

    private struct Parsed {
        var url: String?
        var positional: [String] = []
        var method: String?
        var headers: [(name: String, value: String)] = []
        var data: [DataPiece] = []
        var forms: [FormField] = []
        var user: String?
        var bearer: String?
        var timeout: Double?
        var get = false, head = false, insecure = false, location = false, json = false
    }

    public static func parse(_ command: String) throws(CurlParseError) -> RequestItem {
        var words = try ShellWords.split(command)
        if words.first == "$" { words.removeFirst() }
        guard let program = words.first, isCurl(program) else { throw .notACurlCommand }

        var parsed = Parsed()
        var index = 1
        var optionsEnded = false
        func nextValue(for name: String) throws(CurlParseError) -> String {
            guard index < words.count else { throw .malformed("Missing value for \(name)") }
            defer { index += 1 }
            return words[index]
        }
        while index < words.count {
            let word = words[index]
            index += 1
            if !optionsEnded, word == "--" {
                optionsEnded = true
            } else if !optionsEnded, word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                try apply(name, value: valueOptions.contains(name) ? try nextValue(for: word) : nil, to: &parsed)
            } else if !optionsEnded, word.hasPrefix("-"), word.count > 1 {
                let flags = Array(word.dropFirst())
                var position = 0
                while position < flags.count {
                    let name = shortOptions[flags[position]] ?? String(flags[position])
                    if valueOptions.contains(name) {
                        let attached = String(flags[(position + 1)...])
                        try apply(name, value: attached.isEmpty ? try nextValue(for: "-\(flags[position])") : attached, to: &parsed)
                        break
                    }
                    try apply(name, value: nil, to: &parsed)
                    position += 1
                }
            } else {
                parsed.positional.append(word)
            }
        }
        return try makeItem(from: parsed)
    }

    private static func isCurl(_ program: String) -> Bool {
        let name = program.split(separator: "/").last.map { $0.lowercased() } ?? ""
        return name == "curl" || name == "curl.exe"
    }

    private static func apply(_ name: String, value: String?, to parsed: inout Parsed) throws(CurlParseError) {
        guard let value else {
            switch name {
            case "get": parsed.get = true
            case "head": parsed.head = true
            case "insecure": parsed.insecure = true
            case "location": parsed.location = true
            default: break
            }
            return
        }
        switch name {
        case "url": parsed.url = value
        case "request": parsed.method = value.uppercased()
        case "header":
            if let colon = value.firstIndex(of: ":") {
                parsed.headers.append((
                    value[..<colon].trimmingCharacters(in: .whitespaces),
                    value[value.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                ))
            } else if value.hasSuffix(";") {
                parsed.headers.append((String(value.dropLast()).trimmingCharacters(in: .whitespaces), ""))
            }
        case "data", "data-ascii", "data-binary":
            parsed.data.append(value.hasPrefix("@") ? .file(String(value.dropFirst())) : .text(value))
        case "data-raw": parsed.data.append(.text(value))
        case "json":
            parsed.data.append(.text(value))
            parsed.json = true
        case "data-urlencode": parsed.data.append(.urlEncoded(value))
        case "form": parsed.forms.append(formField(value, literal: false))
        case "form-string": parsed.forms.append(formField(value, literal: true))
        case "user": parsed.user = value
        case "user-agent": parsed.headers.append(("User-Agent", value))
        case "cookie": if value.contains("=") { parsed.headers.append(("Cookie", value)) }
        case "referer": parsed.headers.append(("Referer", value))
        case "oauth2-bearer": parsed.bearer = value
        case "max-time": parsed.timeout = Double(value)
        default: break
        }
    }

    /// `name=value`, `name=@file`, each optionally followed by `;type=…` and `;filename=…`.
    private static func formField(_ text: String, literal: Bool) -> FormField {
        let pair = text.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = pair.first.map(String.init) ?? ""
        var value = pair.count > 1 ? String(pair[1]) : ""
        var contentType = ""
        var isFile = false
        if !literal {
            isFile = value.hasPrefix("@")
            if isFile { value.removeFirst() }
            var kept: [Substring] = []
            for part in value.split(separator: ";", omittingEmptySubsequences: false) {
                if part.hasPrefix("type=") {
                    contentType = String(part.dropFirst(5))
                } else if !(part.hasPrefix("filename=") || part.hasPrefix("headers=")) {
                    if contentType.isEmpty { kept.append(part) }
                }
            }
            value = kept.joined(separator: ";")
        }
        return FormField(
            key: key, kind: isFile ? .file : .text, value: value, contentType: contentType,
            isSecret: !isFile && CredentialHeuristics.looksSensitive(name: key)
        )
    }

    private static func makeItem(from parsed: Parsed) throws(CurlParseError) -> RequestItem {
        guard let rawURL = parsed.url ?? parsed.positional.first, !rawURL.isEmpty else { throw .missingURL }

        // Address, credentials embedded in it, query rows
        var (base, params) = URLTemplate.split(rawURL)
        var user = parsed.user
        if let schemeEnd = base.range(of: "://") {
            let rest = base[schemeEnd.upperBound...]
            let authority = rest.prefix { !"/?#".contains($0) }
            if let at = authority.lastIndex(of: "@") {
                let userinfo = String(authority[..<at])
                if user == nil, !userinfo.isEmpty { user = userinfo }
                base = String(base[..<schemeEnd.upperBound]) + rest[authority.index(after: at)...]
            }
        }

        // Method
        let method: HTTPMethod
        let hasBody = !parsed.forms.isEmpty || !parsed.data.isEmpty
        if let name = parsed.method {
            guard let known = HTTPMethod(rawValue: name) else { throw .malformed("Unsupported HTTP method \(name)") }
            method = known
        } else if parsed.head {
            method = .head
        } else {
            method = hasBody && !parsed.get ? .post : .get
        }

        // Headers and authorization
        var auth = AuthConfig(kind: .none)
        var rows: [KeyValue] = []
        var contentType: String?
        var authorizationRow: (name: String, value: String)?
        for header in parsed.headers where !header.name.isEmpty {
            switch header.name.lowercased() {
            case "content-length":
                continue
            case "content-type":
                contentType = header.value
            case "authorization":
                authorizationRow = header
                continue
            default:
                break
            }
            rows.append(KeyValue(
                key: header.name, value: header.value, isSecret: CredentialHeuristics.looksSensitive(name: header.name)
            ))
        }
        if let user {
            let pair = user.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            auth = AuthConfig(
                kind: .basic, basicUsername: String(pair[0]),
                basicPassword: SecretField(value: pair.count > 1 ? String(pair[1]) : "")
            )
        } else if let token = parsed.bearer, !token.isEmpty {
            auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: token))
        } else if let header = authorizationRow {
            let lowered = header.value.lowercased()
            if lowered.hasPrefix("bearer "), case let token = header.value.dropFirst(7).trimmingCharacters(in: .whitespaces),
               !token.isEmpty {
                auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: token))
            } else if lowered.hasPrefix("basic "),
                      let data = Data(base64Encoded: header.value.dropFirst(6).trimmingCharacters(in: .whitespaces)),
                      let decoded = String(data: data, encoding: .utf8), decoded.contains(":") {
                let pair = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                auth = AuthConfig(kind: .basic, basicUsername: String(pair[0]), basicPassword: SecretField(value: String(pair[1])))
            } else {
                rows.append(KeyValue(key: header.name, value: header.value, isSecret: true))
            }
        }

        // Body
        var body = RequestBody()
        if parsed.get {
            for piece in parsed.data {
                switch piece {
                case .text(let text): params += URLTemplate.split("?" + text).params
                case .urlEncoded(let text): params += URLTemplate.split("?" + text).params
                case .file: break
                }
            }
        } else if !parsed.forms.isEmpty {
            body.mode = .formData
            body.formData = parsed.forms
        } else if !parsed.data.isEmpty {
            if parsed.json, contentType == nil { contentType = "application/json" }
            let removeContentType = applyData(parsed.data, contentType: contentType, to: &body)
            if removeContentType { rows.removeAll { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame } }
        }
        params = params.map { var row = $0; row.isSecret = CredentialHeuristics.looksSensitive(name: row.key); return row }

        var settings = RequestSettings()
        if parsed.insecure { settings.verifyTLS = false }
        if parsed.location { settings.followRedirects = true }
        settings.timeout = parsed.timeout

        return RequestItem(
            name: "\(method.rawValue) \(requestLabel(for: base))", method: method, url: base, queryParams: params,
            headers: rows, auth: auth, body: body, settings: settings
        )
    }

    /// Fills the body from `-d`-style pieces. Returns true when the explicit `Content-Type` header became redundant.
    private static func applyData(_ pieces: [DataPiece], contentType: String?, to body: inout RequestBody) -> Bool {
        if pieces.count == 1, case .file(let path) = pieces[0] {
            body.mode = .binary
            body.binaryPath = path
            return false
        }
        let lowered = contentType?.lowercased() ?? ""
        let text = pieces.compactMap { piece -> String? in
            if case .text(let text) = piece { return text }
            return nil
        }.joined(separator: "&")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksJSON = (trimmed.first == "{" || trimmed.first == "[") && (trimmed.last == "}" || trimmed.last == "]")
        let hasURLEncoded = pieces.contains { if case .urlEncoded = $0 { true } else { false } }
        let isFormType = lowered.hasPrefix("application/x-www-form-urlencoded")
        let looksForm = contentType == nil && !looksJSON && !trimmed.hasPrefix("<") && !trimmed.contains(where: \.isNewline)
            && trimmed.contains("=")

        if hasURLEncoded || isFormType || looksForm {
            body.mode = .urlEncoded
            for piece in pieces {
                switch piece {
                case .text(let text):
                    for segment in text.split(separator: "&") {
                        let pair = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        let key = PercentCoding.mapText(of: String(pair[0]), PercentCoding.decodeForm)
                        let value = PercentCoding.mapText(of: pair.count > 1 ? String(pair[1]) : "", PercentCoding.decodeForm)
                        if !key.isEmpty {
                            body.urlEncoded.append(KeyValue(key: key, value: value, isSecret: CredentialHeuristics.looksSensitive(name: key)))
                        }
                    }
                case .urlEncoded(let text):
                    guard let equals = text.firstIndex(of: "=") else { continue }
                    let key = String(text[..<equals])
                    if !key.isEmpty {
                        body.urlEncoded.append(KeyValue(
                            key: key, value: String(text[text.index(after: equals)...]),
                            isSecret: CredentialHeuristics.looksSensitive(name: key)
                        ))
                    }
                case .file:
                    break
                }
            }
            return isFormType
        }

        let language: RawLanguage
        if lowered.contains("json") {
            language = .json
        } else if lowered.contains("xml") {
            language = .xml
        } else if lowered.contains("html") {
            language = .html
        } else if lowered.contains("javascript") {
            language = .javascript
        } else if lowered.hasPrefix("text/plain") {
            language = .text
        } else {
            language = contentType == nil && looksJSON ? .json : .text
        }
        body.mode = .raw
        body.raw = text
        body.rawLanguage = language
        return lowered.trimmingCharacters(in: .whitespaces) == language.contentType
    }

    /// The last path component of the address, or its host when there is none.
    private static func requestLabel(for address: String) -> String {
        let withoutFragment = address.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
        var rest = Substring(withoutFragment)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 1, let last = parts.last { return String(last) }
        let authority = parts.first.map(String.init) ?? address
        if authority.hasPrefix("[") || authority.hasPrefix("{{") { return authority }
        return String(authority.prefix { $0 != ":" })
    }
}
