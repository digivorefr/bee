import AppKit
import BeeCore
import SwiftUI

// MARK: - CodeEditor

/// A multi-line editor in the wire voice with syntax colors and hanging line numbers.
/// Grows with its content between `minHeight` and `maxHeight`, then scrolls.
struct CodeEditor: View {
    @Binding private var text: String
    private let language: CodeLanguage
    private let context: VariableContext?
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let showsLineNumbers: Bool
    @ViewState private var contentHeight: CGFloat?
    @ViewState private var isFocused = false

    init(
        text: Binding<String>, language: CodeLanguage, context: VariableContext? = nil,
        minHeight: CGFloat = 96, maxHeight: CGFloat = 420, showsLineNumbers: Bool = true
    ) {
        _text = text
        self.language = language
        self.context = context
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.showsLineNumbers = showsLineNumbers
    }

    var body: some View {
        CodeTextArea(
            text: $text, language: language, variables: context, isEditable: true, wraps: true,
            showsLineNumbers: showsLineNumbers, growsUpTo: maxHeight, onFocusChange: { isFocused = $0 },
            onContentHeight: { if contentHeight != $0 { contentHeight = $0 } }
        )
        .frame(height: min(max(contentHeight ?? estimatedHeight, minHeight), maxHeight))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
        .outlined(isFocused: isFocused)
    }

    /// Used until the text view has measured itself.
    private var estimatedHeight: CGFloat {
        let lines = text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
        return CGFloat(lines) * WireMetrics.lineHeight(Theme.Size.body) + 2 * Theme.Space.s
    }
}

// MARK: - CodeViewer

/// Read-only, selectable code that stays fast on large content. Fills the space it is given
/// and scrolls inside it.
struct CodeViewer: View {
    private let text: String
    private let language: CodeLanguage
    private let wraps: Bool
    private let showsLineNumbers: Bool

    init(text: String, language: CodeLanguage, wraps: Bool = true, showsLineNumbers: Bool = true) {
        self.text = text
        self.language = language
        self.wraps = wraps
        self.showsLineNumbers = showsLineNumbers
    }

    var body: some View {
        CodeTextArea(
            text: .constant(text), language: language, variables: nil, isEditable: false, wraps: wraps,
            showsLineNumbers: showsLineNumbers
        )
    }
}

// MARK: - The AppKit text area

/// The text view, its scroll view and its line-number gutter, behind `CodeEditor` and `CodeViewer`.
struct CodeTextArea: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    let variables: VariableContext?
    let isEditable: Bool
    let wraps: Bool
    let showsLineNumbers: Bool
    /// Set for an area that takes the height of its text: the height above which it scrolls instead.
    /// `nil` for an area that fills the space it is given.
    var growsUpTo: CGFloat?
    var onFocusChange: (Bool) -> Void = { _ in }
    var onContentHeight: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CodeContainerView {
        let container = CodeContainerView(isEditable: isEditable, showsLineNumbers: showsLineNumbers)
        let coordinator = context.coordinator
        coordinator.container = container
        container.textView.delegate = coordinator
        container.textView.onFocusChange = { [weak coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        container.onGeometryChange = { [weak coordinator] in coordinator?.reportHeight() }
        if growsUpTo != nil {
            // An area that grows with its text shows its scroller only once it has stopped growing
            // (see `reportHeight`), never because its frame is a step behind its text.
            container.scrollView.autohidesScrollers = false
            container.scrollView.hasVerticalScroller = false
        }
        if isEditable, variables != nil {
            container.textView.completionNames = { [weak coordinator] in
                TokenStyler.completionNames(in: coordinator?.parent.variables)
            }
        }
        return container
    }

    func updateNSView(_ nsView: CodeContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Above this length, colors are computed off the main actor and typing is debounced.
        private static let immediateLimit = 40_000

        var parent: CodeTextArea
        weak var container: CodeContainerView?
        private var appliedText = ""
        private var styledSignature: Int?
        private var generation = 0
        private var restyleTask: Task<Void, Never>?
        private var reportedHeight: CGFloat?
        /// Each editor undoes its own typing only (the window's shared manager would mix fields).
        private let undo = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        init(_ parent: CodeTextArea) {
            self.parent = parent
        }

        // MARK: SwiftUI to AppKit

        func sync() {
            guard let container else { return }
            let textView = container.textView
            let incoming = parent.text
            var textChanged = false
            if incoming != appliedText {
                appliedText = incoming
                if textView.string != incoming {
                    textView.string = incoming
                    // Recorded steps point into the old text: replaying them would corrupt the new one.
                    undo.removeAllActions()
                    textChanged = true
                    generation += 1
                    container.gutter.rebuild()
                    if !parent.isEditable { textView.scroll(.zero) }
                }
            }
            container.showsLineNumbers = parent.showsLineNumbers
            container.setWraps(parent.wraps)
            var hasher = Hasher()
            hasher.combine(parent.language)
            hasher.combine(parent.variables?.styleSignature)
            let signature = hasher.finalize()
            if textChanged || signature != styledSignature {
                styledSignature = signature
                restyle(after: nil)
            }
            reportHeight()
        }

        // MARK: AppKit to SwiftUI

        func textDidChange(_ notification: Notification) {
            guard let container else { return }
            let textView = container.textView
            appliedText = textView.string
            parent.text = appliedText
            generation += 1
            container.gutter.rebuild()
            let isLarge = (textView.textStorage?.length ?? 0) > Self.immediateLimit
            restyle(after: isLarge ? .milliseconds(200) : nil)
            reportHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.isEditable else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                insertNewlineKeepingIndentation(in: textView)
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                outdent(in: textView)
                return true
            default:
                return false
            }
        }

        private func insertNewlineKeepingIndentation(in textView: NSTextView) {
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
            var end = lineStart
            while end < selection.location, string.character(at: end) == 0x20 || string.character(at: end) == 0x09 {
                end += 1
            }
            var indentation = string.substring(with: NSRange(location: lineStart, length: end - lineStart))
            if selection.location > lineStart {
                let previous = string.character(at: selection.location - 1)
                if previous == 0x7B || previous == 0x5B || previous == 0x28 { indentation += "  " }
            }
            textView.insertText("\n" + indentation, replacementRange: selection)
        }

        /// Shift-Tab takes up to two leading spaces off every selected line.
        private func outdent(in textView: NSTextView) {
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            let lines = string.lineRange(for: selection)
            var starts: [Int] = []
            var cursor = lines.location
            repeat {
                starts.append(cursor)
                cursor = NSMaxRange(string.lineRange(for: NSRange(location: cursor, length: 0)))
            } while cursor < NSMaxRange(lines)
            var removed = 0
            var removedOnFirstLine = 0
            for start in starts.reversed() {
                var width = 0
                while width < 2, start + width < string.length, string.character(at: start + width) == 0x20 { width += 1 }
                guard width > 0 else { continue }
                textView.insertText("", replacementRange: NSRange(location: start, length: width))
                removed += width
                if start == lines.location { removedOnFirstLine = width }
            }
            let location = max(lines.location, selection.location - removedOnFirstLine)
            let length = max(0, selection.length - (removed - removedOnFirstLine))
            textView.setSelectedRange(NSRange(location: location, length: selection.length == 0 ? 0 : length))
        }

        // MARK: Colors

        private var grammar: SyntaxScanner.Grammar? {
            switch parent.language {
            case .json: .json
            case .javascript: .javascript
            case .xml, .html: .markup
            case .graphql: .graphql
            case .plain: nil
            }
        }

        /// Colors the whole text: at once when it is small, off the main actor (and after `delay`) when not.
        private func restyle(after delay: Duration?) {
            restyleTask?.cancel()
            guard let storage = container?.textView.textStorage else { return }
            let length = storage.length
            guard let grammar, length <= Theme.Layout.highlightLimit else {
                apply([])
                return
            }
            if length <= Self.immediateLimit, delay == nil {
                apply(SyntaxScanner.spans(in: storage.string, grammar: grammar))
                return
            }
            let text = storage.string
            let expected = generation
            restyleTask = Task { [weak self] in
                if let delay { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                let spans = await Task.detached(priority: .userInitiated) {
                    SyntaxScanner.spans(in: text, grammar: grammar)
                }.value
                guard !Task.isCancelled, let self, self.generation == expected else { return }
                self.apply(spans)
            }
        }

        private func apply(_ spans: [SyntaxSpan]) {
            guard let textView = container?.textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let size = Theme.Size.body
            let base = TokenStyler.base(size: size, paragraph: CodeContainerView.paragraphStyle)
            let length = storage.length
            let secondary: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.Palette.inkSecondary]
            let string: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.Palette.syntaxString]
            let number: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.Palette.syntaxNumber]
            let keyword: [NSAttributedString.Key: Any] = [.font: Theme.nsMono(size, weight: .semibold)]
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: length))
            for span in spans where NSMaxRange(span.range) <= length {
                switch span.kind {
                case .secondary: storage.addAttributes(secondary, range: span.range)
                case .string: storage.addAttributes(string, range: span.range)
                case .number: storage.addAttributes(number, range: span.range)
                case .keyword: storage.addAttributes(keyword, range: span.range)
                }
            }
            if let variables = parent.variables, length <= Theme.Layout.highlightLimit {
                TokenStyler.apply(
                    to: storage, context: variables, size: size,
                    paragraph: CodeContainerView.paragraphStyle, toolTips: true
                )
            }
            storage.endEditing()
            textView.typingAttributes = base
            reportHeight()
        }

        // MARK: Height

        func reportHeight() {
            guard parent.isEditable, let container, container.textView.frame.width > 1,
                  let layoutManager = container.textView.layoutManager,
                  let textContainer = container.textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            let height = ceil(max(used, WireMetrics.lineHeight(Theme.Size.body))) + 2 * container.textView.textContainerInset.height
            if let limit = parent.growsUpTo {
                // A scroller that takes room narrows the text, which rewraps it and changes its height.
                // Left to hide and show by itself, it appeared each time the frame was a step behind the
                // text, and the two chased each other for ever. It is now tied to the one fact that does
                // not go back and forth: narrowing never makes a text shorter, so a text too tall for the
                // area stays too tall with the scroller, and one that fits with it fits without it.
                let needsScroller = height > limit + 0.5
                if container.scrollView.hasVerticalScroller != needsScroller {
                    container.scrollView.hasVerticalScroller = needsScroller
                }
            }
            guard height != reportedHeight else { return }
            reportedHeight = height
            Task { [weak self] in self?.parent.onContentHeight(height) }
        }
    }
}

// MARK: - Container, scroll view, gutter

/// A text view in a scroll view with the line numbers hanging in a gutter at its leading edge.
final class CodeContainerView: NSView {
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        // Code wraps where it runs out of room; word wrapping would strand the indentation of a
        // long unbroken expression on a line of its own.
        style.lineBreakMode = .byCharWrapping
        style.defaultTabInterval = 2 * NSString(" ").size(withAttributes: [.font: Theme.nsMono()]).width
        return style
    }()

    let textView: WireTextView
    let scrollView = CodeScrollView()
    let gutter: LineNumberGutter
    var onGeometryChange: (() -> Void)?
    var showsLineNumbers: Bool {
        didSet { if showsLineNumbers != oldValue { gutter.isHidden = !showsLineNumbers; needsLayout = true } }
    }
    private var wraps: Bool?

    init(isEditable: Bool, showsLineNumbers: Bool) {
        textView = WireTextView.make(size: Theme.Size.body)
        gutter = LineNumberGutter(textView: textView, leadingInset: isEditable ? Theme.Space.s : 0)
        self.showsLineNumbers = showsLineNumbers
        super.init(frame: .zero)

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = TokenStyler.base(size: Theme.Size.body, paragraph: Self.paragraphStyle)
        // An editor is outlined and keeps its text off the outline; read code is bare.
        textView.textContainerInset = NSSize(width: Theme.Space.s, height: isEditable ? Theme.Space.s : 0)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        gutter.isHidden = !showsLineNumbers
        addSubview(gutter)
        addSubview(scrollView)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(geometryChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(geometryChanged), name: NSView.frameDidChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let gutterWidth = showsLineNumbers ? gutter.requiredWidth : 0
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        if wraps == true, textView.frame.width != scrollView.contentSize.width {
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
        }
        // When the area shrinks, the text view would keep its former height until its text changes:
        // a document taller than what it holds, which scrolls for nothing.
        textView.sizeToFit()
        gutter.needsDisplay = true
    }

    func setWraps(_ newValue: Bool) {
        guard newValue != wraps, let container = textView.textContainer else { return }
        wraps = newValue
        let width = scrollView.contentSize.width
        if newValue {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.sizeToFit()
        needsLayout = true
    }

    @objc private func geometryChanged() {
        gutter.needsDisplay = true
        onGeometryChange?()
    }
}

/// Lets the page behind scroll when the code has nowhere to go vertically.
final class CodeScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let documentHeight = documentView?.frame.height ?? 0
        let isVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        if isVertical, documentHeight <= contentSize.height + 1 {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Line numbers in secondary ink at 11 pt, one per line of text (not per wrapped row).
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private let leadingInset: CGFloat
    private let font = Theme.nsMono(Theme.Size.caption)
    /// UTF-16 offsets at which lines start.
    private var lineStarts = [0]

    init(textView: NSTextView, leadingInset: CGFloat) {
        self.textView = textView
        self.leadingInset = leadingInset
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var digitWidth: CGFloat {
        NSString("0").size(withAttributes: [.font: font]).width
    }

    var requiredWidth: CGFloat {
        let digits = max(2, String(lineStarts.count).count)
        return ceil(leadingInset + CGFloat(digits) * digitWidth + Theme.Space.xs)
    }

    func rebuild() {
        guard let string = textView?.string as NSString? else { return }
        let length = string.length
        let previousWidth = requiredWidth
        var starts = [0]
        var index = 0
        while index < length {
            let end = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            if end < length { starts.append(end) }
            index = end
        }
        if length > 0, let last = Unicode.Scalar(string.character(at: length - 1)), CharacterSet.newlines.contains(last) {
            starts.append(length)
        }
        lineStarts = starts
        if requiredWidth != previousWidth { superview?.needsLayout = true }
        needsDisplay = true
    }

    private func lineNumber(startingAt offset: Int) -> Int? {
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if lineStarts[middle] == offset { return middle + 1 }
            if lineStarts[middle] < offset { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Palette.inkSecondary]
        // Numbers share the baseline of the text they count.
        let baselineShift = Theme.nsMono().ascender - font.ascender
        let trailing = bounds.width - Theme.Space.xs

        func drawNumber(_ number: Int, lineTop: CGFloat) {
            let label = String(number) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: trailing - width, y: lineTop + origin.y - visible.minY + baselineShift), withAttributes: attributes)
        }

        let glyphs = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
            let offset = layoutManager.characterIndexForGlyph(at: range.location)
            if let number = self.lineNumber(startingAt: offset) { drawNumber(number, lineTop: rect.minY) }
        }
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0, extra.minY + origin.y < visible.maxY, extra.maxY + origin.y > visible.minY {
            drawNumber(lineStarts.count, lineTop: extra.minY)
        }
    }
}
