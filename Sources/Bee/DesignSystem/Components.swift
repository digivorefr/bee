import AppKit
import BeeCore
import SwiftUI

// Shared components of the design system. Their signatures are the contract every feature codes
// against. The text components live beside this file: TemplateField and TokenText (TemplateField.swift),
// CodeEditor and CodeViewer (CodeViews.swift), SecretValueField (SecretValueField.swift).

// MARK: - Code languages

enum CodeLanguage: Hashable, Sendable {
    case json, javascript, xml, html, graphql, plain

    init(_ raw: RawLanguage) {
        switch raw {
        case .json: self = .json
        case .text: self = .plain
        case .xml: self = .xml
        case .html: self = .html
        case .javascript: self = .javascript
        }
    }

    /// The language of a response body from its media type.
    init(mimeType: String?) {
        guard let mimeType else { self = .plain; return }
        if mimeType == "application/json" || mimeType.hasSuffix("+json") {
            self = .json
        } else if mimeType.contains("html") {
            self = .html
        } else if mimeType.contains("xml") {
            self = .xml
        } else if mimeType.contains("javascript") {
            self = .javascript
        } else {
            self = .plain
        }
    }
}

// MARK: - Outline

extension View {
    /// The 1 px outline that marks what can be written or pressed.
    func outlined(isFocused: Bool = false, radius: CGFloat = Theme.Radius.field) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isFocused ? Theme.focus : Theme.outline, lineWidth: isFocused ? 2 : 1)
        )
    }
}

// MARK: - Document section

/// A part of a document: a heading with its disclosure chevron hanging in the gutter, a quiet count,
/// a one-line summary shown while closed, a trailing accessory, and the content when open.
struct DocumentSection<Summary: View, Accessory: View, Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title: String
    private let count: Int?
    @Binding private var isExpanded: Bool
    private let summary: Summary
    private let accessory: Accessory
    private let content: Content

    init(
        _ title: String, count: Int? = nil, isExpanded: Binding<Bool>,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        _isExpanded = isExpanded
        self.summary = summary()
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button(action: toggle) {
                    HStack(spacing: Theme.Space.s) {
                        HStack(spacing: 0) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: Theme.Glyph.chevron, weight: .semibold))
                                .foregroundStyle(Theme.inkSecondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .frame(width: Theme.Layout.gutter, alignment: .leading)
                                .accessibilityHidden(true)
                            Text(title)
                                .font(Theme.text(weight: .semibold))
                                .foregroundStyle(Theme.ink)
                        }
                        if let count {
                            Text("\(count)")
                                .font(Theme.text())
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        if !isExpanded {
                            summary
                                .font(Theme.text())
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                                .clipped()
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Theme.Space.xl)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityAddTraits(.isHeader)
                accessory
            }
            if isExpanded {
                content
                    .padding(.leading, Theme.Layout.gutter)
                    .transition(.opacity)
            }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : Theme.Motion.fold) { isExpanded.toggle() }
    }
}

extension DocumentSection where Accessory == EmptyView {
    init(
        _ title: String, count: Int? = nil, isExpanded: Binding<Bool>,
        @ViewBuilder summary: () -> Summary, @ViewBuilder content: () -> Content
    ) {
        self.init(title, count: count, isExpanded: isExpanded, summary: summary, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Buttons

/// The one primary action: a honey capsule. Used for Send only.
struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SendButtonBody(configuration: configuration)
    }

    private struct SendButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(Theme.text(weight: .semibold))
                .foregroundStyle(Theme.onHoney)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Theme.Space.l)
                .frame(minHeight: Theme.Layout.controlHeight)
                .background(configuration.isPressed ? Theme.honeyPressed : Theme.honey, in: Capsule())
                .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
                .contentShape(Capsule())
        }
    }
}

/// A secondary action: outlined, no fill.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OutlineButtonBody(configuration: configuration)
    }

    private struct OutlineButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var isHovered = false
        let configuration: Configuration

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            configuration.label
                .font(Theme.text())
                .foregroundStyle(isEnabled ? Theme.ink : Theme.inkTertiary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Theme.Space.m)
                .frame(minHeight: Theme.Layout.controlHeight)
                .background(ground, in: shape)
                .outlined()
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }

        private var ground: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Theme.tokenGround }
            return isHovered ? Theme.rowHover : .clear
        }
    }
}

/// A quiet action: text or glyph only, secondary ink until hovered.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration)
    }

    private struct QuietButtonBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @ViewState private var isHovered = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(Theme.text())
                .foregroundStyle(ink)
                .lineLimit(1)
                .fixedSize()
                .background {
                    // The hover ground reaches past the label without moving it.
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(isEnabled && (isHovered || configuration.isPressed) ? Theme.rowHover : .clear)
                        .padding(.horizontal, -Theme.Space.xs - 2)
                        .padding(.vertical, -Theme.Space.xs)
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var ink: Color {
            guard isEnabled else { return Theme.inkTertiary }
            return isHovered || configuration.isPressed ? Theme.ink : Theme.inkSecondary
        }
    }
}

// MARK: - Small marks

/// The HTTP method as quiet monochrome capitals.
struct MethodLabel: View {
    let method: HTTPMethod
    var size: CGFloat = Theme.Size.caption

    var body: some View {
        Text(method.rawValue)
            .font(Theme.mono(size, weight: .medium))
            .kerning(0.4)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// How the API answered: a glyph, the code and the reason, in the status color.
struct StatusMark: View {
    let code: Int
    let text: String
    var size: CGFloat = Theme.Size.headline

    var body: some View {
        HStack(spacing: Theme.Space.xs + 2) {
            CellMark(glyph, color: Theme.statusColor(code), size: size)
            Text("\(code) \(reason)")
                .font(Theme.mono(size, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.statusColor(code))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status \(code) \(reason)")
    }

    /// The family is told by the glyph as well as the color.
    private var glyph: String {
        switch code {
        case 418: "cup.and.saucer.fill"
        case 100..<300: "checkmark"
        case 300..<400: "arrow.right"
        default: "xmark"
        }
    }

    /// The reason the server gave, or the standard one when it gave none (HTTP/2 never does).
    private var reason: String {
        let given = text.trimmingCharacters(in: .whitespaces)
        if !given.isEmpty { return given }
        return Self.standardReasons[code] ?? Self.familyReason(code)
    }

    private static func familyReason(_ code: Int) -> String {
        switch code {
        case 100..<200: "Informational"
        case 200..<300: "Success"
        case 300..<400: "Redirection"
        case 400..<500: "Client error"
        default: "Server error"
        }
    }

    private static let standardReasons: [Int: String] = [
        100: "Continue", 101: "Switching Protocols",
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict",
        410: "Gone", 412: "Precondition Failed", 413: "Content Too Large", 415: "Unsupported Media Type",
        418: "I'm a teapot", 422: "Unprocessable Content", 425: "Too Early", 429: "Too Many Requests",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout",
    ]
}
