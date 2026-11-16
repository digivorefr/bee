import AppKit
import BeeCore
import SwiftUI

// Small parts private to the request feature, drawn with Theme values only.

// MARK: - Metrics

enum RequestMetrics {
    /// Height of a table row.
    static let rowHeight = Theme.Space.xl + Theme.Space.xs
    /// Width of the Name column of a table and of a form label column.
    static let nameWidth = Theme.Space.xxl * 5
    /// How much a disabled row fades.
    static let disabledOpacity = 0.45
}

// MARK: - Pop-up

struct RequestPopUpOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// A pop-up button under the outline rule: the current choice, then the menu of all choices.
/// Stretched, it fills the frame it is given instead of hugging its title.
struct RequestPopUp<Value: Hashable>: View {
    private let label: String
    @Binding private var selection: Value
    private let options: [RequestPopUpOption<Value>]
    private let font: Font
    private let isOutlined: Bool
    private let isStretched: Bool

    init(
        _ label: String, selection: Binding<Value>, options: [RequestPopUpOption<Value>],
        font: Font = Theme.text(), isOutlined: Bool = true, isStretched: Bool = false
    ) {
        self.label = label
        _selection = selection
        self.options = options
        self.font = font
        self.isOutlined = isOutlined
        self.isStretched = isStretched
    }

    private var title: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Group {
            if isOutlined { menu.outlined() } else { menu }
        }
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }

    private var menu: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(title)
                    .font(font)
                    .foregroundStyle(Theme.ink)
                if isStretched { Spacer(minLength: 0) }
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.text(Theme.Size.caption, weight: .medium))
                    .imageScale(.small)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.horizontal, isOutlined ? Theme.Space.s : 0)
            .padding(.vertical, isOutlined ? Theme.Space.xs : 0)
            .frame(maxWidth: isStretched ? .infinity : nil, maxHeight: isStretched ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !isStretched, vertical: !isStretched)
    }
}

// MARK: - Buttons

/// A part waiting in the Add row: a neutral capsule.
struct RequestChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.text())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs)
            .background(configuration.isPressed ? Theme.rowHover : Theme.tokenGround, in: Capsule())
            .contentShape(Capsule())
    }
}

/// An icon-only quiet control with its accessibility label and tooltip.
struct RequestGlyphButton: View {
    private let systemName: String
    private let label: String
    private let action: () -> Void

    init(_ systemName: String, label: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.text(Theme.Size.caption))
                .frame(width: Theme.Layout.gutter, height: Theme.Layout.gutter)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A quiet menu whose label is plain words.
struct RequestQuietMenu<Items: View>: View {
    private let title: String
    private let items: Items

    init(_ title: String, @ViewBuilder items: () -> Items) {
        self.title = title
        self.items = items()
    }

    var body: some View {
        Menu {
            items
        } label: {
            Text(title)
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Text helpers

extension View {
    /// A label or caption in what Bee says, caption ink.
    func requestCaption() -> some View {
        font(Theme.text(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary)
    }
}

enum RequestText {
    /// True when the text holds at least one placeholder and nothing else but whitespace.
    static func isPlaceholderOnly(_ text: String) -> Bool {
        let tokens = TemplateEngine.tokens(in: text)
        guard tokens.contains(where: { $0.kind != .text }) else { return false }
        return tokens.allSatisfy { token in
            token.kind != .text || text[token.range].allSatisfy(\.isWhitespace)
        }
    }

    /// What may be drawn in place of a credential: its placeholders, or the mask.
    static func sealed(_ value: String) -> String {
        isPlaceholderOnly(value) ? value.trimmingCharacters(in: .whitespaces) : URLTemplate.mask
    }

    /// Several lines folded into one for a resting summary.
    static func folded(_ text: String, limit: Int = 160) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(line.prefix(limit))
    }

    static func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

// MARK: - File chooser

enum RequestFileChooser {
    /// Asks for one file; `nil` when the person cancels.
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Flow layout

/// Lays its subviews in lines, wrapping at the available width; each line is centered vertically.
struct RequestFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var line: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0

        func closeLine() {
            let height = line.map(\.height).max() ?? 0
            frames += line.map { $0.offsetBy(dx: 0, dy: y + (height - $0.height) / 2) }
            widest = max(widest, line.last?.maxX ?? 0)
            y += height + spacing
            line = []
            x = 0
        }

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { closeLine() }
            line.append(CGRect(origin: CGPoint(x: x, y: 0), size: size))
            x += size.width + spacing
        }
        if !line.isEmpty { closeLine() }
        return (CGSize(width: widest, height: max(y - spacing, 0)), frames)
    }
}
