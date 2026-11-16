import Foundation
import Testing
@testable import BeeCore

@Suite struct RequestBuilderTests {
    // MARK: Helpers

    private func build(
        _ item: RequestItem, auth: AuthConfig = AuthConfig(kind: .none), vars: [String: String] = [:],
        secrets: [String: String] = [:], settings: AppSettings = AppSettings()
    ) throws(RequestBuildError) -> BuildOutput {
        let context = VariableContext(environment: vars.map { Variable(name: $0.key, value: $0.value) }
            + secrets.map { Variable(name: $0.key, value: $0.value, isSecret: true) })
        return try RequestBuilder.build(item: item, auth: auth, context: context, settings: settings)
    }

    private func url(_ address: String, params: [KeyValue] = []) throws -> String {
        try build(RequestItem(url: address, queryParams: params)).request.url.absoluteString
    }

    private func headers(_ output: BuildOutput) -> [String] { output.request.headers.map { "\($0.name): \($0.value)" } }

    // MARK: effectiveAuth

    @Test func effectiveAuthInheritsFromTheNearestFolderThenCollection() {
        let bearer = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "item"))
        let outer = Folder(name: "outer", auth: AuthConfig(kind: .basic, basicUsername: "outer"))
        let inner = Folder(name: "inner", auth: AuthConfig(kind: .inherit))
        let innermost = Folder(name: "innermost", auth: AuthConfig(kind: .apiKey, apiKeyName: "K"))
        let collection = Collection(auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "col")))
        let inheriting = RequestItem(auth: AuthConfig(kind: .inherit))

        #expect(RequestBuilder.effectiveAuth(for: RequestItem(auth: bearer), folders: [outer], collection: collection) == bearer)
        // Folders are listed outermost first: the innermost one that is not `.inherit` wins.
        #expect(RequestBuilder.effectiveAuth(for: inheriting, folders: [outer, inner, innermost], collection: collection).kind == .apiKey)
        #expect(RequestBuilder.effectiveAuth(for: inheriting, folders: [outer, inner], collection: collection).basicUsername == "outer")
        #expect(RequestBuilder.effectiveAuth(for: inheriting, folders: [inner], collection: collection).bearerToken.value == "col")
        #expect(RequestBuilder.effectiveAuth(for: inheriting, folders: [], collection: collection).kind == .bearer)
    }

    @Test func effectiveAuthNoneStopsInheritance() {
        let folder = Folder(auth: AuthConfig(kind: .basic, basicUsername: "u"))
        let item = RequestItem(auth: AuthConfig(kind: .none))
        #expect(RequestBuilder.effectiveAuth(for: item, folders: [folder], collection: nil).kind == .none)
    }

    @Test func effectiveAuthInheritAtTheTopMeansNone() {
        let item = RequestItem(auth: AuthConfig(kind: .inherit))
        #expect(RequestBuilder.effectiveAuth(for: item, folders: [], collection: nil).kind == .none)
        let collection = Collection(auth: AuthConfig(kind: .inherit))
        #expect(RequestBuilder.effectiveAuth(for: item, folders: [Folder()], collection: collection).kind == .none)
    }

    @Test func effectiveAuthWorksWithCollectionAncestry() {
        let request = RequestItem(auth: AuthConfig(kind: .inherit))
        let folder = Folder(name: "F", items: [.request(request)], auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "f")))
        let collection = Collection(items: [.folder(folder)])
        let folders = collection.ancestry(of: request.id) ?? []
        #expect(RequestBuilder.effectiveAuth(for: request, folders: folders, collection: collection).bearerToken.value == "f")
    }

    // MARK: URL

    @Test func emptyURLIsRejected() {
        for address in ["", "   ", "\n\t "] {
            #expect(throws: RequestBuildError.emptyURL) { try build(RequestItem(url: address)) }
        }
        #expect(throws: RequestBuildError.emptyURL) { try build(RequestItem(url: "{{base}}"), vars: ["base": " "]) }
    }

    @Test(arguments: [
        ("localhost", "http://localhost"), ("localhost:3000/x", "http://localhost:3000/x"), ("LOCALHOST/x", "http://LOCALHOST/x"),
        ("127.0.0.1:8080", "http://127.0.0.1:8080"), ("127.5.5.5/a", "http://127.5.5.5/a"), ("[::1]:9000/p", "http://[::1]:9000/p"),
        ("myhost.local/api", "http://myhost.local/api"), ("app.localhost:5173", "http://app.localhost:5173"),
        ("10.1.2.3/x", "http://10.1.2.3/x"), ("192.168.0.10:81", "http://192.168.0.10:81"), ("172.16.0.1", "http://172.16.0.1"),
        ("172.31.255.255", "http://172.31.255.255"), ("169.254.1.1", "http://169.254.1.1"), ("user:pw@localhost/x", "http://user:pw@localhost/x"),
        ("[fd12::1]/x", "http://[fd12::1]/x"), ("[fe80::1]/x", "http://[fe80::1]/x"),
        ("example.com", "https://example.com"), ("api.example.com/v1?x=1", "https://api.example.com/v1?x=1"),
        ("8.8.8.8", "https://8.8.8.8"), ("172.32.0.1", "https://172.32.0.1"), ("172.15.0.1", "https://172.15.0.1"),
        ("11.0.0.1", "https://11.0.0.1"), ("localhost.example.com", "https://localhost.example.com"),
        ("[2001:db8::1]", "https://[2001:db8::1]"), ("notlocal", "https://notlocal"),
    ])
    func schemeIsInferred(address: String, expected: String) throws {
        #expect(try url(address) == expected)
    }

    @Test func explicitSchemeIsKept() throws {
        #expect(try url("http://example.com/a") == "http://example.com/a")
        #expect(try url("HTTPS://Example.com/a") == "HTTPS://Example.com/a")
        #expect(try url("  https://example.com/a \n") == "https://example.com/a")
    }

    @Test func variablesAreRenderedIntoTheAddress() throws {
        let output = try build(RequestItem(url: "{{base}}/users/{{id}}"), vars: ["base": "http://localhost:8080", "id": "42"])
        #expect(output.request.url.absoluteString == "http://localhost:8080/users/42")
        #expect(output.unresolvedVariables.isEmpty)
    }

    @Test(arguments: ["https://", "http://:80", "ftp://example.com/file", "file:///etc/passwd", "https://exa mple.com:99999999999"])
    func unusableAddressesAreInvalid(address: String) {
        #expect(throws: RequestBuildError.invalidURL(address)) { try build(RequestItem(url: address)) }
    }

    @Test func invalidURLNeverRevealsSecretValues() {
        do {
            _ = try build(RequestItem(url: "ftp://{{host}}"), secrets: ["host": "secret-host"])
            Issue.record("expected an error")
        } catch {
            #expect(error == .invalidURL("ftp://{{host}}"))
            #expect(!(error.errorDescription ?? "").contains("secret-host"))
        }
    }

    @Test func unresolvedPlaceholderInTheHostStillBuildsAndIsReported() throws {
        let output = try build(RequestItem(url: "{{baseUrl}}/users"))
        #expect(output.unresolvedVariables == ["baseUrl"])
        #expect(output.request.url.absoluteString.hasPrefix("https://"))
    }

    // MARK: Query

    @Test func queryRowsArePercentEncoded() throws {
        let params = [
            KeyValue(key: "q", value: "a b"), KeyValue(key: "plus", value: "1+1"), KeyValue(key: "amp", value: "a&b=c#d"),
            KeyValue(key: "k e&y", value: "v"), KeyValue(key: "uni", value: "é€"), KeyValue(key: "pct", value: "100%"),
            KeyValue(key: "safe", value: "a/b:c@d,e;f'(g)*!$-._~?"),
        ]
        let result = try url("https://h.test/p", params: params)
        #expect(result == "https://h.test/p?q=a%20b&plus=1%2B1&amp=a%26b%3Dc%23d&k%20e%26y=v&uni=%C3%A9%E2%82%AC&pct=100%25&safe=a/b:c@d,e;f'(g)*!$-._~?")
    }

    @Test func existingPercentEscapesAreNotEncodedTwice() throws {
        #expect(try url("https://h.test/", params: [KeyValue(key: "q", value: "a%20b%2Fc")]) == "https://h.test/?q=a%20b%2Fc")
    }

    @Test func rowsAreAppendedToAQueryAlreadyInTheAddress() throws {
        #expect(try url("https://h.test/p?x=1", params: [KeyValue(key: "a", value: "2")]) == "https://h.test/p?x=1&a=2")
        #expect(try url("https://h.test/p?", params: [KeyValue(key: "a", value: "2")]) == "https://h.test/p?a=2")
        #expect(try url("https://h.test/p#frag", params: [KeyValue(key: "a", value: "2")]) == "https://h.test/p?a=2#frag")
    }

    @Test func onlyEnabledRowsWithKeysAreSent() throws {
        let params = [KeyValue(key: "on", value: "1"), KeyValue(key: "off", value: "2", isEnabled: false), KeyValue(key: "  ", value: "3")]
        #expect(try url("https://h.test", params: params) == "https://h.test?on=1")
    }

    @Test func queryRowsAreRendered() throws {
        let output = try build(
            RequestItem(url: "https://h.test", queryParams: [KeyValue(key: "{{name}}", value: "{{v}} x"), KeyValue(key: "k", value: "{{gone}}")]),
            vars: ["name": "n", "v": "1"]
        )
        #expect(output.request.url.query == "n=1%20x&k=%7B%7Bgone%7D%7D")
        #expect(output.unresolvedVariables == ["gone"])
    }

    @Test func secretQueryRowsCarryTheirRealValueOnTheWire() throws {
        let params = [KeyValue(key: "token", value: "s3 cret", isSecret: true)]
        #expect(try url("https://h.test", params: params) == "https://h.test?token=s3%20cret")
    }

    // MARK: Unresolved variables

    @Test func unresolvedNamesAreCollectedAcrossEverythingThatIsSent() throws {
        var item = RequestItem(url: "{{u}}/{{shared}}", queryParams: [KeyValue(key: "q", value: "{{p}}"), KeyValue(key: "x", value: "{{off}}", isEnabled: false)])
        item.headers = [KeyValue(key: "X-{{hk}}", value: "{{hv}}")]
        item.body = RequestBody(mode: .raw, raw: "{{b}} {{shared}}")
        let auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{t}}"), basicUsername: "{{ignored}}")
        let output = try build(item, auth: auth, vars: ["u": "http://h"])
        #expect(output.unresolvedVariables == ["shared", "p", "hk", "hv", "t", "b"])
    }

    @Test func partsThatAreNotSentAreNotReported() throws {
        var item = RequestItem(url: "http://h")
        item.body = RequestBody(mode: .none, raw: "{{raw}}", urlEncoded: [KeyValue(key: "{{k}}")], graphQLQuery: "{{q}}")
        #expect(try build(item).unresolvedVariables.isEmpty)
    }

    // MARK: Headers

    @Test func explicitHeadersAreSentInOrderWithAutomaticOnesAfter() throws {
        var item = RequestItem(url: "http://h")
        item.headers = [
            KeyValue(key: "X-One", value: "1"), KeyValue(key: "X-Off", value: "no", isEnabled: false),
            KeyValue(key: "", value: "orphan"), KeyValue(key: " X-Two ", value: " {{v}} "),
        ]
        let output = try build(item, vars: ["v": "2"])
        #expect(headers(output) == ["X-One: 1", "X-Two: 2", "User-Agent: Bee/1.0", "Accept: */*"])
    }

    @Test func explicitHeadersBeatAutomaticAndDerivedOnes() throws {
        var item = RequestItem(method: .post, url: "http://h")
        item.headers = [
            KeyValue(key: "user-agent", value: "custom/2"), KeyValue(key: "ACCEPT", value: "text/html"),
            KeyValue(key: "authorization", value: "Token abc"), KeyValue(key: "content-type", value: "text/csv"),
        ]
        item.body = RequestBody(mode: .raw, raw: "a,b", rawLanguage: .json)
        let auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "derived"))
        let output = try build(item, auth: auth)
        #expect(headers(output) == ["user-agent: custom/2", "ACCEPT: text/html", "authorization: Token abc", "content-type: text/csv"])
    }

    @Test func disabledAuthorizationHeaderDoesNotShadowTheDerivedOne() throws {
        var item = RequestItem(url: "http://h")
        item.headers = [KeyValue(key: "Authorization", value: "Token abc", isEnabled: false)]
        let auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "derived"))
        #expect(try build(item, auth: auth).request.header("Authorization") == "Bearer derived")
    }

    @Test func lineBreaksNeverReachHeaders() throws {
        var item = RequestItem(url: "http://h")
        item.headers = [KeyValue(key: "X-A", value: "one\r\nInjected: yes")]
        let output = try build(item)
        #expect(output.request.header("X-A") == "oneInjected: yes")
        #expect(output.request.header("Injected") == nil)
    }

    // MARK: Authorization

    @Test func bearerAuthorization() throws {
        let auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: " {{tok}}\n"))
        let output = try build(RequestItem(url: "http://h"), auth: auth, secrets: ["tok": "s3cret"])
        #expect(output.request.header("Authorization") == "Bearer s3cret")
    }

    @Test func basicAuthorization() throws {
        let auth = AuthConfig(kind: .basic, basicUsername: "{{u}}", basicPassword: SecretField(value: "pässword"))
        let output = try build(RequestItem(url: "http://h"), auth: auth, vars: ["u": "alice"])
        let expected = Data("alice:pässword".utf8).base64EncodedString()
        #expect(output.request.header("Authorization") == "Basic \(expected)")
    }

    @Test func basicWithOnlyAUsernameSendsAnEmptyPassword() throws {
        let auth = AuthConfig(kind: .basic, basicUsername: "key")
        #expect(try build(RequestItem(url: "http://h"), auth: auth).request.header("Authorization") == "Basic " + Data("key:".utf8).base64EncodedString())
    }

    @Test func emptyCredentialsOmitTheHeader() throws {
        for auth in [
            AuthConfig(kind: .bearer), AuthConfig(kind: .bearer, bearerToken: SecretField(value: "  ")),
            AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{unset}}")), AuthConfig(kind: .basic),
            AuthConfig(kind: .basic, basicUsername: "{{unset}}", basicPassword: SecretField(value: "{{unset}}")),
            AuthConfig(kind: .apiKey, apiKeyName: "X-Key"), AuthConfig(kind: .apiKey, apiKeyValue: SecretField(value: "v")),
        ] {
            let output = try build(RequestItem(url: "http://h"), auth: auth, vars: ["unset": ""])
            #expect(headers(output) == ["User-Agent: Bee/1.0", "Accept: */*"])
        }
    }

    @Test func apiKeyInAHeaderOrTheQuery() throws {
        let inHeader = AuthConfig(kind: .apiKey, apiKeyName: "X-API-Key", apiKeyValue: SecretField(value: "k 1"), apiKeyLocation: .header)
        #expect(try build(RequestItem(url: "http://h"), auth: inHeader).request.header("x-api-key") == "k 1")

        let inQuery = AuthConfig(kind: .apiKey, apiKeyName: "api key", apiKeyValue: SecretField(value: "k&1"), apiKeyLocation: .query)
        let output = try build(RequestItem(url: "http://h/p?x=1", queryParams: [KeyValue(key: "y", value: "2")]), auth: inQuery)
        #expect(output.request.url.absoluteString == "http://h/p?x=1&y=2&api%20key=k%261")
        #expect(output.request.header("api key") == nil)
    }

    @Test func explicitQueryRowWinsOverAnApiKeyWithTheSameName() throws {
        let auth = AuthConfig(kind: .apiKey, apiKeyName: "key", apiKeyValue: SecretField(value: "derived"), apiKeyLocation: .query)
        let output = try build(RequestItem(url: "http://h", queryParams: [KeyValue(key: "key", value: "mine")]), auth: auth)
        #expect(output.request.url.query == "key=mine")
    }

    @Test func noneAndInheritAddNothing() throws {
        for kind in [AuthKind.none, .inherit] {
            let auth = AuthConfig(kind: kind, bearerToken: SecretField(value: "t"), basicUsername: "u", apiKeyName: "k", apiKeyValue: SecretField(value: "v"))
            #expect(try build(RequestItem(url: "http://h"), auth: auth).request.header("Authorization") == nil)
        }
    }

    // MARK: Bodies

    @Test func noBodyMeansNoContentType() throws {
        let output = try build(RequestItem(url: "http://h", body: RequestBody(mode: .none, raw: "ignored")))
        #expect(output.request.body == .none)
        #expect(output.request.header("Content-Type") == nil)
    }

    @Test(arguments: RawLanguage.allCases)
    func rawBodyUsesTheLanguageContentType(language: RawLanguage) throws {
        let item = RequestItem(method: .post, url: "http://h", body: RequestBody(mode: .raw, raw: "{{greeting}} é", rawLanguage: language))
        let output = try build(item, vars: ["greeting": "hi"])
        #expect(output.request.body == .data(Data("hi é".utf8)))
        #expect(output.request.header("Content-Type") == language.contentType)
    }

    @Test func jsonContentTypeHasNoCharset() throws {
        let item = RequestItem(url: "http://h", body: RequestBody(mode: .raw, raw: "{}", rawLanguage: .json))
        #expect(try build(item).request.header("Content-Type") == "application/json")
    }

    @Test func urlEncodedBodyUsesFormEncoding() throws {
        var body = RequestBody(mode: .urlEncoded)
        body.urlEncoded = [
            KeyValue(key: "name", value: "Jane Doe"), KeyValue(key: "sum", value: "1+1=2"), KeyValue(key: "a&b", value: "é/%"),
            KeyValue(key: "off", value: "x", isEnabled: false), KeyValue(key: "", value: "x"), KeyValue(key: "tok", value: "{{t}}", isSecret: true),
            KeyValue(key: "safe", value: "A-z_0.9~*"),
        ]
        let output = try build(RequestItem(method: .post, url: "http://h", body: body), vars: ["t": "a b"])
        #expect(output.request.bodyText == "name=Jane+Doe&sum=1%2B1%3D2&a%26b=%C3%A9%2F%25&tok=a+b&safe=A-z_0.9~*")
        #expect(output.request.header("Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test func multipartBodyLayout() throws {
        let scratch = HTTPTestScratch()
        defer { scratch.cleanup() }
        let textPath = scratch.write("notes.txt", "file body")
        let blobPath = scratch.write("blob.unknownext", Data([0, 1, 2, 255]))
        var body = RequestBody(mode: .formData)
        body.formData = [
            FormField(key: "title", value: "Hello {{who}}"),
            FormField(key: "meta", value: "{\"a\":1}", contentType: "application/json"),
            FormField(key: "doc", kind: .file, value: textPath),
            FormField(key: "blob", kind: .file, value: blobPath),
            FormField(key: "typed", kind: .file, value: textPath, contentType: "application/x-custom"),
            FormField(key: "skipped", value: "x", isEnabled: false),
            FormField(key: "", value: "no key"),
            FormField(key: "we\"ird\nname", value: "v"),
        ]
        let output = try build(RequestItem(method: .post, url: "http://h", body: body), vars: ["who": "Bee"])
        let contentType = try #require(output.request.header("Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        #expect(!boundary.isEmpty)

        guard case .data(let data) = output.request.body else {
            Issue.record("expected an in-memory body")
            return
        }
        var expected = Data()
        func add(_ text: String) { expected.append(Data(text.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello Bee\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"meta\"\r\nContent-Type: application/json\r\n\r\n{\"a\":1}\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"doc\"; filename=\"notes.txt\"\r\nContent-Type: text/plain\r\n\r\nfile body\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"blob\"; filename=\"blob.unknownext\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        expected.append(Data([0, 1, 2, 255]))
        add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"typed\"; filename=\"notes.txt\"\r\nContent-Type: application/x-custom\r\n\r\nfile body\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"we%22ird%0Aname\"\r\n\r\nv\r\n")
        add("--\(boundary)--\r\n")
        #expect(data == expected)
    }

    @Test func multipartBoundariesDifferBetweenBuilds() throws {
        let item = RequestItem(url: "http://h", body: RequestBody(mode: .formData))
        #expect(try build(item).request.header("Content-Type") != (try build(item).request.header("Content-Type")))
    }

    @Test func emptyMultipartIsJustTheClosingBoundary() throws {
        let output = try build(RequestItem(url: "http://h", body: RequestBody(mode: .formData)))
        let boundary = String((output.request.header("Content-Type") ?? "").dropFirst("multipart/form-data; boundary=".count))
        #expect(output.request.bodyText == "--\(boundary)--\r\n")
    }

    @Test func missingMultipartFileIsReported() {
        var body = RequestBody(mode: .formData)
        body.formData = [FormField(key: "doc", kind: .file, value: "/definitely/not/here.bin")]
        #expect(throws: RequestBuildError.fileNotFound("/definitely/not/here.bin")) {
            try build(RequestItem(url: "http://h", body: body))
        }
    }

    @Test func aDirectoryIsNotAFile() {
        let scratch = HTTPTestScratch()
        defer { scratch.cleanup() }
        var body = RequestBody(mode: .formData)
        body.formData = [FormField(key: "doc", kind: .file, value: scratch.directory.path)]
        #expect(throws: RequestBuildError.fileNotFound(scratch.directory.path)) {
            try build(RequestItem(url: "http://h", body: body))
        }
        #expect(throws: RequestBuildError.fileNotFound("")) {
            try build(RequestItem(url: "http://h", body: RequestBody(mode: .binary, binaryPath: "")))
        }
    }

    @Test func binaryBodyIsStreamedFromDisk() throws {
        let scratch = HTTPTestScratch()
        defer { scratch.cleanup() }
        let png = scratch.write("pic.png", Data([0x89, 0x50]))
        let unknown = scratch.write("data.zzz", "x")
        let output = try build(RequestItem(method: .put, url: "http://h", body: RequestBody(mode: .binary, binaryPath: png)))
        #expect(output.request.body == .file(URL(fileURLWithPath: png)))
        #expect(output.request.header("Content-Type") == "image/png")
        let other = try build(RequestItem(url: "http://h", body: RequestBody(mode: .binary, binaryPath: unknown)))
        #expect(other.request.header("Content-Type") == "application/octet-stream")
    }

    @Test func missingBinaryFileIsReported() {
        #expect(throws: RequestBuildError.fileNotFound("/nope/file.bin")) {
            try build(RequestItem(url: "http://h", body: RequestBody(mode: .binary, binaryPath: "/nope/file.bin")))
        }
    }

    @Test func graphQLBodyIsAJSONEnvelope() throws {
        let body = RequestBody(
            mode: .graphQL, graphQLQuery: "query($id: ID!) {\n  user(id: $id) { name \"x\" }\n}",
            graphQLVariables: "{\"id\": \"{{id}}\", \"big\": 12345678901234567890}"
        )
        let output = try build(RequestItem(method: .post, url: "http://h/graphql", body: body), vars: ["id": "7"])
        #expect(output.request.header("Content-Type") == "application/json")
        let text = try #require(output.request.bodyText)
        let decoded = try JSONDecoder().decode([String: GraphQLEnvelopeValue].self, from: Data(text.utf8))
        #expect(decoded["query"] == .string("query($id: ID!) {\n  user(id: $id) { name \"x\" }\n}"))
        #expect(text.hasSuffix("\"variables\":{\"id\": \"7\", \"big\": 12345678901234567890}}"))
        #expect(text.hasPrefix("{\"query\":"))
    }

    @Test func blankGraphQLVariablesBecomeAnEmptyObject() throws {
        for variables in ["", "  \n"] {
            let body = RequestBody(mode: .graphQL, graphQLQuery: "{ a }", graphQLVariables: variables)
            #expect(try build(RequestItem(url: "http://h", body: body)).request.bodyText == "{\"query\":\"{ a }\",\"variables\":{}}")
        }
    }

    @Test(arguments: ["{bad", "[1, 2]", "\"text\"", "42", "null"])
    func graphQLVariablesMustBeAJSONObject(variables: String) {
        let body = RequestBody(mode: .graphQL, graphQLQuery: "{ a }", graphQLVariables: variables)
        do {
            _ = try build(RequestItem(url: "http://h", body: body))
            Issue.record("expected an error for \(variables)")
        } catch {
            guard case .invalidGraphQLVariables(let reason) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(!reason.isEmpty)
            #expect(!reason.contains(variables))
        }
    }

    // MARK: Settings and secrets

    @Test func settingsFallBackToTheApplication() throws {
        let app = AppSettings(timeout: 12, followRedirects: false, verifyTLS: false)
        let defaults = try build(RequestItem(url: "http://h"), settings: app).request
        #expect(defaults.timeout == 12 && !defaults.followRedirects && !defaults.verifyTLS)

        var item = RequestItem(url: "http://h")
        item.settings = RequestSettings(timeout: 3, followRedirects: true, verifyTLS: true)
        let overridden = try build(item, settings: app).request
        #expect(overridden.timeout == 3 && overridden.followRedirects && overridden.verifyTLS)

        item.settings = RequestSettings(timeout: nil, followRedirects: true, verifyTLS: nil)
        let mixed = try build(item, settings: app).request
        #expect(mixed.timeout == 12 && mixed.followRedirects && !mixed.verifyTLS)
    }

    @Test func methodIsCarriedOver() throws {
        for method in HTTPMethod.allCases {
            #expect(try build(RequestItem(method: method, url: "http://h")).request.method == method.rawValue)
        }
    }

    @Test func secretVariablesAndRowsAreRealOnTheWire() throws {
        var item = RequestItem(url: "http://h")
        item.headers = [KeyValue(key: "X-Secret", value: "row-secret", isSecret: true)]
        let auth = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{tok}}"))
        let output = try build(item, auth: auth, secrets: ["tok": "var-secret"])
        #expect(output.request.header("X-Secret") == "row-secret")
        #expect(output.request.header("Authorization") == "Bearer var-secret")
    }

    @Test func errorDescriptionsAreReadable() {
        #expect(RequestBuildError.emptyURL.errorDescription == "The request has no URL.")
        #expect(RequestBuildError.fileNotFound("/a/b").errorDescription?.contains("/a/b") == true)
        #expect(RequestBuildError.invalidURL("x y").errorDescription?.contains("x y") == true)
        #expect(RequestBuildError.invalidGraphQLVariables("why").errorDescription?.contains("why") == true)
    }
}

/// Decodes the strings of a GraphQL envelope and ignores everything else.
private enum GraphQLEnvelopeValue: Decodable, Equatable {
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .string(text)
        } else {
            self = .other
        }
    }
}
