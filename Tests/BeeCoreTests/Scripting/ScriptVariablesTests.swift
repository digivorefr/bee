import Foundation
import Testing
@testable import BeeCore

@Suite struct ScriptScopeTests {
    private static let scopeNames = ["environment", "collectionVariables", "globals"]

    private static func scopes(for name: String, _ value: [ScriptVariable]) -> ScriptScopes {
        var scopes = ScriptScopes(environmentName: "Dev")
        switch name {
        case "environment": scopes.environment = value
        case "collectionVariables": scopes.collection = value
        default: scopes.globals = value
        }
        return scopes
    }

    private static func variables(_ name: String, in scopes: ScriptScopes) -> [ScriptVariable] {
        switch name {
        case "environment": scopes.environment
        case "collectionVariables": scopes.collection
        default: scopes.globals
        }
    }

    @Test(arguments: scopeNames)
    func getSetHasUnsetToObject(scope: String) async {
        let seed = [ScriptVariable(name: "host", value: "example.com"), ScriptVariable(name: "gone", value: "x")]
        let output = await ScriptHarness.run("""
        const s = bee.\(scope);
        const log = [];
        log.push(s.get('host'), s.get('missing'), s.has('host'), s.has('missing'));
        s.set('count', 3);
        s.unset('gone');
        log.push(s.has('gone'), s.get('count'));
        log.push(JSON.stringify(s.toObject()));
        s.set('host', 'api.example.com');
        log.push(s.get('host'));
        console.log(JSON.stringify(log));
        """, scopes: Self.scopes(for: scope, seed))
        #expect(output.failure == nil)
        #expect(output.console.first?.message
            == #"["example.com",null,true,false,false,"3","{\"host\":\"example.com\",\"count\":\"3\"}","api.example.com"]"#)
        // Existing variables keep their position, new ones are appended, unset ones are removed.
        #expect(Self.variables(scope, in: output.scopes).map(\.name) == ["host", "count"])
        #expect(Self.variables(scope, in: output.scopes).map(\.value) == ["api.example.com", "3"])
    }

    @Test(arguments: scopeNames)
    func clearRemovesEverything(scope: String) async {
        let seed = [ScriptVariable(name: "a", value: "1"), ScriptVariable(name: "b", value: "2")]
        let output = await ScriptHarness.run("bee.\(scope).clear(); bee.\(scope).set('c', 1)",
                                             scopes: Self.scopes(for: scope, seed))
        #expect(Self.variables(scope, in: output.scopes).map(\.name) == ["c"])
    }

    @Test func getReturnsUndefinedWhenAbsent() async {
        #expect(await ScriptHarness.evaluate("typeof bee.environment.get('nope')") == "undefined")
    }

    @Test func valuesAreStoredAsStrings() async {
        let output = await ScriptHarness.run("""
        const e = bee.environment;
        e.set('str', 'plain'); e.set('num', 42); e.set('flt', 1.5); e.set('bool', false);
        e.set('obj', {a: 1, b: [true, null]}); e.set('arr', [1, 'two']); e.set('nul', null);
        """)
        let values = Dictionary(uniqueKeysWithValues: output.scopes.environment.map { ($0.name, $0.value) })
        #expect(values == [
            "str": "plain", "num": "42", "flt": "1.5", "bool": "false",
            "obj": #"{"a":1,"b":[true,null]}"#, "arr": #"[1,"two"]"#, "nul": "null",
        ])
    }

    @Test func environmentNameIsExposed() async {
        #expect(await ScriptHarness.evaluate("bee.environment.name") == "Dev")
        #expect(await ScriptHarness.evaluate("typeof bee.environment.name", scopes: ScriptScopes()) == "undefined")
    }

    @Test(arguments: ["set('a', 1)", "unset('a')", "clear()"])
    func writingWithoutActiveEnvironmentThrows(call: String) async {
        let output = await ScriptHarness.run("""
        let message = 'no error';
        try { bee.environment.\(call); } catch (e) { message = e.message; }
        console.log(message);
        bee.collectionVariables.set('still', 'works');
        bee.environment.\(call);
        """, scopes: ScriptScopes())
        let expected = "No active environment: select one before writing environment variables."
        #expect(output.console.first?.message == expected)
        #expect(output.failure?.message == expected)
        #expect(output.scopes.collectionValue("still")?.value == "works")
        #expect(output.scopes.environment.isEmpty)
    }

    @Test func readingWithoutActiveEnvironmentIsAllowed() async {
        #expect(await ScriptHarness.evaluate("[bee.environment.get('x'), bee.environment.has('x')].join()",
                                              scopes: ScriptScopes()) == ",false")
    }
}

@Suite struct ScriptSecretRuleTests {
    private static func secrets(_ output: ScriptOutput) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: output.scopes.environment.map { ($0.name, $0.isSecret) })
    }

    @Test func existingSecretKeepsItsFlagWhenValueChanges() async {
        let seed = ScriptScopes(environment: [ScriptVariable(name: "region", value: "eu", isSecret: true)], environmentName: "Dev")
        let output = await ScriptHarness.run("bee.environment.set('region', 'us')", scopes: seed)
        #expect(output.scopes.environmentValue("region") == ScriptVariable(name: "region", value: "us", isSecret: true))
    }

    @Test func existingPlainVariableStaysPlainEvenWithSensitiveName() async {
        let seed = ScriptScopes(environment: [ScriptVariable(name: "apiToken", value: "a")], environmentName: "Dev")
        let output = await ScriptHarness.run("bee.environment.set('apiToken', 'b')", scopes: seed)
        #expect(output.scopes.environmentValue("apiToken") == ScriptVariable(name: "apiToken", value: "b", isSecret: false))
    }

    @Test func newVariablesFollowTheNameHeuristic() async {
        let output = await ScriptHarness.run("""
        for (const name of ['accessToken', 'client_secret', 'password', 'X-Api-Key', 'region', 'baseUrl']) {
          bee.environment.set(name, 'v');
        }
        """)
        #expect(Self.secrets(output) == [
            "accessToken": true, "client_secret": true, "password": true, "X-Api-Key": true,
            "region": false, "baseUrl": false,
        ])
    }

    @Test func optionOverridesTheHeuristicForNewVariables() async {
        let output = await ScriptHarness.run("""
        bee.environment.set('region', 'eu', {secret: true});
        bee.environment.set('accessToken', 'abc', {secret: false});
        bee.environment.set('other', 'x', {});
        bee.environment.set('another', 'x', {secret: 'yes'});
        """)
        #expect(Self.secrets(output) == ["region": true, "accessToken": false, "other": false, "another": false])
    }

    @Test func secretTrueUpgradesAnExistingPlainVariable() async {
        let seed = ScriptScopes(environment: [ScriptVariable(name: "region", value: "eu")], environmentName: "Dev")
        let output = await ScriptHarness.run("bee.environment.set('region', 'eu', {secret: true})", scopes: seed)
        #expect(output.scopes.environmentValue("region")?.isSecret == true)
    }

    @Test func secretFalseNeverDowngradesAnExistingSecret() async {
        let seed = ScriptScopes(environment: [ScriptVariable(name: "token", value: "a", isSecret: true)], environmentName: "Dev")
        let output = await ScriptHarness.run("bee.environment.set('token', 'b', {secret: false})", scopes: seed)
        #expect(output.scopes.environmentValue("token") == ScriptVariable(name: "token", value: "b", isSecret: true))
    }

    @Test func ruleAppliesToCollectionAndGlobalScopesToo() async {
        let output = await ScriptHarness.run("""
        bee.collectionVariables.set('sessionId', '1');
        bee.globals.set('plain', '1');
        bee.globals.set('plain2', '1', {secret: true});
        """)
        #expect(output.scopes.collectionValue("sessionId")?.isSecret == true)
        #expect(output.scopes.globalValue("plain")?.isSecret == false)
        #expect(output.scopes.globalValue("plain2")?.isSecret == true)
    }
}

@Suite struct ScriptVariablesResolutionTests {
    private static let layered = ScriptScopes(
        locals: ["name": "local", "onlyLocal": "L"],
        environment: [ScriptVariable(name: "name", value: "env"), ScriptVariable(name: "tier", value: "env-tier")],
        collection: [ScriptVariable(name: "name", value: "collection"), ScriptVariable(name: "tier", value: "col-tier"),
                     ScriptVariable(name: "colOnly", value: "C")],
        globals: [ScriptVariable(name: "name", value: "global"), ScriptVariable(name: "tier", value: "glob-tier"),
                  ScriptVariable(name: "colOnly", value: "G"), ScriptVariable(name: "globOnly", value: "GO")],
        environmentName: "Dev"
    )

    @Test func getResolvesLocalThenEnvironmentThenCollectionThenGlobals() async {
        let result = await ScriptHarness.evaluate(
            "['name', 'tier', 'colOnly', 'globOnly', 'onlyLocal', 'missing'].map(n => bee.variables.get(n)).join('|')",
            scopes: Self.layered
        )
        #expect(result == "local|env-tier|C|GO|L|")
    }

    @Test func hasFollowsTheSameResolution() async {
        #expect(await ScriptHarness.evaluate("[bee.variables.has('globOnly'), bee.variables.has('missing')].join()",
                                              scopes: Self.layered) == "true,false")
    }

    @Test func setWritesARunScopedLocalValue() async {
        let output = await ScriptHarness.run("""
        bee.variables.set('name', 'changed'); bee.variables.set('n', 5); bee.variables.set('o', {a: 1});
        console.log(bee.variables.get('name'), bee.environment.get('name'));
        bee.variables.unset('onlyLocal');
        """, scopes: Self.layered)
        #expect(output.console.first?.message == "changed env")
        #expect(output.scopes.locals == ["name": "changed", "n": "5", "o": #"{"a":1}"#])
        #expect(output.scopes.environment == Self.layered.environment)
        #expect(output.scopes.globals == Self.layered.globals)
    }

    @Test func variablesWorkWithoutAnActiveEnvironment() async {
        let output = await ScriptHarness.run("bee.variables.set('x', 1)", scopes: ScriptScopes())
        #expect(output.failure == nil)
        #expect(output.scopes.locals == ["x": "1"])
    }

    @Test func replaceInSubstitutesKnownPlaceholders() async {
        let result = await ScriptHarness.evaluate(
            #"bee.variables.replaceIn('{{tier}}/{{ name }}/{{unknown}}/{{globOnly}}{{onlyLocal}}/{single}/{{}}')"#,
            scopes: Self.layered
        )
        #expect(result == "env-tier/local/{{unknown}}/GOL/{single}/{{}}")
    }

    @Test func replaceInIsASinglePass() async {
        let scopes = ScriptScopes(locals: ["a": "{{b}}", "b": "B"])
        #expect(await ScriptHarness.evaluate("bee.variables.replaceIn('{{a}}')", scopes: scopes) == "{{b}}")
    }

    @Test func toObjectMergesWithPrecedence() async {
        let result = await ScriptHarness.evaluate("JSON.stringify(bee.variables.toObject())", scopes: Self.layered)
        #expect(result?.contains(#""name":"local""#) == true)
        #expect(result?.contains(#""tier":"env-tier""#) == true)
        #expect(result?.contains(#""colOnly":"C""#) == true)
    }
}
