import AppKit
import BeeCore
import SwiftUI

/// The input of a secret value: masked unless revealed; revealing asks `AppModel.authorizeReveal()`
/// and ends when focus leaves. A value made only of `{{placeholders}}` is a template, shown as tokens.
struct SecretValueField: View {
    /// A fixed count: the mask never tells the length of the value.
    private static let mask = String(repeating: "•", count: 8)

    private enum Mode {
        case template, masked, revealed
    }

    @Environment(AppModel.self) private var model
    private let placeholder: String
    @Binding private var text: String
    private let context: VariableContext?
    private let isBordered: Bool

    @ViewState private var isRevealed = false
    /// The mode is held while an editor has focus, so typing never swaps the editor under the caret.
    @ViewState private var focusedMode: Mode?
    @ViewState private var isHovered = false
    /// What is typed over the mask; it replaces the whole value, like a password field.
    @ViewState private var draft = ""
    @FocusState private var isMaskFocused: Bool

    init(_ placeholder: String, text: Binding<String>, context: VariableContext? = nil, isBordered: Bool = true) {
        self.placeholder = placeholder
        _text = text
        self.context = context
        self.isBordered = isBordered
    }

    var body: some View {
        let row = HStack(spacing: Theme.Space.xs) {
            editor
                .frame(height: WireMetrics.lineHeight(Theme.Size.body))
            actions
        }
        .onHover { isHovered = $0 }
        .onChange(of: isMaskFocused) { _, focused in
            if focused {
                draft = ""
                focusedMode = .masked
            } else if focusedMode == .masked {
                focusedMode = nil
                draft = ""
            }
        }
        if isBordered {
            row
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Layout.fieldInset)
                .outlined(isFocused: focusedMode != nil)
        } else {
            row
        }
    }

    private var mode: Mode {
        focusedMode ?? (isRevealed ? .revealed : Self.isTemplate(text) ? .template : .masked)
    }

    @ViewBuilder private var editor: some View {
        switch mode {
        case .template:
            WireField(
                placeholder: placeholder, text: $text, variables: context ?? VariableContext(), size: Theme.Size.body,
                onFocusChange: { focused in
                    if focused { focusedMode = .template } else if focusedMode == .template { focusedMode = nil }
                }
            )
            // The field stays a secret even while it only refers to other variables. Inside a
            // table row the row's own lock toggle already says so.
            if isBordered {
                Image(systemName: "lock.fill")
                    .font(.system(size: Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityLabel("Secret")
            }
        case .revealed:
            WireField(
                placeholder: placeholder, text: $text, variables: nil, size: Theme.Size.body, focusOnAppear: true,
                onFocusChange: { focused in
                    if focused { focusedMode = .revealed } else { hide() }
                }
            )
        case .masked:
            SecureField(
                "", text: Binding(get: { draft }, set: { replaceValue(with: $0) }),
                prompt: Text(text.isEmpty ? placeholder : Self.mask)
                    .foregroundStyle(text.isEmpty ? Theme.inkTertiary : Theme.ink)
            )
            .textFieldStyle(.plain)
            .font(Theme.mono())
            .focused($isMaskFocused)
            .accessibilityLabel(placeholder)
            .accessibilityValue(text.isEmpty ? "Empty" : "Secret, hidden")
        }
    }

    @ViewBuilder private var actions: some View {
        if mode != .template, !text.isEmpty {
            let isVisible = isHovered || focusedMode != nil
            HStack(spacing: Theme.Space.s) {
                Button(action: toggleReveal) {
                    Image(systemName: mode == .revealed ? "eye.slash" : "eye")
                }
                .help(mode == .revealed ? "Hide" : "Reveal")
                .accessibilityLabel(mode == .revealed ? "Hide" : "Reveal")
                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy")
                .accessibilityLabel("Copy")
            }
            .buttonStyle(QuietButtonStyle())
            .font(.system(size: Theme.Glyph.action))
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
        }
    }

    private func replaceValue(with typed: String) {
        guard typed != draft else { return }
        draft = typed
        text = typed
    }

    private func toggleReveal() {
        if mode == .revealed {
            hide()
            return
        }
        Task {
            guard await model.authorizeReveal() else { return }
            draft = ""
            isRevealed = true
            focusedMode = .revealed
        }
    }

    private func hide() {
        isRevealed = false
        if focusedMode == .revealed { focusedMode = nil }
    }

    private func copy() {
        let value = text
        Task {
            guard await model.authorizeReveal() else { return }
            model.copy(value, isSecret: true)
        }
    }

    /// True when the value is made of placeholders and whitespace only: a reference, not a secret.
    static func isTemplate(_ value: String) -> Bool {
        guard value.contains("{{") else { return false }
        var hasPlaceholder = false
        for token in TemplateEngine.tokens(in: value) {
            switch token.kind {
            case .text:
                if !value[token.range].allSatisfy(\.isWhitespace) { return false }
            case .variable, .dynamic:
                hasPlaceholder = true
            }
        }
        return hasPlaceholder
    }
}
