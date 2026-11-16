import AppKit
import BeeCore

// The TextKit 1 machinery shared by every view that shows the wire voice: the token attribute, the
// layout manager that draws token grounds and locks, the styler, and the text view.

extension NSAttributedString.Key {
    /// Marks the characters of one `{{variable}}`; the value is a `TokenMark`.
    nonisolated static let beeToken = NSAttributedString.Key("bee.token")
}

/// What the layout manager needs to draw one token. One instance per token keeps neighbours apart.
nonisolated final class TokenMark: NSObject {
    let isSecret: Bool

    init(isSecret: Bool) {
        self.isSecret = isSecret
    }
}

enum WireMetrics {
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: Theme.nsMono(size)))
    }

    /// Room reserved before a secret token for its lock.
    static func lockAdvance(_ size: CGFloat) -> CGFloat {
        (size * Theme.Glyph.lockAdvanceScale).rounded()
    }
}

// MARK: - Layout manager

/// Draws the ground of `{{variable}}` tokens (radius 5) and the lock of secret ones.
nonisolated final class TokenLayoutManager: NSLayoutManager {
    /// The theme values the drawing needs, handed over by the main actor.
    struct Style {
        var ground: NSColor
        var lock: NSColor
        var radius: CGFloat
        var lockScale: CGFloat
        var lockAdvanceScale: CGFloat
    }

    private var style = Style(ground: .clear, lock: .clear, radius: 0, lockScale: 1, lockAdvanceScale: 1)
    private var lockImages: [CGFloat: NSImage] = [:]

    @MainActor static func themed() -> TokenLayoutManager {
        let manager = TokenLayoutManager()
        manager.style = Style(
            ground: Theme.Palette.tokenGround, lock: Theme.Palette.inkSecondary, radius: Theme.Radius.token,
            lockScale: Theme.Glyph.lockScale, lockAdvanceScale: Theme.Glyph.lockAdvanceScale
        )
        return manager
    }

    private func lockAdvance(_ fontSize: CGFloat) -> CGFloat {
        (fontSize * style.lockAdvanceScale).rounded()
    }

    private struct Shape {
        var rects: [NSRect]
        var isSecret: Bool
        var fontSize: CGFloat
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let shapes = tokenShapes(in: glyphsToShow, origin: origin)
        style.ground.setFill()
        for shape in shapes {
            for rect in shape.rects {
                NSBezierPath(roundedRect: rect, xRadius: style.radius, yRadius: style.radius).fill()
            }
        }
        // The selection is painted by super, over the grounds.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        for shape in shapes where shape.isSecret {
            if let first = shape.rects.first { drawLock(in: first, fontSize: shape.fontSize) }
        }
    }

    private func tokenShapes(in glyphRange: NSRange, origin: NSPoint) -> [Shape] {
        guard let storage = textStorage, storage.length > 0, glyphRange.length > 0 else { return [] }
        let visible = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)
        var shapes: [Shape] = []
        storage.enumerateAttribute(.beeToken, in: visible, options: []) { value, range, _ in
            guard let mark = value as? TokenMark else { return }
            var full = NSRange(location: 0, length: 0)
            _ = storage.attribute(.beeToken, at: range.location, longestEffectiveRange: &full, in: whole)
            guard full.length > 0 else { return }
            let glyphs = self.glyphRange(forCharacterRange: full, actualCharacterRange: nil)
            guard glyphs.length > 0,
                  let container = self.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
            else { return }
            let font = storage.attribute(.font, at: full.location, effectiveRange: nil) as? NSFont
            let fontSize = font?.pointSize ?? NSFont.systemFontSize
            let trailingKern = (storage.attribute(.kern, at: NSMaxRange(full) - 1, effectiveRange: nil) as? NSNumber)
                .map { CGFloat($0.doubleValue) } ?? 0
            var rects: [NSRect] = []
            self.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: 0.5))
            }
            guard !rects.isEmpty else { return }
            if mark.isSecret {
                // The lock sits in the room reserved before the token.
                let advance = self.lockAdvance(fontSize)
                rects[0].origin.x -= advance
                rects[0].size.width += advance
            }
            if trailingKern > 0 {
                // That room belongs to the secret token that follows, not to this one.
                rects[rects.count - 1].size.width -= trailingKern
            }
            shapes.append(Shape(rects: rects, isSecret: mark.isSecret, fontSize: fontSize))
        }
        return shapes
    }

    private func drawLock(in rect: NSRect, fontSize: CGFloat) {
        guard let image = lockImage(fontSize: fontSize) else { return }
        let size = image.size
        let advance = lockAdvance(fontSize)
        let target = NSRect(
            x: rect.minX + (advance - size.width) / 2 + 1,
            y: rect.midY - size.height / 2,
            width: size.width, height: size.height
        )
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func lockImage(fontSize: CGFloat) -> NSImage? {
        if let cached = lockImages[fontSize] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: fontSize * style.lockScale, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [style.lock]))
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        lockImages[fontSize] = image
        return image
    }
}

// MARK: - Styler

extension VariableContext {
    /// Changes whenever a token could need another look.
    var styleSignature: Int {
        var hasher = Hasher()
        hasher.combine(locals)
        hasher.combine(environment)
        hasher.combine(collection)
        hasher.combine(globals)
        return hasher.finalize()
    }
}

enum TokenStyler {
    /// The names offered after `{{`: the variables in sight, then the dynamic ones.
    static func completionNames(in context: VariableContext?) -> [String] {
        (context?.names ?? []) + ["$uuid", "$timestamp", "$isoTimestamp", "$randomInt"]
    }

    /// The attributes of plain wire text.
    static func base(size: CGFloat, paragraph: NSParagraphStyle = .default) -> [NSAttributedString.Key: Any] {
        [.font: Theme.nsMono(size), .foregroundColor: Theme.Palette.ink, .paragraphStyle: paragraph]
    }

    /// Marks every `{{placeholder}}` of the storage as a token and, when `pathVariables` is given (the text is
    /// an address), every `:name` segment too. With a context, a name without a value is drawn in the warning
    /// color and a secret gets room for its lock. Tooltips never carry a secret's value.
    static func apply(
        to storage: NSTextStorage, context: VariableContext?, size: CGFloat,
        paragraph: NSParagraphStyle = .default, toolTips: Bool, pathVariables: [KeyValue]? = nil
    ) {
        let text = storage.string
        let string = text as NSString
        let font = Theme.nsMono(size)

        func mark(_ range: NSRange, isSecret: Bool, isUnresolved: Bool, toolTip: String?) {
            var attributes: [NSAttributedString.Key: Any] = [
                .beeToken: TokenMark(isSecret: isSecret),
                .font: font,
                .foregroundColor: isUnresolved ? Theme.Palette.warning : Theme.Palette.ink,
            ]
            if let toolTip { attributes[.toolTip] = toolTip }
            storage.addAttributes(attributes, range: range)
            guard isSecret else { return }
            let paragraphRange = string.paragraphRange(for: NSRange(location: range.location, length: 0))
            if range.location > paragraphRange.location {
                let previous = string.rangeOfComposedCharacterSequence(at: range.location - 1)
                storage.addAttribute(.kern, value: NSNumber(value: Double(WireMetrics.lockAdvance(size))), range: previous)
            } else {
                let indented = NSMutableParagraphStyle()
                indented.setParagraphStyle(paragraph)
                indented.firstLineHeadIndent = WireMetrics.lockAdvance(size)
                storage.addAttribute(.paragraphStyle, value: indented, range: paragraphRange)
            }
        }

        if let pathVariables {
            for occurrence in PathVariables.occurrences(in: text) {
                let row = pathVariables.first { $0.key == occurrence.name }
                let template = PathVariables.valueTemplate(for: occurrence.name, in: pathVariables)
                let value = context.map { TemplateEngine.render(template, in: $0) }
                let holdsSecret = row.map { $0.isSecret && !$0.value.isEmpty && !RequestText.isPlaceholderOnly($0.value) } ?? false
                let isSecret = holdsSecret || value?.usedSecret == true
                let isUnresolved = value.map { !$0.unresolved.isEmpty } ?? false
                mark(
                    occurrence.nsRange, isSecret: isSecret, isUnresolved: isUnresolved,
                    toolTip: toolTips ? value.map { pathToolTip(name: occurrence.name, value: $0, isSecret: isSecret) } : nil
                )
            }
        }

        guard text.contains("{{") else { return }
        for token in TemplateEngine.tokens(in: text) {
            let name: String
            let isDynamic: Bool
            switch token.kind {
            case .text: continue
            case .variable(let variable): name = variable; isDynamic = false
            case .dynamic(let dynamic): name = dynamic; isDynamic = true
            }
            let lookup = isDynamic ? nil : context?.lookup(name)
            mark(
                token.nsRange, isSecret: lookup?.isSecret ?? false,
                isUnresolved: !isDynamic && context != nil && lookup == nil,
                toolTip: toolTips && context != nil ? toolTip(lookup: lookup, isDynamic: isDynamic) : nil
            )
        }
    }

    private static func pathToolTip(name: String, value: RenderResult, isSecret: Bool) -> String {
        if !value.unresolved.isEmpty {
            return "Path variable without a value. Set it under Path variables, or add a variable named \(name)."
        }
        if isSecret { return "Path variable · Secret, hidden" }
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Path variable · Empty" }
        return "Path variable · \(text.count > 200 ? text.prefix(200) + "…" : text)"
    }

    private static func toolTip(lookup: VariableLookup?, isDynamic: Bool) -> String {
        if isDynamic { return "Dynamic value, generated when the request is sent" }
        guard let lookup else {
            return "Variable not found. Add it to the active environment, the collection or the globals."
        }
        let scope = switch lookup.scope {
        case .local: "Local variable"
        case .environment: "Environment variable"
        case .collection: "Collection variable"
        case .global: "Global variable"
        }
        if lookup.isSecret { return "\(scope) · Secret, hidden" }
        if lookup.value.isEmpty { return "\(scope) · Empty" }
        let value = lookup.value.count > 200 ? lookup.value.prefix(200) + "…" : lookup.value
        return "\(scope) · \(value)"
    }
}

// MARK: - Text view

/// An `NSTextView` on TextKit 1 with the token layout manager, no rich text and no substitutions.
final class WireTextView: NSTextView {
    /// The text view does not retain the storage of a hand-built text system.
    private var ownedStorage: NSTextStorage?
    var placeholder: NSAttributedString? {
        didSet { needsDisplay = true }
    }
    var onFocusChange: ((Bool) -> Void)?
    /// A field selects everything when the keyboard brings focus to it, and lets go of the selection after.
    var behavesAsField = false
    var wantsInitialFocus = false

    static func make(size: CGFloat) -> WireTextView {
        let storage = NSTextStorage()
        let layout = TokenLayoutManager.themed()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = WireTextView(frame: .zero, textContainer: container)
        view.ownedStorage = storage
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.usesRuler = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = false
        view.insertionPointColor = Theme.Palette.focus
        view.font = Theme.nsMono(size)
        view.textColor = Theme.Palette.ink
        view.typingAttributes = TokenStyler.base(size: size)
        return view
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let origin = textContainerOrigin
        placeholder.draw(at: NSPoint(x: origin.x + (textContainer?.lineFragmentPadding ?? 0), y: origin.y))
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            if behavesAsField, NSApp.currentEvent?.type == .keyDown { selectAll(nil) }
            notifyFocus(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            if behavesAsField {
                setSelectedRange(NSRange(location: 0, length: 0))
                scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            notifyFocus(false)
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsInitialFocus, window != nil else { return }
        wantsInitialFocus = false
        Task { [weak self] in
            guard let self else { return }
            if self.window?.makeFirstResponder(self) != true { self.onFocusChange?(false) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard usesFindBar, window?.firstResponder === self,
              let action = findAction(for: event)
        else { return super.performKeyEquivalent(with: event) }
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
        return true
    }

    private func findAction(for event: NSEvent) -> NSTextFinder.Action? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("f", .command): return .showFindInterface
        case ("g", .command): return .nextMatch
        case ("g", [.command, .shift]): return .previousMatch
        default: return nil
        }
    }

    // MARK: Completion of variable names after `{{`

    /// The names to offer; `nil` turns completion off.
    var completionNames: (() -> [String])?
    private var isInsertingCompletion = false
    private var lastChangeInserted = false

    /// The partial name between an open `{{` and the caret, if the caret is inside a placeholder being typed.
    private func partialNameRange() -> NSRange? {
        let caret = selectedRange()
        guard caret.length == 0, caret.location != NSNotFound else { return nil }
        let text = string as NSString
        var index = min(caret.location, text.length)
        while index > 0 {
            let unit = text.character(at: index - 1)
            if unit == 0x7B {
                guard index >= 2, text.character(at: index - 2) == 0x7B else { return nil }
                return NSRange(location: index, length: caret.location - index)
            }
            let isNameUnit = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
                || unit == 0x5F || unit == 0x2D || unit == 0x2E || unit == 0x24 || unit > 0x7F
            guard isNameUnit else { return nil }
            index -= 1
        }
        return nil
    }

    override var rangeForUserCompletion: NSRange {
        guard completionNames != nil else { return super.rangeForUserCompletion }
        return partialNameRange() ?? NSRange(location: NSNotFound, length: 0)
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let names = completionNames?() else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        // Nothing is chosen until the person picks: typing is never overwritten.
        index.pointee = -1
        let partial = (string as NSString).substring(with: charRange).lowercased()
        let matches = names.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
        return matches.count == 1 && matches[0].lowercased() == partial ? [] : Array(matches.prefix(40))
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        guard completionNames != nil else {
            return super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        }
        isInsertingCompletion = true
        defer { isInsertingCompletion = false }
        var completed = word
        let text = string as NSString
        let isChosen = flag && (movement == NSReturnTextMovement || movement == NSTabTextMovement)
        if isChosen, word != text.substring(with: charRange) {
            let end = NSMaxRange(charRange)
            let isClosed = end + 1 < text.length && text.character(at: end) == 0x7D && text.character(at: end + 1) == 0x7D
            if !isClosed { completed += "}}" }
        }
        super.insertCompletion(completed, forPartialWordRange: charRange, movement: movement, isFinal: flag)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        lastChangeInserted = replacementString?.isEmpty == false
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()
        guard completionNames != nil, lastChangeInserted, !isInsertingCompletion, !hasMarkedText(), partialNameRange() != nil else { return }
        // The list runs its own event loop until it closes. Started from a run-loop timer, never from a
        // task or the main queue, it leaves the main actor free for everything else meanwhile.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showCompletions), object: nil)
        perform(#selector(showCompletions), with: nil, afterDelay: 0, inModes: [.common])
    }

    @objc private func showCompletions() {
        guard window?.firstResponder === self, partialNameRange() != nil else { return }
        complete(nil)
    }

    private func notifyFocus(_ focused: Bool) {
        // Deferred: focus moves during view updates, where SwiftUI state may not change.
        Task { [weak self] in self?.onFocusChange?(focused) }
    }
}
