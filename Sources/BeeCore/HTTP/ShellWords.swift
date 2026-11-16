import Foundation

/// A small POSIX-shell word splitter: single quotes, double quotes with escapes, `$'…'` and backslash line continuations.
/// Nothing is expanded or executed.
enum ShellWords {
    static func split(_ input: String) throws(CurlParseError) -> [String] {
        let characters = Array(input)
        var words: [String] = []
        var current = ""
        var inWord = false
        var index = 0

        func isNewline(_ character: Character) -> Bool { character == "\n" || character == "\r" || character == "\r\n" }
        func endWord() {
            if inWord { words.append(current) }
            current = ""
            inWord = false
        }

        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" || isNewline(character) {
                endWord()
                index += 1
            } else if character == "\\" {
                if index + 1 < characters.count {
                    if !isNewline(characters[index + 1]) {
                        current.append(characters[index + 1])
                        inWord = true
                    }
                    index += 2
                } else {
                    index += 1
                }
            } else if character == "'" {
                guard let close = characters[(index + 1)...].firstIndex(of: "'") else {
                    throw .malformed("Unterminated single quote")
                }
                current += String(characters[(index + 1)..<close])
                inWord = true
                index = close + 1
            } else if character == "\"" {
                index += 1
                var closed = false
                while index < characters.count {
                    let inner = characters[index]
                    if inner == "\"" {
                        closed = true
                        index += 1
                        break
                    }
                    if inner == "\\", index + 1 < characters.count {
                        let escaped = characters[index + 1]
                        if isNewline(escaped) {
                            index += 2
                        } else if "\"\\$`".contains(escaped) {
                            current.append(escaped)
                            index += 2
                        } else {
                            current.append(inner)
                            index += 1
                        }
                    } else {
                        current.append(inner)
                        index += 1
                    }
                }
                guard closed else { throw .malformed("Unterminated double quote") }
                inWord = true
            } else if character == "$", index + 1 < characters.count, characters[index + 1] == "'" {
                index = try readANSIQuoted(characters, from: index + 2, into: &current)
                inWord = true
            } else {
                current.append(character)
                inWord = true
                index += 1
            }
        }
        endWord()
        return words
    }

    /// Reads `$'…'` content starting after the opening quote; returns the index after the closing quote.
    private static func readANSIQuoted(_ characters: [Character], from start: Int, into output: inout String) throws(CurlParseError) -> Int {
        var index = start
        func hexRun(_ maxLength: Int) -> UInt32? {
            var digits = ""
            while digits.count < maxLength, index < characters.count, characters[index].isHexDigit {
                digits.append(characters[index])
                index += 1
            }
            return UInt32(digits, radix: 16)
        }
        while index < characters.count {
            let character = characters[index]
            if character == "'" { return index + 1 }
            guard character == "\\", index + 1 < characters.count else {
                output.append(character)
                index += 1
                continue
            }
            let escape = characters[index + 1]
            index += 2
            switch escape {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "a": output.append("\u{07}")
            case "b": output.append("\u{08}")
            case "e", "E": output.append("\u{1B}")
            case "f": output.append("\u{0C}")
            case "v": output.append("\u{0B}")
            case "\\", "'", "\"", "?": output.append(escape)
            case "x", "u", "U":
                let maxLength = escape == "x" ? 2 : (escape == "u" ? 4 : 8)
                if let value = hexRun(maxLength), let scalar = Unicode.Scalar(value) { output.unicodeScalars.append(scalar) }
            case "0"..."7":
                var digits = String(escape)
                while digits.count < 3, index < characters.count, ("0"..."7").contains(characters[index]) {
                    digits.append(characters[index])
                    index += 1
                }
                if let value = UInt32(digits, radix: 8), let scalar = Unicode.Scalar(value) { output.unicodeScalars.append(scalar) }
            default:
                output.append("\\")
                output.append(escape)
            }
        }
        throw .malformed("Unterminated $'…' quote")
    }
}
