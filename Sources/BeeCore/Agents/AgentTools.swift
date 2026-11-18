import CryptoKit
import Foundation

/// What an AI agent may be allowed to do through Bee's MCP relay, from the least to the most.
public enum AgentAccess: String, Codable, CaseIterable, Sendable, Comparable {
    /// See the collections and the requests as they are written, without any secret value.
    case read
    /// Send a request or a fork that exists, and read what came back, now or the last time, with secrets
    /// masked.
    case run
    /// Suggest a change to a request: it arrives as a fork, which the agent may send when the person
    /// agrees, and which the person merges or discards.
    case propose

    public static func < (lhs: AgentAccess, rhs: AgentAccess) -> Bool {
        allCases.firstIndex(of: lhs).map { left in allCases.firstIndex(of: rhs).map { left < $0 } ?? false } ?? false
    }
}

/// The tools Bee offers to an agent. The relay lists them; the application carries them out.
public enum AgentTool: String, CaseIterable, Sendable {
    case listCollections = "list_collections"
    case listRequests = "list_requests"
    case getRequest = "get_request"
    case listEnvironments = "list_environments"
    case sendRequest = "send_request"
    case getResponse = "get_response"
    case proposeChange = "propose_change"

    /// The least access that allows the tool.
    public var access: AgentAccess {
        switch self {
        case .listCollections, .listRequests, .getRequest, .listEnvironments: .read
        case .sendRequest, .getResponse: .run
        case .proposeChange: .propose
        }
    }

    public var summary: String {
        switch self {
        case .listCollections:
            "Lists the collections of requests the person has opened to agents in Bee, with their identifiers."
        case .listRequests:
            "Lists the folders and requests of a collection: identifier, name, method and URL as written (with {{variables}}). A request that has forks lists them: a fork is a trial copy of the request, made by the person or proposed by an agent, with an identifier of its own."
        case .getRequest:
            "Returns one request or one fork as written: method, URL, parameters, headers, body, scripts. A secret is never returned: its place is marked beeSecret and its value is empty. A fork also says which request it is a fork of and which parts it changes."
        case .listEnvironments:
            "Lists the environments and the names of their variables, and tells which environment is active. Values are never returned. send_request can send with any of them without changing the one the person works with."
        case .sendRequest:
            "Sends a request of a collection, or a fork of one, exactly as written, with the active environment or the one you name. The person is asked to allow it in Bee, where they see what is sent; for a fork, what it changes. Returns the status, the headers and the body; secrets are masked. To try a variation of a request, propose it with propose_change, then send the fork it returns."
        case .getResponse:
            "Returns the last response Bee got for a request or a fork, without sending it again: status, headers, body, test results, secrets masked. Use it to look at a response the person got themselves (they are asked in Bee to let you read it) rather than send again a request that changes something, and with offset to read on in a long body that was cut."
        case .proposeChange:
            "Proposes a change to a request. Nothing is changed in the collection: Bee creates a fork holding the change and returns its identifier. Send the fork with send_request to see what it returns; call propose_change again with the fork's identifier to revise it rather than make another one. The person merges the fork into the request, or discards it. Where a request is sent (scheme, host, port), its authorization, its secrets and its scripts are the person's to change."
        }
    }

    /// The JSON Schema of the arguments.
    public var inputSchema: JSONValue {
        func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false),
            ])
        }
        func text(_ description: String) -> JSONValue {
            .object(["type": .string("string"), "description": .string(description)])
        }
        switch self {
        case .listCollections, .listEnvironments:
            return object([:], required: [])
        case .listRequests:
            return object(["collection_id": text("Identifier of the collection, from list_collections.")], required: ["collection_id"])
        case .getRequest:
            return object(["request_id": text("Identifier of the request or of the fork, from list_requests.")], required: ["request_id"])
        case .sendRequest:
            return object([
                "request_id": text("Identifier of the request or of the fork, from list_requests."),
                "environment": text("Name or identifier of the environment to send with, from list_environments. Leave out to send with the active one. The person sees which one it is before they agree, and the one they work with does not change."),
            ], required: ["request_id"])
        case .getResponse:
            return object([
                "request_id": text("Identifier of the request or of the fork, from list_requests."),
                "offset": .object([
                    "type": .string("integer"), "minimum": .number(0),
                    "description": .string("Where to start in the body, in characters, as a cut body says. Leave out to read from the start."),
                ]),
            ], required: ["request_id"])
        case .proposeChange:
            return object([
                "request_id": text("Identifier of the request to change, or of a fork you proposed, to revise it. From list_requests or an earlier propose_change."),
                "name": text("A few words that name the proposal, shown to the person."),
                "method": text("New HTTP method. Leave out to keep it."),
                "url": text("New URL as written, with {{variables}} and :path variables. Leave out to keep it."),
                "body": text("New raw body text. Leave out to keep the body. Name its type in the Content-Type header."),
                "remove_headers": .object([
                    "type": .string("array"), "items": .object(["type": .string("string")]),
                    "description": .string("Names of headers not to send. They are turned off in the fork, not deleted."),
                ]),
                "headers": .object([
                    "type": .string("object"),
                    "description": .string("Headers to set or replace, by name. A header that holds a secret cannot be set, and a value cannot use a secret variable the request does not use already."),
                    "additionalProperties": .object(["type": .string("string")]),
                ]),
            ], required: ["request_id", "name"])
        }
    }
}

// MARK: - Between the relay and the application

/// One tool call, as the relay hands it to the application over their private socket.
public struct AgentCall: Codable, Sendable, Equatable {
    public var id: String
    public var tool: String
    public var arguments: JSONValue
    /// What the agent's program calls itself. A label only: it proves nothing.
    public var client: String

    public init(id: String, tool: String, arguments: JSONValue, client: String) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
        self.client = client
    }
}

public struct AgentReply: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var isError: Bool

    public init(id: String, text: String, isError: Bool = false) {
        self.id = id
        self.text = text
        self.isError = isError
    }
}

// MARK: - Reading

/// What the reading tools answer, built from the workspace alone. Nothing here can return a secret value:
/// requests go through the same projection as the collection files, which never holds one.
public enum AgentReader {
    public static func collections(_ collections: [Collection]) -> JSONValue {
        .array(collections.map { collection in
            .object([
                "id": .string(collection.id.uuidString), "name": .string(collection.name),
                "requests": .number(Double(collection.allRequests.count)),
            ])
        })
    }

    /// The tree of a collection, each request with what tells it apart and the forks it has.
    public static func requests(of collection: Collection, forks: [RequestFork] = []) -> JSONValue {
        func describe(_ nodes: [CollectionNode]) -> [JSONValue] {
            nodes.map { node in
                switch node {
                case .folder(let folder):
                    return .object([
                        "folder": .string(folder.name), "id": .string(folder.id.uuidString),
                        "items": .array(describe(folder.items)),
                    ])
                case .request(let request):
                    var described: [String: JSONValue] = [
                        "id": .string(request.id.uuidString), "name": .string(request.name),
                        "method": .string(request.method.rawValue),
                        // The address as written: a secret parameter shows as the mask, never as its value.
                        "url": .string(URLTemplate.join(base: request.url, params: request.queryParams)),
                    ]
                    let own = forks.filter { $0.originID == request.id }
                    if !own.isEmpty {
                        described["forks"] = .array(own.map { fork in
                            .object([
                                "id": .string(fork.id.uuidString), "name": .string(fork.name),
                                "method": .string(fork.item.method.rawValue),
                                "url": .string(URLTemplate.join(base: fork.item.url, params: fork.item.queryParams)),
                                "by": .string(fork.proposedBy == nil ? "the person" : "an agent"),
                            ])
                        })
                    }
                    return .object(described)
                }
            }
        }
        return .object(["collection": .string(collection.name), "items": .array(describe(collection.items))])
    }

    /// One request as written, in the shape of a collection file: secrets are empty and marked.
    public static func request(_ item: RequestItem) -> JSONValue {
        CollectionFile.request(item, previous: nil)
    }

    /// A fork as it would be sent, in the same shape, with what it is a fork of and the parts it changes.
    public static func fork(_ fork: RequestFork, of original: RequestItem) -> JSONValue {
        guard case .object(var described) = request(fork.item) else { return request(fork.item) }
        described["name"] = .string(fork.name)
        described["forkOf"] = .object(["id": .string(original.id.uuidString), "name": .string(original.name)])
        described["proposedBy"] = .string(fork.proposedBy == nil ? "the person" : "an agent")
        described["changes"] = .array(
            RequestPart.allCases.filter { fork.item.content(of: $0) != original.content(of: $0) }.map { .string($0.rawValue) }
        )
        return .object(described)
    }

    /// A text someone else wrote, as it may be shown to the person inside what Bee says: on one line, every
    /// line break and every character that hides or reorders text made visible, cut when long. What an agent
    /// writes (an address, a name, a header) cannot then pass for a sentence of Bee's.
    public static func oneLine(_ text: String, limit: Int = 600) -> String {
        var shown = ""
        var count = 0
        for character in text {
            guard count < limit else {
                return shown + " … \(text.count - limit) more characters"
            }
            shown += character.isNewline ? "⏎" : visible(character)
            count += 1
        }
        return shown
    }

    /// A character as it may be shown: one that does not print, or that changes the direction of the text
    /// around it, shows as a mark.
    private static func visible(_ character: Character) -> String {
        if character == "\t" { return " " }
        for scalar in character.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: return "\u{FFFD}"
            default: continue
            }
        }
        return String(character)
    }

    /// What a fork sends that its original does not, spelled out for the person who is asked to allow it:
    /// each part that differs, with its rows and its text. A secret shows as the mask. Empty when the
    /// fork says what its original says.
    public static func changes(of fork: RequestFork, from original: RequestItem, bodyLimit: Int = 20000, lineLimit: Int = 4000) -> String {
        let item = fork.item
        var lines: [String] = []
        func line(_ text: String) { lines.append("  " + oneLine(text, limit: lineLimit)) }
        func shown(_ row: KeyValue) -> String { row.isSecret && !row.value.isEmpty ? Redactor.mask : row.value }
        func rows(_ title: String, _ mine: [KeyValue], _ theirs: [KeyValue], separator: String) {
            lines.append(title)
            let sent = mine.filter { $0.isEnabled && !$0.key.isEmpty }
            let was = theirs.filter { $0.isEnabled && !$0.key.isEmpty }
            for row in sent where !was.contains(where: { $0.key == row.key && $0.value == row.value && $0.isSecret == row.isSecret }) {
                line("\(row.key)\(separator)\(shown(row))")
            }
            for row in was where !sent.contains(where: { $0.key.caseInsensitiveCompare(row.key) == .orderedSame }) {
                line("\(row.key)\(separator)no longer sent")
            }
        }
        // Its size comes first: what follows the part of a long text that is shown is said before it.
        func text(_ title: String, _ value: String) {
            let all = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let size = "\(value.count) characters, \(all.count) \(all.count == 1 ? "line" : "lines")"
            guard value.count > bodyLimit else {
                lines.append("\(title) (\(size))")
                all.forEach { line(String($0)) }
                return
            }
            lines.append("\(title) (\(size); the first \(bodyLimit) are shown: read the rest in the fork before you allow it)")
            value.prefix(bodyLimit).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).forEach { line(String($0)) }
        }
        for part in RequestPart.allCases where item.content(of: part) != original.content(of: part) {
            switch part {
            case .address:
                lines.append("Address")
                line("\(item.method.rawValue) \(item.url)")
                line("was \(original.method.rawValue) \(original.url)")
                // The values given to the `:name` segments are part of where it goes.
                let was = PathVariables.storedRows(for: original.url, from: original.pathVariables)
                for row in PathVariables.storedRows(for: item.url, from: item.pathVariables)
                where !was.contains(where: { $0.key == row.key && $0.value == row.value && $0.isSecret == row.isSecret }) {
                    line(":\(row.key) = \(shown(row))")
                }
            case .parameters: rows("Parameters", item.queryParams, original.queryParams, separator: "=")
            case .authorization: lines.append("Authorization: not the one of the original")
            case .headers: rows("Headers", item.headers, original.headers, separator: ": ")
            case .body:
                switch item.body.mode {
                case .none: lines.append("Body: none")
                case .raw: text("Body", item.body.raw)
                case .urlEncoded: rows("Body (form)", item.body.urlEncoded, original.body.urlEncoded, separator: "=")
                case .graphQL: text("Body (GraphQL)", item.body.graphQLQuery + "\n" + item.body.graphQLVariables)
                case .formData, .binary: lines.append("Body: another \(item.body.mode == .binary ? "file" : "form")")
                }
            case .preRequestScript: lines.append("Script before the request: not the one of the original")
            case .postResponseScript: lines.append("Script after the response: not the one of the original")
            case .settings: lines.append("Settings: not those of the original")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The names of the variables a request takes a value from, as written: `{{name}}` anywhere a collection
    /// file would show it (a secret that is more than variables is not read), and a `:name` of the address
    /// left without a value, which takes the variable of that name. Names are read from the texts
    /// themselves, as the request is rendered: a name is the same whatever white space stands around it.
    public static func variables(in item: RequestItem) -> Set<String> {
        var names: Set<String> = []
        func read(_ value: JSONValue) {
            switch value {
            case .string(let text): names.formUnion(variables(namedIn: text))
            case .array(let values): values.forEach(read)
            case .object(let members):
                for (key, member) in members {
                    names.formUnion(variables(namedIn: key))
                    read(member)
                }
            case .null, .bool, .number: break
            }
        }
        read(request(item))
        for name in PathVariables.names(in: item.url) {
            let row = item.pathVariables.first { $0.key == name }
            if row == nil || (row?.value.isEmpty == true && row?.isSecret == false) { names.insert(name) }
        }
        return names
    }

    private static func variables(namedIn text: String) -> Set<String> {
        guard text.contains("{{") else { return [] }
        var names: Set<String> = []
        for token in TemplateEngine.tokens(in: text) {
            if case .variable(let name) = token.kind { names.insert(name) }
        }
        return names
    }

    /// The names given and every variable their values lead to: a value may itself hold `{{names}}`, which
    /// are replaced in turn when a request is sent. `variables` are those of every place a value may come
    /// from.
    public static func variables(reachedFrom names: Set<String>, among variables: [Variable]) -> Set<String> {
        var reached = names
        var pending = Array(names)
        while let name = pending.popLast() {
            for variable in variables where variable.name == name {
                for inner in Self.variables(namedIn: variable.value) where reached.insert(inner).inserted {
                    pending.append(inner)
                }
            }
        }
        return reached
    }

    public static func environments(_ workspace: Workspace) -> JSONValue {
        .array(workspace.environments.map { environment in
            .object([
                "id": .string(environment.id.uuidString), "name": .string(environment.name),
                "active": .bool(environment.id == workspace.activeEnvironmentID),
                "variables": .array(environment.variables.filter { !$0.name.isEmpty }.map { variable in
                    .object(["name": .string(variable.name), "secret": .bool(variable.isSecret)])
                }),
            ])
        })
    }

    /// What tells whether a request is still the one a person agreed to send: the request as written and
    /// everything it takes from its folders and its collection (authorization, scripts, names of variables),
    /// with its secrets, which only count through a digest. The values of variables are left out: scripts
    /// change them from one send to the next. `nil` when the collection has no such request.
    public static func fingerprint(of requestID: UUID, in collection: Collection) -> String? {
        func path(_ nodes: [CollectionNode]) -> [CollectionNode]? {
            for node in nodes {
                switch node {
                case .request(let request) where request.id == requestID:
                    return [node]
                case .folder(var folder):
                    guard let inside = path(folder.items) else { continue }
                    folder.items = inside
                    return [.folder(folder)]
                case .request:
                    continue
                }
            }
            return nil
        }
        guard let items = path(collection.items) else { return nil }
        var alone = collection
        alone.items = items
        guard let data = try? CollectionFile.data(for: alone) else { return nil }
        var digest = SHA256()
        digest.update(data: data)
        // The file form leaves secrets out: a secret row pointed at another variable, or another token,
        // is another request to agree to.
        func add(_ id: UUID, _ value: inout String) {
            digest.update(data: Data("\(id.uuidString)=\(value)\u{0}".utf8))
        }
        alone.items.forEachSecret(add)
        alone.auth.forEachSecret(add)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Where an address sends: its scheme, host and port as written, variables included, without the rest.
    /// Letters are lowercased except in the names of variables, which tell `{{host}}` from `{{HOST}}`.
    public static func origin(of address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        var rest = Substring(trimmed)
        var scheme = ""
        if let mark = trimmed.range(of: "://") {
            scheme = String(trimmed[..<mark.upperBound])
            rest = trimmed[mark.upperBound...]
        }
        let origin = scheme + rest.prefix { !"/?#".contains($0) }
        var result = ""
        var remaining = Substring(origin)
        while let open = remaining.range(of: "{{") {
            result += remaining[..<open.lowerBound].lowercased()
            guard let close = remaining[open.upperBound...].range(of: "}}") else {
                return result + remaining[open.lowerBound...]
            }
            result += remaining[open.lowerBound..<close.upperBound]
            remaining = remaining[close.upperBound...]
        }
        return result + remaining.lowercased()
    }

    /// The body of a response as an agent reads it: its text from `offset`, `limit` characters at most, and
    /// what to ask for when more follows. Bytes that are not text are counted, not shown.
    public static func body(_ body: Data, from offset: Int = 0, limit: Int = 60000) -> [String] {
        if body.prefix(1024).contains(0) { return ["Body: \(body.count) bytes that are not text."] }
        // As it was received: in UTF-8, or byte for byte in a charset Bee does not know.
        let text = String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1) ?? ""
        let count = text.count
        guard offset == 0 || offset < count else { return ["The body has \(count) characters: nothing follows character \(offset)."] }
        let part = text.dropFirst(offset).prefix(limit)
        var lines = [offset == 0 ? "Body:" : "Body, from character \(offset) of \(count):", String(part)]
        if offset + part.count < count {
            lines.append("… cut: \(count) characters in all. Read on with get_response and offset \(offset + part.count).")
        }
        return lines
    }

    /// A JSON value as the text of a tool answer.
    public static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
