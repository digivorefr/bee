import Foundation
import Testing
@testable import BeeCore

@Suite struct TemplateEngineTests {
    private func context(_ pairs: [String: String] = [:], secrets: [String: String] = [:]) -> VariableContext {
        VariableContext(
            environment: pairs.map { Variable(name: $0.key, value: $0.value) }
                + secrets.map { Variable(name: $0.key, value: $0.value, isSecret: true) }
        )
    }

    // MARK: tokens

    @Test func tokensCoverTheWholeTemplate() {
        let template = "GET {{ host }}/users/{{$uuid}}?x=1"
        let tokens = TemplateEngine.tokens(in: template)
        #expect(tokens.map(\.kind) == [.text, .variable(name: "host"), .text, .dynamic(name: "$uuid"), .text])
        #expect(tokens.map { String(template[$0.range]) }.joined() == template)
        #expect(String(template[tokens[1].range]) == "{{ host }}")
    }

    @Test func tokenNSRangeMatchesUTF16Offsets() {
        let template = "héllo 🐝 {{name}}"
        let placeholder = TemplateEngine.tokens(in: template).first { $0.kind == .variable(name: "name") }
        let range = placeholder?.nsRange
        #expect(range.map { (template as NSString).substring(with: $0) } == "{{name}}")
    }

    @Test func emptyTemplateHasNoTokens() {
        #expect(TemplateEngine.tokens(in: "").isEmpty)
    }

    @Test(arguments: ["{{}}", "{{   }}", "{{a", "{a}}", "{{a}", "{{a{b}}", "no braces", "}}{{"])
    func malformedPlaceholdersStayText(template: String) {
        let kinds = TemplateEngine.tokens(in: template).map(\.kind)
        #expect(!kinds.contains { $0 != .text })
        #expect(TemplateEngine.render(template, in: context(["a": "X", "b": "Y"])).text == template)
    }

    @Test func extraBraceAroundAPlaceholderStaysText() {
        let result = TemplateEngine.render("{{{a}}}", in: context(["a": "X"]))
        #expect(result.text == "{X}")
    }

    @Test func namesMayHoldAnyCharacterButBraces() {
        let template = "{{ my var.v2-é/? }}"
        #expect(TemplateEngine.tokens(in: template).map(\.kind) == [.variable(name: "my var.v2-é/?")])
        #expect(TemplateEngine.render(template, in: context(["my var.v2-é/?": "ok"])).text == "ok")
    }

    // MARK: render

    @Test func replacesVariablesAndToleratesWhitespace() {
        let result = TemplateEngine.render("{{a}}-{{ b }}-{{\tc\n}}", in: context(["a": "1", "b": "2", "c": "3"]))
        #expect(result.text == "1-2-3")
        #expect(result.unresolved.isEmpty)
        #expect(!result.usedSecret)
    }

    @Test func unresolvedStayVerbatimAndAreReportedOnceInOrder() {
        let result = TemplateEngine.render("{{b}} {{ a }} {{b}} {{known}} {{$nope}}", in: context(["known": "k"]))
        #expect(result.text == "{{b}} {{ a }} {{b}} k {{$nope}}")
        #expect(result.unresolved == ["b", "a", "$nope"])
    }

    @Test func variablesNestRecursively() {
        let result = TemplateEngine.render("{{url}}", in: context(["url": "{{scheme}}://{{host}}", "scheme": "https", "host": "{{sub}}.example.com", "sub": "api"]))
        #expect(result.text == "https://api.example.com")
        #expect(result.unresolved.isEmpty)
    }

    @Test func unresolvedInsideAValueIsReported() {
        let result = TemplateEngine.render("{{a}}", in: context(["a": "x{{missing}}y"]))
        #expect(result.text == "x{{missing}}y")
        #expect(result.unresolved == ["missing"])
    }

    @Test func directCycleStaysVerbatim() {
        let result = TemplateEngine.render("{{a}}", in: context(["a": "{{a}}"]))
        #expect(result.text == "{{a}}")
        #expect(result.unresolved == ["a"])
    }

    @Test func indirectCycleStaysVerbatim() {
        let result = TemplateEngine.render("[{{a}}]", in: context(["a": "A{{b}}", "b": "B{{a}}"]))
        #expect(result.text == "[AB{{a}}]")
        #expect(result.unresolved == ["a"])
    }

    @Test func sameVariableTwiceIsNotACycle() {
        let result = TemplateEngine.render("{{a}}{{a}}", in: context(["a": "{{b}}", "b": "x"]))
        #expect(result.text == "xx")
        #expect(result.unresolved.isEmpty)
    }

    @Test func depthLimitIsTen() {
        var variables: [String: String] = [:]
        for level in 1..<12 { variables["v\(level)"] = "{{v\(level + 1)}}" }
        variables["v12"] = "end"
        // v1 -> ... -> v12 needs 12 nested expansions: the 11th stays verbatim.
        let tooDeep = TemplateEngine.render("{{v1}}", in: context(variables))
        #expect(tooDeep.text == "{{v11}}")
        #expect(tooDeep.unresolved == ["v11"])

        var shallow: [String: String] = [:]
        for level in 1..<10 { shallow["v\(level)"] = "{{v\(level + 1)}}" }
        shallow["v10"] = "end"
        let exact = TemplateEngine.render("{{v1}}", in: context(shallow))
        #expect(exact.text == "end")
        #expect(exact.unresolved.isEmpty)
    }

    @Test func fanOutBetweenVariablesTerminatesQuickly() {
        var variables: [String: String] = [:]
        for level in 0..<9 { variables["v\(level)"] = String(repeating: "{{v\(level + 1)}}", count: 10) }
        variables["v9"] = "x"
        let started = ContinuousClock.now
        let result = TemplateEngine.render("{{v0}}", in: context(variables))
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(!result.unresolved.isEmpty)
    }

    @Test func secretUsageIsReported() {
        let used = TemplateEngine.render("Bearer {{token}}", in: context(secrets: ["token": "s3cret"]))
        #expect(used.text == "Bearer s3cret")
        #expect(used.usedSecret)

        let nested = TemplateEngine.render("{{header}}", in: VariableContext(environment: [
            Variable(name: "header", value: "Bearer {{token}}"), Variable(name: "token", value: "s3cret", isSecret: true),
        ]))
        #expect(nested.usedSecret)

        let notUsed = TemplateEngine.render("{{plain}} {{missing}}", in: VariableContext(environment: [
            Variable(name: "plain", value: "p"), Variable(name: "token", value: "s3cret", isSecret: true),
        ]))
        #expect(!notUsed.usedSecret)
    }

    @Test func scopePrecedenceFollowsTheContext() {
        let scoped = VariableContext(
            locals: ["a": "local"],
            environment: [Variable(name: "a", value: "env"), Variable(name: "b", value: "env")],
            collection: [Variable(name: "b", value: "col")]
        )
        #expect(TemplateEngine.render("{{a}} {{b}}", in: scoped).text == "local env")
    }

    // MARK: dynamic variables

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex
    }

    @Test(arguments: ["$uuid", "$guid", "$randomUUID"])
    func uuidVariants(name: String) {
        let text = TemplateEngine.render("{{\(name)}}", in: context()).text
        #expect(matches(text, "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
    }

    @Test func timestampIsUnixSeconds() {
        let before = Int(Date().timeIntervalSince1970)
        let value = Int(TemplateEngine.render("{{$timestamp}}", in: context()).text)
        let after = Int(Date().timeIntervalSince1970)
        #expect(value != nil)
        #expect((before...after).contains(value ?? 0))
    }

    @Test func isoTimestampIsUTCWithMilliseconds() {
        let text = TemplateEngine.render("{{$isoTimestamp}}", in: context()).text
        #expect(matches(text, "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z"))
    }

    @Test func randomIntStaysInRange() {
        for _ in 0..<200 {
            let value = Int(TemplateEngine.render("{{$randomInt}}", in: context()).text)
            #expect((0...1000).contains(value ?? -1))
        }
    }

    @Test func dynamicOccurrencesAreIndependent() {
        let text = TemplateEngine.render("{{$uuid}}|{{$uuid}}", in: context()).text
        let parts = text.split(separator: "|")
        #expect(parts.count == 2)
        #expect(parts[0] != parts[1])
    }

    @Test func dynamicVariablesWorkInsideValues() {
        let text = TemplateEngine.render("{{id}}", in: context(["id": "req-{{$uuid}}"])).text
        #expect(text.hasPrefix("req-"))
        #expect(text.count == 4 + 36)
    }

    @Test func unknownDynamicNameIsUnresolved() {
        let result = TemplateEngine.render("{{$UUID}} {{$whatever}}", in: context())
        #expect(result.text == "{{$UUID}} {{$whatever}}")
        #expect(result.unresolved == ["$UUID", "$whatever"])
    }

    @Test func dynamicNamesAreNeverLookedUpAsVariables() {
        let result = TemplateEngine.render("{{$uuid}}", in: context(["$uuid": "fixed"]))
        #expect(result.text != "fixed")
    }
}
