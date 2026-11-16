import Foundation
import Testing
@testable import BeeCore

@Suite struct PathVariablesTests {
    private func names(_ address: String) -> [String] { PathVariables.names(in: address) }

    private func render(
        _ address: String, rows: [KeyValue] = [], vars: [String: String] = [:], secrets: [String: String] = [:],
        mask: String? = nil
    ) -> RenderResult {
        let context = VariableContext(environment: vars.map { Variable(name: $0.key, value: $0.value) }
            + secrets.map { Variable(name: $0.key, value: $0.value, isSecret: true) })
        return PathVariables.render(address, rows: rows, in: context, secretMask: mask)
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

    @Test func aRenamedVariableKeepsItsRow() {
        let row = KeyValue(key: "ticketId", value: "42", isSecret: true)
        for renamed in ["ticketI", "ticketIds", "ticketIx", "icketId"] {
            let rows = PathVariables.rows(for: "/t/:\(renamed)", from: [row])
            #expect(rows.count == 1)
            #expect(rows[0].id == row.id)
            #expect(rows[0].key == renamed)
            #expect(rows[0].value == "42")
        }
        // Another name altogether is another variable.
        #expect(PathVariables.rows(for: "/t/:userId", from: [row])[0].id != row.id)
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

    @Test func secretsAreReportedAndMaskedOnRequest() {
        let secretRow = [KeyValue(key: "token", value: "s3cr3t-value", isSecret: true)]
        let sent = render("https://h/reset/:token", rows: secretRow)
        #expect(sent.text == "https://h/reset/s3cr3t-value")
        #expect(sent.usedSecret)
        #expect(render("https://h/reset/:token", rows: secretRow, mask: "••••••").text == "https://h/reset/••••••")

        let viaVariable = render("https://h/reset/:token", secrets: ["token": "s3cr3t-value"], mask: "••••••")
        #expect(viaVariable.text == "https://h/reset/••••••")
        #expect(viaVariable.usedSecret)

        // A secret row that only refers to a plain variable hides nothing.
        let reference = [KeyValue(key: "token", value: "{{plain}}", isSecret: true)]
        #expect(render("https://h/reset/:token", rows: reference, vars: ["plain": "abc"], mask: "••••••").text == "https://h/reset/abc")
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
                KeyValue(key: "org", value: "acme corp"),
                KeyValue(key: "token", value: "s3cr3t-value", isSecret: true),
            ]
        )
        let command = CurlCodec.command(for: item, auth: AuthConfig(kind: .none))
        #expect(command == "curl '{{baseUrl}}/orgs/acme%20corp/tickets/{{ticketId}}/reset/<secret>'")
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
