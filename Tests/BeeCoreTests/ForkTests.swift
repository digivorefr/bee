import Foundation
import Testing
@testable import BeeCore

@Suite struct ForkTests {
    private static func original() -> RequestItem {
        RequestItem(
            name: "Get ticket", method: .get, url: "{{baseUrl}}/tickets/:ticketId",
            pathVariables: [KeyValue(key: "ticketId", value: "42")],
            queryParams: [KeyValue(key: "expand", value: "author")],
            headers: [KeyValue(key: "X-Api-Key", value: "sk-original-key", isSecret: true), KeyValue(key: "Accept", value: "*/*")],
            auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "sk-original-token")),
            body: RequestBody(mode: .raw, raw: "{\"a\": 1}")
        )
    }

    private static func workspace(_ request: RequestItem) -> Workspace {
        let folder = Folder(name: "Tickets", items: [.request(request)])
        return Workspace(collections: [Collection(name: "API", items: [.folder(folder)])])
    }

    // MARK: Parts

    @Test func aCopyHasTheSamePartsWhateverItsIdentifiers() {
        let request = Self.original()
        let copy = request.duplicated()
        #expect(copy.headers[0].id != request.headers[0].id)
        for part in RequestPart.allCases {
            #expect(copy.content(of: part) == request.content(of: part))
        }
    }

    @Test func aPartChangesOnlyWithWhatItUses() {
        let request = Self.original()
        func changed(_ edit: (inout RequestItem) -> Void) -> [RequestPart] {
            var copy = request
            edit(&copy)
            return RequestPart.allCases.filter { copy.content(of: $0) != request.content(of: $0) }
        }
        #expect(changed { $0.method = .post } == [.address])
        #expect(changed { $0.url += "/x" } == [.address])
        #expect(changed { $0.pathVariables[0].value = "43" } == [.address])
        // A blank row for a path variable says nothing.
        #expect(changed { $0.url += "/:other"; $0.pathVariables.append(KeyValue(key: "other")) } == [.address])
        #expect(changed { $0.pathVariables.append(KeyValue(key: "unused")) }.isEmpty)
        #expect(changed { $0.queryParams[0].isEnabled = false } == [.parameters])
        #expect(changed { $0.headers[0].value = "sk-other-key" } == [.headers])
        #expect(changed { $0.headers[1].isSecret = true } == [.headers])
        #expect(changed { $0.auth.bearerToken.value = "sk-other-token" } == [.authorization])
        // The password kept under a bearer authorization is not part of it; nor a form kept under a raw body.
        #expect(changed { $0.auth.basicPassword.value = "hidden" }.isEmpty)
        #expect(changed { $0.body.urlEncoded = [KeyValue(key: "k", value: "v")] }.isEmpty)
        #expect(changed { $0.body.raw = "{}" } == [.body])
        #expect(changed { $0.body.mode = .none } == [.body])
        #expect(changed { $0.preRequestScript = "console.log(1)" } == [.preRequestScript])
        #expect(changed { $0.postResponseScript = "console.log(2)" } == [.postResponseScript])
        #expect(changed { $0.settings.timeout = 5 } == [.settings])
        #expect(changed { $0.name = "Renamed"; $0.notes = "n" }.isEmpty)
    }

    // MARK: Fork

    @Test func aForkStartsEqualWithItsOwnRowsAndSecretSlots() {
        let request = Self.original()
        let fork = RequestFork(of: request, name: "Fork")
        #expect(fork.originID == request.id)
        #expect(fork.id == fork.item.id)
        #expect(fork.id != request.id)
        #expect(fork.changedParts.isEmpty)
        #expect(ForkComparison(fork: fork, original: request).differing.isEmpty)

        let slots = [Set(request.secretSlots().keys), Set(fork.item.secretSlots().keys), Set(fork.base.secretSlots().keys)]
        #expect(slots[0].isDisjoint(with: slots[1]))
        #expect(slots[0].isDisjoint(with: slots[2]))
        #expect(slots[1].isDisjoint(with: slots[2]))
        #expect(fork.item.headers[0].value == "sk-original-key")
    }

    @Test func aForkNeverEncodesASecret() throws {
        var fork = RequestFork(of: Self.original(), name: "Fork")
        fork.item.headers[0].value = "sk-fork-key"
        let encoded = String(decoding: try JSONEncoder().encode(fork), as: UTF8.self)
        for secret in ["sk-original-key", "sk-original-token", "sk-fork-key"] {
            #expect(!encoded.contains(secret))
        }
        #expect(Set(fork.secretValues()) == ["sk-original-key", "sk-original-token", "sk-fork-key"])
        let decoded = try JSONDecoder().decode(RequestFork.self, from: Data(encoded.utf8))
        #expect(decoded.id == fork.id)
        #expect(decoded.name == "Fork")
    }

    @Test func untouchedPartsFollowTheOriginalAndTouchedOnesDoNot() {
        var request = Self.original()
        var fork = RequestFork(of: request, name: "Fork")
        fork.item.body.raw = "{\"a\": 2}"

        request.headers.append(KeyValue(key: "X-New", value: "1"))
        request.body.raw = "{\"a\": 3}"
        request.name = "Get one ticket"
        let moved = fork.follow(request)
        #expect(moved)

        // Headers were untouched in the fork: they follow, with rows of their own.
        #expect(fork.item.headers.map(\.key) == ["X-Api-Key", "Accept", "X-New"])
        #expect(fork.item.headers[2].id != request.headers[2].id)
        #expect(fork.item.name == "Get one ticket")
        // The body was changed in the fork: it stays, and both sides have now changed it.
        #expect(fork.item.body.raw == "{\"a\": 2}")
        let comparison = ForkComparison(fork: fork, original: request)
        #expect(comparison.state(of: .headers) == .same)
        #expect(comparison.state(of: .body) == .changedInBoth)
        #expect(comparison.conflicts == [.body])
        let movedAgain = fork.follow(request)
        #expect(!movedAgain)
    }

    @Test func aPartChangedTheSameWayOnBothSidesIsTheSame() {
        var request = Self.original()
        var fork = RequestFork(of: request, name: "Fork")
        fork.item.method = .post
        request.method = .post
        #expect(ForkComparison(fork: fork, original: request).state(of: .address) == .same)
        fork.item.method = .put
        #expect(ForkComparison(fork: fork, original: request).state(of: .address) == .changedInBoth)
    }

    // MARK: Workspace

    @Test func forksAreNamedApartAndOnlyForCollectionRequests() {
        let request = Self.original()
        var workspace = Self.workspace(request)
        workspace.scratchRequests = [RequestItem(name: "Scratch")]

        let names = (0..<3).compactMap { _ in workspace.addFork(of: request.id)?.name }
        #expect(names == ["Fork", "Fork 2", "Fork 3"])
        let named = workspace.addFork(of: request.id, name: "  Try v2  ")
        #expect(named?.name == "Try v2")
        #expect(workspace.forks(of: request.id).count == 4)
        let ofScratch = workspace.addFork(of: workspace.scratchRequests[0].id)
        let ofNothing = workspace.addFork(of: UUID())
        #expect(ofScratch == nil)
        #expect(ofNothing == nil)

        let fork = workspace.forks[0]
        #expect(workspace.placeID(of: fork.id) == request.id)
        #expect(workspace.placeID(of: request.id) == request.id)
    }

    @Test func mergingTakesWhatTheForkChangedAndKeepsTheOriginalsIdentity() throws {
        var request = Self.original()
        var workspace = Self.workspace(request)
        let addedFork = workspace.addFork(of: request.id)
        let fork = try #require(addedFork)
        let addedOther = workspace.addFork(of: request.id)
        let other = try #require(addedOther)
        var edited = fork.item
        edited.headers[0].value = "sk-fork-key"
        edited.body.raw = "{\"a\": 2}"
        edited.method = .post
        let stored = workspace.updateFork(edited)
        #expect(stored)

        // Meanwhile the original changes its parameters (the fork follows) and its body (a conflict).
        request.queryParams.append(KeyValue(key: "page", value: "2"))
        request.body.raw = "{\"a\": 3}"
        workspace.collections[0].update(request)
        let moved = workspace.forksFollow(request)
        #expect(Set(moved) == [fork.id, other.id])

        let comparison = ForkComparison(fork: try #require(workspace.fork(id: fork.id)), original: request)
        #expect(comparison.differing == [.address, .headers, .body])
        #expect(comparison.conflicts == [.body])

        let mergedInto = workspace.mergeFork(fork.id, keepingOriginal: [.body])
        #expect(mergedInto == request.id)
        let merged = try #require(workspace.collectionRequest(id: request.id))
        #expect(merged.id == request.id)
        #expect(merged.name == "Get ticket")
        #expect(merged.method == .post)
        #expect(merged.headers[0].value == "sk-fork-key")
        #expect(merged.queryParams.map(\.key) == ["expand", "page"])
        #expect(merged.body.raw == "{\"a\": 3}")
        // The merged fork is gone; the other one follows the new original.
        #expect(workspace.fork(id: fork.id) == nil)
        let follower = try #require(workspace.fork(id: other.id))
        #expect(follower.item.method == .post)
        #expect(follower.item.headers[0].value == "sk-fork-key")
        #expect(ForkComparison(fork: follower, original: merged).differing.isEmpty)
        // No secret slot is shared between the original and the fork that remains.
        #expect(Set(merged.secretSlots().keys).isDisjoint(with: follower.secretSlots().keys))
        // It is still in its folder.
        #expect(workspace.collections[0].ancestry(of: request.id)?.map(\.name) == ["Tickets"])
    }

    @Test func mergingAConflictTakesTheForkUnlessToldOtherwise() throws {
        var request = Self.original()
        var workspace = Self.workspace(request)
        let addedFork = workspace.addFork(of: request.id)
        let fork = try #require(addedFork)
        var edited = fork.item
        edited.body.raw = "fork"
        workspace.updateFork(edited)
        request.body.raw = "original"
        workspace.collections[0].update(request)
        workspace.forksFollow(request)

        workspace.mergeFork(fork.id)
        #expect(workspace.collectionRequest(id: request.id)?.body.raw == "fork")
        let again = workspace.mergeFork(fork.id)
        #expect(again == nil)
    }

    @Test func forksWithoutOriginalAreRemoved() throws {
        let request = Self.original()
        var workspace = Self.workspace(request)
        let addedFork = workspace.addFork(of: request.id)
        let fork = try #require(addedFork)
        workspace.collections[0].remove(id: request.id)
        let removed = workspace.removeForksWithoutOriginal()
        #expect(removed.map(\.id) == [fork.id])
        #expect(workspace.forks.isEmpty)
    }

    @Test func aPartOnlyTheOriginalChangedIsNeverMergedBack() throws {
        var request = Self.original()
        var workspace = Self.workspace(request)
        let added = workspace.addFork(of: request.id)
        let fork = try #require(added)

        // The fork changes its body, the original changes its own, then the fork puts its body back.
        var edited = fork.item
        edited.body.raw = "X"
        edited.method = .post
        workspace.updateFork(edited)
        request.body.raw = "Y"
        workspace.collections[0].update(request)
        workspace.forksFollow(request)
        edited.body.raw = "{\"a\": 1}"
        workspace.updateFork(edited)

        let current = try #require(workspace.fork(id: fork.id))
        let comparison = ForkComparison(fork: current, original: request)
        #expect(comparison.state(of: .body) == .changedInOriginal)
        #expect(comparison.differing == [.address])
        #expect(comparison.conflicts.isEmpty)

        workspace.mergeFork(fork.id)
        let merged = try #require(workspace.collectionRequest(id: request.id))
        #expect(merged.method == .post)
        #expect(merged.body.raw == "Y")
    }

    @Test func everyForkCatchesUpWithItsOriginal() throws {
        var request = Self.original()
        var workspace = Self.workspace(request)
        let added = workspace.addFork(of: request.id)
        let fork = try #require(added)
        // The original changes without its forks being told (another launch, a file changed on disk).
        request.settings.timeout = 3
        workspace.collections[0].update(request)
        let moved = workspace.forksFollowOriginals()
        #expect(moved == [fork.id])
        #expect(workspace.fork(id: fork.id)?.item.settings.timeout == 3)
        #expect(workspace.forksFollowOriginals().isEmpty)
    }

    @Test func takingAPartLeavesWhatIsKeptUnderAnotherKindOrMode() {
        var receiver = Self.original()
        receiver.auth.basicPassword.value = "sk-kept-password"
        receiver.body.formData = [FormField(key: "file", value: "sk-kept-field", isSecret: true)]
        var other = Self.original().duplicated()
        other.auth.bearerToken.value = "sk-new-token"
        other.body.raw = "new"

        let keptPassword = receiver.auth.basicPassword
        receiver.take(.authorization, from: other)
        receiver.take(.body, from: other)
        #expect(receiver.auth.bearerToken == other.auth.bearerToken)
        #expect(receiver.auth.basicPassword == keptPassword)
        #expect(receiver.body.raw == "new")
        #expect(receiver.body.formData.first?.value == "sk-kept-field")
        // What was taken is what `content(of:)` compares.
        #expect(receiver.content(of: .authorization) == other.content(of: .authorization))
        #expect(receiver.content(of: .body) == other.content(of: .body))
    }

    @Test func forksOfDeletedRequestsAreRemovedAndOnlyThose() throws {
        let request = Self.original()
        let other = RequestItem(name: "Other", url: "https://example.com")
        var workspace = Workspace(collections: [Collection(name: "API", items: [.request(request), .request(other)])])
        let addedFirst = workspace.addFork(of: request.id)
        let addedSecond = workspace.addFork(of: other.id)
        let first = try #require(addedFirst)
        let second = try #require(addedSecond)
        let removed = workspace.removeForks(ofOriginals: [request.id])
        #expect(removed.map(\.id) == [first.id])
        #expect(workspace.forks.map(\.id) == [second.id])
    }

    // MARK: Store and runner

    @Test func oneUnreadableForkDoesNotCostTheRestOfTheFile() async throws {
        let directory = try TemporaryDirectory()
        func store() -> WorkspaceStore { WorkspaceStore(directory: directory.url, vault: InMemoryVault()) }
        let request = Self.original()
        var workspace = Self.workspace(request)
        workspace.scratchRequests = [RequestItem(name: "Draft")]
        workspace.globals = [Variable(name: "g", value: "1")]
        let added = workspace.addFork(of: request.id, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let fork = try #require(added)
        try await store().save(workspace)

        // A fork entry this version cannot read, and one written without the optional fields.
        let file = directory.file("workspace.json")
        var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var forks = try #require(manifest["forks"] as? [[String: Any]])
        var bare = forks[0]
        bare.removeValue(forKey: "name")
        bare.removeValue(forKey: "createdAt")
        forks = [["originID": "not a uuid"], bare]
        manifest["forks"] = forks
        try JSONSerialization.data(withJSONObject: manifest).write(to: file)

        let loaded = await store().load()
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.workspace.scratchRequests.map(\.name) == ["Draft"])
        #expect(loaded.workspace.globals.map(\.name) == ["g"])
        #expect(loaded.workspace.forks.map(\.id) == [fork.id])
        #expect(loaded.workspace.forks.first?.name == "Fork")
    }


    @Test func forksAreStoredLocallyWithTheirSecretsInTheVault() async throws {
        let directory = try TemporaryDirectory()
        let provider = InMemoryKeyProvider()
        func store() -> WorkspaceStore {
            WorkspaceStore(directory: directory.url, vault: EncryptedFileVault(fileURL: directory.file("secrets.vault"), keyProvider: provider))
        }
        let request = Self.original()
        var workspace = Self.workspace(request)
        // A whole number of seconds, which is what the files keep of a date.
        let addedFork = workspace.addFork(of: request.id, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let fork = try #require(addedFork)
        var edited = fork.item
        edited.headers[0].value = "sk-fork-key"
        workspace.updateFork(edited)
        try await store().save(workspace)

        // The fork is in the local manifest, not in the collection file, and no file holds a secret.
        for file in directory.allFiles() where file.lastPathComponent != "secrets.vault" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("sk-"))
            if file.path.contains("/collections/") { #expect(!text.contains(fork.id.uuidString)) }
        }
        #expect(try String(contentsOf: directory.file("workspace.json"), encoding: .utf8).contains(fork.id.uuidString))

        let loaded = await store().load()
        let reloaded = try #require(loaded.workspace.fork(id: fork.id))
        #expect(reloaded.item.headers[0].value == "sk-fork-key")
        #expect(reloaded.base.headers[0].value == "sk-original-key")
        #expect(reloaded.changedParts == [.headers])
        #expect(loaded.workspace == workspace)
    }

    @Test func aForkWhoseOriginalIsGoneAtLoadBecomesAOneOffRequest() async throws {
        let directory = try TemporaryDirectory()
        func store() -> WorkspaceStore {
            WorkspaceStore(directory: directory.url, vault: InMemoryVault())
        }
        let request = Self.original()
        var workspace = Self.workspace(request)
        let addedFork = workspace.addFork(of: request.id, name: "Try v2")
        let fork = try #require(addedFork)
        try await store().save(workspace)
        for file in directory.allFiles() where file.path.contains("/collections/") {
            try FileManager.default.removeItem(at: file)
        }
        let loaded = await store().load()
        #expect(loaded.workspace.forks.isEmpty)
        #expect(loaded.workspace.scratchRequests.map(\.id) == [fork.id])
        #expect(loaded.workspace.scratchRequests.first?.name == "Get ticket (Try v2)")
    }
}
