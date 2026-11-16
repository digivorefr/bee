import Foundation
import Testing
@testable import BeeCore

@Suite struct SecretEncodingTests {
    @Test func secretValuesNeverReachEncodedOutput() throws {
        var request = RequestItem(name: "Login", url: "{{baseUrl}}/login")
        request.headers = [KeyValue(key: "X-API-Key", value: "hunter2-header", isSecret: true)]
        request.auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "hunter2-bearer"))
        request.body.formData = [FormField(key: "password", value: "hunter2-form", isSecret: true)]
        let environment = Environment(name: "Production", variables: [
            Variable(name: "apiToken", value: "hunter2-variable", isSecret: true),
            Variable(name: "baseUrl", value: "https://api.example.com"),
        ])
        let workspace = Workspace(
            collections: [Collection(name: "API", items: [.folder(Folder(name: "Auth", items: [.request(request)]))])],
            environments: [environment], activeEnvironmentID: environment.id
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = String(decoding: try encoder.encode(workspace), as: UTF8.self)
        #expect(!encoded.contains("hunter2"))
        #expect(encoded.contains("https://api.example.com"))
        #expect(workspace.secretValues().count == 4)

        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(encoded.utf8))
        #expect(decoded.secretValues().isEmpty)
        #expect(Set(decoded.secretSlots().keys) == Set(workspace.secretSlots().keys))
    }

    @Test func duplicatedRequestGetsFreshSecretSlots() {
        var request = RequestItem(name: "A")
        request.auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "token"))
        request.headers = [KeyValue(key: "Cookie", value: "session", isSecret: true)]
        let copy = request.duplicated(name: "B")
        #expect(Set(copy.secretSlots().keys).isDisjoint(with: Set(request.secretSlots().keys)))
        #expect(copy.secretValues().sorted() == request.secretValues().sorted())
    }
}

@Suite struct CollectionTreeTests {
    @Test func insertUpdateRemove() {
        let folder = Folder(name: "Users")
        var collection = Collection(name: "API", items: [.folder(folder)])
        var request = RequestItem(name: "List users")
        let inserted = collection.insert(.request(request), inFolder: folder.id)
        #expect(inserted)
        #expect(collection.ancestry(of: request.id)?.map(\.name) == ["Users"])
        request.name = "List all users"
        let updated = collection.update(request)
        #expect(updated)
        #expect(collection.request(id: request.id)?.name == "List all users")
        let removed = collection.remove(id: request.id)
        #expect(removed != nil)
        #expect(collection.allRequests.isEmpty)
    }
}

@Suite struct VariableContextTests {
    @Test func precedence() {
        let context = VariableContext(
            locals: ["a": "local"],
            environment: [Variable(name: "a", value: "env"), Variable(name: "b", value: "env", isSecret: true)],
            collection: [Variable(name: "b", value: "col"), Variable(name: "c", value: "col")],
            globals: [Variable(name: "c", value: "glob"), Variable(name: "d", value: "glob", isEnabled: false)]
        )
        #expect(context.lookup("a")?.scope == .local)
        #expect(context.lookup("b") == VariableLookup(value: "env", scope: .environment, isSecret: true))
        #expect(context.lookup("c")?.scope == .collection)
        #expect(context.lookup("d") == nil)
    }
}
