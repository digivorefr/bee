import Foundation
import Testing
@testable import BeeCore

@Suite struct ScriptConsoleTests {
    @Test func formatsArgumentsLikeTheBrief() async {
        let output = await ScriptHarness.run("""
        console.log('plain', 1, true, null, undefined, {a: 1, b: [1, 2]}, [1, 'x'], new Error('boom'));
        console.log();
        console.log("it's \\"raw\\"");
        const circular = {name: 'c'}; circular.self = circular;
        console.log(circular);
        console.log(() => 1, Symbol('s'));
        """)
        #expect(output.failure == nil)
        #expect(output.console.map(\.message) == [
            #"plain 1 true null undefined {"a":1,"b":[1,2]} [1,"x"] boom"#,
            "",
            #"it's "raw""#,
            "{ name: 'c', self: [Circular] }",
            "[Function] Symbol(s)",
        ])
    }

    @Test func levelsMapToConsoleLevels() async {
        let output = await ScriptHarness.run("""
        console.log('a'); console.info('b'); console.warn('c'); console.error('d'); console.debug('e');
        """)
        #expect(output.console.map(\.level) == [.log, .info, .warn, .error, .log])
        #expect(output.console.map(\.message) == ["a", "b", "c", "d", "e"])
    }

    @Test func eachSourceLabelsItsOwnLines() async {
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "Collection · Pre-request", code: "console.log('one'); setTimeout(() => console.log('late one'), 10);"),
            ScriptSource(label: "Request · Pre-request", code: "console.warn('two')"),
        ])
        #expect(output.console.map(\.source) == ["Collection · Pre-request", "Collection · Pre-request", "Request · Pre-request"])
        #expect(output.console.map(\.message) == ["one", "late one", "two"])
    }

    @Test func consoleReturnsRawSecretsForTheCallerToRedact() async {
        let output = await ScriptHarness.run("console.log('token=' + bee.environment.get('token'))",
                                             scopes: ScriptScopes(environment: [ScriptVariable(name: "token", value: "s3cret", isSecret: true)], environmentName: "Dev"))
        #expect(output.console.first?.message == "token=s3cret")
    }
}

@Suite struct ScriptUtilityTests {
    @Test func cryptoMatchesKnownVectors() async {
        let result = await ScriptHarness.evaluate("""
        [bee.crypto.sha256('abc'), bee.crypto.sha1('abc'), bee.crypto.md5('abc'), bee.crypto.sha256(''),
         bee.crypto.hmacSHA256('key', 'The quick brown fox jumps over the lazy dog'),
         bee.crypto.hmacSHA256Base64('key', 'The quick brown fox jumps over the lazy dog'),
         bee.crypto.sha256('héllo')].join('\\n')
        """)
        #expect(result == """
        ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        a9993e364706816aba3e25717850c26c9cd0d89d
        900150983cd24fb0d6963f7d28e17f72
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
        97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg=
        3c48591d8d098a4538f5e013dfcf406e948eac4d3277b10bf614e295d6068179
        """)
    }

    @Test func base64Helpers() async {
        let result = await ScriptHarness.evaluate("""
        [btoa('hello'), atob('aGVsbG8='), atob('aGVsbG8'), bee.base64.encode('héllo'), bee.base64.decode('aMOpbGxv'),
         bee.base64.decode('aMOpbGxv'.replace(/\\+/g, '-')), (() => { try { atob('***'); } catch (e) { return 'atob throws'; } })(),
         (() => { try { btoa('é€'); } catch (e) { return 'btoa throws'; } })()].join('|')
        """)
        #expect(result == "aGVsbG8=|hello|hello|aMOpbGxv|héllo|héllo|atob throws|btoa throws")
    }

    @Test func uuidIsAFreshLowercaseV4() async {
        let result = await ScriptHarness.evaluate("[bee.uuid(), bee.uuid()].join(' ')")
        let parts = (result ?? "").split(separator: " ").map(String.init)
        #expect(parts.count == 2)
        #expect(parts[0] != parts[1])
        for part in parts {
            #expect(part.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil)
        }
    }

    @Test func requireAndHostCapabilitiesAreUnavailable() async {
        let result = await ScriptHarness.evaluate("""
        [(() => { try { require('fs'); } catch (e) { return e.message; } })(),
         typeof fetch, typeof XMLHttpRequest, typeof process, typeof __host, typeof WebSocket].join('|')
        """)
        #expect(result == "require is not available in Bee scripts|undefined|undefined|undefined|undefined|undefined")
    }

    @Test func timersFireInDelayOrderWithArgumentsAndCanBeCleared() async {
        let output = await ScriptHarness.run("""
        const order = [];
        setTimeout(() => order.push('b'), 30);
        setTimeout((x, y) => order.push('a' + x + y), 5, 1, 2);
        const id = setTimeout(() => order.push('cleared'), 10);
        clearTimeout(id);
        await new Promise(r => setTimeout(r, 60));
        console.log(order.join());
        """)
        #expect(output.console.first?.message == "a12,b")
    }

    @Test func unawaitedTimersStillRunBeforeTheSourceEnds() async {
        let output = await ScriptHarness.run("setTimeout(() => bee.environment.set('late', 'yes'), 20)")
        #expect(output.scopes.environmentValue("late")?.value == "yes")
    }
}
