import Foundation

/// Textual conversion between the single address field shown to a person and the model's split form
/// (`RequestItem.url` without query + `queryParams` rows). Nothing is percent-encoded or decoded here, and
/// `{{placeholders}}` are opaque: a `?`, `#`, `&` or `=` inside one is never a delimiter.
public enum URLTemplate {
    /// Shown in place of a secret row's value.
    public static let mask = "••••••"

    /// Splits a full address typed by a person into the base and its query rows (`?a=1&b={{x}}`).
    /// The fragment (`#…`) stays on the base. Segments without a key are dropped; a key without `=` gets an empty value.
    public static func split(_ full: String) -> (base: String, params: [KeyValue]) {
        let delimiters = delimiters(in: full)
        guard let queryStart = delimiters.query else { return (full, []) }
        let queryEnd = delimiters.fragment ?? full.endIndex
        let query = String(full[full.index(after: queryStart)..<queryEnd])
        let fragment = delimiters.fragment.map { String(full[$0...]) } ?? ""
        let params = pieces(of: query, separatedBy: "&").compactMap { segment -> KeyValue? in
            let pair = pieces(of: segment, separatedBy: "=", maxSplits: 1)
            guard let key = pair.first, !key.isEmpty else { return nil }
            return KeyValue(key: key, value: pair.count > 1 ? pair[1] : "")
        }
        return (String(full[..<queryStart]) + fragment, params)
    }

    /// Joins the base and the enabled rows with non-empty keys into the string shown in the address field.
    /// A secret row whose value is not solely made of placeholders is shown as ``mask``.
    public static func join(base: String, params: [KeyValue]) -> String {
        let query = params
            .filter { $0.isEnabled && !$0.key.isEmpty }
            .map { "\($0.key)=\(shownValue(of: $0))" }
            .joined(separator: "&")
        guard !query.isEmpty else { return base }
        let delimiters = delimiters(in: base)
        let head = String(base[..<(delimiters.fragment ?? base.endIndex)])
        let tail = delimiters.fragment.map { String(base[$0...]) } ?? ""
        let separator: String
        if delimiters.query == nil {
            separator = "?"
        } else {
            separator = head.hasSuffix("?") || head.hasSuffix("&") ? "" : "&"
        }
        return head + separator + query + tail
    }

    /// Rows parsed from an edited address merged into the existing rows.
    ///
    /// The address only shows enabled rows with a key. A parsed row takes the id and `isSecret` flag of the
    /// existing shown row at the same position when the keys match (failing that, of the first unclaimed shown row
    /// with the same key). A secret row keeps its in-memory value while its parsed text is unchanged, or is
    /// the ``mask``; a secret row renamed in place keeps its slot as long as its value is still the mask.
    /// Rows the address never shows (disabled, or without a key) stay at their relative place.
    public static func merge(parsed: [KeyValue], into existing: [KeyValue]) -> [KeyValue] {
        let shown = existing.indices.filter { isShown(existing[$0]) }
        var claimed: [Int?] = Array(repeating: nil, count: parsed.count)  // parsed position -> shown position
        var taken: Set<Int> = []

        func claim(_ position: Int, _ shownPosition: Int) {
            claimed[position] = shownPosition
            taken.insert(shownPosition)
        }
        for position in parsed.indices where position < shown.count {
            if existing[shown[position]].key == parsed[position].key { claim(position, position) }
        }
        for position in parsed.indices where claimed[position] == nil {
            let key = parsed[position].key
            if let match = shown.indices.first(where: { !taken.contains($0) && existing[shown[$0]].key == key }) {
                claim(position, match)
            }
        }
        for position in parsed.indices where claimed[position] == nil && position < shown.count {
            if !taken.contains(position), existing[shown[position]].isSecret, parsed[position].value == mask {
                claim(position, position)
            }
        }

        let rows = parsed.indices.map { position -> KeyValue in
            let row = parsed[position]
            guard let shownPosition = claimed[position] else { return row }
            var merged = existing[shown[shownPosition]]
            merged.key = row.key
            let unchanged = row.value == mask || row.value == shownValue(of: merged)
            merged.value = merged.isSecret && unchanged ? merged.value : row.value
            return merged
        }

        // Rows hidden from the address, each anchored after the number of shown rows that precede it.
        var hidden: [(anchor: Int, row: KeyValue)] = []
        var shownBefore = 0
        for row in existing {
            if isShown(row) { shownBefore += 1 } else { hidden.append((shownBefore, row)) }
        }
        var result: [KeyValue] = []
        var next = 0
        func flushHidden(upTo anchor: Int) {
            while next < hidden.count, hidden[next].anchor <= anchor {
                result.append(hidden[next].row)
                next += 1
            }
        }
        flushHidden(upTo: 0)
        for (position, row) in rows.enumerated() {
            result.append(row)
            flushHidden(upTo: position + 1)
        }
        flushHidden(upTo: Int.max)
        return result
    }

    // MARK: Helpers

    private static func isShown(_ row: KeyValue) -> Bool { row.isEnabled && !row.key.isEmpty }

    /// The row's value as displayed in the address.
    private static func shownValue(of row: KeyValue) -> String {
        guard row.isSecret, !row.value.isEmpty, !TemplateEngine.isPlaceholderOnly(row.value) else { return row.value }
        return mask
    }

    /// The first `?` before any `#`, and the first `#`, both outside placeholders.
    private static func delimiters(in text: String) -> (query: String.Index?, fragment: String.Index?) {
        var query: String.Index?
        for token in TemplateEngine.tokens(in: text) where token.kind == .text {
            for index in text[token.range].indices {
                switch text[index] {
                case "#": return (query, index)
                case "?" where query == nil: query = index
                default: break
                }
            }
        }
        return (query, nil)
    }

    /// Splits at the separator outside placeholders, keeping empty pieces.
    private static func pieces(of text: String, separatedBy separator: Character, maxSplits: Int = .max) -> [String] {
        var result: [String] = []
        var current = ""
        for token in TemplateEngine.tokens(in: text) {
            guard token.kind == .text else {
                current += text[token.range]
                continue
            }
            for character in text[token.range] {
                if character == separator, result.count < maxSplits {
                    result.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
        }
        result.append(current)
        return result
    }
}

extension TemplateEngine {
    /// True when the text holds at least one placeholder and nothing else but whitespace.
    static func isPlaceholderOnly(_ text: String) -> Bool {
        let tokens = tokens(in: text)
        guard tokens.contains(where: { $0.kind != .text }) else { return false }
        return tokens.allSatisfy { token in
            token.kind != .text || text[token.range].allSatisfy(\.isWhitespace)
        }
    }
}
