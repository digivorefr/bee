import Foundation

/// One piece of a template: literal text, a `{{variable}}` or a `{{$dynamic}}` placeholder.
public struct TemplateToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text
        /// A named variable; the name is trimmed of the whitespace allowed inside the braces.
        case variable(name: String)
        /// A dynamic variable; the name keeps its leading `$` (for example `$uuid`).
        case dynamic(name: String)
    }

    public var kind: Kind
    /// Range in the template, braces included for placeholders.
    public var range: Range<String.Index>
    /// The same range in UTF-16 units, for AppKit text views.
    public var nsRange: NSRange

    public init(kind: Kind, range: Range<String.Index>, nsRange: NSRange) {
        self.kind = kind
        self.range = range
        self.nsRange = nsRange
    }
}

public struct RenderResult: Hashable, Sendable {
    public var text: String
    /// `text` as it may be drawn or kept: each expansion of a secret variable is replaced by `Redactor.mask`,
    /// whatever its length. Equal to `text` when no secret was used.
    public var shown: String
    /// Distinct names that could not be resolved, in order of first appearance.
    public var unresolved: [String]
    /// True when a secret variable was found and expanded, so `text` may hold a secret value.
    public var usedSecret: Bool

    public init(text: String, shown: String? = nil, unresolved: [String] = [], usedSecret: Bool = false) {
        self.text = text
        self.shown = shown ?? text
        self.unresolved = unresolved
        self.usedSecret = usedSecret
    }
}

/// Expands `{{name}}` placeholders against a `VariableContext`.
public enum TemplateEngine {
    /// How many variable values may be nested inside one another.
    static let maxDepth = 10
    /// Upper bound on substitutions per render; stops exponential fan-out between variables.
    static let maxExpansions = 10_000

    /// Splits a template into text and placeholder tokens that together cover it entirely.
    /// A placeholder is `{{`, a non-empty name without braces (surrounding whitespace ignored), `}}`.
    public static func tokens(in template: String) -> [TemplateToken] {
        let scalars = template.unicodeScalars
        var tokens: [TemplateToken] = []
        var textStart = scalars.startIndex
        var index = scalars.startIndex

        func append(_ kind: TemplateToken.Kind, _ range: Range<String.Index>) {
            tokens.append(TemplateToken(kind: kind, range: range, nsRange: NSRange(range, in: template)))
        }

        /// The trimmed name and the end of the placeholder that opens at `start`, if there is one.
        func placeholder(at start: String.Index) -> (name: String, end: String.Index)? {
            var cursor = start
            for _ in 0..<2 {
                guard cursor < scalars.endIndex, scalars[cursor] == "{" else { return nil }
                cursor = scalars.index(after: cursor)
            }
            let nameStart = cursor
            while cursor < scalars.endIndex, scalars[cursor] != "{", scalars[cursor] != "}" {
                cursor = scalars.index(after: cursor)
            }
            let nameEnd = cursor
            for _ in 0..<2 {
                guard cursor < scalars.endIndex, scalars[cursor] == "}" else { return nil }
                cursor = scalars.index(after: cursor)
            }
            let name = template[nameStart..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (name, cursor)
        }

        while index < scalars.endIndex {
            guard let found = placeholder(at: index) else {
                index = scalars.index(after: index)
                continue
            }
            if textStart < index { append(.text, textStart..<index) }
            append(found.name.hasPrefix("$") ? .dynamic(name: found.name) : .variable(name: found.name), index..<found.end)
            textStart = found.end
            index = found.end
        }
        if textStart < scalars.endIndex { append(.text, textStart..<scalars.endIndex) }
        return tokens
    }

    /// Replaces every placeholder by its value. Values may contain placeholders themselves (resolved
    /// recursively, at most ``maxDepth`` levels deep); a cycle, an unknown name or a name beyond the
    /// depth limit stays verbatim in the output and is reported in `unresolved`.
    public static func render(_ template: String, in context: VariableContext) -> RenderResult {
        var state = RenderState()
        let expanded = expand(template, context: context, depth: 0, active: [], state: &state)
        return RenderResult(
            text: expanded.text, shown: expanded.shown, unresolved: state.unresolved, usedSecret: state.usedSecret
        )
    }

    // MARK: Implementation

    private struct RenderState {
        var unresolved: [String] = []
        var usedSecret = false
        var expansions = 0

        mutating func report(_ name: String) {
            if !unresolved.contains(name) { unresolved.append(name) }
        }
    }

    /// The expansion and its masked twin, built in one pass so dynamic values are the same in both.
    private static func expand(
        _ template: String, context: VariableContext, depth: Int, active: [String], state: inout RenderState
    ) -> (text: String, shown: String) {
        guard template.contains("{{") else { return (template, template) }
        var output = ""
        var shown = ""
        for token in tokens(in: template) {
            let verbatim = template[token.range]
            switch token.kind {
            case .text:
                output += verbatim
                shown += verbatim
            case .dynamic(let name):
                let value = dynamicValue(name)
                if value == nil { state.report(name) }
                output += value ?? String(verbatim)
                shown += value ?? String(verbatim)
            case .variable(let name):
                guard let lookup = context.lookup(name), !active.contains(name),
                      depth < maxDepth, state.expansions < maxExpansions
                else {
                    state.report(name)
                    output += verbatim
                    shown += verbatim
                    continue
                }
                state.expansions += 1
                if lookup.isSecret { state.usedSecret = true }
                let inner = expand(lookup.value, context: context, depth: depth + 1, active: active + [name], state: &state)
                output += inner.text
                if lookup.isSecret {
                    shown += inner.text.isEmpty ? "" : Redactor.mask
                } else {
                    shown += inner.shown
                }
            }
        }
        return (output, shown)
    }

    /// The value of a dynamic variable, evaluated afresh at each call; `nil` for an unknown name.
    private static func dynamicValue(_ name: String) -> String? {
        switch name {
        case "$uuid", "$guid", "$randomUUID":
            UUID().uuidString.lowercased()
        case "$timestamp":
            String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp":
            Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        case "$randomInt":
            String(Int.random(in: 0...1000))
        default:
            nil
        }
    }
}
