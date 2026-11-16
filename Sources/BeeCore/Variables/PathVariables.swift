import Foundation

/// Path variables: a path segment written `:name` in an address (`/tickets/:ticketId`) is replaced
/// when the request is sent.
///
/// The value comes from the request's row of that name, a template that may use `{{variables}}`. Without a
/// row, or with an empty one, the value is the variable of the same name (`{{ticketId}}`), so a path variable
/// reads the collection or the environment with nothing to fill in. Unlike a `{{placeholder}}` typed in the
/// address, which is pasted as it is, the value is percent-encoded as one segment: a `/` in it is sent as `%2F`.
public enum PathVariables {
    /// One `:name` segment in an address.
    public struct Occurrence: Hashable, Sendable {
        public var name: String
        /// Range in the address, colon included.
        public var range: Range<String.Index>
        /// The same range in UTF-16 units, for AppKit text views.
        public var nsRange: NSRange
    }

    /// The `:name` segments of the path, in order. The path starts at the first `/` after the authority and stops
    /// at `?` or `#`. A segment is a variable when it starts with a colon followed by a letter or `_`, and holds
    /// no `{{placeholder}}`; its name is the rest of the segment.
    public static func occurrences(in address: String) -> [Occurrence] {
        guard address.contains(":") else { return [] }
        // A placeholder is opaque: one unit without a character, never a delimiter.
        var units: [(character: Character?, index: String.Index)] = []
        for token in TemplateEngine.tokens(in: address) {
            if token.kind == .text {
                for index in address[token.range].indices { units.append((address[index], index)) }
            } else {
                units.append((nil, token.range.lowerBound))
            }
        }
        func isPathEnd(_ character: Character?) -> Bool { character == "?" || character == "#" }

        guard let firstSlash = units.firstIndex(where: { $0.character == "/" || isPathEnd($0.character) }),
              units[firstSlash].character == "/"
        else { return [] }
        var pathStart = firstSlash
        // `scheme://authority/path`: the two slashes after the scheme open the authority, not the path.
        if firstSlash > 0, units[firstSlash - 1].character == ":",
           firstSlash + 1 < units.count, units[firstSlash + 1].character == "/" {
            guard let next = units[(firstSlash + 2)...].firstIndex(where: { $0.character == "/" || isPathEnd($0.character) }),
                  units[next].character == "/"
            else { return [] }
            pathStart = next
        }

        var result: [Occurrence] = []
        var segmentStart = pathStart + 1
        for position in (pathStart + 1)...units.count {
            let isEnd = position == units.count
            let character = isEnd ? nil : units[position].character
            guard isEnd || character == "/" || isPathEnd(character) else { continue }
            let segment = units[segmentStart..<position]
            if segment.count >= 2, segment.first?.character == ":", segment.allSatisfy({ $0.character != nil }),
               let initial = segment.dropFirst().first?.character, initial.isLetter || initial == "_" {
                let range = units[segmentStart].index..<(isEnd ? address.endIndex : units[position].index)
                let name = String(address[address.index(after: range.lowerBound)..<range.upperBound])
                result.append(Occurrence(name: name, range: range, nsRange: NSRange(range, in: address)))
            }
            if isEnd || character != "/" { break }
            segmentStart = position + 1
        }
        return result
    }

    /// The distinct names of the path variables of an address, in order of first appearance.
    public static func names(in address: String) -> [String] {
        var names: [String] = []
        for occurrence in occurrences(in: address) where !names.contains(occurrence.name) {
            names.append(occurrence.name)
        }
        return names
    }

    /// One row per path variable of the address, in order. A row is taken from `existing` by name; a name with no
    /// row takes over a leftover row that is one keystroke away from it (the variable was renamed in the address),
    /// otherwise it starts blank. Rows whose name left the address are dropped.
    public static func rows(for address: String, from existing: [KeyValue]) -> [KeyValue] {
        let names = names(in: address)
        var leftovers = existing.filter { row in !names.contains(row.key) }
        return names.map { name in
            if let row = existing.first(where: { $0.key == name }) {
                var row = row
                row.isEnabled = true
                return row
            }
            if let index = leftovers.firstIndex(where: { isOneEdit(from: $0.key, to: name) }) {
                var row = leftovers.remove(at: index)
                row.key = name
                row.isEnabled = true
                return row
            }
            return KeyValue(key: name)
        }
    }

    /// The rows worth keeping with the request: the ones of ``rows(for:from:)`` that say something.
    public static func storedRows(for address: String, from existing: [KeyValue]) -> [KeyValue] {
        rows(for: address, from: existing).filter { !$0.value.isEmpty || $0.isSecret }
    }

    /// The template that gives the variable its value: the row's when it has one, else `{{name}}`.
    public static func valueTemplate(for name: String, in rows: [KeyValue]) -> String {
        guard let row = rows.first(where: { $0.key == name }), !row.value.isEmpty else { return "{{\(name)}}" }
        return row.value
    }

    /// The address with each `:name` segment replaced by what `replacement` returns for the name.
    public static func substituting(_ address: String, _ replacement: (String) -> String) -> String {
        var output = ""
        var cursor = address.startIndex
        for occurrence in occurrences(in: address) {
            output += address[cursor..<occurrence.range.lowerBound]
            output += replacement(occurrence.name)
            cursor = occurrence.range.upperBound
        }
        output += address[cursor...]
        return output
    }

    /// Renders an address: the text around the path variables as `TemplateEngine` does, each path variable by its
    /// value, trimmed and percent-encoded as one segment.
    ///
    /// - Parameter secretMask: when set, a path variable whose value is or uses a secret is drawn as this mask
    ///   instead of its value, for an address about to be shown.
    public static func render(
        _ address: String, rows: [KeyValue], in context: VariableContext, secretMask: String? = nil
    ) -> RenderResult {
        var text = ""
        var unresolved: [String] = []
        var usedSecret = false
        func take(_ result: RenderResult) {
            for name in result.unresolved where !unresolved.contains(name) { unresolved.append(name) }
            if result.usedSecret { usedSecret = true }
        }

        var cursor = address.startIndex
        for occurrence in occurrences(in: address) {
            let literal = TemplateEngine.render(String(address[cursor..<occurrence.range.lowerBound]), in: context)
            take(literal)
            text += literal.text
            cursor = occurrence.range.upperBound

            let row = rows.first { $0.key == occurrence.name }
            let template = valueTemplate(for: occurrence.name, in: rows)
            let value = TemplateEngine.render(template, in: context)
            take(value)
            let holdsSecret = row.map { $0.isSecret && !$0.value.isEmpty && !TemplateEngine.isPlaceholderOnly($0.value) } ?? false
            if holdsSecret { usedSecret = true }
            if let secretMask, holdsSecret || value.usedSecret {
                text += secretMask
            } else {
                text += PercentCoding.encodePathSegment(value.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let tail = TemplateEngine.render(String(address[cursor...]), in: context)
        take(tail)
        text += tail.text
        return RenderResult(text: text, unresolved: unresolved, usedSecret: usedSecret)
    }

    // MARK: Helpers

    /// True when one name becomes the other by typing or deleting one character, or replacing one.
    private static func isOneEdit(from old: String, to new: String) -> Bool {
        let old = Array(old)
        let new = Array(new)
        guard old != new, abs(old.count - new.count) <= 1 else { return false }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        return max(old.count, new.count) - prefix - suffix <= 1
    }
}
