import Foundation

/// Percent-encoding for query strings and form bodies.
enum PercentCoding {
    private static let hex = Array("0123456789ABCDEF".utf8)

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        default: byte - 0x61 + 10
        }
    }

    private static let queryAllowed = Set("-._~!$'()*,;:@/?".utf8)
    private static let formAllowed = Set("-._~*".utf8)

    /// Encodes a query key or value. Unreserved characters and `!$'()*,;:@/?` stay, a space becomes `%20`, `+ & = #`
    /// and everything else is encoded. An existing `%XX` triplet is kept, so a pasted address is not encoded twice.
    static func encodeQuery(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            if isAlphanumeric(byte) || queryAllowed.contains(byte) {
                output.append(byte)
            } else if byte == 0x25, index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) {
                output.append(byte)
            } else {
                output.append(contentsOf: [0x25, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Encodes a field for an `application/x-www-form-urlencoded` body: a space becomes `+`, everything but
    /// alphanumerics and `-._~*` is encoded.
    static func encodeForm(_ text: String) -> String {
        var output: [UInt8] = []
        for byte in text.utf8 {
            if isAlphanumeric(byte) || formAllowed.contains(byte) {
                output.append(byte)
            } else if byte == 0x20 {
                output.append(0x2B)
            } else {
                output.append(contentsOf: [0x25, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes a form-encoded field (`+` is a space, `%XX` is a byte). Malformed escapes are kept as typed.
    static func decodeForm(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x2B {
                output.append(0x20)
            } else if byte == 0x25, index + 2 < bytes.count, isHexDigit(bytes[index + 1]), isHexDigit(bytes[index + 2]) {
                output.append(hexValue(bytes[index + 1]) << 4 | hexValue(bytes[index + 2]))
                index += 2
            } else {
                output.append(byte)
            }
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Applies `transform` to the literal text of a template and leaves its `{{placeholders}}` untouched.
    static func mapText(of template: String, _ transform: (String) -> String) -> String {
        TemplateEngine.tokens(in: template).reduce(into: "") { result, token in
            let piece = String(template[token.range])
            result += token.kind == .text ? transform(piece) : piece
        }
    }
}
