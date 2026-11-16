import AppKit
import BeeCore
import SwiftUI

// MARK: - TemplateField

/// A single-line editable text in the wire voice where `{{variables}}` show as tokens.
struct TemplateField: View {
    private let placeholder: String
    @Binding private var text: String
    private let context: VariableContext
    private let size: CGFloat
    private let isBordered: Bool
    private let pathVariables: [KeyValue]?
    private let onSubmit: (() -> Void)?
    @ViewState private var isFocused = false

    /// - Parameter pathVariables: for an address field, the request's path variable rows: the `:name`
    ///   segments of the text then show as tokens too.
    init(
        _ placeholder: String, text: Binding<String>, context: VariableContext,
        size: CGFloat = Theme.Size.body, isBordered: Bool = true, pathVariables: [KeyValue]? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.context = context
        self.size = size
        self.isBordered = isBordered
        self.pathVariables = pathVariables
        self.onSubmit = onSubmit
    }

    var body: some View {
        let field = WireField(
            placeholder: placeholder, text: $text, variables: context, size: size, pathVariables: pathVariables,
            inset: isBordered ? NSSize(width: Theme.Space.s, height: Theme.Layout.fieldInset) : .zero,
            onSubmit: onSubmit, onFocusChange: { isFocused = $0 }
        )
        if isBordered {
            field
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .outlined(isFocused: isFocused)
        } else {
            field
        }
    }
}

// MARK: - The AppKit field

/// The single-line editor behind `TemplateField` and the open states of `SecretValueField`.
struct WireField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let variables: VariableContext?
    let size: CGFloat
    /// Set for an address: its `:name` segments are tokens whose values these rows hold.
    var pathVariables: [KeyValue]?
    var inset: NSSize = .zero
    var focusOnAppear = false
    var onSubmit: (() -> Void)?
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SingleLineScrollView {
        let textView = WireTextView.make(size: size)
        textView.behavesAsField = true
        textView.wantsInitialFocus = focusOnAppear
        textView.textContainerInset = inset
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        let scrollView = SingleLineScrollView(textView: textView, fieldHeight: WireMetrics.lineHeight(size) + 2 * inset.height)
        context.coordinator.textView = textView
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        if variables != nil {
            textView.completionNames = { [weak coordinator = context.coordinator] in
                TokenStyler.completionNames(in: coordinator?.parent.variables)
            }
        }
        return scrollView
    }

    func updateNSView(_ nsView: SingleLineScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let textView = nsView.textView
        if textView.string != text {
            textView.string = text
            // Recorded steps point into the old text: replaying them would corrupt the new one.
            coordinator.undo.removeAllActions()
            coordinator.styledSignature = nil
            // A field that is not being edited shows its beginning.
            if textView.window?.firstResponder !== textView { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        if textView.placeholder?.string != placeholder {
            textView.placeholder = NSAttributedString(
                string: placeholder,
                attributes: [.font: Theme.nsMono(size), .foregroundColor: Theme.Palette.inkTertiary]
            )
            textView.setAccessibilityPlaceholderValue(placeholder)
        }
        coordinator.restyleIfNeeded()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SingleLineScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: nsView.fieldHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WireField
        weak var textView: WireTextView?
        var styledSignature: Int?
        /// Each field undoes its own typing only (the window's shared manager would mix fields).
        let undo = UndoManager()

        init(_ parent: WireField) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            styledSignature = nil
            restyleIfNeeded()
        }

        /// A field holds one line: line breaks of pasted text are dropped.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString, replacement.contains(where: \.isNewline) else { return true }
            // A shell continuation (backslash, line break, indent) and a bare line break both become
            // one space, so a multi-line cURL command stays parseable.
            let flattened = replacement.replacingOccurrences(
                of: #"\\?\r?\n[ \t]*"#, with: " ", options: .regularExpression
            )
            textView.insertText(flattened, replacementRange: range)
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onSubmit?()
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(textView)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(textView)
                return true
            default:
                return false
            }
        }

        func restyleIfNeeded() {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            var hasher = Hasher()
            hasher.combine(storage.string)
            hasher.combine(parent.variables?.styleSignature)
            hasher.combine(parent.size)
            hasher.combine(parent.pathVariables)
            let signature = hasher.finalize()
            guard signature != styledSignature else { return }
            styledSignature = signature
            let base = TokenStyler.base(size: parent.size)
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            TokenStyler.apply(
                to: storage, context: parent.variables, size: parent.size, toolTips: true,
                pathVariables: parent.pathVariables
            )
            storage.endEditing()
            textView.typingAttributes = base
        }
    }
}

/// Holds one line of text and scrolls it sideways when it is longer than the field.
final class SingleLineScrollView: NSScrollView {
    let textView: WireTextView
    let fieldHeight: CGFloat

    init(textView: WireTextView, fieldHeight: CGFloat) {
        self.textView = textView
        self.fieldHeight = fieldHeight
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func tile() {
        super.tile()
        let size = contentSize
        textView.minSize = size
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: size.height)
        textView.sizeToFit()
        if textView.frame.height != size.height || textView.frame.width < size.width {
            textView.setFrameSize(NSSize(width: max(textView.frame.width, size.width), height: size.height))
        }
    }

    /// The page behind keeps scrolling vertically while the pointer is over a field.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - TokenText

/// A read-only line in the wire voice where `{{variables}}` show as tokens (a lock on secrets).
struct TokenText: View {
    private let template: String
    private let context: VariableContext?
    private let size: CGFloat

    init(_ template: String, context: VariableContext? = nil, size: CGFloat = Theme.Size.body) {
        self.template = template
        self.context = context
        self.size = size
    }

    var body: some View {
        TokenLine(template: template, variables: context, size: size)
    }
}

private struct TokenLine: NSViewRepresentable {
    let template: String
    let variables: VariableContext?
    let size: CGFloat

    func makeNSView(context: Context) -> TokenLineView {
        TokenLineView()
    }

    func updateNSView(_ nsView: TokenLineView, context: Context) {
        nsView.show(template: template, variables: variables, size: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TokenLineView, context: Context) -> CGSize? {
        let natural = nsView.naturalSize
        return CGSize(width: min(natural.width, proposal.width ?? natural.width), height: natural.height)
    }
}

/// Draws one truncating line through the token layout manager. Never takes the pointer.
final class TokenLineView: NSView {
    private let storage = NSTextStorage()
    private let layoutManager = TokenLayoutManager.themed()
    private let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    private var signature: Int?
    private(set) var naturalSize = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 1
        container.lineBreakMode = .byTruncatingTail
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(template: String, variables: VariableContext?, size: CGFloat) {
        var hasher = Hasher()
        hasher.combine(template)
        hasher.combine(variables?.styleSignature)
        hasher.combine(size)
        let newSignature = hasher.finalize()
        guard newSignature != signature else { return }
        signature = newSignature
        let line = template.split(whereSeparator: \.isNewline).joined(separator: " ")
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: line, attributes: TokenStyler.base(size: size)))
        TokenStyler.apply(to: storage, context: variables, size: size, toolTips: false)
        storage.endEditing()
        // The template holds names only, never a value.
        setAccessibilityValue(line)
        container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        naturalSize = NSSize(width: ceil(used.maxX), height: max(ceil(used.height), WireMetrics.lineHeight(size)))
        fitContainer()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { naturalSize }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitContainer()
        needsDisplay = true
    }

    private func fitContainer() {
        guard bounds.width > 0 else { return }
        container.size = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }
}
