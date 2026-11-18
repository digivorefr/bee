import Foundation

// MARK: - Parts of a request

/// A part of a request that a fork may change and a merge takes whole. The parts are the sections of
/// the request page, in wire order.
public enum RequestPart: String, CaseIterable, Hashable, Sendable, Codable, Identifiable {
    case address, parameters, authorization, headers, body, preRequestScript, postResponseScript, settings

    public var id: String { rawValue }
}

public extension RequestItem {
    /// What a part says, without what only tells rows apart: two requests have the same part when
    /// these are equal, whatever their identifiers. Fields that the part does not use (the password
    /// kept under a bearer authorization, the raw text kept under a form body) are left out.
    func content(of part: RequestPart) -> AnyHashable {
        func rows(_ rows: [KeyValue]) -> [[String]] {
            rows.map { [$0.key, $0.value, $0.isEnabled ? "on" : "off", $0.isSecret ? "secret" : "plain"] }
        }
        switch part {
        case .address:
            // Only the rows that say something count: a blank row is the same as no row.
            let pathRows = PathVariables.storedRows(for: url, from: pathVariables)
            return AnyHashable([[method.rawValue, url]] + rows(pathRows))
        case .parameters:
            return AnyHashable(rows(queryParams))
        case .authorization:
            switch auth.kind {
            case .inherit, .none: return AnyHashable([auth.kind.rawValue])
            case .bearer: return AnyHashable([auth.kind.rawValue, auth.bearerToken.value])
            case .basic: return AnyHashable([auth.kind.rawValue, auth.basicUsername, auth.basicPassword.value])
            case .apiKey:
                return AnyHashable([auth.kind.rawValue, auth.apiKeyName, auth.apiKeyValue.value, auth.apiKeyLocation.rawValue])
            }
        case .headers:
            return AnyHashable(rows(headers))
        case .body:
            switch body.mode {
            case .none: return AnyHashable([[body.mode.rawValue]])
            case .raw: return AnyHashable([[body.mode.rawValue, body.rawLanguage.rawValue, body.raw]])
            case .urlEncoded: return AnyHashable([[body.mode.rawValue]] + rows(body.urlEncoded))
            case .formData:
                return AnyHashable([[body.mode.rawValue]] + body.formData.map {
                    [$0.key, $0.kind.rawValue, $0.value, $0.contentType, $0.isEnabled ? "on" : "off", $0.isSecret ? "secret" : "plain"]
                })
            case .binary: return AnyHashable([[body.mode.rawValue, body.binaryPath]])
            case .graphQL: return AnyHashable([[body.mode.rawValue, body.graphQLQuery, body.graphQLVariables]])
            }
        case .preRequestScript:
            return AnyHashable(preRequestScript)
        case .postResponseScript:
            return AnyHashable(postResponseScript)
        case .settings:
            return AnyHashable(settings)
        }
    }

    /// Replaces a part by the one of `other`, rows and secret slots included, identifiers as they are.
    /// Take from a `duplicated()` copy when both requests go on living.
    mutating func take(_ part: RequestPart, from other: RequestItem) {
        switch part {
        case .address:
            method = other.method
            url = other.url
            pathVariables = other.pathVariables
        case .parameters: queryParams = other.queryParams
        case .authorization:
            // Only what the kind uses, as `content(of:)` reads it: a credential kept under another kind
            // is not part of the change and stays where it is.
            auth.kind = other.auth.kind
            switch other.auth.kind {
            case .inherit, .none: break
            case .bearer: auth.bearerToken = other.auth.bearerToken
            case .basic:
                auth.basicUsername = other.auth.basicUsername
                auth.basicPassword = other.auth.basicPassword
            case .apiKey:
                auth.apiKeyName = other.auth.apiKeyName
                auth.apiKeyValue = other.auth.apiKeyValue
                auth.apiKeyLocation = other.auth.apiKeyLocation
            }
        case .headers: headers = other.headers
        case .body:
            // Likewise: the content kept under another mode stays.
            body.mode = other.body.mode
            switch other.body.mode {
            case .none: break
            case .raw:
                body.raw = other.body.raw
                body.rawLanguage = other.body.rawLanguage
            case .urlEncoded: body.urlEncoded = other.body.urlEncoded
            case .formData: body.formData = other.body.formData
            case .binary: body.binaryPath = other.body.binaryPath
            case .graphQL:
                body.graphQLQuery = other.body.graphQLQuery
                body.graphQLVariables = other.body.graphQLVariables
            }
        case .preRequestScript: preRequestScript = other.preRequestScript
        case .postResponseScript: postResponseScript = other.postResponseScript
        case .settings: settings = other.settings
        }
    }
}

// MARK: - Fork

/// A copy of a request of a collection to try things on without touching the original.
///
/// A fork is kept on this Mac only, never in the collection. The parts it has not changed follow the
/// original; the parts it has changed are its own until it is merged into the original or discarded.
public struct RequestFork: Identifiable, Hashable, Sendable, Codable, SecretContaining {
    /// The request this is a fork of.
    public var originID: UUID
    public var name: String
    /// The request as edited in the fork. Its identifier is the identifier of the fork.
    public var item: RequestItem
    /// The original as the fork last saw it: what tells a part the fork changed from one it only follows.
    /// It has its own secret slots, so the comparison holds for secret values too.
    public var base: RequestItem
    public var createdAt: Date
    /// What the agent that suggested the fork calls itself. `nil` for a fork the person made, and from
    /// the moment they edit one an agent suggested: it is then theirs, and no agent revises it.
    public var proposedBy: String?

    public var id: UUID { item.id }

    public init(of original: RequestItem, name: String, createdAt: Date = Date()) {
        originID = original.id
        self.name = name
        item = original.duplicated()
        base = original.duplicated()
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case originID, name, item, base, createdAt, proposedBy }

    /// Only the fork's request and its original's identifier are needed: the rest has a fallback, so a
    /// file written by another version still opens.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originID = try container.decode(UUID.self, forKey: .originID)
        item = try container.decode(RequestItem.self, forKey: .item)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Fork"
        // Without a base, everything the fork holds counts as its own.
        base = try container.decodeIfPresent(RequestItem.self, forKey: .base) ?? RequestItem(name: item.name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        proposedBy = try container.decodeIfPresent(String.self, forKey: .proposedBy)
    }

    public mutating func forEachSecret(_ body: (UUID, inout String) -> Void) {
        item.forEachSecret(body)
        base.forEachSecret(body)
    }

    /// The parts the fork changed.
    public var changedParts: [RequestPart] {
        RequestPart.allCases.filter { item.content(of: $0) != base.content(of: $0) }
    }

    /// Brings the parts the fork has not changed up to date with the original.
    /// Returns true when something moved.
    @discardableResult
    public mutating func follow(_ original: RequestItem) -> Bool {
        var moved = false
        for part in RequestPart.allCases where item.content(of: part) == base.content(of: part)
            && original.content(of: part) != base.content(of: part) {
            // Two copies: the fork and its base never share a row or a secret slot with anything.
            item.take(part, from: original.duplicated())
            base.take(part, from: original.duplicated())
            moved = true
        }
        if item.name != original.name {
            item.name = original.name
            base.name = original.name
            moved = true
        }
        return moved
    }
}

// MARK: - Comparison with the original

public enum ForkPartState: Hashable, Sendable {
    /// The fork says what the original says.
    case same
    /// Only the fork changed the part: a merge takes it.
    case changedInFork
    /// Only the original changed the part, and the fork has not caught up yet: a merge leaves it alone.
    case changedInOriginal
    /// The fork changed the part and so did the original since: a merge needs a choice.
    case changedInBoth
}

/// Where a fork stands against its original, part by part.
public struct ForkComparison: Hashable, Sendable {
    public private(set) var states: [RequestPart: ForkPartState] = [:]

    public init(fork: RequestFork, original: RequestItem) {
        for part in RequestPart.allCases {
            let forked = fork.item.content(of: part)
            let current = original.content(of: part)
            let based = fork.base.content(of: part)
            if forked == current {
                states[part] = .same
            } else if current == based {
                states[part] = .changedInFork
            } else if forked == based {
                // The fork still says what it started from: it is the original that moved.
                states[part] = .changedInOriginal
            } else {
                states[part] = .changedInBoth
            }
        }
    }

    public func state(of part: RequestPart) -> ForkPartState { states[part] ?? .same }

    /// The parts the fork changed and a merge would put in the original, in wire order.
    public var differing: [RequestPart] {
        RequestPart.allCases.filter { state(of: $0) == .changedInFork || state(of: $0) == .changedInBoth }
    }

    /// The parts both sides changed, in wire order.
    public var conflicts: [RequestPart] { RequestPart.allCases.filter { state(of: $0) == .changedInBoth } }
}

// MARK: - Forks in the workspace

public extension Workspace {
    /// The request of a collection with the given id.
    func collectionRequest(id: UUID) -> RequestItem? {
        for collection in collections {
            if let request = collection.request(id: id) { return request }
        }
        return nil
    }

    func fork(id: UUID) -> RequestFork? { forks.first { $0.id == id } }

    /// The forks of a request, oldest first.
    func forks(of originID: UUID) -> [RequestFork] { forks.filter { $0.originID == originID } }

    /// Where a request stands in its collection: itself, or its original for a fork.
    func placeID(of requestID: UUID) -> UUID { fork(id: requestID)?.originID ?? requestID }

    /// Forks a request of a collection. `nil` when the request is not in a collection.
    @discardableResult
    mutating func addFork(of originID: UUID, name: String? = nil, createdAt: Date = Date()) -> RequestFork? {
        guard let original = collectionRequest(id: originID) else { return nil }
        let taken = Set(forks(of: originID).map(\.name))
        var chosen = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if chosen.isEmpty {
            chosen = "Fork"
            var number = 2
            while taken.contains(chosen) {
                chosen = "Fork \(number)"
                number += 1
            }
        }
        let fork = RequestFork(of: original, name: chosen, createdAt: createdAt)
        forks.append(fork)
        return fork
    }

    /// Stores the request of a fork as the person edited it, which makes a fork an agent suggested their
    /// own. Returns false when no fork has that id.
    @discardableResult
    mutating func updateFork(_ item: RequestItem) -> Bool {
        guard let index = forks.firstIndex(where: { $0.id == item.id }) else { return false }
        // What counts as an edit is what a part says, not what only tells rows apart.
        if RequestPart.allCases.contains(where: { forks[index].item.content(of: $0) != item.content(of: $0) }) {
            forks[index].proposedBy = nil
        }
        forks[index].item = item
        return true
    }

    /// Stores what an agent suggests in a fork, part by part so the rows and the secret slots of the fork
    /// stay its own. Returns false when no fork has that id.
    @discardableResult
    mutating func suggest(_ changed: RequestItem, inFork forkID: UUID, by agent: String) -> Bool {
        guard let index = forks.firstIndex(where: { $0.id == forkID }) else { return false }
        for part in RequestPart.allCases where changed.content(of: part) != forks[index].item.content(of: part) {
            forks[index].item.take(part, from: changed.duplicated())
        }
        forks[index].proposedBy = agent
        return true
    }

    mutating func renameFork(_ forkID: UUID, to name: String) {
        guard let index = forks.firstIndex(where: { $0.id == forkID }) else { return }
        forks[index].name = name
    }

    @discardableResult
    mutating func removeFork(_ forkID: UUID) -> RequestFork? {
        guard let index = forks.firstIndex(where: { $0.id == forkID }) else { return nil }
        return forks.remove(at: index)
    }

    /// After the original changed: its forks follow it for the parts they have not changed.
    /// Returns the forks that moved.
    @discardableResult
    mutating func forksFollow(_ original: RequestItem) -> [UUID] {
        var moved: [UUID] = []
        for index in forks.indices where forks[index].originID == original.id {
            if forks[index].follow(original) { moved.append(forks[index].id) }
        }
        return moved
    }

    /// Merges a fork into its original, then removes it. The parts only the fork changed are taken; a part
    /// both changed is taken too unless listed in `keepingOriginal`. The original keeps its identifier and
    /// its name. Returns the original's id, or `nil` when the fork or its original is gone.
    @discardableResult
    mutating func mergeFork(_ forkID: UUID, keepingOriginal: Set<RequestPart> = []) -> UUID? {
        guard let fork = fork(id: forkID), var original = collectionRequest(id: fork.originID),
              let collection = collections.firstIndex(where: { $0.request(id: fork.originID) != nil })
        else { return nil }
        let comparison = ForkComparison(fork: fork, original: original)
        for part in comparison.differing where !(comparison.state(of: part) == .changedInBoth && keepingOriginal.contains(part)) {
            // The fork is removed right after: the original takes over its rows and its secret slots.
            original.take(part, from: fork.item)
        }
        collections[collection].update(original)
        removeFork(forkID)
        forksFollow(original)
        return original.id
    }

    /// Every fork follows its original as it is now. Returns the forks that moved.
    @discardableResult
    mutating func forksFollowOriginals() -> [UUID] {
        var moved: [UUID] = []
        for index in forks.indices {
            guard let original = collectionRequest(id: forks[index].originID) else { continue }
            if forks[index].follow(original) { moved.append(forks[index].id) }
        }
        return moved
    }

    /// Removes the forks of the given requests (requests that were just deleted). Returns them.
    @discardableResult
    mutating func removeForks(ofOriginals originIDs: Set<UUID>) -> [RequestFork] {
        let removed = forks.filter { originIDs.contains($0.originID) }
        forks.removeAll { originIDs.contains($0.originID) }
        return removed
    }

    /// Removes the forks whose original is no longer in a collection. Returns them.
    @discardableResult
    mutating func removeForksWithoutOriginal() -> [RequestFork] {
        let orphans = forks.filter { collectionRequest(id: $0.originID) == nil }
        forks.removeAll { fork in orphans.contains { $0.id == fork.id } }
        return orphans
    }
}
