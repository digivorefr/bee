import AppKit
import BeeCore
import SwiftUI
import UniformTypeIdentifiers

/// What a response body is, for showing it.
enum ResponseBodyContent {
    case text(String, CodeLanguage)
    case image(NSImage)
    case binary

    init(_ response: HTTPResponse) {
        let mimeType = response.mimeType
        if let mimeType, mimeType.hasPrefix("image/"), let image = NSImage(data: response.body), image.isValid {
            self = .image(image)
            return
        }
        guard !response.body.prefix(1024).contains(0), let text = String(data: response.body, encoding: .utf8) else {
            self = .binary
            return
        }
        var language = CodeLanguage(mimeType: mimeType)
        if language == .plain, JSONIndenter.looksLikeJSON(text) { language = .json }
        self = .text(text, language)
    }

    /// The kind of content in one word.
    var kind: String {
        switch self {
        case .text(_, .json): "JSON"
        case .text(_, .html): "HTML"
        case .text(_, .xml): "XML"
        case .text(_, .javascript): "JavaScript"
        case .text(_, .graphql): "GraphQL"
        case .text(_, .plain): "Text"
        case .image: "Image"
        case .binary: "Binary"
        }
    }
}

enum ResponseBodyMode: String, CaseIterable, Identifiable {
    case pretty, raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pretty: "Pretty"
        case .raw: "Raw"
        }
    }
}

/// Keeps the decoded and the re-indented body of the response on the page, so a large body is
/// processed once, not at every update of the view.
private final class ResponseBodyCache {
    private var source: Data?
    private var content: ResponseBodyContent?
    private var prettyText: String?

    func content(for response: HTTPResponse) -> ResponseBodyContent {
        if source == response.body, let content { return content }
        let fresh = ResponseBodyContent(response)
        source = response.body
        content = fresh
        prettyText = nil
        return fresh
    }

    func pretty(_ text: String) -> String {
        if let prettyText { return prettyText }
        let fresh = JSONIndenter.pretty(text)
        prettyText = fresh
        return fresh
    }
}

/// The body of the response. Open, it takes the height the page has left and scrolls inside.
struct ResponseBodySection: View {
    @Environment(AppModel.self) private var model
    let response: HTTPResponse
    @Binding var isExpanded: Bool
    @ViewState private var mode = ResponseBodyMode.pretty
    @ViewState private var wraps = true
    @ViewState private var cache = ResponseBodyCache()

    private static let minHeight: CGFloat = 240

    var body: some View {
        let content = cache.content(for: response)
        DocumentSection("Body", isExpanded: $isExpanded) {
            Text("\(content.kind), \(ResponseFormat.size(response.size))")
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
        } accessory: {
            if isExpanded { controls(for: content) }
        } content: {
            switch content {
            case .text(let text, let language):
                let shown = displayed(text, language)
                if let height = Self.huggingHeight(for: shown, wraps: wraps) {
                    // A short body is read whole: the next section follows it directly.
                    CodeViewer(text: shown, language: language, wraps: wraps)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                } else {
                    // The clear ground decides the height (what the page has left, at least the
                    // minimum); the viewer fills it whatever its own ideal size is.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: Self.minHeight, maxHeight: .infinity)
                        .overlay(alignment: .topLeading) {
                            CodeViewer(text: shown, language: language, wraps: wraps)
                        }
                }
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height, alignment: .topLeading)
                    .accessibilityLabel("Image response")
            case .binary:
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Text("Binary response, \(ResponseFormat.size(response.size))")
                        .font(Theme.text())
                        .foregroundStyle(Theme.inkSecondary)
                    Button("Save…", action: save)
                        .buttonStyle(OutlineButtonStyle())
                }
            }
        }
    }

    /// The height a short text needs, or `nil` when it is long enough to take what the page has left.
    /// Wrapped lines are counted against a narrow page so the estimate errs on the tall side.
    private static func huggingHeight(for text: String, wraps: Bool) -> CGFloat? {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: Theme.nsMono())
        let limit = Int(minHeight / lineHeight) - 1
        let narrowPageColumns = 44
        var rows = 1
        var column = 0
        // A short text is small: anything beyond this many bytes takes the remaining height.
        guard text.utf8.count <= 4096 else { return nil }
        for byte in text.utf8 {
            if byte == 0x0A {
                rows += 1
                column = 0
            } else {
                column += 1
                if wraps, column > narrowPageColumns {
                    rows += 1
                    column = 0
                }
            }
            if rows > limit { return nil }
        }
        return CGFloat(rows + 1) * lineHeight
    }

    private func displayed(_ text: String, _ language: CodeLanguage) -> String {
        language == .json && mode == .pretty ? cache.pretty(text) : text
    }

    @ViewBuilder
    private func controls(for content: ResponseBodyContent) -> some View {
        HStack(spacing: Theme.Space.m) {
            if case .text(let text, let language) = content {
                if language == .json {
                    Menu {
                        Picker("Body view", selection: $mode) {
                            ForEach(ResponseBodyMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text(mode.title)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityLabel("Body view")
                    .accessibilityValue(mode.title)
                }
                Button {
                    wraps.toggle()
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "checkmark")
                            .font(Theme.text(Theme.Size.caption, weight: .semibold))
                            .opacity(wraps ? 1 : 0)
                        Text("Wrap")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .help(wraps ? "Stop wrapping long lines" : "Wrap long lines")
                .accessibilityLabel("Wrap long lines")
                .accessibilityValue(wraps ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
                Button("Copy") {
                    model.copy(displayed(text, language))
                    model.inform("Copied the body.")
                }
                .buttonStyle(QuietButtonStyle())
            }
            if case .binary = content {
                EmptyView()
            } else {
                Button("Save…", action: save)
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    // MARK: Saving

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url, options: .atomic)
        } catch {
            model.notice = Notice(
                kind: .error,
                message: "Bee could not save the body: \(error.localizedDescription) Choose another location and try again."
            )
        }
    }

    /// The last part of the address when it names a file, else `response` with the extension of its type.
    private var suggestedFileName: String {
        if let name = response.finalURL?.lastPathComponent, name.contains("."), !name.hasPrefix(".") {
            return name
        }
        let fileExtension = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
        return fileExtension.map { "response.\($0)" } ?? "response"
    }
}
