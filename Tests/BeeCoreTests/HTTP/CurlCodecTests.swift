import Foundation
import Testing
@testable import BeeCore

@Suite struct CurlCodecTests {
    private func parse(_ command: String) throws(CurlParseError) -> RequestItem { try CurlCodec.parse(command) }

    // MARK: Shell quoting

    @Test func shellWordsHandleQuotingStyles() throws {
        #expect(try ShellWords.split("a 'b c' \"d e\" f\\ g") == ["a", "b c", "d e", "f g"])
        #expect(try ShellWords.split(#"'it'\''s' "say \"hi\" \$HOME \\ \n""#) == ["it's", #"say "hi" $HOME \ \n"#])
        #expect(try ShellWords.split("pre'mid'\"post\"") == ["premidpost"])
        #expect(try ShellWords.split("curl \\\n  -X POST \\\r\n  url") == ["curl", "-X", "POST", "url"])
        #expect(try ShellWords.split("$'a\\nb\\t\\x41\\u00e9\\'q\\101'") == ["a\nb\tAé'qA"])
        #expect(try ShellWords.split("'' x") == ["", "x"])
        #expect(try ShellWords.split("  \n ").isEmpty)
    }

    @Test(arguments: ["'open", "\"open", "$'open"])
    func unterminatedQuotesAreMalformed(text: String) {
        #expect(throws: CurlParseError.self) { try ShellWords.split(text) }
    }

    // MARK: Parse

    @Test func notACurlCommandAndMissingURL() {
        #expect(throws: CurlParseError.notACurlCommand) { try parse("wget https://x.test") }
        #expect(throws: CurlParseError.notACurlCommand) { try parse("") }
        #expect(throws: CurlParseError.missingURL) { try parse("curl -X POST -H 'A: b'") }
        #expect(throws: CurlParseError.malformed("Missing value for -H")) { try parse("curl https://x.test -H") }
        #expect(throws: CurlParseError.self) { try parse("curl 'https://x.test") }
    }

    @Test func simpleGet() throws {
        let item = try parse("curl https://api.example.com/v1/users/42")
        #expect(item.method == .get)
        #expect(item.url == "https://api.example.com/v1/users/42")
        #expect(item.name == "GET 42")
        #expect(item.body.mode == .none)
        #expect(item.auth.kind == .none)
        #expect(try parse("$ /usr/bin/curl --url https://x.test/").name == "GET x.test")
    }

    @Test func urlQuerySplitsIntoRowsAndKeepsTheFragment() throws {
        let item = try parse("curl 'https://h.test/p?a=1&b={{x}}&flag#top'")
        #expect(item.url == "https://h.test/p#top")
        #expect(item.queryParams.map(\.key) == ["a", "b", "flag"])
        #expect(item.queryParams.map(\.value) == ["1", "{{x}}", ""])
    }

    @Test func methodsAndImplicitPost() throws {
        #expect(try parse("curl -X put https://h.test").method == .put)
        #expect(try parse("curl -XDELETE https://h.test").method == .delete)
        #expect(try parse("curl -d 'a=b' https://h.test").method == .post)
        #expect(try parse("curl -I https://h.test").method == .head)
        #expect(try parse("curl -X PATCH -d '{}' https://h.test").method == .patch)
        #expect(throws: CurlParseError.malformed("Unsupported HTTP method PURGE")) { try parse("curl -X PURGE https://h.test") }
    }

    @Test func headersAndSensitiveFlagging() throws {
        let item = try parse("curl https://h.test -H 'Accept: application/json' -H 'X-Api-Key: abc' -H 'X-Empty;' --header 'Cookie: sid=1'")
        #expect(item.headers.map(\.key) == ["Accept", "X-Api-Key", "X-Empty", "Cookie"])
        #expect(item.headers.map(\.isSecret) == [false, true, false, true])
        #expect(item.headers[1].value == "abc")
    }

    @Test func bearerAndBasicAuthorizationHeadersBecomeAuth() throws {
        let bearer = try parse("curl https://h.test -H 'Authorization: Bearer tok123'")
        #expect(bearer.auth.kind == .bearer && bearer.auth.bearerToken.value == "tok123")
        #expect(bearer.headers.isEmpty)

        let encoded = Data("alice:p:ass".utf8).base64EncodedString()
        let basic = try parse("curl https://h.test -H 'authorization: basic \(encoded)'")
        #expect(basic.auth.kind == .basic && basic.auth.basicUsername == "alice" && basic.auth.basicPassword.value == "p:ass")

        let undecodable = try parse("curl https://h.test -H 'Authorization: Basic !!!' -H 'Authorization: Digest x'")
        #expect(undecodable.auth.kind == .none)
        #expect(undecodable.headers.map(\.key) == ["Authorization"])
        #expect(undecodable.headers[0].isSecret)
    }

    @Test func userOptionAndUrlCredentials() throws {
        let option = try parse("curl -u alice:s3cret https://h.test")
        #expect(option.auth.kind == .basic && option.auth.basicUsername == "alice" && option.auth.basicPassword.value == "s3cret")
        let onlyUser = try parse("curl --user bob https://h.test")
        #expect(onlyUser.auth.basicUsername == "bob" && onlyUser.auth.basicPassword.value == "")
        let embedded = try parse("curl https://carol:pw@h.test/x")
        #expect(embedded.url == "https://h.test/x")
        #expect(embedded.auth.basicUsername == "carol" && embedded.auth.basicPassword.value == "pw")
        #expect(try parse("curl --oauth2-bearer abc https://h.test").auth.bearerToken.value == "abc")
    }

    @Test func jsonBodyBecomesRawJSON() throws {
        let item = try parse("curl https://h.test -H 'Content-Type: application/json' -d '{\"a\": {{x}}}'")
        #expect(item.body.mode == .raw && item.body.rawLanguage == .json)
        #expect(item.body.raw == "{\"a\": {{x}}}")
        #expect(item.headers.isEmpty)
        let sniffed = try parse("curl https://h.test --data-raw '[1,2]'")
        #expect(sniffed.body.rawLanguage == .json && sniffed.body.mode == .raw)
        let custom = try parse("curl https://h.test -H 'Content-Type: application/vnd.api+json' -d '{}'")
        #expect(custom.body.rawLanguage == .json)
        #expect(custom.headers.map(\.key) == ["Content-Type"])
        let xml = try parse("curl https://h.test -H 'Content-Type: text/xml; charset=utf-8' --data-binary '<a/>'")
        #expect(xml.body.rawLanguage == .xml && xml.body.raw == "<a/>")
    }

    @Test func formBodyBecomesURLEncodedRowsWithDecodedValues() throws {
        let item = try parse("curl https://h.test -d 'name=Jane+Doe&path=a%2Fb' -d 'password=x&empty='")
        #expect(item.body.mode == .urlEncoded)
        #expect(item.body.urlEncoded.map(\.key) == ["name", "path", "password", "empty"])
        #expect(item.body.urlEncoded.map(\.value) == ["Jane Doe", "a/b", "x", ""])
        #expect(item.body.urlEncoded.map(\.isSecret) == [false, false, true, false])

        let typed = try parse("curl https://h.test -H 'Content-Type: application/x-www-form-urlencoded' -d 'a=1'")
        #expect(typed.body.mode == .urlEncoded && typed.headers.isEmpty)

        let encoded = try parse("curl https://h.test --data-urlencode 'q=a b&c' --data-urlencode 'n={{v}}'")
        #expect(encoded.body.urlEncoded.map(\.value) == ["a b&c", "{{v}}"])
    }

    @Test func plainTextBodyStaysRaw() throws {
        let item = try parse("curl https://h.test -H 'Content-Type: text/plain' -d 'hello world'")
        #expect(item.body.mode == .raw && item.body.rawLanguage == .text && item.body.raw == "hello world")
        #expect(item.headers.isEmpty)
        #expect(try parse("curl https://h.test -d @payload.bin").body == RequestBody(mode: .binary, binaryPath: "payload.bin"))
    }

    @Test func multipartForms() throws {
        let item = try parse("curl https://h.test -F 'title=Hello' -F 'doc=@/tmp/a.png;type=image/png;filename=x.png' -F 'meta={\"a\":1};type=application/json' --form-string 'raw=@not-a-file' -F 'token=abc'")
        #expect(item.method == .post && item.body.mode == .formData)
        let fields = item.body.formData
        #expect(fields.map(\.key) == ["title", "doc", "meta", "raw", "token"])
        #expect(fields.map(\.kind) == [.text, .file, .text, .text, .text])
        #expect(fields[1].value == "/tmp/a.png" && fields[1].contentType == "image/png")
        #expect(fields[2].value == "{\"a\":1}" && fields[2].contentType == "application/json")
        #expect(fields[3].value == "@not-a-file")
        #expect(fields.map(\.isSecret) == [false, false, false, false, true])
    }

    @Test func getFlagMovesDataToTheQuery() throws {
        let item = try parse("curl -G https://h.test/search -d 'q=swift' --data-urlencode 'page=2'")
        #expect(item.method == .get && item.body.mode == .none)
        #expect(item.queryParams.map { "\($0.key)=\($0.value)" } == ["q=swift", "page=2"])
    }

    @Test func settingsAndIgnoredFlags() throws {
        let item = try parse("curl -sSLk --compressed --max-time 5 -o out.txt --retry 3 -A 'Bee/9' -b 'a=b' -e https://ref.test --http2 https://h.test")
        #expect(item.url == "https://h.test")
        #expect(item.settings.verifyTLS == false && item.settings.followRedirects == true && item.settings.timeout == 5)
        #expect(item.headers.map(\.key) == ["User-Agent", "Cookie", "Referer"])
        #expect(try parse("curl https://h.test").settings == RequestSettings())
    }

    @Test func multilineCommandsParse() throws {
        let command = """
        curl -X POST 'https://api.test/v1/items' \\
          -H 'Content-Type: application/json' \\
          -H "X-Note: it's \\"quoted\\"" \\
          --data-raw $'{"line":"a\\nb"}'
        """
        let item = try parse(command)
        #expect(item.method == .post && item.name == "POST items")
        #expect(item.headers.map(\.value) == ["it's \"quoted\""])
        #expect(item.body.raw == "{\"line\":\"a\nb\"}")
    }

    // MARK: Export

    private func export(_ item: RequestItem, auth: AuthConfig = AuthConfig(kind: .none)) -> String {
        CurlCodec.command(for: item, auth: auth)
    }

    @Test func exportKeepsPlaceholdersAndEncodesLiterals() {
        var item = RequestItem(method: .post, url: "{{base}}/users", queryParams: [
            KeyValue(key: "q", value: "a b&c"), KeyValue(key: "off", value: "1", isEnabled: false), KeyValue(key: "id", value: "{{id}}"),
        ])
        item.headers = [KeyValue(key: "X-A", value: "it's")]
        item.body = RequestBody(mode: .raw, raw: "{\"a\":\"{{x}}\"}", rawLanguage: .json)
        #expect(export(item) == """
        curl -X POST '{{base}}/users?q=a%20b%26c&id={{id}}' \\
          -H 'X-A: it'\\''s' \\
          -H 'Content-Type: application/json' \\
          --data-raw '{"a":"{{x}}"}'
        """)
    }

    @Test func exportNeverContainsLiteralSecrets() {
        var item = RequestItem(url: "https://h.test", queryParams: [
            KeyValue(key: "k", value: "query-secret", isSecret: true), KeyValue(key: "ref", value: "{{tok}}", isSecret: true),
        ])
        item.headers = [KeyValue(key: "X-Key", value: "header-secret", isSecret: true), KeyValue(key: "X-Ref", value: " {{a}}{{b}} ", isSecret: true)]
        item.body = RequestBody(
            mode: .urlEncoded, urlEncoded: [KeyValue(key: "pw", value: "form-secret", isSecret: true)],
            formData: [FormField(key: "f", value: "multipart-secret", isSecret: true)]
        )
        var text = export(item)
        let literals = ["query-secret", "header-secret", "form-secret", "multipart-secret"]
        #expect(literals.allSatisfy { !text.contains($0) })
        #expect(text.contains("k=<secret>") && text.contains("ref={{tok}}"))
        #expect(text.contains("X-Key: <secret>") && text.contains("X-Ref:  {{a}}{{b}} "))
        #expect(text.contains("pw=<secret>"))

        item.body.mode = .formData
        text = export(item)
        #expect(literals.allSatisfy { !text.contains($0) })
        #expect(text.contains("f=<secret>"))
    }

    @Test func exportAuthorizationSlots() {
        let item = RequestItem(url: "https://h.test")
        let literal = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "tok-literal"))
        #expect(export(item, auth: literal).contains("-H 'Authorization: Bearer <secret>'"))
        let reference = AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{token}}"))
        #expect(export(item, auth: reference).contains("-H 'Authorization: Bearer {{token}}'"))
        let basic = AuthConfig(kind: .basic, basicUsername: "{{user}}", basicPassword: SecretField(value: "pw-literal"))
        let basicText = export(item, auth: basic)
        #expect(basicText.contains("-u '{{user}}:<secret>'") && !basicText.contains("pw-literal"))
        let apiHeader = AuthConfig(kind: .apiKey, apiKeyName: "X-Key", apiKeyValue: SecretField(value: "key-literal"))
        #expect(export(item, auth: apiHeader).contains("-H 'X-Key: <secret>'"))
        let apiQuery = AuthConfig(kind: .apiKey, apiKeyName: "key", apiKeyValue: SecretField(value: "key-literal"), apiKeyLocation: .query)
        let queryText = export(item, auth: apiQuery)
        #expect(queryText.hasPrefix("curl 'https://h.test?key=<secret>'") && !queryText.contains("key-literal"))
        #expect(!export(item, auth: AuthConfig(kind: .bearer)).contains("Authorization"))
        #expect(!export(item, auth: AuthConfig(kind: .inherit, bearerToken: SecretField(value: "x"))).contains("Authorization"))
    }

    @Test func explicitAuthorizationHeaderWinsInExport() {
        var item = RequestItem(url: "https://h.test")
        item.headers = [KeyValue(key: "authorization", value: "Token {{t}}")]
        let text = export(item, auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{other}}")))
        #expect(text.contains("authorization: Token {{t}}") && !text.contains("{{other}}"))
    }

    @Test func exportMethodsFlagsAndBodies() {
        #expect(export(RequestItem(method: .get, url: "https://h.test")) == "curl 'https://h.test'")
        #expect(export(RequestItem(method: .head, url: "https://h.test")) == "curl -I 'https://h.test'")
        var item = RequestItem(method: .put, url: "https://h.test")
        item.settings = RequestSettings(timeout: 2.5, followRedirects: true, verifyTLS: false)
        #expect(export(item).hasSuffix("-k \\\n  -L \\\n  -m 2.5"))
        item.body = RequestBody(mode: .graphQL, graphQLQuery: "{ a }", graphQLVariables: "")
        #expect(export(item).contains("--data-raw '{\"query\":\"{ a }\",\"variables\":{}}'"))
        item.body = RequestBody(mode: .binary, binaryPath: "/tmp/pic.png")
        #expect(export(item).contains("--data-binary '@/tmp/pic.png'") && export(item).contains("Content-Type: image/png"))
        item.method = .get
        #expect(export(item).hasPrefix("curl -X GET "))
        item.body = RequestBody(mode: .formData, formData: [
            FormField(key: "t", value: "x", contentType: "text/plain"), FormField(key: "at", value: "@x"),
            FormField(key: "f", kind: .file, value: "/tmp/a.txt", contentType: "text/plain"),
        ])
        let form = export(item)
        #expect(form.contains("-F 't=x;type=text/plain'") && form.contains("--form-string 'at=@x'") && form.contains("-F 'f=@/tmp/a.txt;type=text/plain'"))
    }

    @Test func exportThenParseRoundTrips() throws {
        var item = RequestItem(method: .post, url: "{{base}}/users#top", queryParams: [KeyValue(key: "q", value: "a b"), KeyValue(key: "id", value: "{{id}}")])
        item.headers = [KeyValue(key: "X-Trace", value: "it's {{t}}")]
        item.body = RequestBody(mode: .raw, raw: "{\n  \"a\": \"{{x}}\"\n}", rawLanguage: .json)
        item.settings = RequestSettings(timeout: 3, followRedirects: true, verifyTLS: false)
        let parsed = try parse(export(item, auth: AuthConfig(kind: .bearer, bearerToken: SecretField(value: "{{token}}"))))
        #expect(parsed.method == .post)
        #expect(parsed.url == "{{base}}/users#top")
        #expect(parsed.queryParams.map { "\($0.key)=\($0.value)" } == ["q=a%20b", "id={{id}}"])
        #expect(parsed.headers.map(\.key) == ["X-Trace"] && parsed.headers[0].value == "it's {{t}}")
        #expect(parsed.auth.kind == .bearer && parsed.auth.bearerToken.value == "{{token}}")
        #expect(parsed.body.mode == .raw && parsed.body.raw == item.body.raw && parsed.body.rawLanguage == .json)
        #expect(parsed.settings == item.settings)
    }

    @Test func parsedRequestBuildsTheSameWireRequest() throws {
        let item = try parse("curl 'https://h.test/p?q=a%20b&plus=1%2B1' -H 'Accept: text/csv' -d 'name=Jane+Doe&n=1%262'")
        let built = try RequestBuilder.build(item: item, auth: item.auth, context: VariableContext(), settings: AppSettings())
        #expect(built.request.url.absoluteString == "https://h.test/p?q=a%20b&plus=1%2B1")
        #expect(built.request.bodyText == "name=Jane+Doe&n=1%262")
        #expect(built.request.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(built.request.header("Accept") == "text/csv")
    }

    @Test func parseErrorDescriptionsAreReadable() {
        #expect(CurlParseError.notACurlCommand.errorDescription != nil)
        #expect(CurlParseError.missingURL.errorDescription != nil)
        #expect(CurlParseError.malformed("why").errorDescription?.contains("why") == true)
    }
}
