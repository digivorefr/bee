import AppKit
import BeeCore
import SwiftUI

// MARK: - Headers

/// Header lines as bare two-column rows in the wire voice.
struct WireHeaderRows: View {
    let headers: [HeaderEntry]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                GridRow {
                    Text(header.name)
                        .foregroundStyle(Theme.inkSecondary)
                    Text(header.value)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(Theme.mono())
        .textSelection(.enabled)
    }
}

struct HeadersSection: View {
    let headers: [HeaderEntry]
    @Binding var isExpanded: Bool

    var body: some View {
        DocumentSection("Headers", count: headers.count, isExpanded: $isExpanded) {
            // Two pairs when the line has room, else one.
            ViewThatFits(in: .horizontal) {
                summary(pairs: 2)
                summary(pairs: 1)
            }
        } content: {
            WireHeaderRows(headers: headers)
        }
    }

    private func summary(pairs: Int) -> some View {
        HStack(spacing: Theme.Space.l) {
            ForEach(Array(headers.prefix(pairs).enumerated()), id: \.offset) { _, header in
                Text("\(Text(header.name).foregroundStyle(Theme.inkSecondary)) \(Text(header.value).foregroundStyle(Theme.ink))")
                    .font(Theme.mono())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if headers.count > pairs {
                Text("\(headers.count - pairs) more")
                    .font(Theme.text())
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }
}

// MARK: - Tests

/// A check or a cross in its status color; the words next to it say the same.
private struct TestMark: View {
    let passed: Bool

    var body: some View {
        CellMark(passed ? "checkmark" : "xmark", color: passed ? Theme.positive : Theme.negative)
    }
}

struct TestsSection: View {
    let tests: [TestResult]
    @Binding var isExpanded: Bool

    var body: some View {
        DocumentSection("Tests", isExpanded: $isExpanded) {
            HStack(spacing: Theme.Space.xs) {
                TestMark(passed: failedCount == 0)
                Text(summary).foregroundStyle(Theme.inkSecondary)
            }
            .font(Theme.text())
        } content: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(tests) { test in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        TestMark(passed: test.passed)
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
                                Text(test.name).foregroundStyle(Theme.ink)
                                Text(test.passed ? "Passed" : "Failed").foregroundStyle(Theme.inkSecondary)
                            }
                            if !test.passed, let message = test.message, !message.isEmpty {
                                Text(message)
                                    .font(Theme.mono())
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(Theme.text())
            .textSelection(.enabled)
        }
    }

    private var failedCount: Int { tests.count { !$0.passed } }

    private var summary: String {
        let passed = tests.count - failedCount
        if failedCount == 0 { return "\(passed) passed" }
        return passed == 0 ? "\(failedCount) failed" : "\(failedCount) failed, \(passed) passed"
    }
}

// MARK: - Variables set

struct VariablesSetSection: View {
    let session: RequestSession
    let changes: [VariableChange]
    @Binding var isExpanded: Bool

    var body: some View {
        DocumentSection("Variables set", count: changes.count, isExpanded: $isExpanded) {
            Text(changes.map(\.name).joined(separator: ", "))
                .font(Theme.mono())
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    VariableChangeRow(session: session, change: change)
                }
            }
        }
    }
}

/// One variable a script set or removed. The value of a secret is never drawn unless the person
/// reveals it; it is then read from the workspace and hidden again when the pointer leaves the row
/// or after ten seconds.
private struct VariableChangeRow: View {
    @Environment(AppModel.self) private var model
    let session: RequestSession
    let change: VariableChange
    @ViewState private var revealedValue: String?
    @ViewState private var hideTask: Task<Void, Never>?

    private static let revealDuration: Duration = .seconds(10)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                if isSecret {
                    Image(systemName: "lock.fill")
                        .font(Theme.text(Theme.Size.caption))
                        .foregroundStyle(Theme.inkSecondary)
                        .accessibilityLabel("Secret")
                }
                Text(change.name)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }
            detail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isInside in
            if !isInside { hide() }
        }
        .onDisappear(perform: hide)
    }

    @ViewBuilder private var detail: some View {
        if change.value == nil {
            Text("\(scopeName) · Removed")
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
        } else if isSecret {
            if let revealedValue {
                Text(scopeName)
                    .font(Theme.text())
                    .foregroundStyle(Theme.inkSecondary)
                Text(revealedValue)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Hide", action: hide)
                    .buttonStyle(OutlineButtonStyle())
            } else {
                Text("\(scopeName) · Secret, hidden")
                    .font(Theme.text())
                    .foregroundStyle(Theme.inkSecondary)
                Button("Reveal") {
                    Task { await reveal() }
                }
                .buttonStyle(OutlineButtonStyle())
                .accessibilityLabel("Reveal \(change.name)")
            }
        } else {
            Text(scopeName)
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
            Text(change.value ?? "")
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(change.value ?? "")
        }
    }

    private var current: Variable? {
        model.currentVariable(
            for: change, environmentName: session.sentEnvironmentName, collectionID: session.collectionID
        )
    }

    /// Secret when the script said so or when the workspace holds it as a secret.
    private var isSecret: Bool {
        change.isSecret || current?.isSecret == true
    }

    private var scopeName: String {
        switch change.scope {
        case .local: "This run"
        case .environment: session.sentEnvironmentName ?? "Environment"
        case .collection: "Collection"
        case .global: "Globals"
        }
    }

    private func reveal() async {
        guard await model.authorizeReveal() else { return }
        guard let variable = current else {
            model.inform("“\(change.name)” is no longer in \(scopeName). Send the request again to set it.")
            return
        }
        revealedValue = variable.value
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.revealDuration)
            guard !Task.isCancelled else { return }
            revealedValue = nil
        }
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        revealedValue = nil
    }
}

// MARK: - Console

struct ConsoleSection: View {
    let entries: [ConsoleEntry]
    @Binding var isExpanded: Bool

    var body: some View {
        DocumentSection("Console", count: entries.count, isExpanded: $isExpanded) {
            if let last = entries.last {
                Text(last.message)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } content: {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        levelMark(entry.level)
                            .frame(width: Theme.Space.l)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.message)
                                .font(Theme.mono())
                                .foregroundStyle(Theme.ink)
                            let caption = caption(for: entry)
                            if !caption.isEmpty {
                                Text(caption)
                                    .font(Theme.text(Theme.Size.caption))
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func levelMark(_ level: ConsoleLevel) -> some View {
        switch level {
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.text(Theme.Size.caption))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(Theme.text(Theme.Size.caption))
                .foregroundStyle(Theme.negative)
                .accessibilityHidden(true)
        case .info:
            Image(systemName: "info.circle")
                .font(Theme.text(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
        case .log:
            Image(systemName: "circle.fill")
                .font(Theme.text(Theme.Size.caption))
                .scaleEffect(0.4)
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
        }
    }

    /// The level in words for warnings and errors, then where the line comes from.
    private func caption(for entry: ConsoleEntry) -> String {
        let level: String? = switch entry.level {
        case .warn: "Warning"
        case .error: "Error"
        case .log, .info: nil
        }
        return [level, entry.source.isEmpty ? nil : entry.source].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Request sent

/// The request as it went on the wire. The core has already masked every secret; it is shown as is.
struct RequestSentSection: View {
    let sent: SentRequest
    @Binding var isExpanded: Bool

    private static let longBodyHeight: CGFloat = 240

    var body: some View {
        DocumentSection("Request sent", isExpanded: $isExpanded) {
            Text("\(sent.method) \(sent.url)")
                .font(Theme.mono())
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("\(sent.method) \(sent.url)")
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                if !sent.headers.isEmpty {
                    WireHeaderRows(headers: sent.headers)
                }
                if let preview = sent.bodyPreview, !preview.isEmpty {
                    if preview.utf8.count > 4000 {
                        CodeViewer(text: preview, language: language(of: preview))
                            .frame(height: Self.longBodyHeight)
                    } else {
                        Text(preview)
                            .font(Theme.mono())
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func language(of preview: String) -> CodeLanguage {
        let contentType = sent.headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let mimeType = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let language = CodeLanguage(mimeType: mimeType)
        return language == .plain && JSONIndenter.looksLikeJSON(preview) ? .json : language
    }
}
