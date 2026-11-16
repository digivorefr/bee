import BeeCore
import SwiftUI

// MARK: - Format

/// The choices of the Body format pop-up; the five raw languages share the raw mode.
enum BodyFormat: Hashable, CaseIterable {
    case json, text, xml, html, javascript, urlEncoded, multipart, file, graphQL

    var title: String {
        switch self {
        case .json: "JSON"
        case .text: "Text"
        case .xml: "XML"
        case .html: "HTML"
        case .javascript: "JavaScript"
        case .urlEncoded: "Form URL-encoded"
        case .multipart: "Multipart form"
        case .file: "File"
        case .graphQL: "GraphQL"
        }
    }

    init(_ body: RequestBody) {
        switch body.mode {
        case .none, .raw:
            switch body.rawLanguage {
            case .json: self = .json
            case .text: self = .text
            case .xml: self = .xml
            case .html: self = .html
            case .javascript: self = .javascript
            }
        case .urlEncoded: self = .urlEncoded
        case .formData: self = .multipart
        case .binary: self = .file
        case .graphQL: self = .graphQL
        }
    }

    /// Switches the body to this format. The content of the other formats is kept.
    func apply(to body: inout RequestBody) {
        switch self {
        case .json: body.mode = .raw; body.rawLanguage = .json
        case .text: body.mode = .raw; body.rawLanguage = .text
        case .xml: body.mode = .raw; body.rawLanguage = .xml
        case .html: body.mode = .raw; body.rawLanguage = .html
        case .javascript: body.mode = .raw; body.rawLanguage = .javascript
        case .urlEncoded: body.mode = .urlEncoded
        case .multipart: body.mode = .formData
        case .file: body.mode = .binary
        case .graphQL: body.mode = .graphQL
        }
    }

    static var options: [RequestPopUpOption<BodyFormat>] {
        allCases.map { RequestPopUpOption(value: $0, title: $0.title) }
    }
}

// MARK: - Editor

/// The body in its current format.
struct BodyEditor: View {
    @Environment(AppModel.self) private var model
    @Binding private var content: RequestBody
    private let context: VariableContext

    init(body: Binding<RequestBody>, context: VariableContext) {
        _content = body
        self.context = context
    }

    var body: some View {
        switch content.mode {
        case .none:
            EmptyView()
        case .raw:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                CodeEditor(text: $content.raw, language: CodeLanguage(content.rawLanguage), context: context)
                if content.rawLanguage == .json {
                    Button("Format") { format() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(!canFormat)
                        .opacity(canFormat ? 1 : RequestMetrics.disabledOpacity)
                        .help("Indent the JSON with two spaces; {{variables}} stay as they are")
                }
            }
        case .urlEncoded:
            KeyValueTable(rows: $content.urlEncoded, noun: "field", context: context)
        case .formData:
            FormFieldTable(rows: $content.formData, context: context)
        case .binary:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    TemplateField("Path of the file to send", text: $content.binaryPath, context: context)
                    Button("Choose…") {
                        if let path = RequestFileChooser.choose() { content.binaryPath = path }
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                Text("The file is sent as it is.").requestCaption()
            }
        case .graphQL:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Query").requestCaption()
                CodeEditor(text: $content.graphQLQuery, language: .graphql, context: context)
                Text("Variables")
                    .requestCaption()
                    .padding(.top, Theme.Space.s)
                CodeEditor(
                    text: $content.graphQLVariables, language: .json, context: context,
                    minHeight: Theme.Space.xxl * 2
                )
            }
        }
    }

    /// True when formatting would change the text (it is JSON and not yet tidy).
    private var canFormat: Bool {
        guard content.raw.utf8.count <= JSONTextFormatter.liveCheckLimit else { return true }
        guard let formatted = JSONTextFormatter.format(content.raw) else { return false }
        return formatted != content.raw
    }

    private func format() {
        if let formatted = JSONTextFormatter.format(content.raw) {
            content.raw = formatted
        } else {
            model.inform("The body is not valid JSON, so it was left as it is.")
        }
    }

    /// The resting summary: the body folded into one line, or how many fields it has.
    static func summary(of body: RequestBody) -> (wire: String?, words: String?) {
        switch body.mode {
        case .none:
            return (nil, "None")
        case .raw:
            let line = RequestText.folded(body.raw)
            return line.isEmpty ? (nil, "Empty") : (line, nil)
        case .urlEncoded:
            return (nil, RequestText.counted(body.urlEncoded.count, "field", "fields"))
        case .formData:
            return (nil, RequestText.counted(body.formData.count, "field", "fields"))
        case .binary:
            let name = (body.binaryPath as NSString).lastPathComponent
            return name.isEmpty ? (nil, "No file") : (name, nil)
        case .graphQL:
            let line = RequestText.folded(body.graphQLQuery)
            return line.isEmpty ? (nil, "Empty") : (line, nil)
        }
    }
}

// MARK: - JSON formatting

/// Pretty-prints JSON textually (2 spaces). Strings are copied verbatim and a `{{placeholder}}`
/// standing where a value goes is one opaque value, so templates survive untouched.
enum JSONTextFormatter {
    /// Above this size the text is formatted only when asked, never just to enable the action.
    static let liveCheckLimit = 200_000

    private enum Token: Equatable {
        case open(Character)
        case close(Character)
        case colon
        case comma
        /// A string with its quotes, exactly as written.
        case string(String)
        /// A number, `true`, `false`, `null` or a `{{placeholder}}`.
        case atom(String)
    }

    /// The formatted text, or `nil` when the text is not JSON.
    static func format(_ text: String) -> String? {
        guard let tokens = tokenize(text), !tokens.isEmpty else { return nil }
        var writer = Writer(tokens: tokens)
        guard writer.value(depth: 0), writer.index == tokens.count else { return nil }
        return writer.output
    }

    private static func tokenize(_ text: String) -> [Token]? {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            switch character {
            case "{" where index + 1 < characters.count && characters[index + 1] == "{":
                // `{{` never opens two objects in JSON (a key is a string): it is a placeholder.
                var end = index + 2
                while end + 1 < characters.count, !(characters[end] == "}" && characters[end + 1] == "}") {
                    end += 1
                }
                guard end + 1 < characters.count else { return nil }
                tokens.append(.atom(String(characters[index...(end + 1)])))
                index = end + 2
            case "{", "[":
                tokens.append(.open(character))
                index += 1
            case "}", "]":
                tokens.append(.close(character))
                index += 1
            case ":":
                tokens.append(.colon)
                index += 1
            case ",":
                tokens.append(.comma)
                index += 1
            case "\"":
                var end = index + 1
                var isClosed = false
                while end < characters.count {
                    if characters[end] == "\\" {
                        end += 2
                        continue
                    }
                    if characters[end] == "\"" {
                        isClosed = true
                        break
                    }
                    if characters[end].isNewline { return nil }
                    end += 1
                }
                guard isClosed else { return nil }
                tokens.append(.string(String(characters[index...end])))
                index = end + 1
            default:
                var end = index
                while end < characters.count, !characters[end].isWhitespace, !"{}[]:,\"".contains(characters[end]) {
                    end += 1
                }
                let literal = String(characters[index..<end])
                guard isLiteral(literal) else { return nil }
                tokens.append(.atom(literal))
                index = end
            }
        }
        return tokens
    }

    private static func isLiteral(_ text: String) -> Bool {
        if ["true", "false", "null"].contains(text) { return true }
        return text.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/) != nil
    }

    private struct Writer {
        let tokens: [Token]
        var index = 0
        var output = ""

        private static let maxDepth = 256

        mutating func value(depth: Int) -> Bool {
            guard index < tokens.count, depth < Self.maxDepth else { return false }
            switch tokens[index] {
            case .string(let text), .atom(let text):
                output += text
                index += 1
                return true
            case .open(let bracket):
                index += 1
                return container(depth: depth, isObject: bracket == "{")
            case .close, .colon, .comma:
                return false
            }
        }

        private mutating func container(depth: Int, isObject: Bool) -> Bool {
            let closing: Character = isObject ? "}" : "]"
            if index < tokens.count, tokens[index] == .close(closing) {
                index += 1
                output += isObject ? "{}" : "[]"
                return true
            }
            let indent = String(repeating: "  ", count: depth + 1)
            output += isObject ? "{\n" : "[\n"
            while true {
                output += indent
                if isObject {
                    guard index + 1 < tokens.count, case .string(let key) = tokens[index],
                          tokens[index + 1] == .colon else { return false }
                    output += key + ": "
                    index += 2
                }
                guard value(depth: depth + 1), index < tokens.count else { return false }
                if tokens[index] == .comma {
                    output += ",\n"
                    index += 1
                } else if tokens[index] == .close(closing) {
                    index += 1
                    output += "\n" + String(repeating: "  ", count: depth) + String(closing)
                    return true
                } else {
                    return false
                }
            }
        }
    }
}
