import Foundation
import Testing
@testable import BeeCore

@Suite struct ScriptExpectTests {
    /// `message == nil` means the assertion must pass; otherwise it must throw exactly that message.
    struct Case: Sendable {
        let code: String
        let message: String?
        init(_ code: String, _ message: String? = nil) {
            self.code = code
            self.message = message
        }
    }

    private static let cases: [Case] = [
        Case("bee.expect(1).to.equal(1)"), Case("bee.expect('a').to.eq('a')"), Case("bee.expect(1).to.not.equal(2)"),
        Case("bee.expect(404).to.equal(200)", "expected 404 to equal 200"),
        Case("bee.expect('a').to.equal('b')", "expected 'a' to equal 'b'"),
        Case("bee.expect(1).to.not.equal(1)", "expected 1 to not equal 1"),
        Case("bee.expect('1').to.equal(1)", "expected '1' to equal 1"),
        Case("bee.expect(undefined).to.equal(1)", "expected undefined to equal 1"),
        Case("bee.expect({a: 'x', 'b-c': [1, null]}).to.equal(1)", "expected { a: 'x', 'b-c': [ 1, null ] } to equal 1"),
        Case("bee.expect(1, 'Custom').to.equal(2)", "Custom: expected 1 to equal 2"),

        Case("bee.expect({a: [1, {b: 2}]}).to.eql({a: [1, {b: 2}]})"), Case("bee.expect([1, 2]).to.deep.equal([1, 2])"),
        Case("bee.expect(NaN).to.eql(NaN)"),
        Case("bee.expect({a: 1}).to.eql({a: 2})", "expected { a: 1 } to deeply equal { a: 2 }"),
        Case("bee.expect([1, 2]).to.eql([1, 2, 3])", "expected [ 1, 2 ] to deeply equal [ 1, 2, 3 ]"),
        Case("bee.expect({a: 1}).to.deep.equal({a: 2})", "expected { a: 1 } to deeply equal { a: 2 }"),

        Case("bee.expect('x').to.be.a('string')"), Case("bee.expect(1).to.be.a('number')"), Case("bee.expect(true).to.be.a('boolean')"),
        Case("bee.expect({}).to.be.an('object')"), Case("bee.expect([]).to.be.an('array')"), Case("bee.expect(() => 1).to.be.a('function')"),
        Case("bee.expect(null).to.be.a('null')"), Case("bee.expect(undefined).to.be.an('undefined')"),
        Case("bee.expect(1).to.be.a('string')", "expected 1 to be a string"),
        Case("bee.expect([]).to.be.an('object')", "expected [] to be an object"),
        Case("bee.expect('x').to.not.be.a('string')", "expected 'x' to not be a string"),
        Case("bee.expect([]).to.be.instanceOf(Array)"),
        Case("bee.expect({}).to.be.instanceOf(Array)", "expected {} to be an instance of Array"),

        Case("bee.expect(1).to.be.ok"), Case("bee.expect(0).to.not.be.ok"),
        Case("bee.expect(0).to.be.ok", "expected 0 to be truthy"), Case("bee.expect(1).to.not.be.ok", "expected 1 to not be truthy"),
        Case("bee.expect(true).to.be.true"), Case("bee.expect(false).to.be.false"),
        Case("bee.expect(false).to.be.true", "expected false to be true"), Case("bee.expect(1).to.be.false", "expected 1 to be false"),
        Case("bee.expect(null).to.be.null"), Case("bee.expect(undefined).to.be.undefined"),
        Case("bee.expect(0).to.be.null", "expected 0 to be null"), Case("bee.expect(null).to.be.undefined", "expected null to be undefined"),
        Case("bee.expect(0).to.exist"), Case("bee.expect(null).to.not.exist"),
        Case("bee.expect(null).to.exist", "expected null to exist"), Case("bee.expect(0).to.not.exist", "expected 0 to not exist"),
        Case("bee.expect('').to.be.empty"), Case("bee.expect([]).to.be.empty"), Case("bee.expect({}).to.be.empty"),
        Case("bee.expect({a: 1}).to.not.be.empty"),
        Case("bee.expect([1]).to.be.empty", "expected [ 1 ] to be empty"),

        Case("bee.expect(5).to.be.above(3)"), Case("bee.expect(5).to.be.gt(3)"), Case("bee.expect(5).to.be.at.least(5)"),
        Case("bee.expect(5).to.be.gte(5)"), Case("bee.expect(5).to.be.below(9)"), Case("bee.expect(5).to.be.lt(9)"),
        Case("bee.expect(5).to.be.at.most(5)"), Case("bee.expect(5).to.be.lte(5)"), Case("bee.expect(5).to.be.within(1, 5)"),
        Case("bee.expect(3).to.be.above(5)", "expected 3 to be above 5"),
        Case("bee.expect(3).to.be.at.least(4)", "expected 3 to be at least 4"),
        Case("bee.expect(300).to.be.below(200)", "expected 300 to be below 200"),
        Case("bee.expect(5).to.be.at.most(4)", "expected 5 to be at most 4"),
        Case("bee.expect(9).to.be.within(1, 5)", "expected 9 to be within 1..5"),
        Case("bee.expect('a').to.be.above(1)", "expected 'a' to be a number to use above()"),

        Case("bee.expect(() => { throw new TypeError('bad id') }).to.throw()"),
        Case("bee.expect(() => { throw new TypeError('bad id') }).to.throw(TypeError)"),
        Case("bee.expect(() => { throw new TypeError('bad id') }).to.throw('bad')"),
        Case("bee.expect(() => { throw new TypeError('bad id') }).to.throw(TypeError, /id$/)"),
        Case("bee.expect(() => { throw 'plain' }).to.throws(/^plain$/)"),
        Case("bee.expect(() => 1).to.not.throw()"),
        Case("bee.expect(() => 1).to.throw()", "expected the function to throw an error but nothing was thrown"),
        Case("bee.expect(() => { throw new Error('boom') }).to.throw(TypeError)", "expected the function to throw TypeError but 'boom' was thrown"),
        Case("bee.expect(() => { throw new Error('boom') }).to.throw('bang')", "expected the function to throw an error matching 'bang' but 'boom' was thrown"),
        Case("bee.expect(() => { throw new Error('boom') }).to.not.throw()", "expected the function to not throw an error"),
        Case("bee.expect(1).to.throw()", "expected 1 to be a function to use throw()"),

        Case("bee.expect('hello').to.include('ell')"), Case("bee.expect([1, 2, 3]).to.contain(2)"),
        Case("bee.expect({a: 1, b: 2}).to.include({a: 1})"), Case("bee.expect([{a: 1}]).to.deep.include({a: 1})"),
        Case("bee.expect('abc').to.not.include('z')"),
        Case("bee.expect('hello').to.include('xyz')", "expected 'hello' to include 'xyz'"),
        Case("bee.expect([1, 2]).to.include(3)", "expected [ 1, 2 ] to include 3"),
        Case("bee.expect({a: 1}).to.include({a: 2})", "expected { a: 1 } to include { a: 2 }"),
        Case("bee.expect([1]).to.not.include(1)", "expected [ 1 ] to not include 1"),

        Case("bee.expect({a: 1}).to.have.property('a')"), Case("bee.expect({a: 1}).to.have.property('a', 1)"),
        Case("bee.expect({a: 1}).to.have.property('a').that.equals(1)"), Case("bee.expect({a: {b: 2}}).to.have.property('a').that.eql({b: 2})"),
        Case("bee.expect({a: 1}).to.not.have.property('b')"), Case("bee.expect('abc').to.have.property('length', 3)"),
        Case("bee.expect({a: 1}).to.have.property('b')", "expected { a: 1 } to have property 'b'"),
        Case("bee.expect({a: 1}).to.have.property('a', 2)", "expected { a: 1 } to have property 'a' of 2, but got 1"),
        Case("bee.expect({a: 1}).to.not.have.property('a')", "expected { a: 1 } to not have property 'a'"),
        Case("bee.expect({a: 1}).to.have.property('a').that.equals(2)", "expected 1 to equal 2"),
        Case("bee.expect(null).to.have.property('a')", "expected null to have property 'a'"),

        Case("bee.expect([1, 2]).to.have.lengthOf(2)"), Case("bee.expect('abc').to.have.lengthOf(3)"),
        Case("bee.expect([1]).to.have.length(1)"), Case("bee.expect(new Set([1])).to.have.lengthOf(1)"),
        Case("bee.expect([1]).to.have.lengthOf(2)", "expected [ 1 ] to have a length of 2 but got 1"),
        Case("bee.expect([1]).to.not.have.lengthOf(1)", "expected [ 1 ] to not have a length of 1"),

        Case(#"bee.expect('abc123').to.match(/\d+/)"#), Case(#"bee.expect('abc').to.not.match(/\d/)"#),
        Case(#"bee.expect('abc').to.match(/\d/)"#, #"expected 'abc' to match /\d/"#),

        Case("bee.expect(2).to.be.oneOf([1, 2])"), Case("bee.expect(3).to.be.oneOf([1, 2])", "expected 3 to be one of [ 1, 2 ]"),

        Case("bee.expect({a: 1, b: 2}).to.have.keys('a', 'b')"), Case("bee.expect({a: 1, b: 2}).to.have.keys(['a', 'b'])"),
        Case("bee.expect({a: 1}).to.have.any.keys('a', 'z')"), Case("bee.expect({a: 1, b: 2}).to.have.all.keys('b', 'a')"),
        Case("bee.expect({a: 1, b: 2}).to.have.keys({a: 0, b: 0})"),
        Case("bee.expect({a: 1}).to.have.keys('a', 'b')", "expected { a: 1 } to have all keys [ 'a', 'b' ]"),
        Case("bee.expect({a: 1, b: 2}).to.have.keys('a')", "expected { a: 1, b: 2 } to have all keys [ 'a' ]"),
        Case("bee.expect({a: 1}).to.have.any.keys('x')", "expected { a: 1 } to have any keys [ 'x' ]"),

        Case("bee.expect('foobar').to.have.string('oba')"),
        Case("bee.expect('foo').to.have.string('x')", "expected 'foo' to contain string 'x'"),

        Case("bee.expect(1).to.be.been.is.that.which.and.has.have.with.at.of.same.equal(1)"),
    ]

    @Test func everyMatcherPassesAndFailsWithChaiStyleMessages() async {
        let script = Self.cases.enumerated().map { index, item in
            "bee.test('case-\(index)', () => { \(item.code); });"
        }.joined(separator: "\n")
        let output = await ScriptHarness.run(script)
        #expect(output.failure == nil)
        #expect(output.tests.count == Self.cases.count)
        for (index, item) in Self.cases.enumerated() {
            guard let result = output.test(named: "case-\(index)") else {
                Issue.record("missing result for \(item.code)")
                continue
            }
            #expect(result.passed == (item.message == nil), Comment(rawValue: item.code))
            #expect(result.message == item.message, Comment(rawValue: item.code))
        }
    }

    @Test func failuresAreAssertionErrors() async {
        let result = await ScriptHarness.evaluate("""
        (() => { try { bee.expect(1).to.equal(2); } catch (e) { return [e.name, e instanceof Error, e.message].join('|'); } })()
        """)
        #expect(result == "AssertionError|true|expected 1 to equal 2")
    }

    @Test func longValuesAreTruncatedInMessages() async {
        let output = await ScriptHarness.run("bee.test('t', () => bee.expect('x'.repeat(500)).to.equal('y'))")
        let message = output.test(named: "t")?.message ?? ""
        #expect(message.count < 300)
        #expect(message.contains("..."))
    }
}

@Suite struct ScriptTestFunctionTests {
    @Test func passingAndFailingTestsAreRecordedAndNeverAbortTheScript() async {
        let output = await ScriptHarness.run("""
        bee.test('passes', () => { bee.expect(1).to.equal(1); });
        bee.test('fails', () => { bee.expect(1).to.equal(2); });
        bee.test('throws error', () => { throw new TypeError('boom'); });
        bee.test('throws string', () => { throw 'plain'; });
        bee.test('not a function');
        console.log('script continued');
        """)
        #expect(output.failure == nil)
        #expect(output.tests.map(\.name) == ["passes", "fails", "throws error", "throws string", "not a function"])
        #expect(output.tests.map(\.passed) == [true, false, false, false, false])
        #expect(output.tests[0].message == nil)
        #expect(output.tests[1].message == "expected 1 to equal 2")
        #expect(output.tests[2].message == "boom")
        #expect(output.tests[3].message == "plain")
        #expect(output.tests[4].message == "bee.test needs a function as its second argument")
        #expect(output.console.map(\.message) == ["script continued"])
    }

    @Test func asyncTestsAreAwaited() async {
        let output = await ScriptHarness.run("""
        bee.test('async pass', async () => { await new Promise(r => setTimeout(r, 10)); bee.expect(1).to.equal(1); });
        bee.test('async fail', async () => { await null; throw new Error('late'); });
        bee.test('rejected promise', () => Promise.reject(new Error('rejected')));
        bee.test('resolved promise', () => Promise.resolve());
        """)
        #expect(output.failure == nil)
        #expect(output.tests.map(\.passed) == [true, false, false, true])
        #expect(output.tests[1].message == "late")
        #expect(output.tests[2].message == "rejected")
    }

    @Test func resultsKeepRegistrationOrderEvenWhenCompletionDiffers() async {
        let output = await ScriptHarness.run("""
        bee.test('slow', () => new Promise(r => setTimeout(r, 40)));
        bee.test('fast', () => {});
        """)
        #expect(output.tests.map(\.name) == ["slow", "fast"])
        #expect(output.tests.map(\.passed) == [true, true])
    }

    @Test func awaitingATestWaitsForIt() async {
        let output = await ScriptHarness.run("""
        let done = false;
        await bee.test('t', async () => { await new Promise(r => setTimeout(r, 20)); done = true; });
        console.log(done);
        """)
        #expect(output.console.first?.message == "true")
    }

    @Test func aTestThatNeverSettlesIsReportedAsIncomplete() async {
        let output = await ScriptHarness.run("bee.test('hang', () => new Promise(() => {}))")
        #expect(output.failure?.message.contains("never finished") == true)
        #expect(output.test(named: "hang") == TestResult(id: output.tests[0].id, name: "hang", passed: false, message: "Test did not complete"))
    }
}
