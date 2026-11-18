import Foundation

/// Replaces secret values with a mask in any text about to be shown, logged or persisted
/// (resolved addresses, console lines, error messages, response excerpts).
///
/// A secret is found in clear and in its usual transport forms:
/// - percent-encoded, whatever the encoder (any byte may be `%XX` in either case, a space may be `+`);
/// - escaped inside a JSON string (with or without `\/`, with or without `\uXXXX` for non-ASCII);
/// - Base64 of the value, standard or URL-safe alphabet, alone or inside a longer Base64 payload
///   (such as the `user:password` of a Basic authorization header).
///
/// The text is scanned once; overlapping matches are merged into a single mask so no fragment of a
/// secret survives next to it.
public struct Redactor: Sendable {
    public static let mask = "••••••"

    private static let maskBytes = Array(mask.utf8)
    private static let minimumLength = 4
    /// Below this length a Base64 fragment is too likely to appear by chance.
    private static let minimumFragmentLength = 8

    private static let percent = UInt8(ascii: "%")
    private static let plus = UInt8(ascii: "+")
    private static let space = UInt8(ascii: " ")

    /// Every byte sequence to mask.
    private let needles: [[UInt8]]
    /// For each possible first byte, the needles that start with it.
    private let needlesByFirstByte: [[Int]]
    /// Whether a text byte can start a match at all, checked before anything else.
    private let canStartMatch: [Bool]

    /// - Parameter secrets: values to hide. Values shorter than 4 characters, and values made only of
    ///   `{{placeholders}}` and whitespace, are templates or noise rather than secrets and are ignored.
    public init(secrets: [String]) {
        var unique = Set<[UInt8]>()
        for secret in secrets where Self.isRedactable(secret) {
            for variant in Self.variants(of: secret) where variant.count >= Self.minimumLength {
                unique.insert(variant)
            }
        }
        let needles = unique.sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }

        var byFirstByte = [[Int]](repeating: [], count: 256)
        for (index, needle) in needles.enumerated() {
            byFirstByte[Int(needle[0])].append(index)
        }
        var canStart = byFirstByte.map { !$0.isEmpty }
        if !needles.isEmpty {
            // An escape can stand for any first byte, and "+" for a space.
            canStart[Int(Self.percent)] = true
            canStart[Int(Self.plus)] = canStart[Int(Self.plus)] || canStart[Int(Self.space)]
        }

        self.needles = needles
        self.needlesByFirstByte = byFirstByte
        self.canStartMatch = canStart
    }

    /// True when there is nothing to hide: `redact` then returns its input.
    public var isEmpty: Bool { needles.isEmpty }

    /// The text with every occurrence of every secret replaced by `mask`.
    public func redact(_ text: String) -> String {
        guard !needles.isEmpty, !text.isEmpty else { return text }
        var source = text
        let redacted = source.withUTF8 { masked($0, with: Self.maskBytes) }
        return redacted.map { String(decoding: $0, as: UTF8.self) } ?? text
    }

    /// The bytes with every occurrence of every secret replaced by `mask`, or `nil` when there is none.
    /// The bytes are scanned as they are: they need not be valid text in any charset.
    private func masked(_ bytes: UnsafeBufferPointer<UInt8>, with mask: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        var copied = 0
        var maskStart = -1
        var maskEnd = -1

        func closeMask() {
            if output.isEmpty { output.reserveCapacity(bytes.count) }
            output.append(contentsOf: bytes[copied..<maskStart])
            output.append(contentsOf: mask)
            copied = maskEnd
            maskStart = -1
        }

        var index = 0
        while index < bytes.count {
            if maskStart >= 0, index >= maskEnd { closeMask() }
            let byte = bytes[index]
            if canStartMatch[Int(byte)], let end = matchEnd(in: bytes, at: index, first: byte) {
                if maskStart < 0 {
                    maskStart = index
                    maskEnd = end
                } else if end > maskEnd {
                    maskEnd = end
                }
            }
            index += 1
        }
        if maskStart >= 0 { closeMask() }
        guard copied > 0 || !output.isEmpty else { return nil }
        output.append(contentsOf: bytes[copied...])
        return output
    }

    /// A response body with every secret masked, when it is text. A body that is not valid UTF-8 (another
    /// charset, a stray byte) is text all the same: it is read byte for byte, and masked with a mask that
    /// any charset can spell. A body with a zero byte near its start is taken for binary and left as it is.
    public func redact(body: Data) -> Data {
        guard !needles.isEmpty, !body.prefix(1024).contains(0) else { return body }
        let mask = String(data: body, encoding: .utf8) != nil ? Self.maskBytes : Array(Self.plainMask.utf8)
        let masked = body.withUnsafeBytes { masked($0.bindMemory(to: UInt8.self), with: mask) }
        return masked.map { Data($0) } ?? body
    }

    /// The mask in a text whose charset Bee does not know.
    public static let plainMask = "******"

    // MARK: Matching

    /// The furthest end of a needle matching at `index`, or `nil` when none does.
    private func matchEnd(in text: UnsafeBufferPointer<UInt8>, at index: Int, first byte: UInt8) -> Int? {
        var furthest: Int?
        func tryNeedles(startingWith first: UInt8) {
            for needleIndex in needlesByFirstByte[Int(first)] {
                if let end = Self.match(needles[needleIndex], from: 0, in: text, at: index), end > (furthest ?? -1) {
                    furthest = end
                }
            }
        }
        tryNeedles(startingWith: byte)
        if byte == Self.percent, let decoded = Self.decodedByte(in: text, at: index), decoded != byte {
            tryNeedles(startingWith: decoded)
        } else if byte == Self.plus {
            tryNeedles(startingWith: Self.space)
        }
        return furthest
    }

    /// Matches the needle against the text, accepting any needle byte written as `%XX` and a space
    /// written as `+`. Returns the text index after the match.
    private static func match(
        _ needle: [UInt8], from needleStart: Int, in text: UnsafeBufferPointer<UInt8>, at textStart: Int
    ) -> Int? {
        var needleIndex = needleStart
        var textIndex = textStart
        while needleIndex < needle.count {
            guard textIndex < text.count else { return nil }
            let expected = needle[needleIndex]
            let actual = text[textIndex]
            if actual == percent, decodedByte(in: text, at: textIndex) == expected {
                if expected != percent {
                    needleIndex += 1
                    textIndex += 3
                    continue
                }
                // "%25" is either an escaped "%" or the secret's own characters: try the escape first.
                if let end = match(needle, from: needleIndex + 1, in: text, at: textIndex + 3) { return end }
            }
            guard actual == expected || (expected == space && actual == plus) else { return nil }
            needleIndex += 1
            textIndex += 1
        }
        return textIndex
    }

    /// The byte written as `%XX` at `index`, or `nil` when the text holds no valid escape there.
    private static func decodedByte(in text: UnsafeBufferPointer<UInt8>, at index: Int) -> UInt8? {
        guard index + 2 < text.count, let high = hexValue(text[index + 1]), let low = hexValue(text[index + 2]) else {
            return nil
        }
        return high << 4 | low
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: Needles

    /// False for values too short to be told apart from ordinary text and for pure templates.
    private static func isRedactable(_ secret: String) -> Bool {
        guard secret.count >= minimumLength else { return false }
        var rest = secret[...]
        while let character = rest.first {
            if character.isWhitespace {
                rest = rest.dropFirst()
            } else if rest.hasPrefix("{{"), let close = rest.range(of: "}}") {
                rest = rest[close.upperBound...]
            } else {
                return true
            }
        }
        return false
    }

    /// The byte forms under which a secret travels, percent-encoding aside (the matcher handles it).
    private static func variants(of secret: String) -> Set<[UInt8]> {
        let bytes = Array(secret.utf8)
        var variants: Set<[UInt8]> = [bytes]
        // A server may answer in another charset: the secret as UTF-16 spells it, and as Latin-1 does when
        // that differs from UTF-8.
        let units = Array(secret.utf16)
        variants.insert(units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        variants.insert(units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        if let latin = secret.data(using: .isoLatin1) { variants.insert(Array(latin)) }
        for unicodeEscape in [UnicodeEscape.none, .lowercase, .uppercase] {
            for escapesSlash in [false, true] {
                variants.insert(Array(jsonEscaped(secret, escapesSlash: escapesSlash, unicodeEscape: unicodeEscape).utf8))
            }
        }
        for encoded in base64Forms(of: bytes) {
            variants.insert(encoded)
            // URL-safe alphabet.
            variants.insert(encoded.map { byte in
                switch byte {
                case UInt8(ascii: "+"): UInt8(ascii: "-")
                case UInt8(ascii: "/"): UInt8(ascii: "_")
                default: byte
                }
            })
        }
        return variants
    }

    private enum UnicodeEscape { case none, lowercase, uppercase }

    /// The secret as it appears between the quotes of a JSON string.
    private static func jsonEscaped(_ secret: String, escapesSlash: Bool, unicodeEscape: UnicodeEscape) -> String {
        var result = ""
        for scalar in secret.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "/": result += escapesSlash ? "\\/" : "/"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 || (unicodeEscape != .none && scalar.value > 0x7F) {
                    for unit in String(scalar).utf16 {
                        let digits = String(unit, radix: 16, uppercase: unicodeEscape == .uppercase)
                        result += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
                    }
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// Base64 of the value on its own (padded and unpadded), plus the stable middle of its encoding at
    /// each of the three alignments it can take inside a longer payload: the characters that mix
    /// in bits of the neighbouring bytes are left out, the rest identifies the secret.
    private static func base64Forms(of bytes: [UInt8]) -> [[UInt8]] {
        let padding = UInt8(ascii: "=")
        let exact = Array(Data(bytes).base64EncodedString().utf8)
        var forms = [exact, exact.filter { $0 != padding }]
        for offset in 0...2 {
            let shifted = [UInt8](repeating: 0, count: offset) + bytes
            let encoded = Array(Data(shifted).base64EncodedString().utf8).filter { $0 != padding }
            let head = offset == 0 ? 0 : offset + 1
            let tail = shifted.count % 3 == 0 ? 0 : 1
            guard encoded.count - head - tail >= minimumFragmentLength else { continue }
            forms.append(Array(encoded[head..<(encoded.count - tail)]))
        }
        return forms
    }
}
