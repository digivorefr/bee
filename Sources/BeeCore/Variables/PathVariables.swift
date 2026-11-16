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

    /// One row per path variable of the address, in order, each taken from `existing` by name or started blank.
    /// Rows whose name is not in the address are left out.
    ///
    /// - Parameter previous: the address before the edit that produced `address`. When that edit is one keystroke
    ///   that turned exactly one variable name into another, the row follows its variable (it was renamed).
    ///   Any larger change (a paste, a replacement) is a different variable: nothing is carried over.
    public static func rows(for address: String, from existing: [KeyValue], renamedFrom previous: String? = nil) -> [KeyValue] {
        let names = names(in: address)
        var renamed: (from: String, to: String)?
        if let previous, isOneEdit(from: previous, to: address) {
            let before = self.names(in: previous)
            let gone = before.filter { !names.contains($0) }
            let new = names.filter { !before.contains($0) }
            if gone.count == 1, new.count == 1, isOneEdit(from: gone[0], to: new[0]) { renamed = (gone[0], new[0]) }
        }
        return names.map { name in
            if var row = existing.first(where: { $0.key == name }) {
                row.isEnabled = true
                return row
            }
            if let renamed, renamed.to == name, var row = existing.first(where: { $0.key == renamed.from }) {
                row.key = name
                row.isEnabled = true
                return row
            }
            return KeyValue(key: name)
        }
    }

    /// The rows worth keeping with the request: the ones of ``rows(for:from:renamedFrom:)`` that say something.
    public static func storedRows(
        for address: String, from existing: [KeyValue], renamedFrom previous: String? = nil
    ) -> [KeyValue] {
        rows(for: address, from: existing, renamedFrom: previous).filter { !$0.value.isEmpty || $0.isSecret }
    }

    /// The rows to keep with a request whose address goes from `previous` to `address`, and the rows to set
    /// aside in memory. A row whose name left the address is set aside rather than lost, and comes back with
    /// its value when the name does (an undo, a cut then paste); it is never carried to another name.
    public static func reconcile(
        stored: [KeyValue], aside: [KeyValue], address: String, previous: String
    ) -> (stored: [KeyValue], aside: [KeyValue]) {
        let stillAside = aside.filter { old in !stored.contains { $0.key == old.key } }
        let kept = storedRows(for: address, from: stored + stillAside, renamedFrom: previous)
        let dropped = stored.filter { row in !kept.contains { $0.id == row.id } }
        let remaining = stillAside.filter { old in
            !kept.contains { $0.id == old.id } && !dropped.contains { $0.key == old.key }
        }
        return (kept, remaining + dropped)
    }

    /// The template that gives the variable its value: the row's, trimmed, when it has one, else `{{name}}`.
    public static func valueTemplate(for name: String, in rows: [KeyValue]) -> String {
        let value = rows.first { $0.key == name }?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "{{\(name)}}" : value
    }

    /// True when the row itself holds a secret: it is marked secret and its value is more than a reference.
    public static func holdsSecret(_ row: KeyValue?) -> Bool {
        guard let row, row.isSecret else { return false }
        let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !TemplateEngine.isPlaceholderOnly(value)
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
    /// value, trimmed and percent-encoded as one segment. In `shown`, a path variable whose value is or uses a
    /// secret is the mask, whatever the length of the value.
    public static func render(_ address: String, rows: [KeyValue], in context: VariableContext) -> RenderResult {
        var text = ""
        var shown = ""
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
            shown += literal.shown
            cursor = occurrence.range.upperBound

            let value = TemplateEngine.render(valueTemplate(for: occurrence.name, in: rows), in: context)
            take(value)
            let isSecret = holdsSecret(rows.first { $0.key == occurrence.name }) || value.usedSecret
            if isSecret { usedSecret = true }
            let encoded = PercentCoding.encodePathSegment(value.text.trimmingCharacters(in: .whitespacesAndNewlines))
            text += encoded
            shown += isSecret && !encoded.isEmpty ? Redactor.mask : encoded
        }
        let tail = TemplateEngine.render(String(address[cursor...]), in: context)
        take(tail)
        text += tail.text
        shown += tail.shown
        return RenderResult(text: text, shown: shown, unresolved: unresolved, usedSecret: usedSecret)
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
