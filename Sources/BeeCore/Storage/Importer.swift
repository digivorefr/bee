import Foundation

/// Why a file could not be imported.
public enum ImportError: Error, Equatable, Sendable, LocalizedError {
    /// Not a Postman or Bee document.
    case unrecognizedFormat
    /// A known format in a version Bee does not read.
    case unsupportedVersion(String)
    /// A known format whose content is broken or not what was asked for.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            "This file is neither a Postman export nor a Bee archive."
        case .unsupportedVersion(let version):
            "\(version) is not supported. Bee imports Postman Collection v2.0 and v2.1, Postman environments and Bee archives."
        case .malformed(let detail):
            "The file could not be imported. \(detail)"
        }
    }
}

/// What an importable file contains.
public enum ImportKind: Sendable, Equatable {
    case postmanCollection, postmanEnvironment, beeCollection, beeEnvironment
}

/// Reads collections and environments exported by Postman or by Bee.
///
/// Imported credentials become secrets: authorization fields land in secret slots, and rows or
/// variables named like a credential are marked secret, so the first save moves them to the vault.
public enum Importer {
    /// The kind of document in `data`, or `nil` when it is not recognized.
    public static func detect(_ data: Data) -> ImportKind? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return kind(of: root)
    }

    /// Reads a Postman collection (v2.0 or v2.1) or a Bee collection archive.
    /// A Bee archive gets new identifiers throughout, so importing it twice never collides.
    public static func collection(from data: Data) throws(ImportError) -> Collection {
        let root = try parse(data)
        switch kind(of: root) {
        case .postmanCollection:
            // An import is a copy of its own: importing a file twice never gives two collections one identity.
            return try PostmanReader.collection(from: root).withFreshIdentifiers()
        case .beeCollection:
            try checkArchiveVersion(root)
            do {
                return try StorageCoding.decoder().decode(BeeArchive.CollectionDocument.self, from: data)
                    .collection.withFreshIdentifiers()
            } catch {
                throw .malformed("The Bee archive does not hold a valid collection.")
            }
        case .postmanEnvironment, .beeEnvironment:
            throw .malformed("The file holds an environment, not a collection.")
        case nil:
            throw .unrecognizedFormat
        }
    }

    /// Reads a Postman environment (or globals) export or a Bee environment archive.
    public static func environment(from data: Data) throws(ImportError) -> Environment {
        let root = try parse(data)
        switch kind(of: root) {
        case .postmanEnvironment:
            return try PostmanReader.environment(from: root)
        case .beeEnvironment:
            try checkArchiveVersion(root)
            do {
                return try StorageCoding.decoder().decode(BeeArchive.EnvironmentDocument.self, from: data)
                    .environment.withFreshIdentifiers()
            } catch {
                throw .malformed("The Bee archive does not hold a valid environment.")
            }
        case .postmanCollection, .beeCollection:
            throw .malformed("The file holds a collection, not an environment.")
        case nil:
            throw .unrecognizedFormat
        }
    }

    // MARK: Detection

    private static func parse(_ data: Data) throws(ImportError) -> JSONValue {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw .unrecognizedFormat }
        return root
    }

    private static func kind(of root: JSONValue) -> ImportKind? {
        guard root.object != nil else { return nil }
        if root["bee"] != nil {
            switch root["kind"]?.string {
            case "collection": return .beeCollection
            case "environment": return .beeEnvironment
            default: return nil
            }
        }
        if PostmanReader.isCollection(PostmanReader.unwrapped(root, key: "collection")) { return .postmanCollection }
        if PostmanReader.isEnvironment(PostmanReader.unwrapped(root, key: "environment")) { return .postmanEnvironment }
        return nil
    }

    private static func checkArchiveVersion(_ root: JSONValue) throws(ImportError) {
        guard case .number(let number)? = root["bee"], let version = Int(exactly: number), version >= 1 else {
            throw .malformed("The Bee archive has no valid version.")
        }
        guard version <= BeeArchive.version else { throw .unsupportedVersion("Bee archive version \(version)") }
    }
}

// MARK: - Postman

/// Maps Postman's Collection v2.0 / v2.1 and environment formats onto Bee's models.
enum PostmanReader {
    /// The Postman API wraps exports as `{"collection": {…}}` / `{"environment": {…}}`.
    static func unwrapped(_ root: JSONValue, key: String) -> JSONValue {
        if let inner = root[key], inner.object != nil, root["info"] == nil, root["values"] == nil { return inner }
        return root
    }

    static func isCollection(_ root: JSONValue) -> Bool {
        if root["info"]?.object != nil, root["item"]?.array != nil { return true }
        if root["info"]?["schema"]?.string?.contains("/collection/") == true { return true }
        return isVersion1Collection(root)
    }

    static func isEnvironment(_ root: JSONValue) -> Bool {
        guard root["values"]?.array != nil else { return false }
        return root["_postman_variable_scope"] != nil || root["name"]?.string != nil
    }

    private static func isVersion1Collection(_ root: JSONValue) -> Bool {
        root["requests"]?.array != nil && root["name"]?.string != nil && root["item"] == nil
    }

    // MARK: Collection

    static func collection(from document: JSONValue) throws(ImportError) -> Collection {
        let root = unwrapped(document, key: "collection")
        if isVersion1Collection(root) { throw .unsupportedVersion("Postman Collection v1") }
        guard let info = root["info"], info.object != nil else {
            throw .malformed("The Postman collection has no \"info\" section.")
        }
        if let version = schemaVersion(info["schema"]?.string), !version.hasPrefix("2.") {
            throw .unsupportedVersion("Postman Collection v\(version)")
        }
        guard let items = root["item"]?.array else {
            throw .malformed("The Postman collection has no \"item\" list.")
        }

        // Without authorization a Postman collection sends none, which Bee spells `.none` at this level.
        let (auth, authNote) = authorization(root["auth"], whenMissing: .none)
        let scripts = scripts(root["event"])
        let guesses = guessesSecrets(in: root)
        return Collection(
            id: identifier(info["_postman_id"]) ?? UUID(),
            name: info["name"]?.string ?? "Imported collection",
            items: items.compactMap { node($0, guesses: guesses) },
            variables: variables(root["variable"], guesses: guesses),
            auth: auth,
            preRequestScript: scripts.preRequest,
            postResponseScript: scripts.postResponse,
            notes: notes(description(info["description"]), authNote)
        )
    }

    /// The version in a schema address such as `…/json/collection/v2.1.0/collection.json`.
    private static func schemaVersion(_ schema: String?) -> String? {
        guard let schema else { return nil }
        for component in schema.split(separator: "/") where component.hasPrefix("v") {
            let version = component.dropFirst()
            if version.first?.isNumber == true { return String(version) }
        }
        return nil
    }

    /// A UUID written in the file, when there is one: what lets a file Bee keeps in sync name the same
    /// collection, folders and requests from one reading to the next.
    static func identifier(_ value: JSONValue?) -> UUID? {
        value?.string.flatMap(UUID.init(uuidString:))
    }

    /// False for a file Bee wrote: its secrets are the rows it marked, and a row it left plain stays plain
    /// whatever its name. Anywhere else a row named like a credential is taken for one.
    static func guessesSecrets(in root: JSONValue) -> Bool {
        root["info"]?[CollectionFile.secretsMarkedKey]?.string != CollectionFile.secretsMarkedValue
    }

    static func node(_ value: JSONValue, guesses: Bool = true) -> CollectionNode? {
        guard value.object != nil else { return nil }
        if let children = value["item"]?.array {
            let (auth, authNote) = authorization(value["auth"], whenMissing: .inherit)
            let scripts = scripts(value["event"])
            return .folder(Folder(
                id: identifier(value["id"]) ?? UUID(),
                name: value["name"]?.string ?? "Folder",
                items: children.compactMap { node($0, guesses: guesses) },
                auth: auth,
                preRequestScript: scripts.preRequest,
                postResponseScript: scripts.postResponse,
                notes: notes(description(value["description"]), authNote)
            ))
        }
        guard let request = value["request"] else { return nil }
        return .request(requestItem(request, in: value, guesses: guesses))
    }

    // MARK: Request

    private static func requestItem(_ request: JSONValue, in item: JSONValue, guesses: Bool) -> RequestItem {
        var result = RequestItem(id: identifier(item["id"]) ?? UUID(), name: item["name"]?.string ?? "Untitled request")
        result.settings = settings(item)
        let scripts = scripts(item["event"])
        result.preRequestScript = scripts.preRequest
        result.postResponseScript = scripts.postResponse

        // The short form: the request is just its address.
        guard request.object != nil else {
            (result.url, result.queryParams) = address(request, guesses: guesses)
            result.notes = description(item["description"])
            return result
        }

        var methodNote: String?
        let methodName = (request["method"]?.string ?? "GET").uppercased()
        if let method = HTTPMethod(rawValue: methodName) {
            result.method = method
        } else {
            methodNote = "The method \(methodName) is not supported by Bee; GET is used instead."
        }
        (result.url, result.queryParams) = address(request["url"], guesses: guesses)
        result.pathVariables = pathVariables(request["url"], address: result.url, guesses: guesses)
        result.headers = headers(request["header"], guesses: guesses)
        result.body = body(request["body"], headers: result.headers, guesses: guesses)
        let (auth, authNote) = authorization(request["auth"], whenMissing: .inherit)
        result.auth = auth
        let text = description(request["description"])
        result.notes = notes(text.isEmpty ? description(item["description"]) : text, methodNote, authNote)
        return result
    }

    /// What the request does differently from the application settings: Postman's protocol profile, and the
    /// timeout Bee writes beside it.
    private static func settings(_ item: JSONValue) -> RequestSettings {
        let behavior = item["protocolProfileBehavior"]
        var settings = RequestSettings()
        settings.followRedirects = behavior?["followRedirects"]?.bool
        settings.verifyTLS = behavior?["strictSSL"]?.bool
        if case .number(let seconds)? = item["beeTimeout"], seconds > 0 { settings.timeout = seconds }
        return settings
    }

    /// The address without its query, and the query rows. Postman stores the address as a string
    /// or as an object with `raw` and, usually, a structured `query` list.
    private static func address(_ value: JSONValue?, guesses: Bool) -> (url: String, query: [KeyValue]) {
        guard let value else { return ("", []) }
        let raw = value.string ?? value["raw"]?.string ?? composedAddress(value)
        let (base, rawQuery) = splitQuery(raw)
        if let rows = value["query"]?.array {
            return (base, rows.compactMap { row in
                guard row.object != nil else { return nil }
                return keyValue(key: row["key"]?.text ?? "", value: row["value"]?.text ?? "", disabled: row["disabled"], marked: row["beeSecret"], guesses: guesses)
            })
        }
        let rows = rawQuery.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return keyValue(key: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "", disabled: nil, guesses: guesses)
        }
        return (base, rows)
    }

    /// The values Postman keeps for the `:name` segments of the address (`url.variable`). A variable left
    /// empty gets no row: Bee then reads the variable of the same name.
    private static func pathVariables(_ value: JSONValue?, address: String, guesses: Bool) -> [KeyValue] {
        let rows = (value?["variable"]?.array ?? []).compactMap { entry -> KeyValue? in
            guard let key = entry["key"]?.text ?? entry["id"]?.text, !key.isEmpty else { return nil }
            return keyValue(key: key, value: entry["value"]?.text ?? "", disabled: nil, marked: entry["beeSecret"], guesses: guesses)
        }
        return PathVariables.storedRows(for: address, from: rows)
    }

    /// Splits at the first `?`; the fragment, which is never sent, is dropped with the query.
    private static func splitQuery(_ raw: String) -> (base: String, query: String) {
        guard let mark = raw.firstIndex(of: "?") else { return (raw, "") }
        let query = raw[raw.index(after: mark)...]
        return (String(raw[..<mark]), String(query.prefix { $0 != "#" }))
    }

    /// Rebuilds the address from Postman's parts when `raw` is absent.
    private static func composedAddress(_ value: JSONValue) -> String {
        func joined(_ part: JSONValue?, separator: String) -> String {
            if let text = part?.text { return text }
            return (part?.array ?? []).compactMap { $0.text ?? $0["value"]?.text }.joined(separator: separator)
        }
        var result = ""
        if let scheme = value["protocol"]?.string, !scheme.isEmpty { result += scheme + "://" }
        result += joined(value["host"], separator: ".")
        if let port = value["port"]?.text, !port.isEmpty { result += ":" + port }
        let path = joined(value["path"], separator: "/")
        if !path.isEmpty { result += "/" + path }
        return result
    }

    private static func headers(_ value: JSONValue?, guesses: Bool) -> [KeyValue] {
        if let rows = value?.array {
            return rows.compactMap { row in
                guard row.object != nil else { return nil }
                return keyValue(key: row["key"]?.text ?? "", value: row["value"]?.text ?? "", disabled: row["disabled"], marked: row["beeSecret"], guesses: guesses)
            }
        }
        // Old exports write headers as "Name: value" lines.
        return (value?.string ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return keyValue(
                key: parts[0].trimmingCharacters(in: .whitespaces),
                value: parts[1].trimmingCharacters(in: .whitespaces), disabled: nil, guesses: guesses
            )
        }
    }

    /// A row that is secret when Bee marked it, or, in a file Bee did not write, when its name looks like a
    /// credential and it has a value to protect.
    /// - Parameter marked: `beeSecret`, which Bee writes on a secret row since the file never holds its value.
    private static func keyValue(
        key: String, value: String, disabled: JSONValue?, marked: JSONValue? = nil, guesses: Bool
    ) -> KeyValue {
        KeyValue(
            key: key, value: value, isEnabled: disabled?.bool != true,
            isSecret: marked?.bool == true || (guesses && !value.isEmpty && CredentialHeuristics.looksSensitive(name: key))
        )
    }

    // MARK: Body

    private static func body(_ value: JSONValue?, headers: [KeyValue], guesses: Bool) -> RequestBody {
        var body = RequestBody()
        guard let value, value.object != nil else { return body }
        switch value["mode"]?.string {
        case "raw":
            body.mode = .raw
            body.raw = value["raw"]?.string ?? ""
            body.rawLanguage = rawLanguage(value["options"]?["raw"]?["language"]?.string, headers: headers)
        case "urlencoded":
            body.mode = .urlEncoded
            body.urlEncoded = (value["urlencoded"]?.array ?? []).compactMap { row in
                guard row.object != nil else { return nil }
                return keyValue(key: row["key"]?.text ?? "", value: row["value"]?.text ?? "", disabled: row["disabled"], marked: row["beeSecret"], guesses: guesses)
            }
        case "formdata":
            body.mode = .formData
            body.formData = (value["formdata"]?.array ?? []).compactMap { formField($0, guesses: guesses) }
        case "file":
            body.mode = .binary
            body.binaryPath = value["file"]?["src"]?.string ?? ""
        case "graphql":
            body.mode = .graphQL
            body.graphQLQuery = value["graphql"]?["query"]?.string ?? ""
            body.graphQLVariables = jsonText(value["graphql"]?["variables"])
        default:
            break
        }
        return body
    }

    private static func rawLanguage(_ name: String?, headers: [KeyValue]) -> RawLanguage {
        if let name, let language = RawLanguage(rawValue: name.lowercased()) { return language }
        // Collection v2.0 has no language: the Content-Type header says what the text is.
        let contentType = headers
            .first { $0.isEnabled && $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.lowercased() ?? ""
        let hints: [(String, RawLanguage)] = [("json", .json), ("xml", .xml), ("html", .html), ("javascript", .javascript)]
        return hints.first { contentType.contains($0.0) }?.1 ?? .text
    }

    private static func formField(_ row: JSONValue, guesses: Bool) -> FormField? {
        guard row.object != nil else { return nil }
        let key = row["key"]?.text ?? ""
        let isEnabled = row["disabled"]?.bool != true
        let contentType = row["contentType"]?.string ?? ""
        if row["type"]?.string == "file" {
            // `src` is a path, a list of paths (the first is kept) or null.
            let path = row["src"]?.string ?? row["src"]?.array?.first?.string ?? ""
            return FormField(key: key, kind: .file, value: path, contentType: contentType, isEnabled: isEnabled)
        }
        let value = row["value"]?.text ?? ""
        return FormField(
            key: key, kind: .text, value: value, contentType: contentType, isEnabled: isEnabled,
            isSecret: row["beeSecret"]?.bool == true || (guesses && !value.isEmpty && CredentialHeuristics.looksSensitive(name: key))
        )
    }

    /// GraphQL variables are JSON text in Postman, occasionally an inline object.
    private static func jsonText(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let text = value.string { return text }
        guard value.object != nil || value.array != nil else { return value.text ?? "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: Authorization

    /// Credentials go to secret slots. A type Bee cannot send becomes "no authorization" with a note
    /// naming it, so the request does not silently inherit something else.
    private static func authorization(
        _ value: JSONValue?, whenMissing: AuthKind
    ) -> (auth: AuthConfig, note: String?) {
        guard let value, let type = value["type"]?.string else { return (AuthConfig(kind: whenMissing), nil) }
        let fields = authorizationFields(value[type])
        switch type {
        case "noauth":
            return (AuthConfig(kind: .none), nil)
        case "bearer":
            return (AuthConfig(kind: .bearer, bearerToken: SecretField(value: fields["token"] ?? "")), nil)
        case "basic":
            return (AuthConfig(
                kind: .basic, basicUsername: fields["username"] ?? "",
                basicPassword: SecretField(value: fields["password"] ?? "")
            ), nil)
        case "apikey":
            return (AuthConfig(
                kind: .apiKey, apiKeyName: fields["key"] ?? "",
                apiKeyValue: SecretField(value: fields["value"] ?? ""),
                apiKeyLocation: fields["in"] == "query" ? .query : .header
            ), nil)
        default:
            return (
                AuthConfig(kind: .none),
                "The Postman authorization type \"\(type)\" is not supported by Bee and was not imported."
            )
        }
    }

    /// v2.1 lists the fields as `[{key, value}]`; v2.0 uses a plain object.
    private static func authorizationFields(_ value: JSONValue?) -> [String: String] {
        var fields: [String: String] = [:]
        if let entries = value?.array {
            for entry in entries {
                if let key = entry["key"]?.string, let text = entry["value"]?.text { fields[key] = text }
            }
        } else if let members = value?.object {
            for (key, member) in members {
                if let text = member.text { fields[key] = text }
            }
        }
        return fields
    }

    // MARK: Scripts, variables, notes

    private static func scripts(_ value: JSONValue?) -> (preRequest: String, postResponse: String) {
        var preRequest: [String] = []
        var postResponse: [String] = []
        for event in value?.array ?? [] {
            let exec = event["script"]?["exec"]
            let code = exec?.string ?? (exec?.array ?? []).compactMap(\.string).joined(separator: "\n")
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            switch event["listen"]?.string {
            case "prerequest": preRequest.append(code)
            case "test": postResponse.append(code)
            default: break
            }
        }
        return (preRequest.joined(separator: "\n"), postResponse.joined(separator: "\n"))
    }

    private static func variables(_ value: JSONValue?, guesses: Bool) -> [Variable] {
        (value?.array ?? []).compactMap { entry in
            guard let name = entry["key"]?.string ?? entry["id"]?.string else { return nil }
            return Variable(
                name: name, value: entry["value"]?.text ?? "",
                isSecret: entry["beeSecret"]?.bool == true || entry["type"]?.string == "secret"
                    || (guesses && isSecretVariable(name: name, type: nil)),
                isEnabled: entry["disabled"]?.bool != true
            )
        }
    }

    private static func isSecretVariable(name: String, type: String?) -> Bool {
        type == "secret" || CredentialHeuristics.looksSensitive(name: name)
    }

    /// A description is a string or `{"content": …}`.
    private static func description(_ value: JSONValue?) -> String {
        value?.string ?? value?["content"]?.string ?? ""
    }

    /// The parts, one paragraph each. A part an earlier one already says is left out: a note Bee added to a
    /// description, written to a file, is not added again when the file is read.
    private static func notes(_ parts: String?...) -> String {
        var kept: [String] = []
        for part in parts.compactMap({ $0 }) where !part.isEmpty && !kept.contains(where: { $0.contains(part) }) {
            kept.append(part)
        }
        return kept.joined(separator: "\n\n")
    }

    // MARK: Environment

    static func environment(from document: JSONValue) throws(ImportError) -> Environment {
        let root = unwrapped(document, key: "environment")
        guard let values = root["values"]?.array else {
            throw .malformed("The Postman environment has no \"values\" list.")
        }
        let fallbackName = root["_postman_variable_scope"]?.string == "globals" ? "Globals" : "Imported environment"
        return Environment(
            name: root["name"]?.string ?? fallbackName,
            variables: values.compactMap { entry in
                guard let name = entry["key"]?.string else { return nil }
                return Variable(
                    name: name, value: entry["value"]?.text ?? "",
                    isSecret: isSecretVariable(name: name, type: entry["type"]?.string),
                    isEnabled: entry["enabled"]?.bool != false
                )
            }
        )
    }
}
