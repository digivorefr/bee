import Foundation
import Testing
@testable import BeeCore

@Suite struct ScriptSendRequestTests {
    @Test func promiseFormResolvesToAResponseShapedLikeBeeResponse() async {
        let transport = FakeTransport(body: #"{"ok":true,"n":3}"#)
        let output = await ScriptHarness.run("""
        const res = await bee.sendRequest('https://api.example.com/ping');
        console.log([res.code, res.status, res.responseTime, res.responseSize, res.headers.get('x-test'), res.json().n, res.text().length].join('|'));
        bee.test('assertions work', () => res.to.have.status(200));
        bee.test('ok', () => res.to.be.ok);
        """, transport: transport)
        #expect(output.failure == nil)
        #expect(output.console.first?.message == "200|OK|42|17|yes|3|17")
        #expect(output.tests.map(\.passed) == [true, true])
        #expect(transport.requests.count == 1)
        let sent = transport.requests[0]
        #expect(sent.method == "GET")
        #expect(sent.url.absoluteString == "https://api.example.com/ping")
        #expect(sent.timeout == 30)
        #expect(sent.followRedirects)
        #expect(sent.verifyTLS)
        #expect(sent.body == .none)
    }

    @Test func callbackFormReceivesErrorAndResponse() async {
        let output = await ScriptHarness.run("""
        bee.sendRequest('https://api.example.com/a', (err, res) => {
          console.log('callback', err, res.code);
          bee.test('in callback', () => bee.expect(res.json().ok).to.be.true);
        });
        """, transport: FakeTransport())
        // The source finishes without awaiting; the engine still delivers the callback before returning.
        #expect(output.failure == nil)
        #expect(output.console.map(\.message) == ["callback null 200"])
        #expect(output.tests.map(\.passed) == [true])
    }

    @Test func optionsBuildTheTransportRequest() async {
        let transport = FakeTransport()
        _ = await ScriptHarness.run("""
        await bee.sendRequest({url: 'https://e.com/raw', method: 'post', header: {'X-A': '1', 'Content-Type': 'text/plain'}, body: 'hello'});
        await bee.sendRequest({url: 'https://e.com/arr', method: 'PUT', header: [{key: 'X-B', value: '2'}, {key: 'X-Off', value: 'no', disabled: true}], body: {mode: 'raw', raw: '{"a":1}'}});
        await bee.sendRequest({url: 'https://e.com/form', method: 'POST', body: {mode: 'urlencoded', urlencoded: [{key: 'a b', value: 'c&d'}, {key: 'x', value: '1'}, {key: 'off', value: '0', disabled: true}]}});
        """, transport: transport)
        let sent = transport.requests
        #expect(sent.count == 3)
        #expect(sent[0].method == "POST")
        #expect(sent[0].headers == [HeaderEntry(name: "X-A", value: "1"), HeaderEntry(name: "Content-Type", value: "text/plain")])
        #expect(sent[0].body == .data(Data("hello".utf8)))
        #expect(sent[1].method == "PUT")
        #expect(sent[1].headers == [HeaderEntry(name: "X-B", value: "2")])
        #expect(sent[1].body == .data(Data(#"{"a":1}"#.utf8)))
        #expect(sent[2].body == .data(Data("a+b=c%26d&x=1".utf8)))
        #expect(sent[2].headers == [HeaderEntry(name: "Content-Type", value: "application/x-www-form-urlencoded")])
    }

    @Test func variablesAreNotSubstitutedAutomatically() async {
        let transport = FakeTransport()
        _ = await ScriptHarness.run("""
        await bee.sendRequest(bee.variables.replaceIn('https://{{host}}/{{path}}'));
        """, scopes: ScriptScopes(locals: ["host": "api.example.com"], environmentName: "Dev"), transport: transport)
        #expect(transport.requests.first?.url.absoluteString == "https://api.example.com/%7B%7Bpath%7D%7D"
            || transport.requests.first?.url.absoluteString == "https://api.example.com/{{path}}")
    }

    @Test func withoutATransportTheCallRejectsWithAClearError() async {
        let output = await ScriptHarness.run("""
        try { await bee.sendRequest('https://e.com'); } catch (e) { console.log('promise', e.message); }
        bee.sendRequest('https://e.com', (err, res) => console.log('callback', err.message, res));
        """)
        let expected = "bee.sendRequest is not available: no HTTP transport is configured"
        #expect(output.failure == nil)
        #expect(output.console.map(\.message) == ["promise " + expected, "callback " + expected + " undefined"])
    }

    @Test func transportErrorsRejectTheCall() async {
        let transport = FakeTransport { _ in throw TransportFailure() }
        let output = await ScriptHarness.run("""
        try { await bee.sendRequest('https://e.com'); } catch (e) { console.log(e.message); }
        await bee.sendRequest('https://e.com');
        """, transport: transport)
        #expect(output.console.map(\.message) == ["connection refused"])
        #expect(output.failure?.message == "connection refused")
    }

    @Test(arguments: ["file:///etc/passwd", "ftp://e.com/x", "not a url", "/relative", "{}"])
    func onlyAbsoluteHTTPURLsAreAccepted(url: String) async {
        let transport = FakeTransport()
        let literal = url == "{}" ? "{method: 'GET'}" : "'\(url)'"
        let output = await ScriptHarness.run("""
        try { await bee.sendRequest(\(literal)); console.log('sent'); } catch (e) { console.log(e.message); }
        """, transport: transport)
        #expect(transport.requests.isEmpty)
        #expect(output.console.first?.message != "sent")
        #expect(output.console.first?.message.isEmpty == false)
    }

    @Test func unsupportedBodyModesAreRejected() async {
        let output = await ScriptHarness.run("""
        try { await bee.sendRequest({url: 'https://e.com', body: {mode: 'formdata'}}); } catch (e) { console.log(e.message); }
        """, transport: FakeTransport())
        #expect(output.console.first?.message == "bee.sendRequest does not support the body mode 'formdata'")
    }

    @Test func requestsRunConcurrentlyThroughPromiseAll() async {
        let transport = FakeTransport(delay: .milliseconds(50))
        let started = ContinuousClock.now
        let output = await ScriptHarness.run("""
        const all = await Promise.all([1, 2, 3, 4].map(i => bee.sendRequest('https://e.com/' + i)));
        console.log(all.map(r => r.code).join());
        """, transport: transport)
        #expect(output.console.first?.message == "200,200,200,200")
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aSlowRequestIsCutOffByTheRunTimeout() async {
        let transport = FakeTransport(delay: .seconds(30))
        let output = await ScriptHarness.run("await bee.sendRequest('https://e.com')", transport: transport, timeout: 0.4)
        #expect(output.failure?.message == "Script timed out after 0.4 s")
    }
}
