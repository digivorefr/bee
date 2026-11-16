import BeeCore
import SwiftUI

// MARK: - Key-value table

/// A borderless table of name/value rows (parameters, headers, form fields): no grid lines,
/// the enable mark hangs in the gutter, the last line adds a row.
struct KeyValueTable: View {
    @Binding private var rows: [KeyValue]
    private let noun: String
    private let context: VariableContext
    private let sealsSensitiveNames: Bool

    /// - Parameters:
    ///   - noun: what a row is, lower case ("parameter", "header", "field").
    ///   - sealsSensitiveNames: a new row whose name looks like a credential defaults to secret.
    init(rows: Binding<[KeyValue]>, noun: String, context: VariableContext, sealsSensitiveNames: Bool = false) {
        _rows = rows
        self.noun = noun
        self.context = context
        self.sealsSensitiveNames = sealsSensitiveNames
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                RequestTableCaptions(columns: [("Name", RequestMetrics.nameWidth), ("Value", nil)])
            }
            ForEach(rows) { row in
                KeyValueRow(
                    row: binding(for: row.id), noun: noun, context: context,
                    sealsSensitiveNames: sealsSensitiveNames
                ) {
                    rows.removeAll { $0.id == row.id }
                }
            }
            RequestAddLine(title: "Add \(noun)") { rows.append(KeyValue()) }
        }
    }

    /// A binding by identity, so removing a row never leaves a binding on a stale index.
    private func binding(for id: UUID) -> Binding<KeyValue> {
        Binding(
            get: { rows.first { $0.id == id } ?? KeyValue(id: id) },
            set: { updated in
                if let index = rows.firstIndex(where: { $0.id == id }) { rows[index] = updated }
            }
        )
    }
}

private struct KeyValueRow: View {
    @Environment(AppModel.self) private var model
    @Binding var row: KeyValue
    let noun: String
    let context: VariableContext
    let sealsSensitiveNames: Bool
    let remove: () -> Void

    var body: some View {
        RequestTableRow(
            isEnabled: $row.isEnabled, itemName: row.key.isEmpty ? noun : "\(noun) \(row.key)",
            isSecret: row.isSecret, toggleSecret: toggleSecret, remove: remove
        ) {
            TemplateField("Name", text: nameBinding, context: context, isBordered: false)
                .frame(width: RequestMetrics.nameWidth, alignment: .leading)
            Group {
                if row.isSecret {
                    SecretValueField("Value", text: $row.value, context: context, isBordered: false)
                } else {
                    TemplateField("Value", text: $row.value, context: context, isBordered: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Typing a name that looks like a credential seals the row while it has no value yet.
    private var nameBinding: Binding<String> {
        Binding(
            get: { row.key },
            set: { newKey in
                var updated = row
                if sealsSensitiveNames, !updated.isSecret, updated.value.isEmpty,
                   CredentialHeuristics.looksSensitive(name: newKey),
                   !CredentialHeuristics.looksSensitive(name: updated.key) {
                    updated.isSecret = true
                }
                updated.key = newKey
                row = updated
            }
        )
    }

    /// Sealing is immediate; unsealing would draw the value, so it asks like a reveal does.
    private func toggleSecret() {
        guard row.isSecret else {
            row.isSecret = true
            return
        }
        if row.value.isEmpty || RequestText.isPlaceholderOnly(row.value) {
            row.isSecret = false
            return
        }
        Task {
            if await model.authorizeReveal() { row.isSecret = false }
        }
    }
}

// MARK: - Multipart table

/// The rows of a multipart form: each is a text (optionally secret) or a file chosen from disk.
struct FormFieldTable: View {
    @Binding private var rows: [FormField]
    private let context: VariableContext

    init(rows: Binding<[FormField]>, context: VariableContext) {
        _rows = rows
        self.context = context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                RequestTableCaptions(columns: [
                    ("Name", RequestMetrics.nameWidth), ("Kind", FormFieldRow.kindWidth), ("Value", nil),
                ])
            }
            ForEach(rows) { row in
                FormFieldRow(row: binding(for: row.id), context: context) {
                    rows.removeAll { $0.id == row.id }
                }
            }
            RequestAddLine(title: "Add field") { rows.append(FormField()) }
        }
    }

    private func binding(for id: UUID) -> Binding<FormField> {
        Binding(
            get: { rows.first { $0.id == id } ?? FormField(id: id) },
            set: { updated in
                if let index = rows.firstIndex(where: { $0.id == id }) { rows[index] = updated }
            }
        )
    }
}

private struct FormFieldRow: View {
    static let kindWidth = Theme.Space.xxl * 2

    @Environment(AppModel.self) private var model
    @Binding var row: FormField
    let context: VariableContext
    let remove: () -> Void

    var body: some View {
        RequestTableRow(
            isEnabled: $row.isEnabled, itemName: row.key.isEmpty ? "field" : "field \(row.key)",
            isSecret: row.kind == .text ? row.isSecret : nil, toggleSecret: toggleSecret, remove: remove
        ) {
            TemplateField("Name", text: $row.key, context: context, isBordered: false)
                .frame(width: RequestMetrics.nameWidth, alignment: .leading)
            RequestPopUp(
                "Kind", selection: kindBinding,
                options: [
                    RequestPopUpOption(value: FormField.Kind.text, title: "Text"),
                    RequestPopUpOption(value: FormField.Kind.file, title: "File"),
                ],
                isOutlined: false
            )
            .frame(width: Self.kindWidth, alignment: .leading)
            Group {
                switch row.kind {
                case .text:
                    if row.isSecret {
                        SecretValueField("Value", text: $row.value, context: context, isBordered: false)
                    } else {
                        TemplateField("Value", text: $row.value, context: context, isBordered: false)
                    }
                case .file:
                    HStack(spacing: Theme.Space.s) {
                        if row.value.isEmpty {
                            Text("No file").font(Theme.text()).foregroundStyle(Theme.inkTertiary)
                        } else {
                            Text((row.value as NSString).lastPathComponent)
                                .font(Theme.mono())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(row.value)
                        }
                        Button("Choose…") {
                            if let path = RequestFileChooser.choose() { row.value = path }
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A text and a file path are different things: the value does not survive a change of kind.
    private var kindBinding: Binding<FormField.Kind> {
        Binding(
            get: { row.kind },
            set: { kind in
                guard kind != row.kind else { return }
                var updated = row
                updated.kind = kind
                updated.value = ""
                if kind == .file { updated.isSecret = false }
                row = updated
            }
        )
    }

    private func toggleSecret() {
        guard row.isSecret else {
            row.isSecret = true
            return
        }
        if row.value.isEmpty || RequestText.isPlaceholderOnly(row.value) {
            row.isSecret = false
            return
        }
        Task {
            if await model.authorizeReveal() { row.isSecret = false }
        }
    }
}

// MARK: - Shared table parts

/// Column captions in caption ink.
struct RequestTableCaptions: View {
    /// Title and width of each column; `nil` takes the remaining width.
    let columns: [(title: String, width: CGFloat?)]

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(columns, id: \.title) { column in
                Text(column.title)
                    .requestCaption()
                    .frame(width: column.width, alignment: .leading)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .frame(height: Theme.Space.xl)
    }
}

/// One row: the enable mark in the gutter (shown on hover or when the row is off), the cells,
/// the lock that seals the value, and Remove on hover.
struct RequestTableRow<Cells: View>: View {
    @Binding private var isEnabled: Bool
    private let itemName: String
    private let isSecret: Bool?
    private let toggleSecret: () -> Void
    private let remove: () -> Void
    private let cells: Cells
    @ViewState private var isHovered = false

    /// - Parameter isSecret: `nil` when the row cannot be sealed (a file).
    init(
        isEnabled: Binding<Bool>, itemName: String, isSecret: Bool?,
        toggleSecret: @escaping () -> Void, remove: @escaping () -> Void,
        @ViewBuilder cells: () -> Cells
    ) {
        _isEnabled = isEnabled
        self.itemName = itemName
        self.isSecret = isSecret
        self.toggleSecret = toggleSecret
        self.remove = remove
        self.cells = cells()
    }

    var body: some View {
        HStack(spacing: 0) {
            RequestGlyphButton(
                isEnabled ? "checkmark.square" : "square",
                label: isEnabled ? "Turn off \(itemName)" : "Turn on \(itemName)"
            ) { isEnabled.toggle() }
                .opacity(isHovered || !isEnabled ? 1 : 0)
            HStack(spacing: Theme.Space.s) {
                cells
            }
            .opacity(isEnabled ? 1 : RequestMetrics.disabledOpacity)
            if let isSecret {
                RequestGlyphButton(
                    isSecret ? "lock.fill" : "lock.open",
                    label: isSecret ? "Stop keeping \(itemName) secret" : "Keep \(itemName) secret",
                    action: toggleSecret
                )
                .opacity(isSecret || isHovered ? 1 : 0)
            }
            RequestGlyphButton("xmark", label: "Remove \(itemName)", action: remove)
                .opacity(isHovered ? 1 : 0)
        }
        .frame(height: RequestMetrics.rowHeight)
        // The enable mark hangs in the gutter; the row's hover area reaches over it.
        .padding(.leading, -Theme.Layout.gutter)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// The last line of a table: `+ Add header`.
struct RequestAddLine: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "plus").font(Theme.text(Theme.Size.caption, weight: .medium))
                Text(title)
            }
            .frame(height: RequestMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
    }
}
