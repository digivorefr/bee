import Foundation

/// A run of code that is not plain ink.
nonisolated struct SyntaxSpan: Sendable {
    enum Kind: Sendable {
        /// Punctuation and comments.
        case secondary
        case string
        case number
        /// Ink, semibold.
        case keyword
    }

    var range: NSRange
    var kind: Kind
}

/// Finds the few runs the language colors: strings, numbers, keywords, punctuation and comments.
/// Works on UTF-16 units so ranges go straight to a text storage; safe off the main actor.
nonisolated enum SyntaxScanner {
    enum Grammar: Sendable {
        case json, javascript, markup, graphql
    }

    static func spans(in text: String, grammar: Grammar) -> [SyntaxSpan] {
        let units = Array(text.utf16)
        switch grammar {
        case .json: return json(units)
        case .javascript: return script(units, keywords: javascriptKeywords, isGraphQL: false)
        case .graphql: return script(units, keywords: graphqlKeywords, isGraphQL: true)
        case .markup: return markup(units)
        }
    }

    // MARK: Characters

    private static let quote: UInt16 = 0x22
    private static let apostrophe: UInt16 = 0x27
    private static let backtick: UInt16 = 0x60
    private static let backslash: UInt16 = 0x5C
    private static let newline: UInt16 = 0x0A
    private static let slash: UInt16 = 0x2F
    private static let star: UInt16 = 0x2A
    private static let hash: UInt16 = 0x23
    private static let dot: UInt16 = 0x2E
    private static let minus: UInt16 = 0x2D
    private static let colon: UInt16 = 0x3A
    private static let less: UInt16 = 0x3C
    private static let greater: UInt16 = 0x3E
    private static let equals: UInt16 = 0x3D
    private static let bang: UInt16 = 0x21
    private static let question: UInt16 = 0x3F

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x24 || unit > 0x7F
    }

    private static func isWord(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit)
    }

    private static func word(_ units: [UInt16], _ start: Int, _ end: Int) -> String {
        String(decoding: units[start..<end], as: UTF16.self)
    }

    private static func span(_ start: Int, _ end: Int, _ kind: SyntaxSpan.Kind) -> SyntaxSpan {
        SyntaxSpan(range: NSRange(location: start, length: end - start), kind: kind)
    }

    /// The index after a quoted string that opens at `start`; an unclosed one ends with its line
    /// unless `multiline`.
    private static func endOfString(_ units: [UInt16], from start: Int, multiline: Bool) -> Int {
        let delimiter = units[start]
        var index = start + 1
        while index < units.count {
            let unit = units[index]
            if unit == backslash { index += 2; continue }
            if unit == delimiter { return index + 1 }
            if unit == newline, !multiline { return index }
            index += 1
        }
        return units.count
    }

    private static func endOfNumber(_ units: [UInt16], from start: Int) -> Int {
        var index = start + 1
        while index < units.count {
            let unit = units[index]
            let isSign = (unit == minus || unit == 0x2B) && (units[index - 1] == 0x65 || units[index - 1] == 0x45)
            guard isWord(unit) || unit == dot || isSign else { break }
            index += 1
        }
        return index
    }

    // MARK: JSON

    private static func json(_ units: [UInt16]) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            if unit == quote {
                let end = endOfString(units, from: index, multiline: false)
                var next = end
                while next < count, isSpace(units[next]) { next += 1 }
                // A member name stays in ink; a value takes the string hue.
                if !(next < count && units[next] == colon) { spans.append(span(index, end, .string)) }
                index = end
            } else if isDigit(unit) || (unit == minus && index + 1 < count && isDigit(units[index + 1])) {
                let end = endOfNumber(units, from: index)
                spans.append(span(index, end, .number))
                index = end
            } else if isLetter(unit) {
                var end = index + 1
                while end < count, isWord(units[end]) { end += 1 }
                if ["true", "false", "null"].contains(word(units, index, end)) { spans.append(span(index, end, .keyword)) }
                index = end
            } else if unit == 0x7B || unit == 0x7D || unit == 0x5B || unit == 0x5D || unit == 0x2C || unit == colon {
                spans.append(span(index, index + 1, .secondary))
                index += 1
            } else {
                index += 1
            }
        }
        return spans
    }

    // MARK: JavaScript and GraphQL

    private static let javascriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
        "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in",
        "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
        "try", "typeof", "undefined", "var", "void", "while", "yield",
    ]

    private static let graphqlKeywords: Set<String> = [
        "directive", "enum", "extend", "false", "fragment", "implements", "input", "interface", "mutation",
        "null", "on", "query", "scalar", "schema", "subscription", "true", "type", "union",
    ]

    private static func script(_ units: [UInt16], keywords: Set<String>, isGraphQL: Bool) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            let next = index + 1 < count ? units[index + 1] : 0
            if (isGraphQL && unit == hash) || (!isGraphQL && unit == slash && next == slash) {
                var end = index
                while end < count, units[end] != newline { end += 1 }
                spans.append(span(index, end, .secondary))
                index = end
            } else if !isGraphQL, unit == slash, next == star {
                var end = index + 2
                while end < count, !(units[end] == slash && units[end - 1] == star && end > index + 2) { end += 1 }
                end = min(end + 1, count)
                spans.append(span(index, end, .secondary))
                index = end
            } else if isGraphQL, unit == quote, next == quote, index + 2 < count, units[index + 2] == quote {
                var end = index + 3
                while end < count, !(units[end] == quote && units[end - 1] == quote && units[end - 2] == quote && end >= index + 5) {
                    end += 1
                }
                end = min(end + 1, count)
                spans.append(span(index, end, .string))
                index = end
            } else if unit == quote || (!isGraphQL && (unit == apostrophe || unit == backtick)) {
                let end = endOfString(units, from: index, multiline: unit == backtick)
                spans.append(span(index, end, .string))
                index = end
            } else if isDigit(unit) {
                let end = endOfNumber(units, from: index)
                spans.append(span(index, end, .number))
                index = end
            } else if isLetter(unit) {
                var end = index + 1
                while end < count, isWord(units[end]) { end += 1 }
                let isMember = index > 0 && units[index - 1] == dot
                if !isMember, keywords.contains(word(units, index, end)) { spans.append(span(index, end, .keyword)) }
                index = end
            } else {
                index += 1
            }
        }
        return spans
    }

    // MARK: XML and HTML

    private static func markup(_ units: [UInt16]) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var index = 0
        let count = units.count
        while index < count {
            guard units[index] == less, index + 1 < count else { index += 1; continue }
            let next = units[index + 1]
            if next == bang || next == question {
                // Comments, doctype, CDATA and processing instructions read as one quiet run.
                let isComment = index + 3 < count && units[index + 2] == minus && units[index + 3] == minus
                var end = index + 2
                while end < count {
                    if units[end] == greater, !isComment || (end >= index + 6 && units[end - 1] == minus && units[end - 2] == minus) { break }
                    end += 1
                }
                end = min(end + 1, count)
                spans.append(span(index, end, .secondary))
                index = end
                continue
            }
            guard isLetter(next) || next == slash else { index += 1; continue }
            var cursor = index + 1
            if next == slash { cursor += 1 }
            spans.append(span(index, cursor, .secondary))
            let nameStart = cursor
            while cursor < count, isWord(units[cursor]) || units[cursor] == minus || units[cursor] == colon || units[cursor] == dot {
                cursor += 1
            }
            if cursor > nameStart { spans.append(span(nameStart, cursor, .keyword)) }
            while cursor < count, units[cursor] != greater {
                let unit = units[cursor]
                if unit == quote || unit == apostrophe {
                    let end = endOfString(units, from: cursor, multiline: true)
                    spans.append(span(cursor, end, .string))
                    cursor = end
                } else if unit == equals || unit == slash {
                    spans.append(span(cursor, cursor + 1, .secondary))
                    cursor += 1
                } else {
                    cursor += 1
                }
            }
            if cursor < count {
                spans.append(span(cursor, cursor + 1, .secondary))
                cursor += 1
            }
            index = cursor
        }
        return spans
    }
}
