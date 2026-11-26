import Foundation

// MARK: - Folder

public struct Folder: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    public var id: UUID
    public var name: String
    public var items: [CollectionNode]
    public var auth: AuthConfig
    public var preRequestScript: String
    public var postResponseScript: String
    public var notes: String

    public init(
        id: UUID = UUID(), name: String = "New folder", items: [CollectionNode] = [],
        auth: AuthConfig = AuthConfig(), preRequestScript: String = "", postResponseScript: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.auth = auth
        self.preRequestScript = preRequestScript
        self.postResponseScript = postResponseScript
        self.notes = notes
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        auth.forEachSecret(body)
        items.forEachSecret(body)
    }
}

// MARK: - Tree node

public indirect enum CollectionNode: Identifiable, Hashable, Sendable, SecretContaining {
    case folder(Folder)
    case request(RequestItem)

    public var id: UUID {
        switch self {
        case .folder(let folder): folder.id
        case .request(let request): request.id
        }
    }

    public var name: String {
        switch self {
        case .folder(let folder): folder.name
        case .request(let request): request.name
        }
    }

    public var children: [CollectionNode]? {
        if case .folder(let folder) = self { return folder.items }
        return nil
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        switch self {
        case .folder(var folder):
            folder.forEachSecret(body)
            self = .folder(folder)
        case .request(var request):
            request.forEachSecret(body)
            self = .request(request)
        }
    }
}

extension CollectionNode: Codable {
    private enum CodingKeys: String, CodingKey { case type, folder, request }
    private enum NodeType: String, Codable { case folder, request }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(NodeType.self, forKey: .type) {
        case .folder: self = .folder(try container.decode(Folder.self, forKey: .folder))
        case .request: self = .request(try container.decode(RequestItem.self, forKey: .request))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let folder):
            try container.encode(NodeType.folder, forKey: .type)
            try container.encode(folder, forKey: .folder)
        case .request(let request):
            try container.encode(NodeType.request, forKey: .type)
            try container.encode(request, forKey: .request)
        }
    }
}

// MARK: - Collection

public struct Collection: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    public var id: UUID
    public var name: String
    public var items: [CollectionNode]
    public var variables: [Variable]
    /// `inherit` at collection level means "no authorization".
    public var auth: AuthConfig
    public var preRequestScript: String
    public var postResponseScript: String
    public var notes: String

    public init(
        id: UUID = UUID(), name: String = "New collection", items: [CollectionNode] = [],
        variables: [Variable] = [], auth: AuthConfig = AuthConfig(kind: .none),
        preRequestScript: String = "", postResponseScript: String = "", notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.variables = variables
        self.auth = auth
        self.preRequestScript = preRequestScript
        self.postResponseScript = postResponseScript
        self.notes = notes
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        variables.forEachSecret(body)
        auth.forEachSecret(body)
        items.forEachSecret(body)
    }
}

// MARK: - Tree operations

public extension Collection {
    /// Every request of the collection, depth first.
    var allRequests: [RequestItem] {
        var result: [RequestItem] = []
        func walk(_ nodes: [CollectionNode]) {
            for node in nodes {
                switch node {
                case .folder(let folder): walk(folder.items)
                case .request(let request): result.append(request)
                }
            }
        }
        walk(items)
        return result
    }

    func node(id: UUID) -> CollectionNode? {
        func search(_ nodes: [CollectionNode]) -> CollectionNode? {
            for node in nodes {
                if node.id == id { return node }
                if case .folder(let folder) = node, let found = search(folder.items) { return found }
            }
            return nil
        }
        return search(items)
    }

    func request(id: UUID) -> RequestItem? {
        if case .request(let request) = node(id: id) { return request }
        return nil
    }

    func folder(id: UUID) -> Folder? {
        if case .folder(let folder) = node(id: id) { return folder }
        return nil
    }

    /// Where a request or a folder stands: the folder that holds it (`nil` for the collection itself) and
    /// its index among what that holds. `nil` when the collection has no such node.
    func place(of id: UUID) -> (folderID: UUID?, index: Int)? {
        func search(_ nodes: [CollectionNode], in folderID: UUID?) -> (folderID: UUID?, index: Int)? {
            for (index, node) in nodes.enumerated() {
                if node.id == id { return (folderID, index) }
                if case .folder(let folder) = node, let found = search(folder.items, in: folder.id) { return found }
            }
            return nil
        }
        return search(items, in: nil)
    }

    /// What holds a request or a folder, itself included: what the collection or its folder holds. `nil`
    /// when the collection has no such node.
    func siblings(of id: UUID) -> [CollectionNode]? {
        guard let place = place(of: id) else { return nil }
        guard let folderID = place.folderID else { return items }
        return folder(id: folderID)?.items
    }

    /// True when the folder `folderID` is the node `id` or stands inside it: a folder does not go there.
    func isFolder(_ folderID: UUID, within id: UUID) -> Bool {
        folderID == id || ancestry(of: folderID)?.contains { $0.id == id } == true
    }

    /// The collection as `order` shows it, at every level.
    func arranged(_ order: ListOrder) -> Collection {
        var arranged = self
        arranged.items = order.arrangedDeeply(items)
        return arranged
    }

    /// Where a node goes to stand right before or right after `target`, said as `insert(_:inFolder:at:)`
    /// reads it once the node has left its own place. `nil` when the collection has no such target, when
    /// the node would not move, or when it would go inside itself.
    func destination(of id: UUID, beside target: UUID, after: Bool) -> (folderID: UUID?, index: Int)? {
        guard id != target, let goal = place(of: target) else { return nil }
        if let folderID = goal.folderID, isFolder(folderID, within: id) { return nil }
        var index = goal.index + (after ? 1 : 0)
        if let from = place(of: id), from.folderID == goal.folderID {
            // Leaving its place first moves up what stood after it.
            if from.index < index { index -= 1 }
            if from.index == index { return nil }
        }
        return (goal.folderID, index)
    }

    /// The folders that contain the node, outermost first. `nil` when the node is not in the collection.
    func ancestry(of id: UUID) -> [Folder]? {
        func search(_ nodes: [CollectionNode], path: [Folder]) -> [Folder]? {
            for node in nodes {
                if node.id == id { return path }
                if case .folder(let folder) = node, let found = search(folder.items, path: path + [folder]) {
                    return found
                }
            }
            return nil
        }
        return search(items, path: [])
    }

    /// Replaces the node that has the same id as `node`. Returns false when it is not in the collection.
    @discardableResult
    mutating func replace(_ node: CollectionNode) -> Bool {
        func rewrite(_ nodes: inout [CollectionNode]) -> Bool {
            for index in nodes.indices {
                if nodes[index].id == node.id {
                    nodes[index] = node
                    return true
                }
                if case .folder(var folder) = nodes[index], rewrite(&folder.items) {
                    nodes[index] = .folder(folder)
                    return true
                }
            }
            return false
        }
        return rewrite(&items)
    }

    @discardableResult
    mutating func update(_ request: RequestItem) -> Bool { replace(.request(request)) }

    /// The collection with `request` standing where the request `originID` is: a fork is read and sent
    /// from the place of its original. `nil` when the collection has no such request.
    func placing(_ request: RequestItem, at originID: UUID) -> Collection? {
        func rewrite(_ nodes: inout [CollectionNode]) -> Bool {
            for index in nodes.indices {
                if case .request(let found) = nodes[index], found.id == originID {
                    nodes[index] = .request(request)
                    return true
                }
                if case .folder(var folder) = nodes[index], rewrite(&folder.items) {
                    nodes[index] = .folder(folder)
                    return true
                }
            }
            return false
        }
        var placed = self
        return rewrite(&placed.items) ? placed : nil
    }

    @discardableResult
    mutating func update(_ folder: Folder) -> Bool { replace(.folder(folder)) }

    /// Removes and returns the node with the given id.
    @discardableResult
    mutating func remove(id: UUID) -> CollectionNode? {
        func extract(_ nodes: inout [CollectionNode]) -> CollectionNode? {
            if let index = nodes.firstIndex(where: { $0.id == id }) {
                return nodes.remove(at: index)
            }
            for index in nodes.indices {
                if case .folder(var folder) = nodes[index], let removed = extract(&folder.items) {
                    nodes[index] = .folder(folder)
                    return removed
                }
            }
            return nil
        }
        return extract(&items)
    }

    /// Inserts a node in a folder (`nil` = the collection root) at `index` (`nil` = at the end).
    /// Returns false when the folder is not in the collection.
    @discardableResult
    mutating func insert(_ node: CollectionNode, inFolder folderID: UUID?, at index: Int? = nil) -> Bool {
        func place(_ nodes: inout [CollectionNode]) {
            let position = min(max(index ?? nodes.count, 0), nodes.count)
            nodes.insert(node, at: position)
        }
        guard let folderID else {
            place(&items)
            return true
        }
        func descend(_ nodes: inout [CollectionNode]) -> Bool {
            for nodeIndex in nodes.indices {
                guard case .folder(var folder) = nodes[nodeIndex] else { continue }
                if folder.id == folderID {
                    place(&folder.items)
                    nodes[nodeIndex] = .folder(folder)
                    return true
                }
                if descend(&folder.items) {
                    nodes[nodeIndex] = .folder(folder)
                    return true
                }
            }
            return false
        }
        return descend(&items)
    }
}

// MARK: - Environment

public struct Environment: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    public var id: UUID
    public var name: String
    public var variables: [Variable]

    public init(id: UUID = UUID(), name: String = "New environment", variables: [Variable] = []) {
        self.id = id
        self.name = name
        self.variables = variables
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        variables.forEachSecret(body)
    }
}

// MARK: - Workspace

/// Everything a person keeps: the in-memory aggregate the application edits and the store persists.
public struct Workspace: Hashable, Sendable, Codable, SecretContaining {
    public var collections: [Collection]
    public var environments: [Environment]
    /// Variables available whatever the active environment.
    public var globals: [Variable]
    public var activeEnvironmentID: UUID?
    /// One-off requests tried without being kept in a collection.
    public var scratchRequests: [RequestItem]
    /// Copies of collection requests to try things on. Kept on this Mac only, never in a collection.
    public var forks: [RequestFork]

    public init(
        collections: [Collection] = [], environments: [Environment] = [], globals: [Variable] = [],
        activeEnvironmentID: UUID? = nil, scratchRequests: [RequestItem] = [], forks: [RequestFork] = []
    ) {
        self.collections = collections
        self.environments = environments
        self.globals = globals
        self.activeEnvironmentID = activeEnvironmentID
        self.scratchRequests = scratchRequests
        self.forks = forks
    }

    private enum CodingKeys: String, CodingKey {
        case collections, environments, globals, activeEnvironmentID, scratchRequests, forks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collections = try container.decodeIfPresent([Collection].self, forKey: .collections) ?? []
        environments = try container.decodeIfPresent([Environment].self, forKey: .environments) ?? []
        globals = try container.decodeIfPresent([Variable].self, forKey: .globals) ?? []
        activeEnvironmentID = try container.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
        scratchRequests = try container.decodeIfPresent([RequestItem].self, forKey: .scratchRequests) ?? []
        forks = try container.decodeIfPresent([RequestFork].self, forKey: .forks) ?? []
    }

    public var activeEnvironment: Environment? {
        environments.first { $0.id == activeEnvironmentID }
    }

    /// The collection that contains the node with the given id.
    public func collection(containing nodeID: UUID) -> Collection? {
        collections.first { $0.node(id: nodeID) != nil }
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        collections.forEachSecret(body)
        environments.forEachSecret(body)
        globals.forEachSecret(body)
        scratchRequests.forEachSecret(body)
        forks.forEachSecret(body)
    }
}
