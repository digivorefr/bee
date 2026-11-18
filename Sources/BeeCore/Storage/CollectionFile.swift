import Foundation

/// A collection as a file Bee keeps up to date beside it: a Postman Collection v2.1 document that can be
/// sent as it is, read by Postman, or dropped in the folder of another copy of Bee.
///
/// The file holds what is shared: the tree, the requests, their scripts and the names of the variables.
/// It never holds a secret value nor the value of a variable; those stay on this Mac (see ``merge``).
///
/// Bee writes only what it changed: a part of a request the file already says, and anything the file holds
/// that Bee does not model (saved responses, an authorization of a kind Bee cannot send, a description on a
/// row), is kept as it was written.
public enum CollectionFile {
    static let schema = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
    /// Written on a row, a field or a variable whose value is a secret: the value itself is left empty.
    static let secretMarker = "beeSecret"
    /// Written in `info` by Bee: the secrets of this file are the rows it marked, and no other row is to be
    /// taken for one because of its name.
    static let secretsMarkedKey = "beeSecrets"
    static let secretsMarkedValue = "marked"

    /// The content of the file for a collection. `previous` is the file as it is on disk, when it exists and
    /// can be read.
    public static func data(for collection: Collection, previous: Data? = nil) throws -> Data {
        try data(for: collection, document: previous.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) })
    }

    /// The same, from the document of the file when it is already read.
    static func data(for collection: Collection, document: JSONValue?) throws -> Data {
        try StorageCoding.encoder().encode(self.document(for: collection, previous: document))
    }

    /// Reads a file. Identifiers written in it are kept, so the same file always names the same collection
    /// and requests; what has none (a file written by Postman) gets new ones.
    public static func read(_ data: Data) throws(ImportError) -> Collection {
        try collection(in: document(in: data))
    }

    /// The document of a file, without the wrapper some tools put around it.
    static func document(in data: Data) throws(ImportError) -> JSONValue {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw .unrecognizedFormat }
        let document = PostmanReader.unwrapped(root, key: "collection")
        guard PostmanReader.isCollection(document) else { throw .malformed("The file is not a Postman collection.") }
        return document
    }

    static func collection(in document: JSONValue) throws(ImportError) -> Collection {
        try PostmanReader.collection(from: document)
    }

    /// The identifier a document gives its collection, when it gives one.
    static func identifier(of document: JSONValue) -> UUID? {
        PostmanReader.identifier(document["info"]?["_postman_id"])
    }

    // MARK: - Identifiers

    /// The document with an identifier on its collection and on every folder and request, written where the
    /// reader and the writer both find it. What has none takes the one of the folder or request of the same
    /// name at the same place in `local`, so a file written again by a tool that drops identifiers still
    /// names the requests Bee holds, with their secrets. An identifier used twice is kept once.
    ///
    /// - Parameters:
    ///   - adoptsUnknown: true for a file another tool wrote: an identifier `local` does not have is the
    ///     tool's own, and counts as none. In a file Bee wrote it is a new request.
    ///   - reserved: identifiers other collections hold, which this one cannot take.
    static func identified(
        _ document: JSONValue, as id: UUID, like local: Collection?, adoptsUnknown: Bool = false, reserved: Set<UUID> = []
    ) -> JSONValue {
        guard var root = document.object else { return document }
        var info = root["info"]?.object ?? [:]
        info["_postman_id"] = .string(id.uuidString)
        root["info"] = .object(info)

        var here: Set<UUID> = []
        func collect(_ nodes: [CollectionNode]) {
            for node in nodes {
                here.insert(node.id)
                collect(node.children ?? [])
            }
        }
        collect(local?.items ?? [])
        /// The identifier an entry really gives: none when it is another tool's.
        func given(_ entry: JSONValue) -> UUID? {
            PostmanReader.identifier(entry["id"]).flatMap { !adoptsUnknown || here.contains($0) ? $0 : nil }
        }
        var named: Set<UUID> = []
        func collect(_ entries: [JSONValue]) {
            for entry in entries {
                if let id = given(entry) { named.insert(id) }
                collect(entry["item"]?.array ?? [])
            }
        }
        collect(root["item"]?.array ?? [])

        var used = reserved
        func stamped(_ entries: [JSONValue], like local: [CollectionNode]) -> [JSONValue] {
            // What an entry without identifier may stand for: the local nodes no entry of the file names.
            var free = local.filter { !named.contains($0.id) }
            return entries.map { entry in
                guard var object = entry.object, object["item"]?.array != nil || object["request"] != nil else { return entry }
                let isFolder = object["item"]?.array != nil
                var id = given(entry)
                if id == nil, let position = free.firstIndex(where: { ($0.children != nil) == isFolder && $0.name == object["name"]?.string }) {
                    id = free.remove(at: position).id
                }
                // Otherwise the one written, when no one else has it.
                var resolved = id ?? PostmanReader.identifier(object["id"]) ?? UUID()
                if !used.insert(resolved).inserted {
                    resolved = UUID()
                    used.insert(resolved)
                }
                object["id"] = .string(resolved.uuidString)
                if let children = object["item"]?.array {
                    object["item"] = .array(stamped(children, like: local.first { $0.id == resolved }?.children ?? []))
                }
                return .object(object)
            }
        }
        root["item"] = .array(stamped(root["item"]?.array ?? [], like: local?.items ?? []))
        return .object(root)
    }

    /// True when a document of another tool holds the requests of `local` under other identifiers: at
    /// least half of the requests held here are there by name.
    static func resembles(_ document: JSONValue, _ local: Collection) -> Bool {
        var names: [String: Int] = [:]
        func collect(_ entries: [JSONValue]) {
            for entry in entries {
                if let children = entry["item"]?.array {
                    collect(children)
                } else if entry["request"] != nil, let name = entry["name"]?.string {
                    names[name, default: 0] += 1
                }
            }
        }
        collect(document["item"]?.array ?? [])
        let requests = local.allRequests
        var found = 0
        for request in requests where (names[request.name] ?? 0) > 0 {
            names[request.name, default: 0] -= 1
            found += 1
        }
        return !requests.isEmpty && found * 2 >= requests.count
    }

    /// The document as another collection: every identifier is new.
    static func withFreshIdentifiers(_ document: JSONValue) -> JSONValue {
        func fresh(_ entries: [JSONValue]) -> [JSONValue] {
            entries.map { entry in
                guard var object = entry.object else { return entry }
                object["id"] = .string(UUID().uuidString)
                if let children = object["item"]?.array { object["item"] = .array(fresh(children)) }
                return .object(object)
            }
        }
        guard var root = document.object else { return document }
        var info = root["info"]?.object ?? [:]
        info["_postman_id"] = .string(UUID().uuidString)
        root["info"] = .object(info)
        root["item"] = .array(fresh(root["item"]?.array ?? []))
        return .object(root)
    }

    // MARK: - Writing

    static func document(for collection: Collection, previous: JSONValue?) -> JSONValue {
        let before = previous.map { PostmanReader.unwrapped($0, key: "collection") }
        var root = before?.object ?? [:]

        let previousModel = before.flatMap { try? PostmanReader.collection(from: $0) }
        let guesses = before.map(PostmanReader.guessesSecrets(in:)) ?? false

        var info = before?["info"]?.object ?? [:]
        info["_postman_id"] = .string(collection.id.uuidString)
        info["name"] = .string(collection.name)
        info["schema"] = .string(schema)
        info[secretsMarkedKey] = .string(secretsMarkedValue)
        // Compared as it was read: the reader may have added a note of its own to the description.
        setText(
            &info, "description", collection.notes, previous: before?["info"]?["description"],
            unchanged: previousModel?.notes == collection.notes
        )
        root["info"] = .object(info)

        if previousModel.map({ sameAuthorization($0.auth, collection.auth) }) != true {
            // At the top, "inherit" has nothing to inherit from: both mean no authorization.
            root["auth"] = authorization(collection.auth.kind == .inherit ? AuthConfig(kind: .none) : collection.auth)
        }
        if previousModel?.preRequestScript != collection.preRequestScript
            || previousModel?.postResponseScript != collection.postResponseScript {
            setArray(&root, "event", events(pre: collection.preRequestScript, post: collection.postResponseScript))
        }
        setArray(&root, "variable", variables(collection.variables, previous: before?["variable"]?.array))
        // What the file said of each node, by identifier, wherever it was: a request moved to another
        // folder keeps what Bee does not model.
        var known: [UUID: JSONValue] = [:]
        func index(_ entries: [JSONValue]) {
            for entry in entries {
                if let id = PostmanReader.identifier(entry["id"]), known[id] == nil { known[id] = entry }
                index(entry["item"]?.array ?? [])
            }
        }
        index(before?["item"]?.array ?? [])
        root["item"] = .array(nodes(collection.items, known: known, guesses: guesses))
        return .object(root)
    }

    private static func nodes(_ nodes: [CollectionNode], known: [UUID: JSONValue], guesses: Bool) -> [JSONValue] {
        nodes.map { node in
            switch node {
            case .folder(let folder): self.folder(folder, previous: known[folder.id], known: known, guesses: guesses)
            case .request(let request): self.request(request, previous: known[request.id], guesses: guesses)
            }
        }
    }

    private static func folder(_ folder: Folder, previous: JSONValue?, known: [UUID: JSONValue], guesses: Bool) -> JSONValue {
        var object = previous?.object ?? [:]
        var before: Folder?
        if let previous, case .folder(let read)? = PostmanReader.node(previous, guesses: guesses) { before = read }

        object["id"] = .string(folder.id.uuidString)
        object["name"] = .string(folder.name)
        setText(&object, "description", folder.notes, previous: previous?["description"], unchanged: before?.notes == folder.notes)
        if before.map({ sameAuthorization($0.auth, folder.auth) }) != true {
            object["auth"] = folder.auth.kind == .inherit ? nil : authorization(folder.auth)
        }
        if before?.preRequestScript != folder.preRequestScript || before?.postResponseScript != folder.postResponseScript {
            setArray(&object, "event", events(pre: folder.preRequestScript, post: folder.postResponseScript))
        }
        object["item"] = .array(nodes(folder.items, known: known, guesses: guesses))
        return .object(object)
    }

    /// - Parameter guesses: how `previous` is read: false when it comes from a file Bee wrote.
    static func request(_ item: RequestItem, previous: JSONValue?, guesses: Bool = false) -> JSONValue {
        var object = previous?.object ?? [:]
        var request = previous?["request"]?.object ?? [:]
        var before: RequestItem?
        if let previous, case .request(let read)? = PostmanReader.node(previous, guesses: guesses) { before = read }
        // The file never holds a secret value: what is compared with it is the request without them.
        let shared = withoutSecretValues(item)
        func unchanged(_ parts: RequestPart...) -> Bool {
            guard let before else { return false }
            return parts.allSatisfy { before.content(of: $0) == shared.content(of: $0) }
        }

        object["id"] = .string(item.id.uuidString)
        object["name"] = .string(item.name)
        if object["response"] == nil { object["response"] = .array([]) }
        if before?.notes != item.notes {
            // Notes are read from the request's description first, then from the item's.
            request["description"] = nil
            setText(&object, "description", item.notes, previous: nil)
        }

        if !unchanged(.address, .parameters) {
            request["method"] = .string(item.method.rawValue)
            request["url"] = address(shared, previous: previous?["request"]?["url"])
        }
        if !unchanged(.headers) {
            request["header"] = .array(rows(shared.headers, previous: previous?["request"]?["header"]?.array))
        }
        if !unchanged(.body) {
            request["body"] = body(shared.body, previous: previous?["request"]?["body"])
        }
        if !unchanged(.authorization) {
            request["auth"] = shared.auth.kind == .inherit ? nil : authorization(shared.auth)
        }
        object["request"] = .object(request)

        if !unchanged(.preRequestScript, .postResponseScript) {
            setArray(&object, "event", events(pre: item.preRequestScript, post: item.postResponseScript))
        }
        if !unchanged(.settings) {
            var behavior = previous?["protocolProfileBehavior"]?.object ?? [:]
            behavior["followRedirects"] = item.settings.followRedirects.map(JSONValue.bool)
            behavior["strictSSL"] = item.settings.verifyTLS.map(JSONValue.bool)
            object["protocolProfileBehavior"] = behavior.isEmpty ? nil : .object(behavior)
            object["beeTimeout"] = item.settings.timeout.map(JSONValue.number)
        }
        return .object(object)
    }

    /// A copy whose secret slots are empty unless they only refer to variables, which is no secret.
    static func withoutSecretValues(_ item: RequestItem) -> RequestItem {
        var copy = item
        copy.forEachSecret { _, value in
            if !TemplateEngine.isPlaceholderOnly(value) { value = "" }
        }
        return copy
    }

    private static func address(_ item: RequestItem, previous: JSONValue?) -> JSONValue {
        var object = previous?.object ?? [:]
        // The parts Postman derives from the address would no longer match it: they are left out.
        for derived in ["protocol", "host", "port", "path", "hash"] { object[derived] = nil }
        object["raw"] = .string(URLTemplate.join(base: item.url, params: item.queryParams))
        setArray(&object, "query", rows(item.queryParams, previous: previous?["query"]?.array))
        let pathRows = PathVariables.storedRows(for: item.url, from: item.pathVariables)
        setArray(&object, "variable", rows(pathRows, previous: previous?["variable"]?.array, canBeOff: false))
        return .object(object)
    }

    /// Rows as `{key, value}` objects. A row keeps what the file said of the row of the same name at the same
    /// place (a description, for instance), or of the first unused row of that name.
    private static func rows(_ rows: [KeyValue], previous: [JSONValue]?, canBeOff: Bool = true) -> [JSONValue] {
        var unused = previous ?? []
        return rows.enumerated().map { index, row in
            var object: [String: JSONValue] = [:]
            if index < (previous?.count ?? 0), previous?[index]["key"]?.text == row.key,
               let position = unused.firstIndex(of: previous?[index] ?? .null) {
                object = unused.remove(at: position).object ?? [:]
            } else if let position = unused.firstIndex(where: { $0["key"]?.text == row.key }) {
                object = unused.remove(at: position).object ?? [:]
            }
            object["key"] = .string(row.key)
            object["value"] = .string(row.value)
            object["disabled"] = canBeOff && !row.isEnabled ? .bool(true) : nil
            object[secretMarker] = row.isSecret ? .bool(true) : nil
            return .object(object)
        }
    }

    private static func body(_ body: RequestBody, previous: JSONValue?) -> JSONValue? {
        var object = previous?.object ?? [:]
        switch body.mode {
        case .none:
            return nil
        case .raw:
            object["mode"] = .string("raw")
            object["raw"] = .string(body.raw)
            object["options"] = .object(["raw": .object(["language": .string(body.rawLanguage.rawValue)])])
        case .urlEncoded:
            object["mode"] = .string("urlencoded")
            object["urlencoded"] = .array(rows(body.urlEncoded, previous: previous?["urlencoded"]?.array))
        case .formData:
            object["mode"] = .string("formdata")
            object["formdata"] = .array(body.formData.map { field in
                var entry: [String: JSONValue] = ["key": .string(field.key)]
                switch field.kind {
                case .text:
                    entry["type"] = .string("text")
                    entry["value"] = .string(field.value)
                case .file:
                    entry["type"] = .string("file")
                    entry["src"] = .string(field.value)
                }
                if !field.contentType.isEmpty { entry["contentType"] = .string(field.contentType) }
                if !field.isEnabled { entry["disabled"] = .bool(true) }
                if field.isSecret { entry[secretMarker] = .bool(true) }
                return .object(entry)
            })
        case .binary:
            object["mode"] = .string("file")
            object["file"] = .object(["src": .string(body.binaryPath)])
        case .graphQL:
            object["mode"] = .string("graphql")
            object["graphql"] = .object([
                "query": .string(body.graphQLQuery), "variables": .string(body.graphQLVariables),
            ])
        }
        return .object(object)
    }

    /// The authorization in Postman's shape. A credential is written only when it refers to a variable.
    private static func authorization(_ auth: AuthConfig) -> JSONValue {
        func field(_ key: String, _ value: String) -> JSONValue {
            .object(["key": .string(key), "value": .string(value), "type": .string("string")])
        }
        func credential(_ secret: SecretField) -> String {
            TemplateEngine.isPlaceholderOnly(secret.value) ? secret.value : ""
        }
        switch auth.kind {
        case .inherit, .none:
            return .object(["type": .string("noauth")])
        case .bearer:
            return .object(["type": .string("bearer"), "bearer": .array([field("token", credential(auth.bearerToken))])])
        case .basic:
            return .object(["type": .string("basic"), "basic": .array([
                field("username", auth.basicUsername), field("password", credential(auth.basicPassword)),
            ])])
        case .apiKey:
            return .object(["type": .string("apikey"), "apikey": .array([
                field("key", auth.apiKeyName), field("value", credential(auth.apiKeyValue)),
                field("in", auth.apiKeyLocation.rawValue),
            ])])
        }
    }

    /// True when both say the same without their credentials, which the file never holds.
    private static func sameAuthorization(_ read: AuthConfig, _ current: AuthConfig) -> Bool {
        var request = RequestItem(auth: current)
        request = withoutSecretValues(request)
        // At the top of a collection, "inherit" and "none" are one thing.
        let kinds: Set<AuthKind> = [read.kind, request.auth.kind]
        if kinds.isSubset(of: [.inherit, .none]) { return true }
        return RequestItem(auth: read).content(of: .authorization) == request.content(of: .authorization)
    }

    private static func events(pre: String, post: String) -> [JSONValue] {
        func event(_ listen: String, _ code: String) -> JSONValue? {
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let lines = code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { JSONValue.string(String($0)) }
            return .object([
                "listen": .string(listen),
                "script": .object(["type": .string("text/javascript"), "exec": .array(lines)]),
            ])
        }
        return [event("prerequest", pre), event("test", post)].compactMap { $0 }
    }

    /// The names of the variables. A value is never written; one that was already in the file stays there.
    private static func variables(_ variables: [Variable], previous: [JSONValue]?) -> [JSONValue] {
        // Each variable takes what the file said of the first unused one of its name: two of the same name
        // (one of them off, usually) stay two.
        var unused = previous ?? []
        return variables.filter { !$0.name.isEmpty }.map { variable in
            var object: [String: JSONValue] = [:]
            if let position = unused.firstIndex(where: { ($0["key"]?.string ?? $0["id"]?.string) == variable.name }) {
                object = unused.remove(at: position).object ?? [:]
            }
            object["key"] = .string(variable.name)
            if object["value"] == nil || variable.isSecret { object["value"] = .string("") }
            object["disabled"] = variable.isEnabled ? nil : .bool(true)
            object[secretMarker] = variable.isSecret ? .bool(true) : nil
            return .object(object)
        }
    }

    private static func setArray(_ object: inout [String: JSONValue], _ key: String, _ values: [JSONValue]) {
        object[key] = values.isEmpty ? nil : .array(values)
    }

    /// Sets or removes a text. `unchanged` keeps whatever shape the file gave it (a string or an object).
    private static func setText(
        _ object: inout [String: JSONValue], _ key: String, _ text: String, previous: JSONValue?, unchanged: Bool = false
    ) {
        if unchanged || (previous?.string ?? previous?["content"]?.string) == text { return }
        object[key] = text.isEmpty ? nil : .string(text)
    }

    // MARK: - Reading back

    /// The collection as it is now: what `file` says, with what only this Mac holds taken from `local` (the
    /// values of the variables, the secret values and their slots, what is kept under another kind of
    /// authorization or body). A request, a folder or a row the file does not change keeps its identity.
    ///
    /// - Parameter base: the file as it was when Bee last wrote or read it. With it, only what the file
    ///   changed since is taken: a change made in Bee that has not reached the file yet stands. Without it
    ///   the file wins wherever the two differ, and nothing held here is removed because the file lacks it.
    public static func merge(file: Collection, base: Collection? = nil, into local: Collection?) -> Collection {
        guard let local else { return file }
        // What was known of another collection says nothing of this one.
        let base = base?.id == file.id ? base : nil
        var result = local
        result.id = file.id
        if base?.name != file.name { result.name = file.name }
        if base?.notes != file.notes { result.notes = file.notes }
        if base.map({ sameAsRead($0.auth, file.auth, atTop: true) }) != true { result.auth = merged(file.auth, into: local.auth) }
        if base?.preRequestScript != file.preRequestScript { result.preRequestScript = file.preRequestScript }
        if base?.postResponseScript != file.postResponseScript { result.postResponseScript = file.postResponseScript }

        result.variables = merged(file.variables, base: base?.variables, into: local.variables)

        let tree = TreeMerge(file: file.items, base: base?.items, mine: local.items)
        let items = tree.children(file: file.items, base: base?.items, mine: local.items)
        var seen: Set<UUID> = []
        result.items = withoutRepeats(items + tree.leftOut(of: items), seen: &seen)
        return result
    }

    /// The variables of the file with the values held here. A file holds no value: a variable is told by
    /// its name, and by its rank among those of the same name. With `base`, only what the file changed is
    /// taken: a variable added, removed, turned off or made plain here and not yet in the file stands.
    private static func merged(_ file: [Variable], base: [Variable]?, into mine: [Variable]) -> [Variable] {
        func keyed(_ variables: [Variable]) -> [(key: String, variable: Variable)] {
            var ranks: [String: Int] = [:]
            return variables.map { variable in
                ranks[variable.name, default: 0] += 1
                return ("\(ranks[variable.name] ?? 1) \(variable.name)", variable)
            }
        }
        func shape(_ variables: [Variable]) -> [[String]] {
            variables.map { [$0.name, $0.isEnabled ? "on" : "off", $0.isSecret ? "secret" : "plain"] }
        }
        let here = Dictionary(keyed(mine).map { ($0.key, $0.variable) }, uniquingKeysWith: { first, _ in first })
        guard let base else {
            let there = Set(keyed(file).map(\.key))
            let taken = keyed(file).map { key, variable -> Variable in
                guard var kept = here[key] else { return variable }
                kept.isEnabled = variable.isEnabled
                // Marked secret by either side, it is a secret: a file never makes one plain.
                kept.isSecret = kept.isSecret || variable.isSecret
                return kept
            }
            // Nothing tells what was removed from what was added: what only this Mac holds stays.
            return taken + keyed(mine).filter { !there.contains($0.key) }.map(\.variable)
        }
        if shape(base) == shape(file) { return mine }
        let before = Dictionary(keyed(base).map { ($0.key, $0.variable) }, uniquingKeysWith: { first, _ in first })
        let there = Set(keyed(file).map(\.key))
        var result: [Variable] = []
        for (key, variable) in keyed(file) {
            guard var kept = here[key] else {
                // Not here: removed here if it was in the file before, new in the file otherwise.
                if before[key] == nil { result.append(variable) }
                continue
            }
            if before[key]?.isEnabled != variable.isEnabled { kept.isEnabled = variable.isEnabled }
            if before[key]?.isSecret != variable.isSecret { kept.isSecret = kept.isSecret || variable.isSecret }
            result.append(kept)
        }
        // Added here, and not in the file yet.
        result += keyed(mine).filter { before[$0.key] == nil && !there.contains($0.key) }.map(\.variable)
        return result
    }

    /// The tree of the file merged with the tree held here, folder by folder.
    private struct TreeMerge {
        private var file: [UUID: CollectionNode] = [:]
        private var base: [UUID: CollectionNode] = [:]
        private var mine: [UUID: CollectionNode] = [:]
        /// Every folder and request of both sides, those held here first, each before what it holds.
        private var order: [UUID] = []
        private let hasBase: Bool

        init(file: [CollectionNode], base: [CollectionNode]?, mine: [CollectionNode]) {
            hasBase = base != nil
            var ignored: [UUID] = []
            Self.index(mine, into: &self.mine, order: &order)
            Self.index(file, into: &self.file, order: &order)
            Self.index(base ?? [], into: &self.base, order: &ignored)
        }

        private static func index(_ nodes: [CollectionNode], into table: inout [UUID: CollectionNode], order: inout [UUID]) {
            for node in nodes {
                if table[node.id] == nil { order.append(node.id) }
                table[node.id] = node
                index(node.children ?? [], into: &table, order: &order)
            }
        }

        /// What the merge left out though neither side deleted it: a request one side put in a folder the
        /// other side deleted, or added there. It goes to the top of the collection rather than be lost.
        func leftOut(of merged: [CollectionNode]) -> [CollectionNode] {
            guard hasBase else { return [] }
            var kept: Set<UUID> = []
            func collect(_ nodes: [CollectionNode]) {
                for node in nodes {
                    kept.insert(node.id)
                    collect(node.children ?? [])
                }
            }
            collect(merged)
            var rescued: [CollectionNode] = []
            for id in order where !kept.contains(id) {
                let wasThere = base[id] != nil
                // Deleted in the file, or deleted here: it stays deleted.
                guard !(wasThere && file[id] == nil), !(wasThere && mine[id] == nil), let node = node(id) else { continue }
                rescued.append(node)
                collect([node])
            }
            return rescued
        }

        /// The content of a folder (or of the collection). A list only one side changed is that side's; when
        /// both did, it is the file's order without what was removed here, then what was added here. Without
        /// a base it is the file's order, then what only this Mac holds.
        func children(file: [CollectionNode]?, base: [CollectionNode]?, mine: [CollectionNode]?) -> [CollectionNode] {
            let order: [UUID]
            switch (file?.map(\.id), mine?.map(\.id)) {
            case (nil, nil): order = []
            case (let theirs?, nil): order = theirs
            case (nil, let ours?): order = ours
            case (let theirs?, let ours?):
                guard let before = base?.map(\.id) else {
                    // Nothing tells what was removed from what was added: nothing is dropped.
                    order = theirs + ours.filter { !theirs.contains($0) }
                    break
                }
                if theirs == before {
                    order = ours
                } else if ours == before {
                    order = theirs
                } else {
                    let removedHere = Set(before).subtracting(ours)
                    let known = Set(before).union(theirs)
                    order = theirs.filter { !removedHere.contains($0) } + ours.filter { !known.contains($0) }
                }
            }
            return order.compactMap(node)
        }

        private func node(_ id: UUID) -> CollectionNode? {
            switch (file[id], mine[id]) {
            case (nil, nil):
                return nil
            case (.request(let read)?, .request(let ours)?):
                var before: RequestItem?
                if case .request(let known)? = base[id] { before = known }
                return .request(CollectionFile.merged(read, base: before, into: ours))
            case (.folder(let read)?, .folder(let ours)?):
                var before: Folder?
                if case .folder(let known)? = base[id] { before = known }
                var folder = ours
                if before?.name != read.name { folder.name = read.name }
                if before?.notes != read.notes { folder.notes = read.notes }
                if before.map({ CollectionFile.sameAsRead($0.auth, read.auth) }) != true {
                    folder.auth = CollectionFile.merged(read.auth, into: ours.auth)
                }
                if before?.preRequestScript != read.preRequestScript { folder.preRequestScript = read.preRequestScript }
                if before?.postResponseScript != read.postResponseScript { folder.postResponseScript = read.postResponseScript }
                folder.items = children(file: read.items, base: before?.items, mine: ours.items)
                return .folder(folder)
            case (.folder(var read)?, nil):
                // A folder made in the file may hold requests that were already here.
                read.items = children(file: read.items, base: nil, mine: nil)
                return .folder(read)
            case (nil, .folder(var ours)?):
                // And a folder made here, requests the file changed.
                ours.items = children(file: nil, base: nil, mine: ours.items)
                return .folder(ours)
            case (let read?, _):
                return read
            case (nil, let ours?):
                return ours
            }
        }
    }

    /// The tree with each folder and request once: where two places hold the same one, the first keeps it.
    private static func withoutRepeats(_ nodes: [CollectionNode], seen: inout Set<UUID>) -> [CollectionNode] {
        var kept: [CollectionNode] = []
        for node in nodes where seen.insert(node.id).inserted {
            if case .folder(var folder) = node {
                folder.items = withoutRepeats(folder.items, seen: &seen)
                kept.append(.folder(folder))
            } else {
                kept.append(node)
            }
        }
        return kept
    }

    /// True when two authorizations read from files say the same.
    private static func sameAsRead(_ one: AuthConfig, _ other: AuthConfig, atTop: Bool = false) -> Bool {
        // At the top of a collection, "inherit" and "none" are one thing.
        if atTop, Set([one.kind, other.kind]).isSubset(of: [.inherit, .none]) { return true }
        return RequestItem(auth: one).content(of: .authorization) == RequestItem(auth: other).content(of: .authorization)
    }

    /// `mine` with the parts the file changed. A part is taken from the file only when it differs once the
    /// secrets of `mine` are put back in it: reading a file twice changes nothing. With `base`, a part the
    /// file says as it did then was not changed there, and `mine` keeps its own.
    static func merged(_ read: RequestItem, base: RequestItem? = nil, into mine: RequestItem) -> RequestItem {
        var restored = read
        var pathRows = restoring(read.pathVariables, from: mine.pathVariables)
        // A tool that drops what it does not know leaves no row for a secret path variable: it is still here.
        let names = PathVariables.names(in: read.url)
        for kept in mine.pathVariables where kept.isSecret && names.contains(kept.key) && !pathRows.contains(where: { $0.key == kept.key }) {
            pathRows.append(kept)
        }
        restored.pathVariables = pathRows
        restored.queryParams = restoring(read.queryParams, from: mine.queryParams)
        restored.headers = restoring(read.headers, from: mine.headers)
        restored.body.urlEncoded = restoring(read.body.urlEncoded, from: mine.body.urlEncoded)
        var unusedFields = mine.body.formData.filter(\.isSecret)
        restored.body.formData = read.body.formData.map { field in
            guard field.value.isEmpty, field.kind == .text,
                  let position = unusedFields.firstIndex(where: { $0.key == field.key }) else { return field }
            let kept = unusedFields.remove(at: position)
            var field = field
            field.id = kept.id
            field.value = kept.value
            field.isSecret = true
            return field
        }
        restored.auth = merged(read.auth, into: mine.auth)

        var result = mine
        if base?.name != read.name { result.name = read.name }
        if base?.notes != read.notes { result.notes = read.notes }
        for part in RequestPart.allCases {
            if let base, base.content(of: part) == read.content(of: part) { continue }
            if restored.content(of: part) != mine.content(of: part) { result.take(part, from: restored) }
        }
        return result
    }

    /// The rows of the file, each empty one taking back the secret of the row of the same name.
    private static func restoring(_ rows: [KeyValue], from mine: [KeyValue]) -> [KeyValue] {
        var unused = mine.filter(\.isSecret)
        return rows.map { row in
            guard row.value.isEmpty, let position = unused.firstIndex(where: { $0.key == row.key }) else { return row }
            var row = row
            let kept = unused.remove(at: position)
            row.id = kept.id
            row.value = kept.value
            row.isSecret = true
            return row
        }
    }

    /// The authorization of the file, each credential it leaves empty taken back from `mine`.
    private static func merged(_ read: AuthConfig, into mine: AuthConfig) -> AuthConfig {
        var result = mine
        result.kind = read.kind
        result.basicUsername = read.kind == .basic ? read.basicUsername : mine.basicUsername
        if read.kind == .apiKey {
            result.apiKeyName = read.apiKeyName
            result.apiKeyLocation = read.apiKeyLocation
        }
        func credential(_ read: SecretField, _ mine: SecretField) -> SecretField {
            read.value.isEmpty ? mine : SecretField(id: mine.id, value: read.value)
        }
        switch read.kind {
        case .bearer: result.bearerToken = credential(read.bearerToken, mine.bearerToken)
        case .basic: result.basicPassword = credential(read.basicPassword, mine.basicPassword)
        case .apiKey: result.apiKeyValue = credential(read.apiKeyValue, mine.apiKeyValue)
        case .inherit, .none: break
        }
        return result
    }
}
