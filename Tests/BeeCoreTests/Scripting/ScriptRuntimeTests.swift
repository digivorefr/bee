import Foundation
import Testing
@testable import BeeCore

@Suite struct ScriptFailureTests {
    @Test func uncaughtErrorReportsMessageSourceAndLine() async {
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "Collection · Pre-request", code: "bee.environment.set('first', 1);\nconsole.log('before');\n\nthrow new Error('kaput');"),
        ])
        #expect(output.failure == ScriptFailure(source: "Collection · Pre-request", message: "kaput", line: 4))
    }

    @Test func stateBeforeTheFailureIsStillReturned() async {
        let output = await ScriptHarness.run("""
        bee.environment.set('kept', 'yes');
        bee.request.headers.add({key: 'X-Kept', value: '1'});
        bee.test('earlier', () => {});
        console.log('earlier line');
        undefinedFunction();
        """)
        #expect(output.failure?.line == 5)
        #expect(output.scopes.environmentValue("kept")?.value == "yes")
        #expect(output.request.headers == [HeaderEntry(name: "X-Kept", value: "1")])
        #expect(output.tests.map(\.name) == ["earlier"])
        #expect(output.console.map(\.message) == ["earlier line"])
    }

    @Test func laterSourcesAreSkippedAfterAFailure() async {
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "A", code: "console.log('a')"),
            ScriptSource(label: "B", code: "throw new Error('b broke')"),
            ScriptSource(label: "C", code: "console.log('c'); bee.environment.set('c', 1)"),
        ])
        #expect(output.failure?.source == "B")
        #expect(output.failure?.message == "b broke")
        #expect(output.console.map(\.message) == ["a"])
        #expect(output.scopes.environmentValue("c") == nil)
    }

    @Test func lineNumbersAreCorrectAfterAnAwait() async {
        let output = await ScriptHarness.run("const a = 1;\nawait new Promise(r => setTimeout(r, 5));\nconst b = 2;\nnull.boom;")
        #expect(output.failure?.line == 4)
    }

    @Test func errorsThrownByTheAPIPointAtTheCallerLine() async {
        let output = await ScriptHarness.run("const x = 1;\n\nbee.response.json();", phase: .postResponse,
                                             response: ScriptResponse(code: 200, status: "OK", body: Data("nope".utf8)))
        #expect(output.failure == ScriptFailure(source: "Request · Script", message: "Response body is not valid JSON", line: 3))
    }

    @Test func syntaxErrorsReportTheLine() async {
        let output = await ScriptHarness.run("const ok = 1;\nconst = ;")
        #expect(output.failure?.line == 2)
        #expect(output.failure?.message.isEmpty == false)
    }

    @Test func intervalsRepeatUntilCleared() async {
        let output = await ScriptHarness.run("""
        let ticks = 0;
        await new Promise(resolve => {
          const id = setInterval(() => {
            ticks += 1;
            if (ticks === 3) { clearInterval(id); resolve(); }
          }, 5);
        });
        console.log(ticks);
        """)
        #expect(output.failure == nil)
        #expect(output.console.first?.message == "3")
    }

    @Test func anIntervalNeverClearedEndsAtTheTimeLimit() async {
        let output = await ScriptHarness.run("setInterval(() => {}, 5);", timeout: 0.3)
        #expect(output.failure != nil)
    }

    @Test func rejectedPromisesAndNonErrorThrowsAreReported() async {
        let rejected = await ScriptHarness.run("await Promise.reject(new Error('rejected'))")
        #expect(rejected.failure?.message == "rejected")
        let text = await ScriptHarness.run("throw 'just text'")
        #expect(text.failure == ScriptFailure(source: "Request · Script", message: "just text", line: nil))
        let object = await ScriptHarness.run("throw {message: 'object message'}")
        #expect(object.failure?.message == "object message")
    }

    @Test func errorsInTimerCallbacksStopTheRun() async {
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "A", code: "setTimeout(() => { throw new Error('from timer'); }, 5)"),
            ScriptSource(label: "B", code: "console.log('never')"),
        ])
        #expect(output.failure?.source == "A")
        #expect(output.failure?.message == "from timer")
        #expect(output.console.isEmpty)
    }

    @Test func deepRecursionIsAnErrorNotACrash() async {
        let output = await ScriptHarness.run("function f() { return f() + 1; } f();")
        #expect(output.failure?.message.contains("call stack") == true)
    }

    @Test func aPromiseThatCanNeverSettleFailsFast() async {
        let started = ContinuousClock.now
        let output = await ScriptHarness.run("await new Promise(() => {})", timeout: 5)
        #expect(output.failure?.message.contains("never finished") == true)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

@Suite struct ScriptTimeoutTests {
    @Test func aRunawayLoopIsTerminated() async {
        let started = ContinuousClock.now
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "A", code: "bee.environment.set('before', 1); bee.test('ok', () => {}); while (true) {}"),
            ScriptSource(label: "B", code: "console.log('never')"),
        ], timeout: 0.5)
        #expect(output.failure == ScriptFailure(source: "A", message: "Script timed out after 0.5 s", line: nil))
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(output.scopes.environmentValue("before")?.value == "1")
        #expect(output.tests.map(\.name) == ["ok"])
        #expect(output.console.isEmpty)
    }

    @Test func aLoopInsideAPromiseJobIsTerminated() async {
        let output = await ScriptHarness.run("await null; while (true) {}", timeout: 0.4)
        #expect(output.failure?.message == "Script timed out after 0.4 s")
    }

    @Test func theTimeoutBoundsTheWholeRunIncludingTimers() async {
        let started = ContinuousClock.now
        let output = await ScriptHarness.run("await new Promise(r => setTimeout(r, 10000))", timeout: 0.3)
        #expect(output.failure?.message == "Script timed out after 0.3 s")
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func theMessageUsesTheConfiguredValue() {
        #expect(ScriptFailure.timeout(source: "S", seconds: 10).message == "Script timed out after 10 s")
        #expect(ScriptFailure.timeout(source: "S", seconds: 2.5).message == "Script timed out after 2.5 s")
    }

    @Test func theWatchdogFallbackAbandonsARunawayThread() async {
        // Without JavaScriptCore's own limit only the watchdog can end the run. The busy loop is bounded so
        // the abandoned thread finishes by itself.
        let engine = JSScriptEngine(transport: nil, timeout: 0.3, usesExecutionTimeLimit: false)
        let started = ContinuousClock.now
        let output = await engine.run(ScriptHarness.input([
            ScriptSource(label: "Busy", code: "bee.environment.set('seen', 1); const t = Date.now(); while (Date.now() - t < 1500) {}"),
        ]))
        #expect(output.failure == ScriptFailure(source: "Busy", message: "Script timed out after 0.3 s", line: nil))
        #expect(ContinuousClock.now - started < .seconds(1.2))
        #expect(output.scopes.environmentValue("seen")?.value == "1")
    }
}

@Suite struct ScriptRunBehaviourTests {
    @Test func topLevelAwaitWorks() async {
        let output = await ScriptHarness.run("""
        const a = await Promise.resolve(2);
        const b = await new Promise(r => setTimeout(() => r(3), 10));
        bee.environment.set('sum', a + b);
        """)
        #expect(output.failure == nil)
        #expect(output.scopes.environmentValue("sum")?.value == "5")
    }

    @Test func sourcesShareBeeStateButNotLexicalScope() async {
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "A", code: "const shared = 1; let other = 2; bee.variables.set('fromA', 'a'); bee.test('A', () => {}); console.log('A');"),
            ScriptSource(label: "B", code: "const shared = 'redeclared'; console.log(typeof other, bee.variables.get('fromA')); bee.test('B', () => {});"),
        ])
        #expect(output.failure == nil)
        #expect(output.console.map(\.message) == ["A", "undefined a"])
        #expect(output.tests.map(\.name) == ["A", "B"])
    }

    @Test func emptyAndWhitespaceSourcesAreSkipped() async {
        let output = await ScriptHarness.runSources([
            ScriptSource(label: "Empty", code: ""), ScriptSource(label: "Blank", code: " \n\t "),
            ScriptSource(label: "Real", code: "console.log('x')"),
        ])
        #expect(output.console.map(\.source) == ["Real"])
    }

    @Test func noRunnableSourceReturnsTheInputUnchanged() async {
        let scopes = ScriptScopes(locals: ["a": "1"], environment: [ScriptVariable(name: "e", value: "v")], environmentName: "Dev")
        let request = ScriptRequest(method: "POST", url: "u", headers: [HeaderEntry(name: "H", value: "1")], body: "b")
        let output = await ScriptHarness.runSources([ScriptSource(label: "Blank", code: "  ")], request: request, scopes: scopes)
        #expect(output.request == request)
        #expect(output.scopes == scopes)
        #expect(output.tests.isEmpty && output.console.isEmpty && output.failure == nil)
        let none = await ScriptHarness.runSources([], request: request, scopes: scopes)
        #expect(none.request == request)
    }

    @Test func scopesAreReturnedUnchangedWhenNothingIsWritten() async {
        let scopes = ScriptScopes(locals: ["a": "1"], environment: [ScriptVariable(name: "e", value: "v", isSecret: true)],
                                  collection: [ScriptVariable(name: "c", value: "w")], globals: [ScriptVariable(name: "g", value: "x")], environmentName: "Dev")
        let output = await ScriptHarness.run("console.log('noop')", scopes: scopes)
        #expect(output.scopes == scopes)
        #expect(output.request == ScriptHarness.defaultRequest)
    }

    @Test func runsAreIsolatedFromEachOther() async {
        let engine = JSScriptEngine()
        let first = await engine.run(ScriptHarness.input([ScriptSource(label: "1", code: """
        globalThis.leak = 'secret'; Array.prototype.polluted = true; bee.globals.set('g', 1); bee.test('first', () => {}); console.log('first');
        """)]))
        let second = await engine.run(ScriptHarness.input([ScriptSource(label: "2", code: """
        console.log(typeof leak, typeof [].polluted, bee.globals.get('g'), typeof bee.globals.get('g'));
        """)]))
        #expect(first.tests.count == 1)
        #expect(second.console.map(\.message) == ["undefined undefined undefined undefined"])
        #expect(second.tests.isEmpty)
        #expect(second.scopes.globals.isEmpty)
        let fresh = await JSScriptEngine().run(ScriptHarness.input([ScriptSource(label: "3", code: "console.log(typeof leak)")]))
        #expect(fresh.console.first?.message == "undefined")
    }

    @Test func concurrentRunsDoNotInterfere() async {
        let engine = JSScriptEngine()
        let results = await withTaskGroup(of: (Int, String?).self) { group in
            for index in 0..<16 {
                group.addTask {
                    let output = await engine.run(ScriptHarness.input([ScriptSource(label: "S\(index)", code: """
                    await new Promise(r => setTimeout(r, \(index % 4) * 10));
                    bee.environment.set('n', \(index)); bee.variables.set('v', \(index * 2));
                    console.log('run \(index)');
                    """)]))
                    return (index, output.scopes.environmentValue("n")?.value.appending("/\(output.scopes.locals["v"] ?? "")/\(output.console.first?.message ?? "")"))
                }
            }
            var collected: [Int: String?] = [:]
            for await (index, value) in group { collected[index] = value }
            return collected
        }
        for index in 0..<16 {
            #expect(results[index] == .some("\(index)/\(index * 2)/run \(index)"))
        }
    }

    @Test func cancellingTheCallerReturnsPromptly() async {
        let engine = JSScriptEngine(transport: FakeTransport(delay: .seconds(30)), timeout: 20)
        let started = ContinuousClock.now
        let task = Task {
            await engine.run(ScriptHarness.input([ScriptSource(label: "Slow", code: "await bee.sendRequest('https://e.com')")]))
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let output = await task.value
        #expect(output.failure?.message == "Script cancelled")
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
