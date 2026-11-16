import CryptoKit
import Foundation

/// Hashing and encoding helpers behind `bee.crypto`, `bee.base64`, `atob` and `btoa`.
enum ScriptCodec {
    static func hash(_ algorithm: String, of text: String) -> String? {
        let data = Data(text.utf8)
        switch algorithm {
        case "sha256": return hex(SHA256.hash(data: data))
        case "sha1": return hex(Insecure.SHA1.hash(data: data))
        case "md5": return hex(Insecure.MD5.hash(data: data))
        default: return nil
        }
    }

    static func hmacSHA256(key: String, text: String, base64: Bool) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return base64 ? Data(code).base64EncodedString() : hex(code)
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Base64 of the UTF-8 bytes of `text`.
    static func encodeUTF8(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Decodes base64 (standard or URL-safe, padding optional, whitespace ignored) to UTF-8 text.
    static func decodeUTF8(_ text: String) -> String? {
        decodeBytes(text, allowURLSafe: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `btoa`: every character of the binary string must fit in one byte.
    static func binaryToBase64(_ text: String) -> String? {
        var bytes: [UInt8] = []
        for scalar in text.unicodeScalars {
            guard let byte = UInt8(exactly: scalar.value) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes).base64EncodedString()
    }

    /// `atob`: decodes base64 to a binary string with one character per byte.
    static func base64ToBinary(_ text: String) -> String? {
        decodeBytes(text, allowURLSafe: false).map { bytes in
            String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        }
    }

    private static func decodeBytes(_ text: String, allowURLSafe: Bool) -> Data? {
        var cleaned = String(text.filter { !$0.isWhitespace })
        if allowURLSafe {
            cleaned = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        }
        while cleaned.hasSuffix("=") { cleaned.removeLast() }
        if cleaned.count % 4 == 1 { return nil }
        cleaned += String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: cleaned)
    }
}
