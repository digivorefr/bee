import Foundation
import Testing
@testable import BeeCore

@Suite struct RedactorTests {
    private let mask = Redactor.mask

    @Test func plainOccurrences() {
        let redactor = Redactor(secrets: ["hunter2-token"])
        #expect(!redactor.isEmpty)
        #expect(redactor.redact("a hunter2-token b hunter2-token") == "a \(mask) b \(mask)")
        #expect(redactor.redact("héllo 🐝 hunter2-token wörld") == "héllo 🐝 \(mask) wörld")
        #expect(redactor.redact("nothing here") == "nothing here")
    }

    @Test func percentEncodedForms() {
        let redactor = Redactor(secrets: ["p@ss word/1+é"])
        // Strict, upper and lower case escapes.
        #expect(redactor.redact("?k=p%40ss%20word%2F1%2B%C3%A9&x=1") == "?k=\(mask)&x=1")
        #expect(redactor.redact("?k=p%40ss%20word%2f1%2b%c3%a9&x=1") == "?k=\(mask)&x=1")
        // Lenient query style and form style.
        #expect(redactor.redact("?k=p@ss%20word/1+%C3%A9&x=1") == "?k=\(mask)&x=1")
        #expect(redactor.redact("k=p%40ss+word%2F1%2B%C3%A9&x=1") == "k=\(mask)&x=1")
        // A secret that itself looks like an escape, literal and escaped.
        let literal = Redactor(secrets: ["100%25off"])
        #expect(literal.redact("a 100%25off b 100%2525off c") == "a \(mask) b \(mask) c")
    }

    @Test func jsonEscapedForms() {
        let redactor = Redactor(secrets: ["pa\"ss\\wörd/1\n"])
        #expect(redactor.redact(#"{"k":"pa\"ss\\wörd/1\n"}"#) == #"{"k":"\#(mask)"}"#)
        #expect(redactor.redact(#"{"k":"pa\"ss\\wörd\/1\n"}"#) == #"{"k":"\#(mask)"}"#)
        #expect(redactor.redact(#"{"k":"pa\"ss\\wörd/1\n"}"#) == #"{"k":"\#(mask)"}"#)
        #expect(redactor.redact(#"{"k":"pa\"ss\\wörd\/1\n"}"#) == #"{"k":"\#(mask)"}"#)
    }

    @Test func base64Forms() {
        let secret = "correct-horse-battery"
        let redactor = Redactor(secrets: [secret])
        let encoded = Data(secret.utf8).base64EncodedString()
        #expect(redactor.redact("v=\(encoded);") == "v=\(mask);")
        let urlSafe = Data("a?>secret>>?value".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(Redactor(secrets: ["a?>secret>>?value"]).redact("v=\(urlSafe);") == "v=\(mask);")

        // Inside a longer payload (Basic authorization), at each of the three alignments.
        for user in ["ab", "abc", "abcd"] {
            let header = "Basic " + Data("\(user):\(secret)".utf8).base64EncodedString()
            let redacted = redactor.redact(header)
            #expect(redacted.contains(mask))
            // What is left is the user part and at most one mixed character plus padding.
            let leftover = redacted.replacingOccurrences(of: mask, with: "").dropFirst("Basic ".count)
            #expect(leftover.count <= (user.count + 1) * 4 / 3 + 4, "\(leftover)")
        }
    }

    @Test func overlapsAreMergedLongestWins() {
        let redactor = Redactor(secrets: ["abcd1234", "abcd1234efgh", "efgh-tail"])
        #expect(redactor.redact("x abcd1234efgh y") == "x \(mask) y")
        #expect(redactor.redact("x abcd1234efgh-tail y") == "x \(mask) y")
        #expect(redactor.redact("x abcd1234 y") == "x \(mask) y")
    }

    @Test func shortAndTemplateValuesAreIgnored() {
        let ignored = Redactor(secrets: ["abc", "", "{{apiToken}}", " {{a}} {{$timestamp}}\n", "    "])
        #expect(ignored.isEmpty)
        #expect(ignored.redact("abc {{apiToken}}") == "abc {{apiToken}}")
        let mixed = Redactor(secrets: ["Bearer {{token}}", "abcd"])
        #expect(!mixed.isEmpty)
        #expect(mixed.redact("abcd") == mask)
    }

    @Test func largeTextIsScannedOnce() {
        let secrets = (0..<50).map { "secret-value-\($0)-xyz" }
        let redactor = Redactor(secrets: secrets)
        let chunk = String(repeating: "lorem ipsum dolor sit amet %20 + s se sec ", count: 60)
        let text = (0..<200).map { chunk + secrets[$0 % secrets.count] }.joined()
        #expect(text.utf8.count > 400_000)
        let clock = ContinuousClock()
        var redacted = ""
        let elapsed = clock.measure { redacted = redactor.redact(text) }
        #expect(!redacted.contains("secret-value-"))
        #expect(redacted.components(separatedBy: mask).count == 201)
        #expect(elapsed < .seconds(5))
    }

    @Test func aBodyIsMaskedWhateverItsCharset() throws {
        let redactor = Redactor(secrets: ["sk-live-12345"])
        let utf8 = Data("{\"echo\": \"sk-live-12345\", \"café\": true}".utf8)
        #expect(String(decoding: redactor.redact(body: utf8), as: UTF8.self) == "{\"echo\": \"\(Redactor.mask)\", \"café\": true}")

        // Latin-1, which is not valid UTF-8: the secret is masked all the same, and the rest is left byte for byte.
        let latin = try #require("Erreur d\u{E9}tect\u{E9}e pour Authorization: Bearer sk-live-12345.".data(using: .isoLatin1))
        #expect(String(data: latin, encoding: .utf8) == nil)
        let masked = redactor.redact(body: latin)
        #expect(String(data: masked, encoding: .isoLatin1) == "Erreur d\u{E9}tect\u{E9}e pour Authorization: Bearer \(Redactor.plainMask).")

        // A secret that is not ASCII, in a body one stray byte makes invalid: masked as UTF-8 spells it, and
        // as Latin-1 does.
        let accented = Redactor(secrets: ["cl\u{E9}-secr\u{E8}te"])
        let stray = Data("jeton: cl\u{E9}-secr\u{E8}te ".utf8) + Data([0xE9])
        #expect(redactor.redact(body: stray) == stray)
        #expect(accented.redact(body: stray) == Data("jeton: \(Redactor.plainMask) ".utf8) + Data([0xE9]))
        let inLatin = try #require("jeton: cl\u{E9}-secr\u{E8}te.".data(using: .isoLatin1))
        #expect(accented.redact(body: inLatin) == Data("jeton: \(Redactor.plainMask).".utf8))

        // UTF-16 far from the start of a body that passes for text: the secret is found between its zero bytes.
        let wide = try #require("sk-live-12345".data(using: .utf16LittleEndian))
        let late = Data(repeating: 0x20, count: 2000) + wide + Data("end".utf8)
        let hidden = redactor.redact(body: late)
        #expect(hidden.range(of: wide) == nil)
        #expect(hidden.suffix(3) == Data("end".utf8))
        let big = try #require("sk-live-12345".data(using: .utf16BigEndian))
        #expect(redactor.redact(body: Data(repeating: 0x20, count: 2000) + big).range(of: big) == nil)

        // Nothing to hide, or not text: the very same bytes.
        #expect(redactor.redact(body: Data("nothing here".utf8)) == Data("nothing here".utf8))
        let binary = Data([0x89, 0x50, 0x00, 0x01]) + Data("sk-live-12345".utf8)
        #expect(redactor.redact(body: binary) == binary)
        #expect(Redactor(secrets: []).redact(body: latin) == latin)
    }
}
