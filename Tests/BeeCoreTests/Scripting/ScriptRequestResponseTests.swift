import Foundation
import Testing
@testable import BeeCore

@Suite struct ScriptRequestTests {
    private static let request = ScriptRequest(
        method: "POST", url: "{{baseUrl}}/users",
        headers: [HeaderEntry(name: "Content-Type", value: "application/json"), HeaderEntry(name: "X-Trace", value: "1")],
        body: #"{"a":1}"#
    )

    @Test func exposesTheRequest() async {
        let result = await ScriptHarness.evaluate(
            "[bee.request.method, bee.request.url, bee.request.body, bee.request.headers.get('content-type'), bee.request.headers.has('X-TRACE'), bee.request.headers.has('nope'), typeof bee.request.headers.get('nope')].join('|')",
            request: Self.request
        )
        #expect(result == #"POST|{{baseUrl}}/users|{"a":1}|application/json|true|false|undefined"#)
    }

    @Test func bodyIsNullWhenTheRequestHasNone() async {
        #expect(await ScriptHarness.evaluate("bee.request.body === null") == "true")
    }

    @Test func headersToObject() async {
        let result = await ScriptHarness.evaluate("JSON.stringify(bee.request.headers.toObject())", request: Self.request)
        #expect(result == #"{"Content-Type":"application/json","X-Trace":"1"}"#)
    }

    @Test func preRequestScriptsRewriteTheRequest() async {
        let output = await ScriptHarness.run("""
        bee.request.method = 'put';
        bee.request.url = bee.request.url + '?debug=1';
        bee.request.body = {changed: true};
        bee.request.headers.add({key: 'X-Added', value: 'a'});
        bee.request.headers.add({key: 'X-Added', value: 'b'});
        bee.request.headers.upsert({key: 'x-trace', value: '2'});
        bee.request.headers.upsert({key: 'X-New', value: 'n'});
        bee.request.headers.remove('CONTENT-TYPE');
        """, request: Self.request)
        #expect(output.failure == nil)
        #expect(output.request.method == "PUT")
        #expect(output.request.url == "{{baseUrl}}/users?debug=1")
        #expect(output.request.body == #"{"changed":true}"#)
        #expect(output.request.headers == [
            HeaderEntry(name: "x-trace", value: "2"), HeaderEntry(name: "X-Added", value: "a"),
            HeaderEntry(name: "X-Added", value: "b"), HeaderEntry(name: "X-New", value: "n"),
        ])
    }

    @Test func upsertCollapsesDuplicatesAndRemoveDropsAllMatches() async {
        let request = ScriptRequest(method: "GET", url: "u", headers: [
            HeaderEntry(name: "A", value: "1"), HeaderEntry(name: "B", value: "x"), HeaderEntry(name: "a", value: "2"),
        ])
        let output = await ScriptHarness.run("bee.request.headers.upsert({key: 'A', value: '3'})", request: request)
        #expect(output.request.headers == [HeaderEntry(name: "A", value: "3"), HeaderEntry(name: "B", value: "x")])
        let removed = await ScriptHarness.run("bee.request.headers.remove('a')", request: request)
        #expect(removed.request.headers == [HeaderEntry(name: "B", value: "x")])
    }

    @Test func assigningNullClearsTheBody() async {
        let output = await ScriptHarness.run("bee.request.body = null", request: Self.request)
        #expect(output.request.body == nil)
        #expect(output.request.method == "POST")
    }

    @Test func changesAreVisibleToLaterSources() async {
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "Collection", code: "bee.request.headers.add({key: 'X-From', value: 'collection'})"),
            ScriptSource(label: "Request", code: "bee.request.url += '/' + bee.request.headers.get('x-from')"),
        ], request: ScriptRequest(method: "GET", url: "https://e.com"))
        #expect(output.request.url == "https://e.com/collection")
        #expect(output.request.headers == [HeaderEntry(name: "X-From", value: "collection")])
    }

    @Test func headerArgumentsAreValidated() async {
        let output = await ScriptHarness.run("bee.request.headers.add('nope')")
        #expect(output.failure?.message.contains("header must be an object") == true)
    }

    @Test func requestIsReadOnlyInThePostResponsePhase() async {
        let output = await ScriptHarness.run("""
        bee.request.method = 'DELETE';
        bee.request.url = 'https://evil.example';
        bee.request.body = 'x';
        bee.request.headers.add({key: 'X-Added', value: 'a'});
        bee.request.headers.upsert({key: 'X-Trace', value: '9'});
        bee.request.headers.remove('Content-Type');
        console.log(bee.request.method, bee.request.url, bee.request.body, bee.request.headers.get('x-trace'), bee.request.headers.has('content-type'));
        """, phase: .postResponse, request: Self.request, response: ScriptHarness.jsonResponse())
        #expect(output.failure == nil)
        #expect(output.request == Self.request)
        #expect(output.console.first?.message == #"POST {{baseUrl}}/users {"a":1} 1 true"#)
    }

    @Test func infoDescribesTheRequestAndPhase() async {
        let pre = await ScriptHarness.evaluate("[bee.info.requestName, bee.info.eventName].join()")
        #expect(pre == "Get user,prerequest")
        let post = await ScriptHarness.evaluate("[bee.info.requestName, bee.info.eventName].join()",
                                                 phase: .postResponse, response: ScriptHarness.jsonResponse())
        #expect(post == "Get user,test")
    }

    @Test func pmIsTheSameObjectAsBee() async {
        #expect(await ScriptHarness.evaluate("pm === bee && pm.request === bee.request") == "true")
    }
}

@Suite struct ScriptResponseTests {
    private static let response = ScriptResponse(
        code: 201, status: "Created",
        headers: [HeaderEntry(name: "Content-Type", value: "application/json; charset=utf-8"),
                  HeaderEntry(name: "X-Rate", value: "5")],
        body: Data(#"{"id":7,"tags":["a","b"]}"#.utf8), responseTime: 123.5
    )

    private func evaluate(_ expression: String, response: ScriptResponse = Self.response) async -> String? {
        await ScriptHarness.evaluate(expression, phase: .postResponse, response: response)
    }

    @Test func accessors() async {
        let result = await evaluate("""
        [bee.response.code, bee.response.status, bee.response.responseTime, bee.response.responseSize,
         bee.response.headers.get('content-type'), bee.response.headers.has('X-RATE'), bee.response.headers.has('x'),
         typeof bee.response.headers.get('x'), bee.response.text()].join('|')
        """)
        #expect(result == #"201|Created|123.5|25|application/json; charset=utf-8|true|false|undefined|{"id":7,"tags":["a","b"]}"#)
    }

    @Test func headersToObject() async {
        #expect(await evaluate("JSON.stringify(bee.response.headers.toObject())")
            == #"{"Content-Type":"application/json; charset=utf-8","X-Rate":"5"}"#)
    }

    @Test func jsonParsesTheBody() async {
        #expect(await evaluate("bee.response.json().tags.join('+') + bee.response.json().id") == "a+b7")
    }

    @Test func jsonToleratesAByteOrderMark() async {
        let response = ScriptResponse(code: 200, status: "OK", body: Data([0xEF, 0xBB, 0xBF]) + Data(#"{"ok":true}"#.utf8))
        #expect(await evaluate("bee.response.json().ok", response: response) == "true")
    }

    @Test(arguments: ["not json", "", "{\"a\":"])
    func jsonThrowsAClearErrorWhenTheBodyIsNotJSON(body: String) async {
        let response = ScriptResponse(code: 200, status: "OK", body: Data(body.utf8))
        let result = await evaluate("(() => { try { bee.response.json(); return 'no error'; } catch (e) { return e.message; } })()",
                                    response: response)
        #expect(result == "Response body is not valid JSON")
    }

    @Test func sizeCountsBytesNotCharacters() async {
        let response = ScriptResponse(code: 200, status: "OK", body: Data("héllo".utf8))
        #expect(await evaluate("[bee.response.responseSize, bee.response.text().length].join()", response: response) == "6,5")
    }

    @Test func isUndefinedInThePreRequestPhase() async {
        let output = await ScriptHarness.run(
            "console.log(typeof bee.response, 'response' in bee)", phase: .preRequest, response: Self.response
        )
        #expect(output.console.first?.message == "undefined false")
    }

    @Test func isUndefinedWhenNoResponseIsProvided() async {
        #expect(await ScriptHarness.evaluate("typeof bee.response", phase: .postResponse) == "undefined")
    }

    @Test func responseAssertions() async {
        let output = await ScriptHarness.run("""
        bee.test('status', () => bee.response.to.have.status(201));
        bee.test('status by reason', () => bee.response.to.have.status('Created'));
        bee.test('not status', () => bee.response.to.not.have.status(200));
        bee.test('wrong status', () => bee.response.to.have.status(200));
        bee.test('header', () => bee.response.to.have.header('content-type'));
        bee.test('header value', () => bee.response.to.have.header('X-Rate', '5'));
        bee.test('wrong header value', () => bee.response.to.have.header('X-Rate', '6'));
        bee.test('missing header', () => bee.response.to.have.header('X-Missing'));
        bee.test('ok', () => bee.response.to.be.ok);
        bee.test('not ok', () => bee.response.to.not.be.ok);
        bee.test('via expect', () => bee.expect(bee.response).to.have.status(201));
        """, phase: .postResponse, response: Self.response)
        let results = Dictionary(uniqueKeysWithValues: output.tests.map { ($0.name, $0) })
        for name in ["status", "status by reason", "not status", "header", "header value", "ok", "via expect"] {
            #expect(results[name]?.passed == true, Comment(rawValue: name))
        }
        #expect(results["wrong status"]?.message == "expected response to have status code 200 but got 201")
        #expect(results["wrong header value"]?.message == "expected response to have header 'X-Rate' with value '6' but got '5'")
        #expect(results["missing header"]?.message == "expected response to have header 'X-Missing'")
        #expect(results["not ok"]?.message == "expected response to not be ok (a 2xx status)")
    }

    @Test func okFailsOutsideTheTwoHundredRange() async {
        let output = await ScriptHarness.run("""
        bee.test('404 is not ok', () => bee.response.to.be.ok);
        bee.test('404 not ok', () => bee.response.to.not.be.ok);
        """, phase: .postResponse, response: ScriptHarness.jsonResponse(code: 404, status: "Not Found"))
        #expect(output.test(named: "404 is not ok")?.message == "expected response to be ok (a 2xx status) but got status code 404")
        #expect(output.test(named: "404 not ok")?.passed == true)
    }

    @Test func statusMatcherRejectsNonResponseTargets() async {
        let output = await ScriptHarness.run("bee.test('t', () => bee.expect({code: 200}).to.have.status(200))")
        #expect(output.test(named: "t")?.message == "status() is only available when the target is a response")
    }
}
