import Foundation
import Testing
@testable import BeeCore

@Suite struct CollectionFolderTests {
    private static func collection(_ name: String = "API") -> Collection {
        let request = RequestItem(
            name: "Me", url: "{{baseUrl}}/me",
            headers: [KeyValue(key: "X-Api-Key", value: "sk-header", isSecret: true)]
        )
        return Collection(
            name: name, items: [.request(request)],
            variables: [Variable(name: "baseUrl", value: "https://api.example.com")]
        )
    }

    private func makeFolder(_ directory: TemporaryDirectory) -> CollectionFolder {
CollectionFolder(folder: directory.url.appendingPathComponent("Shared"), stateFile: directory.file("shared.json"), usesTrash: false)
    }

    private func names(in directory: TemporaryDirectory) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("Shared").path)) ?? []).sorted()
    }

    @Test func eachCollectionGetsItsFileAndReadingItBackChangesNothing() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        let collections = [Self.collection("API"), Self.collection("API"), Self.collection("Bad/Name: here")]
        try await folder.write(collections)
        #expect(names(in: directory) == ["API 2.json", "API.json", "Bad-Name- here.json"])
        for name in names(in: directory) {
            let text = try String(contentsOf: directory.url.appendingPathComponent("Shared/\(name)"), encoding: .utf8)
            #expect(!text.contains("sk-header"))
            #expect(!text.contains("https://api.example.com"))
        }
        let reading = await folder.read(into: collections)
        #expect(!reading.changed)
        #expect(reading.warnings.isEmpty)

        // After a restart too: the folder remembers which file is which collection.
        let again = await makeFolder(directory).read(into: collections)
        #expect(!again.changed)
        #expect(again.collections == collections)
    }

    @Test func anEditMadeInAFileComesInAndPrivateDataStays() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        let local = Self.collection()
        try await folder.write([local])

        let file = directory.url.appendingPathComponent("Shared/API.json")
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "{{baseUrl}}/me", with: "{{baseUrl}}/me/v2")
        try Data(edited.utf8).write(to: file)

        let reading = await folder.read(into: [local])
        #expect(reading.changed)
        let request = try #require(reading.collections.first?.allRequests.first)
        #expect(request.url == "{{baseUrl}}/me/v2")
        #expect(request.id == local.allRequests.first?.id)
        #expect(request.headers == local.allRequests.first?.headers)
        #expect(reading.collections.first?.variables.first?.value == "https://api.example.com")
        #expect(!(await folder.read(into: reading.collections)).changed)
    }

    @Test func aFileDroppedInTheFolderBecomesACollectionAndIsPutInBeesForm() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        try await folder.write([])
        let dropped = """
        {"info": {"name": "Theirs", "schema": "\(CollectionFile.schema)"},
         "item": [{"name": "Call", "request": {"method": "GET", "url": "https://h/x",
            "header": [{"key": "Authorization", "value": "Bearer sk-in-file"}]}}]}
        """
        let file = directory.url.appendingPathComponent("Shared/from a colleague.json")
        try Data(dropped.utf8).write(to: file)

        let first = await folder.read(into: [])
        #expect(first.changed)
        let collection = try #require(first.collections.first)
        #expect(collection.name == "Theirs")
        #expect(collection.allRequests.first?.headers.first?.value == "Bearer sk-in-file")
        // The file now carries identifiers and no secret; reading it again finds the same collection.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(collection.id.uuidString))
        #expect(!text.contains("sk-in-file"))
        let second = await folder.read(into: first.collections)
        #expect(!second.changed)
        // Renamed in Bee, the file keeps the name its owner gave it.
        var renamed = collection
        renamed.name = "Renamed here"
        try await folder.write([renamed])
        #expect(names(in: directory) == ["from a colleague.json"])
    }

    @Test func aRenameIsFollowedAndADeletedCollectionLeavesTheFolder() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        var collection = Self.collection("First")
        try await folder.write([collection])
        collection.name = "Second"
        try await folder.write([collection])
        #expect(names(in: directory) == ["Second.json"])
        try await folder.write([])
        #expect(names(in: directory).isEmpty)
    }

    @Test func aFileChangedBySomeoneElseIsNeverOverwrittenNorAFileThatCannotBeRead() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        var collection = Self.collection()
        try await folder.write([collection])
        let file = directory.url.appendingPathComponent("Shared/API.json")

        // Someone saves the file while Bee holds a change of its own.
        let theirs = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\"Me\"", with: "\"Me, renamed in the file\"")
        try Data(theirs.utf8).write(to: file)
        collection.notes = "Changed in Bee"
        try await folder.write([collection])
        #expect(try String(contentsOf: file, encoding: .utf8) == theirs)
        // The reading takes their change in and keeps the one made here; the next write holds both.
        let reading = await folder.read(into: [collection])
        #expect(reading.collections.first?.allRequests.first?.name == "Me, renamed in the file")
        #expect(reading.collections.first?.notes == "Changed in Bee")
        collection = try #require(reading.collections.first)
        try await folder.write([collection])
        let both = try String(contentsOf: file, encoding: .utf8)
        #expect(both.contains("Me, renamed in the file"))
        #expect(both.contains("Changed in Bee"))

        // A file left half written is said once and left alone.
        try Data("{ not json".utf8).write(to: file)
        let broken = await folder.read(into: [collection])
        #expect(broken.warnings.count == 1)
        #expect(!broken.changed)
        #expect((await folder.read(into: [collection])).warnings.isEmpty)
        collection.notes = "Again"
        try await folder.write([collection])
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
        // Once it can be read again, what changed here meanwhile is not undone.
        try Data(both.replacingOccurrences(of: "Me, renamed in the file", with: "Me, mended").utf8).write(to: file)
        let mended = await folder.read(into: [collection])
        #expect(mended.collections.first?.allRequests.first?.name == "Me, mended")
        #expect(mended.collections.first?.notes == "Again")
    }

    @Test func whatTheFolderBroughtIsMergedIntoTheCollectionsAsTheyAreNow() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        let local = Self.collection()
        try await folder.write([local])
        let file = directory.url.appendingPathComponent("Shared/API.json")
        let theirs = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "{{baseUrl}}/me", with: "{{baseUrl}}/me/v2")
        try Data(theirs.utf8).write(to: file)
        let dropped = """
        {"info": {"name": "Theirs", "schema": "\(CollectionFile.schema)"}, "item": []}
        """
        try Data(dropped.utf8).write(to: directory.url.appendingPathComponent("Shared/Theirs.json"))

        // While the folder is read, a header is added here.
        let reading = await folder.read(into: [local])
        var typed = local
        var request = try #require(typed.allRequests.first)
        request.headers.append(KeyValue(key: "X-Typed", value: "meanwhile"))
        typed.update(request)
        // A save that started before the reading came back does not know the new collection: its file stays.
        try await folder.write([typed])
        #expect(names(in: directory) == ["API.json", "Theirs.json"])

        let merged = reading.applied(to: [typed])
        #expect(merged.count == 2)
        #expect(merged[0].allRequests.first?.url == "{{baseUrl}}/me/v2")
        #expect(merged[0].allRequests.first?.headers.map(\.key) == ["X-Api-Key", "X-Typed"])
        #expect(merged[0].allRequests.first?.headers.first?.value == "sk-header")
        try await folder.write(merged)
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("/me/v2"))
        #expect(written.contains("X-Typed"))
        #expect(!(await folder.read(into: merged)).changed)
        // Deleted here, the collection that came from the folder leaves it.
        try await folder.write([merged[0]])
        #expect(names(in: directory) == ["API.json"])
    }

    @Test func whatBeeKnewOfAFileIsKeptFromOneLaunchToTheNext() async throws {
        let directory = try TemporaryDirectory()
        let collection = Self.collection()
        try await makeFolder(directory).write([collection])
        let file = directory.url.appendingPathComponent("Shared/API.json")

        // A change made here never reached the file (Bee quit first): the file does not undo it.
        var changed = collection
        changed.notes = "Not in the file yet"
        let untouched = await makeFolder(directory).read(into: [changed])
        #expect(!untouched.changed)

        // And a file changed while Bee was closed brings its change without undoing that one.
        let theirs = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "{{baseUrl}}/me", with: "{{baseUrl}}/me/v2")
        try Data(theirs.utf8).write(to: file)
        let folder = makeFolder(directory)
        let reading = await folder.read(into: [changed])
        #expect(reading.collections.first?.notes == "Not in the file yet")
        #expect(reading.collections.first?.allRequests.first?.url == "{{baseUrl}}/me/v2")

        // A collection deleted here whose file is still there is not brought back by the next look.
        #expect(!(await folder.read(into: [])).changed)
        try await folder.write([])
        #expect(names(in: directory).isEmpty)
    }

    @Test func aFileOfAnotherToolKeepsWhatBeeDoesNotModelAndItsSecretsStayHere() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        try await folder.write([])
        let postman = """
        {"info": {"_postman_id": "\(UUID().uuidString)", "name": "Theirs", "schema": "\(CollectionFile.schema)"},
         "item": [{"name": "Call", "request": {"method": "GET", "url": "https://h/x",
            "header": [{"key": "Authorization", "value": "Bearer sk-in-file"}],
            "auth": {"type": "oauth2", "oauth2": [{"key": "accessToken", "value": "{{t}}"}]}},
            "response": [{"name": "Saved example", "code": 200}]}]}
        """
        let file = directory.url.appendingPathComponent("Shared/Theirs.json")
        try Data(postman.utf8).write(to: file)
        let first = await folder.read(into: [])
        let collection = try #require(first.collections.first)
        let normalized = try String(contentsOf: file, encoding: .utf8)
        #expect(normalized.contains("Saved example"))
        #expect(normalized.contains("oauth2"))
        #expect(!normalized.contains("sk-in-file"))
        try await folder.write(first.collections)
        #expect(try String(contentsOf: file, encoding: .utf8) == normalized)

        // Exported again over the file, without identifiers: the same request, with its secret.
        try Data(postman.replacingOccurrences(of: "Bearer sk-in-file", with: "").replacingOccurrences(of: "https://h/x", with: "https://h/y").utf8).write(to: file)
        let second = await folder.read(into: first.collections)
        let request = try #require(second.collections.first?.allRequests.first)
        #expect(second.collections.count == 1)
        #expect(request.id == collection.allRequests.first?.id)
        #expect(request.url == "https://h/y")
        #expect(request.headers.first?.value == "Bearer sk-in-file")
    }

    @Test func aFileHoldsOneCollectionAndARenameBySomeoneIsFollowed() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        let orders = Self.collection("Orders")
        try await folder.write([orders])
        let shared = directory.url.appendingPathComponent("Shared")

        // Renamed in the Finder, then a save before Bee looks: no second file, no second collection.
        try FileManager.default.moveItem(at: shared.appendingPathComponent("Orders.json"), to: shared.appendingPathComponent("Commandes.json"))
        try await folder.write([orders])
        #expect(names(in: directory) == ["Commandes.json"])
        let followed = await folder.read(into: [orders])
        #expect(followed.collections == [orders])
        var renamed = orders
        renamed.name = "Orders 2026"
        try await folder.write([renamed])
        #expect(names(in: directory) == ["Commandes.json"])

        // Another collection saved over that file: it takes the file, and the first one gets a new one.
        let other = Self.collection("Orders of a colleague")
        try CollectionFile.data(for: other).write(to: shared.appendingPathComponent("Commandes.json"))
        let reading = await folder.read(into: [renamed])
        #expect(reading.needsWriting)
        #expect(reading.collections.map(\.id) == [renamed.id, other.id])
        try await folder.write(reading.collections)
        #expect(names(in: directory) == ["Commandes.json", "Orders 2026.json"])
        let mine = try String(contentsOf: shared.appendingPathComponent("Orders 2026.json"), encoding: .utf8)
        #expect(mine.contains(renamed.id.uuidString))
        try await folder.write([renamed])
        #expect(names(in: directory) == ["Orders 2026.json"])
    }

    @Test func aFileWrittenAgainByAnotherToolUnderItsOwnIdentifiersIsStillTheCollection() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        let local = Self.collection()
        try await folder.write([local])
        let file = directory.url.appendingPathComponent("Shared/API.json")
        let exported = """
        {"info": {"_postman_id": "\(UUID().uuidString)", "name": "API", "schema": "\(CollectionFile.schema)"},
         "variable": [{"key": "baseUrl", "value": "https://their.example"}],
         "item": [{"id": "\(UUID().uuidString)", "name": "Me", "request": {"method": "GET", "url": "{{baseUrl}}/me/v2",
            "header": [{"key": "X-Api-Key", "value": ""}]}}]}
        """
        try Data(exported.utf8).write(to: file)
        let reading = await folder.read(into: [local])
        #expect(reading.collections.count == 1)
        #expect(!reading.needsWriting)
        let request = try #require(reading.collections.first?.allRequests.first)
        #expect(request.id == local.allRequests.first?.id)
        #expect(request.url == "{{baseUrl}}/me/v2")
        #expect(request.headers == local.allRequests.first?.headers)
        #expect(reading.collections.first?.variables == local.variables)
        try await folder.write(reading.collections)
        #expect(names(in: directory) == ["API.json"])
    }

    @Test func whatBeeKnewOfOneFolderSaysNothingOfAnother() async throws {
        let directory = try TemporaryDirectory()
        let old = Self.collection()
        // The other folder holds an older copy of the collection's file.
        let elsewhere = directory.url.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try CollectionFile.data(for: old).write(to: elsewhere.appendingPathComponent("API.json"))

        var current = old
        var request = try #require(current.allRequests.first)
        request.url = "{{baseUrl}}/me/v2"
        current.update(request)
        current.items.append(.request(RequestItem(name: "Made since", url: "{{baseUrl}}/since")))
        try await makeFolder(directory).write([current])

        // The folder setting changes: the older file wins where the two differ, and takes nothing away.
        let other = CollectionFolder(folder: elsewhere, stateFile: directory.file("shared.json"), usesTrash: false)
        let reading = await other.read(into: [current])
        #expect(reading.collections.first?.allRequests.map(\.name) == ["Me", "Made since"])
        #expect(reading.collections.first?.allRequests.first?.headers == current.allRequests.first?.headers)
    }

    @Test func aRenameThatOnlyChangesCaseIsNotACopy() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        let collection = Self.collection("api")
        try await folder.write([collection])
        let shared = directory.url.appendingPathComponent("Shared")
        try FileManager.default.moveItem(at: shared.appendingPathComponent("api.json"), to: shared.appendingPathComponent("Api.json"))
        #expect(names(in: directory) == ["Api.json"])

        let reading = await folder.read(into: [collection])
        #expect(reading.collections == [collection])
        var changed = collection
        changed.notes = "Still written"
        try await folder.write([changed])
        #expect(names(in: directory) == ["Api.json"])
        #expect(try String(contentsOf: shared.appendingPathComponent("Api.json"), encoding: .utf8).contains("Still written"))
        #expect(!(await folder.read(into: [changed])).changed)
    }

    @Test func aFileBeeCannotPutInItsOwnFormLeavesNoSecretInWhatBeeKeeps() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        try await folder.write([])
        let shared = directory.url.appendingPathComponent("Shared")
        let dropped = """
        {"info": {"name": "Theirs", "schema": "\(CollectionFile.schema)"},
         "item": [{"name": "Call", "request": {"method": "GET", "url": "https://h/x",
            "header": [{"key": "Authorization", "value": "Bearer sk-in-file"}]}}]}
        """
        try Data(dropped.utf8).write(to: shared.appendingPathComponent("Theirs.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shared.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shared.path) }

        let reading = await folder.read(into: [])
        #expect(reading.collections.first?.allRequests.first?.headers.first?.value == "Bearer sk-in-file")
        #expect(try String(contentsOf: shared.appendingPathComponent("Theirs.json"), encoding: .utf8).contains("sk-in-file"))
        let kept = directory.url.appendingPathComponent("shared.known")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: kept.path)) ?? [] {
            #expect(!(try String(contentsOf: kept.appendingPathComponent(name), encoding: .utf8)).contains("sk-in-file"))
        }
        // Read once: the same file is not taken in again at each look.
        #expect((await folder.read(into: reading.collections)).incoming.isEmpty)
    }

    @Test func aFileThatCannotBeWrittenDoesNotKeepTheOthersFromBeingWritten() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        var first = Self.collection("A")
        var second = Self.collection("B")
        try await folder.write([first, second])
        let shared = directory.url.appendingPathComponent("Shared")
        try FileManager.default.removeItem(at: shared.appendingPathComponent("A.json"))
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("A.json/in the way"), withIntermediateDirectories: true)

        first.notes = "Changed A"
        second.notes = "Changed B"
        await #expect(throws: (any Error).self) { try await folder.write([first, second]) }
        #expect(try String(contentsOf: shared.appendingPathComponent("B.json"), encoding: .utf8).contains("Changed B"))
    }

    @Test func aFileThatIsGoneIsWrittenAgainAndItsCollectionStays() async throws {
        let directory = try TemporaryDirectory()
        let folder = makeFolder(directory)
        let collection = Self.collection()
        try await folder.write([collection])
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Shared/API.json"))
        let reading = await folder.read(into: [collection])
        #expect(reading.collections == [collection])
        try await folder.write([collection])
        #expect(names(in: directory) == ["API.json"])
    }
}
