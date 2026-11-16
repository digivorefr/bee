import Foundation
import Testing
@testable import BeeCore

@Suite struct PathVariablesTests {
    private func names(_ address: String) -> [String] { PathVariables.names(in: address) }

    private func render(
        _ address: String, rows: [KeyValue] = [], vars: [String: String] = [:], secrets: [String: String] = [:]
    ) -> RenderResult {
        let context = VariableContext(environment: vars.map { Variable(name: $0.key, value: $0.value) }
            + secrets.map { Variable(name: $0.key, value: $0.value, isSecret: true) })
        return PathVariables.render(address, rows: rows, in: context)
    }

    // MARK: Detection

    @Test(arguments: [
        ("https://api.example.com/tickets/:ticketId", ["ticketId"]),
        ("{{baseUrl}}/tickets/:ticketId/comments/:commentId", ["ticketId", "commentId"]),
        ("localhost:3000/users/:id", ["id"]),
        ("api.example.com/:a/:b?x=:c#:d", ["a", "b"]),
        ("{{scheme}}://{{host}}/v1/:_private", ["_private"]),
        ("https://example.com/:id/again/:id", ["id"]),
        ("https://example.com/files/:name.json", ["name.json"]),
    ])
    func findsSegmentsThatStartWithAColon(address: String, expected: [String]) {
        #expect(names(address) == expected)
    }

    @Test(arguments: [
        "https://example.com",
        "https://user:pass@example.com:8443/path",
        "localhost:3000",
        "http://[::1]:8080/a",
        "https://example.com/time/12:30",
        "https://example.com/v1/things:cancel",
        "https://example.com/:",
        "https://example.com/:8080",
        "https://example.com/:{{name}}",
        "https://example.com/:id{{suffix}}",
        "https://example.com?next=/:id",
        "https://example.com#/:id",
        "{{baseUrl}}",
        "",
    ])
    func ignoresEverythingElse(address: String) {
        #expect(names(address).isEmpty)
    }

    @Test func aColonInsideAPlaceholderIsNotADelimiter() {
        #expect(names("{{a:b}}/x/:id") == ["id"])
        #expect(names("https://example.com/{{ /:no }}/:yes") == ["yes"])
    }

    @Test func occurrenceRangesCoverTheColonAndTheName() {
        let address = "é://h/:id/x"
        let occurrence = PathVariables.occurrences(in: address)[0]
        #expect(address[occurrence.range] == ":id")
        #expect((address as NSString).substring(with: occurrence.nsRange) == ":id")
    }

    // MARK: Rows

    @Test func rowsFollowTheAddressAndKeepTheirValues() {
        let id = KeyValue(key: "id", value: "42")
        let rows = PathVariables.rows(for: "/a/:org/b/:id", from: [id, KeyValue(key: "gone", value: "x")])
        #expect(rows.map(\.key) == ["org", "id"])
        #expect(rows[0].value.isEmpty)
        #expect(rows[1] == id)
    }

    @Test func aVariableRenamedByOneKeystrokeKeepsItsRow() {
        let row = KeyValue(key: "ticketId", value: "42", isSecret: true)
        for renamed in ["ticketI", "ticketIds", "ticketIx", "icketId"] {
            let rows = PathVariables.rows(for: "/t/:\(renamed)/x", from: [row], renamedFrom: "/t/:ticketId/x")
            #expect(rows.count == 1)
            #expect(rows[0].id == row.id)
            #expect(rows[0].key == renamed)
            #expect(rows[0].value == "42")
        }
    }

    @Test func nothingIsCarriedToAnotherVariable() {
        let row = KeyValue(key: "id", value: "s3cr3t-value", isSecret: true)
        // Without the address it came from, a name one letter away is still another variable (an import).
        #expect(PathVariables.rows(for: "/t/:pid", from: [row])[0].id != row.id)
        // A pasted address is not a rename, however close the names are.
        let pasted = PathVariables.rows(for: "https://other.example/items/:pid", from: [row], renamedFrom: "https://h/t/:id")
        #expect(pasted[0].id != row.id)
        #expect(pasted[0].value.isEmpty)
        // One keystroke that splits a name does not rename it either.
        let split = PathVariables.rows(for: "/t/:tick/etId", from: [KeyValue(key: "ticketId", value: "42")], renamedFrom: "/t/:ticketId")
        #expect(split.map(\.value) == [""])
        // Nor does a keystroke elsewhere in the address make a new name inherit a row.
        let other = PathVariables.rows(for: "/t/:id/:i", from: [row], renamedFrom: "/t/:id/:")
        #expect(other.map(\.key) == ["id", "i"])
        #expect(other[1].value.isEmpty)
    }

    @Test func aRowWhoseNameLeavesTheAddressIsSetAsideAndComesBack() {
        let row = KeyValue(key: "ticketId", value: "42", isSecret: true)
        // A stray `#` hides the path variable for one keystroke.
        var state = PathVariables.reconcile(stored: [row], aside: [], address: "/us#ers/:ticketId", previous: "/users/:ticketId")
        #expect(state.stored.isEmpty)
        #expect(state.aside == [row])
        state = PathVariables.reconcile(stored: state.stored, aside: state.aside, address: "/users/:ticketId", previous: "/us#ers/:ticketId")
        #expect(state.stored == [row])
        #expect(state.aside.isEmpty)

        // Cut, then pasted elsewhere in the address.
        state = PathVariables.reconcile(stored: [row], aside: [], address: "/users", previous: "/users/:ticketId")
        state = PathVariables.reconcile(stored: state.stored, aside: state.aside, address: "/:ticketId/users", previous: "/users")
        #expect(state.stored == [row])

        // A row set aside is never given to another name, even one keystroke away.
        state = PathVariables.reconcile(stored: [], aside: [row], address: "/users/:ticketI", previous: "/users/:ticket")
        #expect(state.stored.isEmpty)
        #expect(state.aside == [row])

        // A newer row of the same name replaces the one set aside.
        let newer = KeyValue(key: "ticketId", value: "43")
        state = PathVariables.reconcile(stored: [newer], aside: [row], address: "/users", previous: "/users/:ticketId")
        #expect(state.aside == [newer])
    }

    @Test func onlyRowsThatSaySomethingAreStored() {
        let secret = KeyValue(key: "b", value: "", isSecret: true)
        let stored = PathVariables.storedRows(
            for: "/:a/:b/:c", from: [KeyValue(key: "a"), secret, KeyValue(key: "c", value: "1"), KeyValue(key: "d", value: "2")]
        )
        #expect(stored.map(\.key) == ["b", "c"])
    }

    @Test func aDisabledRowStillApplies() {
        let rows = PathVariables.rows(for: "/:id", from: [KeyValue(key: "id", value: "1", isEnabled: false)])
        #expect(rows[0].isEnabled)
    }

    // MARK: Rendering

    @Test func aRowValueReplacesTheSegment() {
        let result = render("{{base}}/tickets/:ticketId/x", rows: [KeyValue(key: "ticketId", value: "42")], vars: ["base": "https://h"])
        #expect(result.text == "https://h/tickets/42/x")
        #expect(result.unresolved.isEmpty)
        #expect(!result.usedSecret)
    }

    @Test func aRowValueMayUseVariables() {
        let rows = [KeyValue(key: "ticketId", value: "T-{{number}}")]
        #expect(render("https://h/tickets/:ticketId", rows: rows, vars: ["number": "7"]).text == "https://h/tickets/T-7")
    }

    @Test func withoutAValueTheVariableOfTheSameNameIsUsed() {
        #expect(render("https://h/t/:ticketId", vars: ["ticketId": "9"]).text == "https://h/t/9")
        #expect(render("https://h/t/:ticketId", rows: [KeyValue(key: "ticketId")], vars: ["ticketId": "9"]).text == "https://h/t/9")
    }

    @Test func withoutAnyValueTheNameIsReportedUnresolved() {
        let result = render("https://h/t/:ticketId/:other", vars: ["other": "1"])
        #expect(result.unresolved == ["ticketId"])
        #expect(result.text == "https://h/t/%7B%7BticketId%7D%7D/1")
    }

    @Test func theValueIsEncodedAsOneSegment() {
        let rows = [KeyValue(key: "id", value: " group/project name?#%41%zz ")]
        #expect(render("https://h/p/:id/x", rows: rows).text == "https://h/p/group%2Fproject%20name%3F%23%41%25zz/x")
        // What is typed in the address itself is left as it is.
        #expect(render("https://h/{{path}}/:id", rows: [KeyValue(key: "id", value: "1")], vars: ["path": "a/b"]).text == "https://h/a/b/1")
    }

    @Test func everyOccurrenceOfANameIsReplaced() {
        #expect(render("https://h/:id/copy/:id", rows: [KeyValue(key: "id", value: "5")]).text == "https://h/5/copy/5")
    }

    @Test func secretsAreReportedAndMaskedInWhatIsShown() {
        // Short on purpose: a secret is masked where it is put in, not by looking for its value.
        let secretRow = [KeyValue(key: "pin", value: "12", isSecret: true)]
        let sent = render("https://h/reset/:pin/done", rows: secretRow)
        #expect(sent.text == "https://h/reset/12/done")
        #expect(sent.shown == "https://h/reset/••••••/done")
        #expect(sent.usedSecret)

        let viaVariable = render("{{base}}/reset/:pin", vars: ["base": "https://h"], secrets: ["pin": "7"])
        #expect(viaVariable.text == "https://h/reset/7")
        #expect(viaVariable.shown == "https://h/reset/••••••")
        #expect(viaVariable.usedSecret)

        // A secret row that only refers to a plain variable hides nothing.
        let reference = [KeyValue(key: "pin", value: "{{plain}}", isSecret: true)]
        #expect(render("https://h/reset/:pin", rows: reference, vars: ["plain": "abc"]).shown == "https://h/reset/abc")
    }

    @Test func aValueOfSpacesIsNoValue() {
        let rows = [KeyValue(key: "id", value: "   ")]
        #expect(PathVariables.valueTemplate(for: "id", in: rows) == "{{id}}")
        #expect(render("https://h/:id", rows: rows, vars: ["id": "9"]).text == "https://h/9")
        #expect(PathVariables.valueTemplate(for: "id", in: [KeyValue(key: "id", value: " 42 ")]) == "42")
        #expect(!PathVariables.holdsSecret(KeyValue(key: "id", value: "  ", isSecret: true)))
    }

    @Test func substitutingReplacesEachSegment() {
        #expect(PathVariables.substituting("{{b}}/:a/x/:b?q=:c") { "<\($0)>" } == "{{b}}/<a>/x/<b>?q=:c")
        #expect(PathVariables.valueTemplate(for: "a", in: [KeyValue(key: "a", value: "")]) == "{{a}}")
        #expect(PathVariables.valueTemplate(for: "a", in: [KeyValue(key: "a", value: "1")]) == "1")
    }
}

@Suite struct PathVariableIntegrationTests {
    @Test func theBuilderSendsThePathVariables() throws {
        let item = RequestItem(
            url: "{{baseUrl}}/tickets/:ticketId/comments/:commentId",
            pathVariables: [KeyValue(key: "commentId", value: "c 1")],
            queryParams: [KeyValue(key: "page", value: "2")]
        )
        let context = VariableContext(
            environment: [Variable(name: "baseUrl", value: "https://api.example.com")],
            collection: [Variable(name: "ticketId", value: "T-42")]
        )
        let output = try RequestBuilder.build(item: item, auth: AuthConfig(kind: .none), context: context, settings: AppSettings())
        #expect(output.request.url.absoluteString == "https://api.example.com/tickets/T-42/comments/c%201?page=2")
        #expect(output.unresolvedVariables.isEmpty)
    }

    @Test func theBuilderReportsAPathVariableWithoutValue() throws {
        let item = RequestItem(url: "https://api.example.com/tickets/:ticketId")
        let output = try RequestBuilder.build(item: item, auth: AuthConfig(kind: .none), context: VariableContext(), settings: AppSettings())
        #expect(output.unresolvedVariables == ["ticketId"])
    }

    @Test func anInvalidAddressNeverShowsASecretPathValue() {
        let item = RequestItem(url: "http://:host/x", pathVariables: [])
        let withSecret = RequestItem(
            url: "ftp://example.com/:token", pathVariables: [KeyValue(key: "token", value: "s3cr3t-value", isSecret: true)]
        )
        #expect(throws: RequestBuildError.self) {
            _ = try RequestBuilder.build(item: item, auth: AuthConfig(kind: .none), context: VariableContext(), settings: AppSettings())
        }
        #expect(throws: RequestBuildError.invalidURL("ftp://example.com/:token")) {
            _ = try RequestBuilder.build(item: withSecret, auth: AuthConfig(kind: .none), context: VariableContext(), settings: AppSettings())
        }
    }

    @Test func curlWritesPathVariablesOutAndNeverASecret() {
        let item = RequestItem(
            url: "{{baseUrl}}/orgs/:org/tickets/:ticketId/reset/:token",
            pathVariables: [
                KeyValue(key: "org", value: " acme corp "),
                KeyValue(key: "token", value: "s3cr3t-value", isSecret: true),
            ]
        )
        let command = CurlCodec.command(for: item, auth: AuthConfig(kind: .none))
        // The same trimmed value as the one that is sent.
        #expect(command == "curl '{{baseUrl}}/orgs/acme%20corp/tickets/{{ticketId}}/reset/<secret>'")
    }

    @Test func whatIsShownOfARequestHidesSecretsOfAnyLength() throws {
        let item = RequestItem(
            method: .post,
            url: "https://api.example.com/reset/:pin?fixed=1",
            pathVariables: [KeyValue(key: "pin", value: "123", isSecret: true)],
            queryParams: [
                KeyValue(key: "code", value: "77", isSecret: true),
                KeyValue(key: "via", value: "{{otp}}"),
                KeyValue(key: "plain", value: "a b"),
            ],
            headers: [KeyValue(key: "X-Pin", value: "99", isSecret: true), KeyValue(key: "X-Plain", value: "ok")],
            auth: AuthConfig(kind: .apiKey, apiKeyName: "k", apiKeyValue: SecretField(value: "zz"), apiKeyLocation: .query),
            body: RequestBody(mode: .raw, raw: "{\"otp\": \"{{otp}}\", \"at\": {{$timestamp}}}")
        )
        let context = VariableContext(environment: [Variable(name: "otp", value: "55", isSecret: true)])
        let output = try RequestBuilder.build(item: item, auth: item.auth, context: context, settings: AppSettings())

        #expect(output.request.url.absoluteString == "https://api.example.com/reset/123?fixed=1&code=77&via=55&plain=a%20b&k=zz")
        #expect(output.shownURL == "https://api.example.com/reset/••••••?fixed=1&code=••••••&via=••••••&plain=a%20b&k=••••••")
        #expect(output.shownHeaders.first { $0.name == "X-Pin" }?.value == "••••••")
        #expect(output.shownHeaders.first { $0.name == "X-Plain" }?.value == "ok")
        #expect(output.request.headers.first { $0.name == "X-Pin" }?.value == "99")

        // The body is rendered once: the dynamic value is the same in what is sent and in what is shown.
        guard case .data(let data) = output.request.body else {
            Issue.record("expected a data body")
            return
        }
        let sent = String(decoding: data, as: UTF8.self)
        #expect(sent.contains("\"otp\": \"55\""))
        #expect(output.shownBody == sent.replacingOccurrences(of: "\"55\"", with: "\"••••••\""))
    }

    @Test func withoutSecretsWhatIsShownIsWhatIsSent() throws {
        let item = RequestItem(
            url: "example.com/a b/:id", pathVariables: [KeyValue(key: "id", value: "x/y")],
            queryParams: [KeyValue(key: "q", value: "é")],
            auth: AuthConfig(kind: .basic, basicUsername: "u", basicPassword: SecretField(value: "p"))
        )
        let output = try RequestBuilder.build(item: item, auth: item.auth, context: VariableContext(), settings: AppSettings())
        #expect(output.shownURL == output.request.url.absoluteString)
        #expect(output.shownHeaders.first { $0.name == "Authorization" }?.value == "Basic ••••••")
        #expect(output.shownHeaders.count == output.request.headers.count)
    }

    @Test func postmanPathVariablesAreImported() throws {
        let json = """
        {"info": {"name": "C", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
         "item": [{"name": "Ticket", "request": {"method": "GET", "url": {
            "raw": "{{baseUrl}}/tickets/:ticketId/users/:userId/keys/:apiKey?expand=1",
            "host": ["{{baseUrl}}"], "path": ["tickets", ":ticketId", "users", ":userId", "keys", ":apiKey"],
            "query": [{"key": "expand", "value": "1"}],
            "variable": [
                {"key": "ticketId", "value": "{{currentTicket}}", "description": "The ticket"},
                {"key": "userId", "value": ""},
                {"key": "apiKey", "value": "k-123456"},
                {"key": "unused", "value": "x"}
            ]}}}]}
        """
        let collection = try Importer.collection(from: Data(json.utf8))
        let request = try #require(collection.allRequests.first)
        #expect(request.url == "{{baseUrl}}/tickets/:ticketId/users/:userId/keys/:apiKey")
        #expect(request.pathVariables.map(\.key) == ["ticketId", "apiKey"])
        #expect(request.pathVariables[0].value == "{{currentTicket}}")
        #expect(request.pathVariables[1].isSecret)
        #expect(request.queryParams.map(\.key) == ["expand"])
    }

    @Test func requestsWrittenBeforePathVariablesStillDecode() throws {
        let id = UUID()
        let legacy = """
        {"id": "\(id.uuidString)", "name": "Old", "method": "POST", "url": "https://h/:id",
         "queryParams": [], "headers": [], "auth": {"kind": "none", "bearerToken": {"id": "\(UUID().uuidString)"},
         "basicUsername": "", "basicPassword": {"id": "\(UUID().uuidString)"}, "apiKeyName": "",
         "apiKeyValue": {"id": "\(UUID().uuidString)"}, "apiKeyLocation": "header"},
         "body": {"mode": "none", "raw": "", "rawLanguage": "json", "urlEncoded": [], "formData": [],
         "binaryPath": "", "graphQLQuery": "", "graphQLVariables": ""},
         "preRequestScript": "", "postResponseScript": "", "settings": {}, "notes": ""}
        """
        let item = try JSONDecoder().decode(RequestItem.self, from: Data(legacy.utf8))
        #expect(item.id == id)
        #expect(item.method == .post)
        #expect(item.pathVariables.isEmpty)
    }

    @Test func pathVariableSecretsStayOutOfEncodedRequestsAndGetFreshSlots() throws {
        let item = RequestItem(
            url: "https://h/:token", pathVariables: [KeyValue(key: "token", value: "s3cr3t-value", isSecret: true)]
        )
        let encoded = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        #expect(!encoded.contains("s3cr3t-value"))
        #expect(item.secretValues() == ["s3cr3t-value"])
        let copy = item.duplicated()
        #expect(copy.pathVariables[0].id != item.pathVariables[0].id)
        #expect(copy.pathVariables[0].value == "s3cr3t-value")
    }
}
