import Foundation
import Testing
@testable import BeeCore

@Suite struct URLTemplateTests {
    private func row(_ key: String, _ value: String = "", enabled: Bool = true, secret: Bool = false) -> KeyValue {
        KeyValue(key: key, value: value, isEnabled: enabled, isSecret: secret)
    }

    private func pairs(_ rows: [KeyValue]) -> [String] { rows.map { "\($0.key)=\($0.value)" } }

    // MARK: split

    @Test func splitsBaseAndQueryRows() {
        let (base, params) = URLTemplate.split("https://api.example.com/users?a=1&b={{x}}&flag")
        #expect(base == "https://api.example.com/users")
        #expect(pairs(params) == ["a=1", "b={{x}}", "flag="])
        #expect(params.allSatisfy { $0.isEnabled && !$0.isSecret })
    }

    @Test func fragmentStaysOnTheBase() {
        let (base, params) = URLTemplate.split("https://x.test/p?a=1#top")
        #expect(base == "https://x.test/p#top")
        #expect(pairs(params) == ["a=1"])
        let (plain, none) = URLTemplate.split("https://x.test/p#frag?not=query")
        #expect(plain == "https://x.test/p#frag?not=query")
        #expect(none.isEmpty)
    }

    @Test func placeholderDelimitersAreOpaque() {
        let (base, params) = URLTemplate.split("{{host?x#y}}/p?{{k&1}}={{v=2}}&b=1")
        #expect(base == "{{host?x#y}}/p")
        #expect(pairs(params) == ["{{k&1}}={{v=2}}", "b=1"])
    }

    @Test func valueMayContainEqualsAndNothingIsDecoded() {
        let (_, params) = URLTemplate.split("http://h/?q=a=b&space=a%20b&plus=a+b&uni=é")
        #expect(pairs(params) == ["q=a=b", "space=a%20b", "plus=a+b", "uni=é"])
    }

    @Test(arguments: [("http://h/?", 0), ("http://h/?&&", 0), ("http://h/?=x", 0), ("http://h", 0), ("", 0), ("http://h/?a=1&&b=2", 2)])
    func degenerateQueries(full: String, count: Int) {
        #expect(URLTemplate.split(full).params.count == count)
    }

    @Test func splitProducesDistinctIds() {
        let (_, params) = URLTemplate.split("http://h/?a=1&b=2")
        #expect(Set(params.map(\.id)).count == 2)
    }

    // MARK: join

    @Test func joinsEnabledRowsWithKeys() {
        let params = [row("a", "1"), row("off", "x", enabled: false), row("", "orphan"), row("b", "{{x}}"), row("flag")]
        #expect(URLTemplate.join(base: "https://h/p", params: params) == "https://h/p?a=1&b={{x}}&flag=")
    }

    @Test func joinWithoutRowsReturnsTheBase() {
        #expect(URLTemplate.join(base: "https://h/p", params: []) == "https://h/p")
        #expect(URLTemplate.join(base: "https://h/p#f", params: [row("a", enabled: false)]) == "https://h/p#f")
    }

    @Test func joinPutsQueryBeforeTheFragment() {
        #expect(URLTemplate.join(base: "https://h/p#top", params: [row("a", "1")]) == "https://h/p?a=1#top")
    }

    @Test func joinExtendsAQueryAlreadyInTheBase() {
        #expect(URLTemplate.join(base: "https://h/p?x=1", params: [row("a", "1")]) == "https://h/p?x=1&a=1")
        #expect(URLTemplate.join(base: "https://h/p?", params: [row("a", "1")]) == "https://h/p?a=1")
        #expect(URLTemplate.join(base: "{{u?}}", params: [row("a", "1")]) == "{{u?}}?a=1")
    }

    @Test func splitThenJoinRoundTrips() {
        for address in ["https://h/p?a=1&b={{x}}#f", "http://h/", "{{base}}/users?q=a%20b&r=a+b", "http://h/?a=1&a=2"] {
            let (base, params) = URLTemplate.split(address)
            #expect(URLTemplate.join(base: base, params: params) == address)
        }
    }

    @Test func secretRowsAreMaskedUnlessMadeOfPlaceholders() {
        let params = [
            row("literal", "hunter2", secret: true),
            row("mixed", "Bearer {{token}}", secret: true),
            row("ref", "{{token}}", secret: true),
            row("refs", " {{a}}{{$uuid}} ", secret: true),
            row("empty", "", secret: true),
            row("plain", "visible"),
        ]
        let joined = URLTemplate.join(base: "https://h", params: params)
        #expect(joined == "https://h?literal=••••••&mixed=••••••&ref={{token}}&refs= {{a}}{{$uuid}} &empty=&plain=visible")
        #expect(!joined.contains("hunter2"))
    }

    // MARK: merge

    @Test func mergeKeepsIdsAndFlagsOfMatchingRows() {
        let existing = [row("a", "1"), row("b", "2", secret: true)]
        let parsed = URLTemplate.split("https://h?a=9&b=••••••").params
        let merged = URLTemplate.merge(parsed: parsed, into: existing)
        #expect(merged.map(\.id) == existing.map(\.id))
        #expect(merged.map(\.value) == ["9", "2"])
        #expect(merged.map(\.isSecret) == [false, true])
    }

    @Test func secretKeepsItsValueWhileTheShownTextIsUnchanged() {
        let existing = [row("token", "s3cret", secret: true), row("ref", "{{tok}}", secret: true)]
        let shown = URLTemplate.join(base: "https://h", params: existing)
        let merged = URLTemplate.merge(parsed: URLTemplate.split(shown).params, into: existing)
        #expect(merged == existing)
    }

    @Test func typingOverAMaskedSecretReplacesIt() {
        let existing = [row("token", "s3cret", secret: true)]
        let merged = URLTemplate.merge(parsed: URLTemplate.split("https://h?token=new").params, into: existing)
        #expect(merged.count == 1)
        #expect(merged[0].id == existing[0].id)
        #expect(merged[0].value == "new")
        #expect(merged[0].isSecret)
    }

    @Test func emptySecretStaysEmptyWhenUntouched() {
        let existing = [row("token", "", secret: true)]
        let merged = URLTemplate.merge(parsed: [row("token", URLTemplate.mask)], into: existing)
        #expect(merged == existing)
    }

    @Test func disabledRowsStayAtTheirRelativePlace() {
        let a = row("a", "1"), off1 = row("x", "hidden", enabled: false), b = row("b", "2")
        let c = row("c", "3"), off2 = row("y", "hidden", enabled: false)
        let existing = [off1, a, b, off2, c]
        let merged = URLTemplate.merge(parsed: URLTemplate.split("h?a=1&b=22&c=3").params, into: existing)
        #expect(merged.map(\.key) == ["x", "a", "b", "y", "c"])
        #expect(merged[2].value == "22")
        #expect(merged[0] == off1)
        #expect(merged[3] == off2)
    }

    @Test func blankRowsWithoutKeyAreKept() {
        let existing = [row("a", "1"), row("", "", enabled: true)]
        let merged = URLTemplate.merge(parsed: URLTemplate.split("h?a=2").params, into: existing)
        #expect(merged.map(\.key) == ["a", ""])
    }

    @Test func removingAndAddingRows() {
        let existing = [row("a", "1"), row("b", "2"), row("c", "3", secret: true)]
        let removed = URLTemplate.merge(parsed: URLTemplate.split("h?b=2&c=••••••").params, into: existing)
        #expect(removed.map(\.key) == ["b", "c"])
        #expect(removed[0].id == existing[1].id)
        #expect(removed[1].id == existing[2].id)
        #expect(removed[1].value == "3" && removed[1].isSecret)

        let added = URLTemplate.merge(parsed: URLTemplate.split("h?a=1&b=2&c=••••••&d=4").params, into: existing)
        #expect(added.map(\.key) == ["a", "b", "c", "d"])
        #expect(added[3].id != existing[0].id)
        #expect(added[3].value == "4" && !added[3].isSecret)
    }

    @Test func removingTheFirstOfTwoSecretsNeverCrossesTheirValues() {
        let existing = [row("s1", "one", secret: true), row("s2", "two", secret: true)]
        let merged = URLTemplate.merge(parsed: [row("s2", URLTemplate.mask)], into: existing)
        #expect(merged.count == 1)
        #expect(merged[0].key == "s2" && merged[0].value == "two" && merged[0].id == existing[1].id)
    }

    @Test func renamingASecretInPlaceKeepsItsValue() {
        let existing = [row("token", "s3cret", secret: true)]
        let merged = URLTemplate.merge(parsed: [row("auth", URLTemplate.mask)], into: existing)
        #expect(merged.count == 1)
        #expect(merged[0].key == "auth" && merged[0].value == "s3cret" && merged[0].isSecret)
    }

    @Test func aNewRowNeverInheritsASecretFromAChangedKey() {
        let existing = [row("token", "s3cret", secret: true)]
        let merged = URLTemplate.merge(parsed: [row("other", "plain")], into: existing)
        #expect(merged.count == 1)
        #expect(merged[0].id != existing[0].id)
        #expect(merged[0].value == "plain" && !merged[0].isSecret)
    }

    @Test func duplicateKeysKeepTheirPositions() {
        let existing = [row("t", "1"), row("t", "2")]
        let merged = URLTemplate.merge(parsed: [row("t", "1"), row("t", "3")], into: existing)
        #expect(merged.map(\.id) == existing.map(\.id))
        #expect(merged.map(\.value) == ["1", "3"])
    }

    @Test func mergeIntoNothingKeepsParsedRows() {
        let parsed = URLTemplate.split("h?a=1").params
        #expect(URLTemplate.merge(parsed: parsed, into: []) == parsed)
        #expect(URLTemplate.merge(parsed: [], into: [row("a")]).isEmpty)
    }
}
