import Foundation
import Testing
@testable import BeeCore

@Suite struct CollectionFileTests {
    private static func collection() -> Collection {
        var login = RequestItem(
            name: "Login", method: .post, url: "{{baseUrl}}/users/:userId/login",
            pathVariables: [KeyValue(key: "userId", value: "42")],
            queryParams: [KeyValue(key: "verbose", value: "1"), KeyValue(key: "token", value: "sk-query", isSecret: true)],
            headers: [
                KeyValue(key: "X-Api-Key", value: "sk-header", isSecret: true),
                KeyValue(key: "X-Ref", value: "{{apiToken}}", isSecret: true),
                KeyValue(key: "Accept", value: "*/*", isEnabled: false),
            ],
            auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "sk-bearer")),
            body: RequestBody(mode: .raw, raw: "{\"a\": 1}", rawLanguage: .json),
            preRequestScript: "console.log('pre')\nconsole.log('again')", postResponseScript: "bee.test('ok', () => {})",
            settings: RequestSettings(timeout: 5, followRedirects: false, verifyTLS: nil)
        )
        login.body.urlEncoded = [KeyValue(key: "kept", value: "under another mode")]
        let ping = RequestItem(name: "Ping", url: "{{baseUrl}}/ping")
        let folder = Folder(
            name: "Auth", items: [.request(login)],
            auth: AuthConfig(kind: .basic, basicUsername: "bee", basicPassword: SecretField(value: "sk-basic")),
            preRequestScript: "console.log('folder')", notes: "Folder notes"
        )
        return Collection(
            name: "API", items: [.folder(folder), .request(ping)],
            variables: [
                Variable(name: "baseUrl", value: "https://api.example.com"),
                Variable(name: "apiToken", value: "sk-variable", isSecret: true),
            ],
            auth: AuthConfig(kind: .apiKey, apiKeyName: "X-Key", apiKeyValue: SecretField(value: "sk-apikey"), apiKeyLocation: .query),
            postResponseScript: "console.log('collection')", notes: "About this API"
        )
    }

    private static let secrets = ["sk-query", "sk-header", "sk-bearer", "sk-basic", "sk-variable", "sk-apikey"]

    private func text(_ collection: Collection, previous: Data? = nil) throws -> String {
        String(decoding: try CollectionFile.data(for: collection, previous: previous), as: UTF8.self)
    }

    @Test func theFileHoldsNoSecretAndNoVariableValue() throws {
        let written = try text(Self.collection())
        for secret in Self.secrets { #expect(!written.contains(secret)) }
        #expect(!written.contains("https://api.example.com"))
        // What is shared is there: names of variables, references to them, the marker of a secret.
        #expect(written.contains("\"baseUrl\""))
        #expect(written.contains("{{apiToken}}"))
        #expect(written.contains("\"beeSecret\" : true"))
        #expect(written.contains("v2.1.0/collection.json"))
        // What is kept under another body mode is not shared either.
        #expect(!written.contains("under another mode"))
    }

    @Test func aFileReadBackIntoItsCollectionChangesNothing() throws {
        let collection = Self.collection()
        let data = try CollectionFile.data(for: collection)
        let read = try CollectionFile.read(data)
        #expect(read.id == collection.id)
        #expect(read.allRequests.map(\.id) == collection.allRequests.map(\.id))
        #expect(read.secretValues() == ["{{apiToken}}"])

        let merged = CollectionFile.merge(file: read, into: collection)
        #expect(merged == collection)
        // And the file written again is the same, byte for byte.
        #expect(try CollectionFile.data(for: merged, previous: data) == data)
    }

    @Test func aFileAloneGivesTheSharedPartOfTheCollection() throws {
        let collection = Self.collection()
        let read = CollectionFile.merge(file: try CollectionFile.read(try CollectionFile.data(for: collection)), into: nil)
        let login = try #require(read.allRequests.first)
        let original = try #require(collection.allRequests.first)
        #expect(read.name == "API")
        #expect(read.notes == "About this API")
        #expect(read.variables.map(\.name) == ["baseUrl", "apiToken"])
        #expect(read.variables.map(\.value) == ["", ""])
        #expect(read.variables[1].isSecret)
        #expect(read.auth.kind == .apiKey)
        #expect(read.auth.apiKeyLocation == .query)
        #expect(read.folder(id: collection.items[0].id)?.auth.basicUsername == "bee")
        #expect(login.method == .post)
        #expect(login.url == original.url)
        #expect(login.pathVariables.map(\.value) == ["42"])
        #expect(login.queryParams.map(\.key) == ["verbose", "token"])
        #expect(login.queryParams[1].isSecret)
        #expect(login.queryParams[1].value.isEmpty)
        #expect(login.headers.map(\.isSecret) == [true, true, false])
        #expect(login.headers[1].value == "{{apiToken}}")
        #expect(!login.headers[2].isEnabled)
        #expect(login.body.raw == "{\"a\": 1}")
        #expect(login.preRequestScript == original.preRequestScript)
        #expect(login.postResponseScript == original.postResponseScript)
        #expect(login.settings == original.settings)
    }

    @Test func whatBeeDoesNotModelSurvivesItsEdits() throws {
        let id = UUID()
        let foreign = """
        {"info": {"_postman_id": "\(UUID().uuidString)", "name": "Theirs", "schema": "\(CollectionFile.schema)", "version": "3"},
         "custom": {"kept": true},
         "variable": [{"key": "baseUrl", "value": "https://their.example", "description": "Their note"}],
         "item": [{"id": "\(id.uuidString)", "name": "Call",
            "request": {"method": "GET",
              "url": {"raw": "{{baseUrl}}/x?a=1", "host": ["{{baseUrl}}"], "path": ["x"], "query": [{"key": "a", "value": "1", "description": "Why a"}]},
              "header": [{"key": "Accept", "value": "*/*", "description": "Why accept"}],
              "auth": {"type": "oauth2", "oauth2": [{"key": "accessToken", "value": "{{t}}"}]}},
            "response": [{"name": "Saved example", "code": 200}]}]}
        """
        let previous = Data(foreign.utf8)
        var collection = try CollectionFile.read(previous)
        #expect(collection.allRequests.first?.id == id)

        // Untouched: the file is rewritten with the same content.
        let untouched = try JSONDecoder().decode(JSONValue.self, from: try CollectionFile.data(for: collection, previous: previous))
        #expect(untouched["custom"]?["kept"]?.bool == true)
        #expect(untouched["info"]?["version"]?.string == "3")
        #expect(untouched["variable"]?.array?.first?["value"]?.string == "https://their.example")
        let call = try #require(untouched["item"]?.array?.first)
        #expect(call["response"]?.array?.count == 1)
        #expect(call["request"]?["auth"]?["type"]?.string == "oauth2")
        #expect(call["request"]?["url"]?["host"]?.array?.count == 1)
        #expect(call["request"]?["header"]?.array?.first?["description"]?.string == "Why accept")

        // One part changed in Bee: only that part is rewritten.
        var request = try #require(collection.allRequests.first)
        request.headers.append(KeyValue(key: "X-New", value: "1"))
        collection.update(request)
        let edited = try JSONDecoder().decode(JSONValue.self, from: try CollectionFile.data(for: collection, previous: previous))
        let after = try #require(edited["item"]?.array?.first)
        #expect(after["request"]?["header"]?.array?.count == 2)
        #expect(after["request"]?["header"]?.array?.first?["description"]?.string == "Why accept")
        #expect(after["request"]?["auth"]?["type"]?.string == "oauth2")
        #expect(after["request"]?["url"]?["query"]?.array?.first?["description"]?.string == "Why a")
        #expect(after["response"]?.array?.count == 1)
    }

    @Test func anEditMadeInTheFileIsTakenWithoutLosingWhatIsPrivate() throws {
        let local = Self.collection()
        var theirs = local
        var login = try #require(theirs.allRequests.first)
        login.headers.append(KeyValue(key: "X-Added", value: "by a colleague"))
        login.body.raw = "{\"a\": 2}"
        theirs.update(login)
        theirs.items.append(.request(RequestItem(name: "New one", url: "{{baseUrl}}/new")))
        theirs.items.removeAll { $0.name == "Ping" }
        theirs.variables.append(Variable(name: "region", value: "not shared"))

        let merged = CollectionFile.merge(file: try CollectionFile.read(try CollectionFile.data(for: theirs)), into: local)
        let result = try #require(merged.request(id: login.id))
        let before = try #require(local.request(id: login.id))
        #expect(result.headers.map(\.key) == ["X-Api-Key", "X-Ref", "Accept", "X-Added"])
        #expect(result.headers[0] == before.headers[0])
        #expect(result.body.raw == "{\"a\": 2}")
        #expect(result.body.urlEncoded == before.body.urlEncoded)
        // Untouched parts keep their rows, their secrets and their slots.
        #expect(result.queryParams == before.queryParams)
        #expect(result.auth == before.auth)
        #expect(merged.auth == local.auth)
        #expect(merged.variables.map(\.value) == ["https://api.example.com", "sk-variable", ""])
        // Without what Bee knew of the file, a request the file lacks may be one made here: it stays.
        #expect(merged.allRequests.map(\.name) == ["Login", "New one", "Ping"])
        let known = try CollectionFile.read(try CollectionFile.data(for: local))
        let informed = CollectionFile.merge(file: try CollectionFile.read(try CollectionFile.data(for: theirs)), base: known, into: local)
        #expect(informed.allRequests.map(\.name) == ["Login", "New one"])
    }

    @Test func aSecretWrittenInSomeoneElsesFileIsKeptHereAndTakenOutOfTheFile() throws {
        let foreign = """
        {"info": {"name": "Theirs", "schema": "\(CollectionFile.schema)"},
         "item": [{"name": "Call", "request": {"method": "GET", "url": "https://h/x",
            "header": [{"key": "Authorization", "value": "Bearer sk-in-file"}]}}]}
        """
        let previous = Data(foreign.utf8)
        let collection = CollectionFile.merge(file: try CollectionFile.read(previous), into: nil)
        let header = try #require(collection.allRequests.first?.headers.first)
        #expect(header.isSecret)
        #expect(header.value == "Bearer sk-in-file")
        let rewritten = try text(collection, previous: previous)
        #expect(!rewritten.contains("sk-in-file"))
        #expect(rewritten.contains(collection.id.uuidString))
        // Read again, the empty row takes its secret back from this Mac.
        let again = CollectionFile.merge(file: try CollectionFile.read(Data(rewritten.utf8)), into: collection)
        #expect(again == collection)
    }

    // MARK: Three ways

    @Test func aChangeMadeHereThatHasNotReachedTheFileStands() throws {
        let base = Self.collection()
        let known = try CollectionFile.read(try CollectionFile.data(for: base))
        // Here: the address of Login changes, Ping goes, a request comes, the notes change.
        var local = base
        var mine = try #require(local.allRequests.first)
        mine.url = "{{baseUrl}}/users/:userId/signin"
        local.update(mine)
        local.items.removeAll { $0.name == "Ping" }
        local.items.append(.request(RequestItem(name: "Added here", url: "{{baseUrl}}/here")))
        local.notes = "Changed here"
        local.variables.append(Variable(name: "region", value: "eu"))
        // In the file: the body of Login changes, a request comes, the collection is renamed.
        var theirs = base
        var login = try #require(theirs.allRequests.first)
        login.body.raw = "{\"a\": 2}"
        theirs.update(login)
        theirs.items.append(.request(RequestItem(name: "Added there", url: "{{baseUrl}}/there")))
        theirs.name = "API v2"
        let file = try CollectionFile.read(try CollectionFile.data(for: theirs))

        let merged = CollectionFile.merge(file: file, base: known, into: local)
        let result = try #require(merged.request(id: login.id))
        #expect(result.url == "{{baseUrl}}/users/:userId/signin")
        #expect(result.body.raw == "{\"a\": 2}")
        #expect(result.headers == mine.headers)
        #expect(result.auth == mine.auth)
        #expect(merged.name == "API v2")
        #expect(merged.notes == "Changed here")
        #expect(merged.variables == local.variables)
        #expect(merged.auth == local.auth)
        #expect(merged.allRequests.map(\.name) == ["Login", "Added there", "Added here"])
        // Taken in, the file changes nothing more.
        #expect(CollectionFile.merge(file: file, base: file, into: merged) == merged)

        // Without what Bee knew of the file, the file wins wherever the two differ, and nothing is removed.
        let blind = CollectionFile.merge(file: file, into: local)
        #expect(blind.request(id: login.id)?.url == login.url)
        #expect(blind.allRequests.map(\.name) == ["Login", "Ping", "Added there", "Added here"])
        #expect(blind.variables.map(\.name) == ["baseUrl", "apiToken", "region"])
    }

    @Test func aRequestMovedOnOneSideIsThereOnce() throws {
        let base = Self.collection()
        let known = try CollectionFile.read(try CollectionFile.data(for: base))
        let folderID = base.items[0].id
        let ping = try #require(base.allRequests.last)

        // Moved into the folder in the file, while its address changes here.
        var theirs = base
        theirs.items.removeAll { $0.id == ping.id }
        if case .folder(var folder) = theirs.items[0] {
            folder.items.append(.request(ping))
            theirs.items[0] = .folder(folder)
        }
        var local = base
        var mine = ping
        mine.url = "{{baseUrl}}/ping/v2"
        local.update(mine)

        let merged = CollectionFile.merge(file: try CollectionFile.read(try CollectionFile.data(for: theirs)), base: known, into: local)
        #expect(merged.items.map(\.id) == [folderID])
        #expect(merged.folder(id: folderID)?.items.map(\.name) == ["Login", "Ping"])
        #expect(merged.request(id: ping.id)?.url == "{{baseUrl}}/ping/v2")

        // Put in a folder made in the file, a request keeps what is held here.
        var wrapped = base
        let login = try #require(base.allRequests.first)
        wrapped.items = [.folder(Folder(name: "Everything", items: base.items))]
        let inFolder = CollectionFile.merge(file: try CollectionFile.read(try CollectionFile.data(for: wrapped)), base: known, into: base)
        #expect(inFolder.items.map(\.name) == ["Everything"])
        #expect(inFolder.request(id: login.id) == login)
    }

    @Test func aRequestPutInAFolderTheOtherSideDeletedIsNotLost() throws {
        let base = Self.collection()
        let known = try CollectionFile.read(try CollectionFile.data(for: base))
        let folderID = base.items[0].id
        let ping = try #require(base.allRequests.last)
        func movingPingIntoTheFolder(adding added: RequestItem) -> Collection {
            var changed = base
            changed.items.removeAll { $0.id == ping.id }
            if case .folder(var folder) = changed.items[0] {
                folder.items += [.request(ping), .request(added)]
                changed.items[0] = .folder(folder)
            }
            return changed
        }
        var withoutTheFolder = base
        withoutTheFolder.items.removeAll { $0.id == folderID }
        let added = RequestItem(name: "Added in the folder", url: "{{baseUrl}}/added")

        // Moved into the folder here, while the file deletes the folder: Ping and what was added here
        // stay; Login, which the file deleted with its folder, goes.
        let here = CollectionFile.merge(
            file: try CollectionFile.read(try CollectionFile.data(for: withoutTheFolder)), base: known,
            into: movingPingIntoTheFolder(adding: added)
        )
        #expect(here.allRequests.map(\.name) == ["Ping", "Added in the folder"])
        #expect(here.folder(id: folderID) == nil)

        // The other way round: the file moves Ping into the folder and adds a request, the folder is deleted here.
        let there = CollectionFile.merge(
            file: try CollectionFile.read(try CollectionFile.data(for: movingPingIntoTheFolder(adding: added))), base: known,
            into: withoutTheFolder
        )
        #expect(there.allRequests.map(\.name) == ["Ping", "Added in the folder"])
        #expect(there.request(id: ping.id) == ping)
    }

    @Test func variablesAreMergedOneByOne() throws {
        var base = Self.collection()
        base.variables += [Variable(name: "tenant", value: "acme"), Variable(name: "legacy", value: "x", isSecret: true)]
        let known = try CollectionFile.read(try CollectionFile.data(for: base))
        // Here: a secret variable comes, one goes, one is turned off, one is made plain.
        var local = base
        local.variables.append(Variable(name: "apiKey", value: "sk-new", isSecret: true))
        local.variables.removeAll { $0.name == "tenant" }
        local.variables[0].isEnabled = false
        local.variables[2].isSecret = false
        // In the file: a variable comes.
        var theirs = base
        theirs.variables.append(Variable(name: "region", value: "not shared"))

        let merged = CollectionFile.merge(file: try CollectionFile.read(try CollectionFile.data(for: theirs)), base: known, into: local)
        #expect(merged.variables.map(\.name) == ["baseUrl", "apiToken", "legacy", "region", "apiKey"])
        #expect(merged.variables.map(\.value) == ["https://api.example.com", "sk-variable", "x", "", "sk-new"])
        #expect(merged.variables.map(\.isEnabled) == [false, true, true, true, true])
        #expect(merged.variables.map(\.isSecret) == [false, true, false, false, true])
        #expect(merged.variables[4].id == local.variables.last?.id)

        // Removed in the file, a variable goes; made secret there, it is secret here.
        var fewer = base
        fewer.variables.removeAll { $0.name == "tenant" }
        fewer.variables[0].isSecret = true
        let pruned = CollectionFile.merge(file: try CollectionFile.read(try CollectionFile.data(for: fewer)), base: known, into: base)
        #expect(pruned.variables.map(\.name) == ["baseUrl", "apiToken", "legacy"])
        #expect(pruned.variables[0].isSecret)
        #expect(pruned.variables[0].value == "https://api.example.com")
    }

    // MARK: Files of other tools

    @Test func aFileWithoutIdentifiersKeepsWhatBeeDoesNotModelAndTheSecretsHeldHere() throws {
        let postman = """
        {"info": {"_postman_id": "\(UUID().uuidString)", "name": "Theirs", "schema": "\(CollectionFile.schema)"},
         "item": [{"name": "Group", "item": [{"name": "Call",
            "request": {"method": "GET", "url": "https://h/x", "description": "Why",
              "header": [{"key": "Authorization", "value": "Bearer sk-in-file", "description": "Why this header"}],
              "auth": {"type": "oauth2", "oauth2": [{"key": "accessToken", "value": "{{t}}"}]}},
            "response": [{"name": "Saved example", "code": 200}]}]}]}
        """
        let first = try CollectionFile.document(in: Data(postman.utf8))
        let id = try #require(CollectionFile.identifier(of: first))
        let stamped = CollectionFile.identified(first, as: id, like: nil)
        let local = try CollectionFile.collection(in: stamped)
        let request = try #require(local.allRequests.first)
        #expect(request.headers.first?.value == "Bearer sk-in-file")
        #expect(request.headers.first?.isSecret == true)

        // Put in Bee's form, the file keeps the saved example and the authorization Bee cannot send.
        let data = try CollectionFile.data(for: local, document: stamped)
        let written = try JSONDecoder().decode(JSONValue.self, from: data)
        let call = try #require(written["item"]?.array?.first?["item"]?.array?.first)
        #expect(call["id"]?.string == request.id.uuidString)
        #expect(call["response"]?.array?.count == 1)
        #expect(call["request"]?["auth"]?["type"]?.string == "oauth2")
        #expect(call["request"]?["header"]?.array?.first?["value"]?.string == "")
        #expect(call["request"]?["header"]?.array?.first?["description"]?.string == "Why this header")
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-in-file"))

        // Exported again by that tool, without identifiers nor the secret: the same requests, secrets included.
        let exported = Data(postman.replacingOccurrences(of: "Bearer sk-in-file", with: "").utf8)
        let again = CollectionFile.identified(try CollectionFile.document(in: exported), as: id, like: local)
        #expect(CollectionFile.merge(file: try CollectionFile.collection(in: again), into: local) == local)
        // And the copy of a file is another collection, in the file too.
        let copy = try CollectionFile.collection(in: CollectionFile.withFreshIdentifiers(stamped))
        #expect(copy.id != local.id)
        #expect(Set(copy.allRequests.map(\.id)).isDisjoint(with: local.allRequests.map(\.id)))
    }

    @Test func aRequestMovedHereKeepsWhatBeeDoesNotModel() throws {
        let id = UUID()
        let foreign = """
        {"info": {"_postman_id": "\(UUID().uuidString)", "name": "Theirs", "schema": "\(CollectionFile.schema)"},
         "item": [{"id": "\(id.uuidString)", "name": "Call",
            "request": {"method": "GET", "url": "https://h/x", "auth": {"type": "oauth2", "oauth2": [{"key": "accessToken", "value": "{{t}}"}]}},
            "response": [{"name": "Saved example", "code": 200}]}]}
        """
        let previous = Data(foreign.utf8)
        var collection = try CollectionFile.read(previous)
        collection.items = [.folder(Folder(name: "Moved into", items: collection.items))]
        let written = try CollectionFile.document(in: try CollectionFile.data(for: collection, previous: previous))
        let call = try #require(written["item"]?.array?.first?["item"]?.array?.first)
        #expect(call["id"]?.string == id.uuidString)
        #expect(call["response"]?.array?.count == 1)
        #expect(call["request"]?["auth"]?["type"]?.string == "oauth2")
    }

    @Test func identifiersOfAnotherToolAndOfOtherCollectionsAreNotTaken() throws {
        let local = Self.collection()
        let login = try #require(local.allRequests.first)
        let ping = try #require(local.allRequests.last)
        // The same collection written by a tool that gave everything identifiers of its own.
        let tool = """
        {"info": {"_postman_id": "\(UUID().uuidString)", "name": "API", "schema": "\(CollectionFile.schema)"},
         "item": [{"id": "\(UUID().uuidString)", "name": "Auth", "item": [{"id": "\(UUID().uuidString)", "name": "Login",
              "request": {"method": "POST", "url": "{{baseUrl}}/users/:userId/login"}}]},
            {"id": "\(UUID().uuidString)", "name": "Ping", "request": {"method": "GET", "url": "{{baseUrl}}/ping"}},
            {"id": "\(UUID().uuidString)", "name": "Theirs alone", "request": {"method": "GET", "url": "{{baseUrl}}/new"}}]}
        """
        let document = try CollectionFile.document(in: Data(tool.utf8))
        #expect(PostmanReader.guessesSecrets(in: document))
        #expect(CollectionFile.resembles(document, local))
        #expect(!CollectionFile.resembles(document, Collection(name: "Other", items: [.request(RequestItem(name: "Elsewhere"))])))
        let adopted = try CollectionFile.collection(in: CollectionFile.identified(document, as: local.id, like: local, adoptsUnknown: true))
        #expect(adopted.allRequests.prefix(2).map(\.id) == [login.id, ping.id])
        #expect(adopted.items.first?.id == local.items.first?.id)
        // In a file Bee wrote, an identifier Bee does not know is a new request, whatever its name.
        let trusted = try CollectionFile.collection(in: CollectionFile.identified(document, as: local.id, like: local))
        #expect(Set(trusted.allRequests.map(\.id)).isDisjoint(with: [login.id, ping.id]))

        // An identifier another collection holds is not given to a request of this one.
        let taken = try CollectionFile.collection(in: CollectionFile.identified(
            try CollectionFile.document(in: try CollectionFile.data(for: local)), as: local.id, like: local, reserved: [ping.id]
        ))
        #expect(taken.allRequests.first?.id == login.id)
        #expect(taken.allRequests.last?.id != ping.id)
    }

    @Test func aRowLeftPlainHereStaysPlainAndOnlyAnotherToolsFileIsGuessed() throws {
        let request = RequestItem(name: "Me", url: "https://h/me", headers: [
            KeyValue(key: "Authorization", value: "Bearer {{token}}"), KeyValue(key: "X-Api-Key", value: "public-demo-key"),
        ])
        let collection = Collection(name: "API", items: [.request(request)], variables: [Variable(name: "apiToken", value: "v")])
        let data = try CollectionFile.data(for: collection)
        let read = try CollectionFile.read(data)
        #expect(read.allRequests.first?.headers.map(\.isSecret) == [false, false])
        #expect(read.variables.first?.isSecret == false)
        #expect(CollectionFile.merge(file: read, into: collection) == collection)

        // The same rows in a file Bee did not write are taken for credentials.
        var document = try #require(try CollectionFile.document(in: data).object)
        var info = try #require(document["info"]?.object)
        info[CollectionFile.secretsMarkedKey] = nil
        document["info"] = .object(info)
        let foreign = try CollectionFile.collection(in: .object(document))
        #expect(foreign.allRequests.first?.headers.map(\.isSecret) == [true, true])
        #expect(foreign.variables.first?.isSecret == true)
    }

    @Test func rowsAndVariablesOfTheSameNameKeepTheirOwnValues() throws {
        var request = RequestItem(name: "Up", method: .post, url: "https://h/up")
        request.body.mode = .formData
        request.body.formData = [
            FormField(key: "token", value: "sk-one", isSecret: true), FormField(key: "token", value: "sk-two", isSecret: true),
        ]
        let collection = Collection(name: "API", items: [.request(request)], variables: [
            Variable(name: "baseUrl", value: "https://dev"), Variable(name: "baseUrl", value: "https://prod", isEnabled: false),
        ])
        let read = try CollectionFile.read(try CollectionFile.data(for: collection))
        #expect(CollectionFile.merge(file: read, into: collection) == collection)
    }

    @Test func aNoteTheReaderAddsIsWrittenOnce() throws {
        let foreign = """
        {"info": {"_postman_id": "\(UUID().uuidString)", "name": "Theirs", "description": "About", "schema": "\(CollectionFile.schema)"},
         "auth": {"type": "oauth2"}, "item": []}
        """
        var data = Data(foreign.utf8)
        var collection = try CollectionFile.read(data)
        let notes = collection.notes
        #expect(notes.hasPrefix("About\n\n"))
        for _ in 0..<3 {
            data = try CollectionFile.data(for: collection, previous: data)
            collection = CollectionFile.merge(file: try CollectionFile.read(data), into: collection)
        }
        #expect(collection.notes == notes)
        #expect(try CollectionFile.document(in: data)["info"]?["description"]?.string == "About")
        #expect(try CollectionFile.document(in: data)["auth"]?["type"]?.string == "oauth2")
        // Edited here, the notes are written whole, and read back as they are.
        collection.notes = notes + "\n\nMine"
        data = try CollectionFile.data(for: collection, previous: data)
        #expect(try CollectionFile.read(data).notes == notes + "\n\nMine")
    }

    @Test func aSecretPathVariableWhoseRowAToolDroppedIsStillHere() throws {
        let request = RequestItem(
            name: "One", url: "https://h/t/:ticketId", pathVariables: [KeyValue(key: "ticketId", value: "sk-path", isSecret: true)]
        )
        let collection = Collection(name: "API", items: [.request(request)])
        let data = try CollectionFile.data(for: collection)
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-path"))
        let root = try #require(try JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? NSMutableDictionary)
        let item = try #require((root["item"] as? NSMutableArray)?.firstObject as? NSMutableDictionary)
        let url = try #require((item["request"] as? NSMutableDictionary)?["url"] as? NSMutableDictionary)
        #expect(url["variable"] != nil)
        url.removeObject(forKey: "variable")
        let stripped = try CollectionFile.read(try JSONSerialization.data(withJSONObject: root))
        #expect(CollectionFile.merge(file: stripped, base: try CollectionFile.read(data), into: collection) == collection)
        #expect(CollectionFile.merge(file: stripped, into: collection) == collection)
    }

    @Test func whatIsNotACollectionIsRefused() {
        #expect(throws: ImportError.self) { try CollectionFile.read(Data("not json".utf8)) }
        #expect(throws: ImportError.self) { try CollectionFile.read(Data("{\"values\": [], \"name\": \"env\"}".utf8)) }
    }
}
