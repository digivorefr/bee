import Foundation
import Testing
@testable import BeeCore

@Suite struct ImportTests {
    private static let postmanCollection = #"""
    {
      "info": {
        "_postman_id": "0f1e2d3c-0000-4000-8000-000000000001",
        "name": "Shop API",
        "description": {"content": "Everything about the shop.", "type": "text/markdown"},
        "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
      },
      "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "collection-bearer-token", "type": "string"}]},
      "event": [
        {"listen": "prerequest", "script": {"type": "text/javascript", "exec": ["console.log('before');", "var a = 1;"]}},
        {"listen": "test", "script": {"type": "text/javascript", "exec": "console.log('after');"}}
      ],
      "variable": [
        {"key": "baseUrl", "value": "https://shop.example.com"},
        {"key": "clientSecret", "value": "variable-secret-value"},
        {"key": "retries", "value": 3, "disabled": true}
      ],
      "item": [
        {
          "name": "Orders",
          "description": "Order endpoints",
          "auth": {"type": "basic", "basic": [{"key": "username", "value": "bee"}, {"key": "password", "value": "folder-basic-password"}]},
          "event": [{"listen": "test", "script": {"exec": ["// folder test"]}}],
          "item": [
            {
              "name": "List orders",
              "request": {
                "method": "GET",
                "header": [
                  {"key": "Accept", "value": "application/json"},
                  {"key": "X-Api-Key", "value": "header-secret-value"},
                  {"key": "X-Debug", "value": "1", "disabled": true}
                ],
                "url": {
                  "raw": "{{baseUrl}}/orders?page=1&token=query-secret-value&unused=x",
                  "host": ["{{baseUrl}}"], "path": ["orders"],
                  "query": [
                    {"key": "page", "value": "1"},
                    {"key": "token", "value": "query-secret-value"},
                    {"key": "unused", "value": "x", "disabled": true}
                  ]
                },
                "description": "Lists the orders."
              },
              "event": [
                {"listen": "prerequest", "script": {"exec": ["// request pre"]}},
                {"listen": "test", "script": {"exec": ["// request test", "// line 2"]}}
              ]
            },
            {
              "name": "Create order",
              "request": {
                "method": "POST",
                "auth": {"type": "apikey", "apikey": [{"key": "key", "value": "api_key"}, {"key": "value", "value": "apikey-secret-value"}, {"key": "in", "value": "query"}]},
                "header": [],
                "body": {"mode": "raw", "raw": "{\"sku\": \"{{sku}}\"}", "options": {"raw": {"language": "json"}}},
                "url": "{{baseUrl}}/orders?dryRun=true&note=a=b#fragment"
              }
            }
          ]
        },
        {
          "name": "Login form",
          "request": {
            "method": "POST",
            "auth": {"type": "noauth"},
            "body": {"mode": "urlencoded", "urlencoded": [
              {"key": "user", "value": "bee"},
              {"key": "password", "value": "form-secret-value"},
              {"key": "remember", "value": "1", "disabled": true}
            ]},
            "url": {"raw": "{{baseUrl}}/login"}
          }
        },
        {
          "name": "Upload",
          "request": {
            "method": "PUT",
            "auth": {"type": "oauth2", "oauth2": [{"key": "accessToken", "value": "oauth-token"}]},
            "body": {"mode": "formdata", "formdata": [
              {"key": "title", "value": "Report", "type": "text"},
              {"key": "api_token", "value": "multipart-secret-value", "type": "text"},
              {"key": "file", "type": "file", "src": "/tmp/report.pdf", "contentType": "application/pdf"}
            ]},
            "url": {"protocol": "https", "host": ["shop", "example", "com"], "port": "8443", "path": ["upload"]}
          }
        },
        {
          "name": "Binary",
          "request": {"method": "POST", "body": {"mode": "file", "file": {"src": "/tmp/blob.bin"}}, "url": "{{baseUrl}}/blob"}
        },
        {
          "name": "Graph",
          "request": {
            "method": "POST",
            "body": {"mode": "graphql", "graphql": {"query": "query { me { id } }", "variables": "{\"first\": 1}"}},
            "url": "{{baseUrl}}/graphql"
          }
        }
      ]
    }
    """#

    @Test func postmanCollectionMapping() throws {
        let data = Data(Self.postmanCollection.utf8)
        #expect(Importer.detect(data) == .postmanCollection)
        let collection = try Importer.collection(from: data)

        #expect(collection.name == "Shop API")
        #expect(collection.notes == "Everything about the shop.")
        #expect(collection.auth.kind == .bearer)
        #expect(collection.auth.bearerToken.value == "collection-bearer-token")
        #expect(collection.preRequestScript == "console.log('before');\nvar a = 1;")
        #expect(collection.postResponseScript == "console.log('after');")
        #expect(collection.variables.map(\.name) == ["baseUrl", "clientSecret", "retries"])
        #expect(collection.variables.map(\.value) == ["https://shop.example.com", "variable-secret-value", "3"])
        #expect(collection.variables.map(\.isSecret) == [false, true, false])
        #expect(collection.variables.map(\.isEnabled) == [true, true, false])
        #expect(collection.items.map(\.name) == ["Orders", "Login form", "Upload", "Binary", "Graph"])

        guard case .folder(let orders) = collection.items[0] else {
            Issue.record("Expected a folder")
            return
        }
        #expect(orders.notes == "Order endpoints")
        #expect(orders.auth.kind == .basic)
        #expect(orders.auth.basicUsername == "bee")
        #expect(orders.auth.basicPassword.value == "folder-basic-password")
        #expect(orders.postResponseScript == "// folder test")

        let requests = collection.allRequests
        let list = requests[0]
        #expect(list.method == .get)
        #expect(list.url == "{{baseUrl}}/orders")
        #expect(list.queryParams.map(\.key) == ["page", "token", "unused"])
        #expect(list.queryParams.map(\.isSecret) == [false, true, false])
        #expect(list.queryParams.map(\.isEnabled) == [true, true, false])
        #expect(list.headers.map(\.key) == ["Accept", "X-Api-Key", "X-Debug"])
        #expect(list.headers.map(\.isSecret) == [false, true, false])
        #expect(list.headers.map(\.isEnabled) == [true, true, false])
        #expect(list.headers[1].value == "header-secret-value")
        #expect(list.auth.kind == .inherit)
        #expect(list.notes == "Lists the orders.")
        #expect(list.preRequestScript == "// request pre")
        #expect(list.postResponseScript == "// request test\n// line 2")

        let create = requests[1]
        #expect(create.method == .post)
        #expect(create.url == "{{baseUrl}}/orders")
        #expect(create.queryParams.map(\.key) == ["dryRun", "note"])
        #expect(create.queryParams.map(\.value) == ["true", "a=b"])
        #expect(create.auth.kind == .apiKey)
        #expect(create.auth.apiKeyName == "api_key")
        #expect(create.auth.apiKeyValue.value == "apikey-secret-value")
        #expect(create.auth.apiKeyLocation == .query)
        #expect(create.body.mode == .raw)
        #expect(create.body.rawLanguage == .json)
        #expect(create.body.raw == #"{"sku": "{{sku}}"}"#)

        let login = requests[2]
        #expect(login.auth.kind == AuthKind.none)
        #expect(login.body.mode == .urlEncoded)
        #expect(login.body.urlEncoded.map(\.key) == ["user", "password", "remember"])
        #expect(login.body.urlEncoded.map(\.isSecret) == [false, true, false])
        #expect(login.body.urlEncoded.map(\.isEnabled) == [true, true, false])

        let upload = requests[3]
        #expect(upload.method == .put)
        #expect(upload.url == "https://shop.example.com:8443/upload")
        #expect(upload.auth.kind == AuthKind.none)
        #expect(upload.notes.contains("\"oauth2\""))
        #expect(upload.body.mode == .formData)
        #expect(upload.body.formData.map(\.kind) == [.text, .text, .file])
        #expect(upload.body.formData.map(\.isSecret) == [false, true, false])
        #expect(upload.body.formData[2].value == "/tmp/report.pdf")
        #expect(upload.body.formData[2].contentType == "application/pdf")

        #expect(requests[4].body.mode == .binary)
        #expect(requests[4].body.binaryPath == "/tmp/blob.bin")
        #expect(requests[5].body.mode == .graphQL)
        #expect(requests[5].body.graphQLQuery == "query { me { id } }")
        #expect(requests[5].body.graphQLVariables == #"{"first": 1}"#)

        // Every imported credential sits in a secret slot, so none reaches an encoded file.
        let encoded = try BeeArchive.data(for: collection)
        for credential in [
            "collection-bearer-token", "variable-secret-value", "folder-basic-password", "header-secret-value",
            "query-secret-value", "apikey-secret-value", "form-secret-value", "multipart-secret-value",
        ] {
            #expect(collection.secretValues().contains(credential))
            #expect(!encoded.contains(credential))
        }
    }

    @Test func postmanVersion2_0AndErrors() throws {
        let v2 = #"""
        {"info": {"name": "Old", "schema": "https://schema.getpostman.com/json/collection/v2.0.0/collection.json"},
         "item": [{"name": "Ping", "request": {"method": "POST", "url": "https://example.com/ping?x=1",
           "auth": {"type": "bearer", "bearer": {"token": "v2-token"}},
           "header": [{"key": "Content-Type", "value": "application/xml"}],
           "body": {"mode": "raw", "raw": "<a/>"}}}]}
        """#
        let collection = try Importer.collection(from: Data(v2.utf8))
        #expect(collection.auth.kind == AuthKind.none)
        let ping = try #require(collection.allRequests.first)
        #expect(ping.url == "https://example.com/ping")
        #expect(ping.queryParams.map(\.key) == ["x"])
        #expect(ping.auth.bearerToken.value == "v2-token")
        #expect(ping.body.rawLanguage == .xml)

        let v1 = #"{"id": "1", "name": "Legacy", "order": [], "requests": []}"#
        #expect(throws: ImportError.unsupportedVersion("Postman Collection v1")) {
            try Importer.collection(from: Data(v1.utf8))
        }
        #expect(throws: ImportError.unrecognizedFormat) { try Importer.collection(from: Data("not json".utf8)) }
        #expect(throws: ImportError.unrecognizedFormat) { try Importer.environment(from: Data(#"{"a": 1}"#.utf8)) }
        #expect(Importer.detect(Data("[1, 2]".utf8)) == nil)
        #expect(throws: ImportError.malformed("The file holds a collection, not an environment.")) {
            try Importer.environment(from: Data(v2.utf8))
        }
        #expect(throws: ImportError.unsupportedVersion("Bee archive version 2")) {
            try Importer.collection(from: Data(#"{"bee": 2, "kind": "collection", "collection": {}}"#.utf8))
        }
    }

    @Test func postmanEnvironmentMapping() throws {
        let fixture = #"""
        {"id": "e1", "name": "Staging", "_postman_variable_scope": "environment", "values": [
          {"key": "baseUrl", "value": "https://staging.example.com", "type": "default", "enabled": true},
          {"key": "license", "value": "secret-typed-value", "type": "secret", "enabled": true},
          {"key": "api_key", "value": "sensitive-name-value", "type": "default", "enabled": false},
          {"key": "accessToken", "value": "", "enabled": true}
        ]}
        """#
        let data = Data(fixture.utf8)
        #expect(Importer.detect(data) == .postmanEnvironment)
        let environment = try Importer.environment(from: data)
        #expect(environment.name == "Staging")
        #expect(environment.variables.map(\.name) == ["baseUrl", "license", "api_key", "accessToken"])
        #expect(environment.variables.map(\.isSecret) == [false, true, true, true])
        #expect(environment.variables.map(\.isEnabled) == [true, true, false, true])
        #expect(environment.secretValues().sorted() == ["secret-typed-value", "sensitive-name-value"])
    }

    @Test func beeArchiveRoundTripRegeneratesIdentifiers() throws {
        let workspace = SampleData.workspace()
        var collection = try #require(workspace.collections.first)
        collection.auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "archive-bearer-secret"))
        collection.variables = [Variable(name: "token", value: "archive-variable-secret", isSecret: true)]

        let data = try BeeArchive.data(for: collection)
        #expect(!data.contains("archive-bearer-secret"))
        #expect(!data.contains("archive-variable-secret"))
        #expect(!data.contains("{{apiToken}}"))
        #expect(Importer.detect(data) == .beeCollection)

        let imported = try Importer.collection(from: data)
        #expect(imported.name == collection.name)
        #expect(imported.allRequests.map(\.name) == collection.allRequests.map(\.name))
        #expect(imported.allRequests.map(\.url) == collection.allRequests.map(\.url))
        #expect(imported.preRequestScript == collection.preRequestScript)
        #expect(imported.secretValues().isEmpty)
        #expect(imported.secretSlots().count == collection.secretSlots().count)

        func identifiers(_ collection: Collection) -> Set<UUID> {
            var ids: Set<UUID> = [collection.id]
            ids.formUnion(collection.variables.map(\.id))
            ids.formUnion(collection.secretSlots().keys)
            func walk(_ nodes: [CollectionNode]) {
                for node in nodes {
                    ids.insert(node.id)
                    if case .request(let request) = node {
                        ids.formUnion(request.headers.map(\.id))
                        ids.formUnion(request.queryParams.map(\.id))
                    }
                    walk(node.children ?? [])
                }
            }
            walk(collection.items)
            return ids
        }
        #expect(identifiers(imported).isDisjoint(with: identifiers(collection)))
        #expect(identifiers(imported).count == identifiers(collection).count)

        let environment = try #require(workspace.environments.first)
        let environmentData = try BeeArchive.data(for: environment)
        #expect(!environmentData.contains("demo-token-1234"))
        #expect(Importer.detect(environmentData) == .beeEnvironment)
        let importedEnvironment = try Importer.environment(from: environmentData)
        #expect(importedEnvironment.variables.map(\.name) == environment.variables.map(\.name))
        #expect(importedEnvironment.id != environment.id)
        #expect(Set(importedEnvironment.variables.map(\.id)).isDisjoint(with: Set(environment.variables.map(\.id))))
        #expect(importedEnvironment.secretValues().isEmpty)
    }
}

@Suite struct SampleDataTests {
    @Test func contentAndNoSecretInEncodedForm() throws {
        let workspace = SampleData.workspace()
        #expect(workspace.environments.map(\.name) == ["httpbin", "Local"])
        #expect(workspace.activeEnvironment?.name == "httpbin")
        #expect(workspace.secretValues().contains("demo-token-1234"))

        let collection = try #require(workspace.collections.first)
        #expect(collection.name == "Bee Basics")
        #expect(collection.preRequestScript.contains("X-Request-Id"))
        let requests = collection.allRequests
        #expect(requests.map(\.name) == [
            "Get with parameters", "Get by path variable", "Send JSON", "Send a secret header",
            "1 · Get a token", "2 · Call with the token", "Teapot",
        ])
        for request in requests {
            #expect(request.url.hasPrefix("{{baseUrl}}"))
        }
        #expect(PathVariables.names(in: requests[1].url) == ["ticketId", "commentId"])
        #expect(requests[1].pathVariables.map(\.key) == ["commentId"])
        #expect(requests[3].headers.first?.isSecret == true)
        #expect(requests[5].auth.kind == .bearer)
        #expect(requests[5].auth.bearerToken.value == "{{accessToken}}")

        let encoded = try StorageCoding.encoder().encode(workspace)
        #expect(!encoded.contains("demo-token-1234"))
        #expect(!encoded.contains("{{apiToken}}"))
        #expect(encoded.contains("https://httpbin.org"))
    }
}
