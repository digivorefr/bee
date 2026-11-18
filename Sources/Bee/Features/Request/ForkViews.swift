import BeeCore
import SwiftUI

// A fork is a request being tried: its page has its own ground and says so under the request line.

extension RequestPart {
    /// The part as the request page names it.
    var title: String {
        switch self {
        case .address: "Method and URL"
        case .parameters: "Parameters"
        case .authorization: "Authorization"
        case .headers: "Headers"
        case .body: "Body"
        case .preRequestScript: "Pre-request script"
        case .postResponseScript: "Post-response script"
        case .settings: "Settings"
        }
    }
}

// MARK: - Banner

/// The line under the request line of a fork: whose fork it is, what it changes, and what to do with it.
struct ForkBanner: View {
    @Environment(AppModel.self) private var model
    let fork: RequestFork

    var body: some View {
        let original = model.original(of: fork)
        let differing = original.map { ForkComparison(fork: fork, original: $0).differing } ?? []
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs + 2) {
                CellMark(color: Theme.forkInk, size: Theme.Size.caption, isHollow: true)
                Text("Fork of \(original?.name ?? "a request that is gone")")
                    .font(Theme.text(weight: .semibold))
                    .foregroundStyle(Theme.forkInk)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Text(Self.describe(differing))
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .help(differing.map(\.title).joined(separator: ", "))
            Spacer(minLength: Theme.Space.s)
            Button("Merge…") { ShellState.shared.mergingFork = fork.id }
                .buttonStyle(OutlineButtonStyle())
                .disabled(differing.isEmpty || model.isVaultLocked)
                .help(
                    model.isVaultLocked ? "Unlock your secrets to merge"
                        : differing.isEmpty ? "Nothing to merge yet" : "Put these changes in the original"
                )
            Button("Discard") { ShellActions.discardFork(fork, model: model) }
                .buttonStyle(QuietButtonStyle())
                .help("Remove this fork; the original is not touched")
        }
    }

    static func describe(_ differing: [RequestPart]) -> String {
        switch differing.count {
        case 0: "Same as the original for now"
        case 1: "Changes \(differing[0].title.lowercased(with: Locale(identifier: "en")).replacingOccurrences(of: "url", with: "URL"))"
        default: "Changes \(differing.count) parts"
        }
    }
}

// MARK: - Merge sheet

/// The review before a fork goes into its original: each part that differs, and a choice where both
/// sides changed.
struct ForkMergeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let forkID: UUID
    @ViewState private var keepsOriginal: Set<RequestPart> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let fork = model.fork(id: forkID), let original = model.original(of: fork) {
                content(fork: fork, original: original)
            } else {
                Text("This fork is no longer there.")
                    .font(Theme.text())
                    .foregroundStyle(Theme.inkSecondary)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(Theme.Layout.pageInset)
        .frame(width: 540)
        .background(Theme.paper)
    }

    @ViewBuilder
    private func content(fork: RequestFork, original: RequestItem) -> some View {
        let comparison = ForkComparison(fork: fork, original: original)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Merge “\(fork.name)” into “\(original.name)”")
                .font(Theme.text(Theme.Size.headline, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(
                comparison.differing.isEmpty
                    ? "This fork says what the original says: there is nothing to merge."
                    : "The original takes these parts from the fork, then the fork is removed."
            )
            .font(Theme.text())
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !comparison.differing.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    ForEach(comparison.differing) { part in
                        partRow(part, state: comparison.state(of: part), fork: fork, original: original)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        HStack(spacing: Theme.Space.s) {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Merge") {
                model.mergeFork(forkID, keepingOriginal: keepsOriginal)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(comparison.differing.isEmpty)
        }
        .buttonStyle(OutlineButtonStyle())
    }

    @ViewBuilder
    private func partRow(_ part: RequestPart, state: ForkPartState, fork: RequestFork, original: RequestItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(part.title)
                .font(Theme.text(weight: .semibold))
                .foregroundStyle(Theme.ink)
            if state == .changedInBoth {
                Text("The original changed this part too since the fork was made.")
                    .font(Theme.text(Theme.Size.caption))
                    .foregroundStyle(Theme.warning)
                Picker("\(part.title): which one to keep", selection: choice(for: part)) {
                    Text("Take the fork’s").tag(false)
                    Text("Keep the original’s").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                version("Fork", ForkSummary.line(of: part, in: fork.item), isKept: !keepsOriginal.contains(part))
                version("Original", ForkSummary.line(of: part, in: original), isKept: keepsOriginal.contains(part))
            } else {
                version("Fork", ForkSummary.line(of: part, in: fork.item), isKept: true)
                version("Original", ForkSummary.line(of: part, in: original), isKept: false)
            }
            if ForkSummary.line(of: part, in: fork.item) == ForkSummary.line(of: part, in: original) {
                // The two lines read the same when the difference is in a value that is not drawn.
                Text("The difference is in a secret value, which is not shown.")
                    .font(Theme.text(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    /// One side of a part: the one that stays in ink, the one that goes struck through.
    private func version(_ side: String, _ line: String, isKept: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(side)
                .font(Theme.text(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: Theme.Space.xxl * 2, alignment: .leading)
            Text(line)
                .font(Theme.mono(Theme.Size.caption))
                .foregroundStyle(isKept ? Theme.ink : Theme.inkTertiary)
                .strikethrough(!isKept, color: Theme.inkTertiary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(side), \(isKept ? "kept" : "replaced"): \(line)")
    }

    private func choice(for part: RequestPart) -> Binding<Bool> {
        Binding(
            get: { keepsOriginal.contains(part) },
            set: { keeps in
                if keeps { keepsOriginal.insert(part) } else { keepsOriginal.remove(part) }
            }
        )
    }
}

// MARK: - One line per part

/// What a part says, in one line, for the merge review. A secret is never written: its place is.
enum ForkSummary {
    static func line(of part: RequestPart, in item: RequestItem) -> String {
        switch part {
        case .address:
            let rows = PathVariables.storedRows(for: item.url, from: item.pathVariables)
            let address = "\(item.method.rawValue) \(item.url.isEmpty ? "(no URL)" : item.url)"
            return rows.isEmpty ? address : "\(address)  ·  \(pairs(rows))"
        case .parameters:
            return item.queryParams.isEmpty ? "None" : pairs(item.queryParams)
        case .headers:
            return item.headers.isEmpty ? "None" : pairs(item.headers)
        case .authorization:
            return AuthEditor.summary(of: item.auth)
        case .body:
            let summary = BodyEditor.summary(of: item.body)
            return summary.wire ?? summary.words ?? "None"
        case .preRequestScript:
            return script(item.preRequestScript)
        case .postResponseScript:
            return script(item.postResponseScript)
        case .settings:
            var parts: [String] = []
            if let timeout = item.settings.timeout { parts.append("Timeout \(RequestSettingsEditor.describe(timeout)) s") }
            if let follows = item.settings.followRedirects { parts.append(follows ? "Follows redirects" : "Does not follow redirects") }
            if let verifies = item.settings.verifyTLS { parts.append(verifies ? "Verifies TLS" : "Does not verify TLS") }
            return parts.isEmpty ? "Application settings" : parts.joined(separator: " · ")
        }
    }

    private static func pairs(_ rows: [KeyValue]) -> String {
        rows.map { row in
            let value = row.isSecret && !row.value.isEmpty ? RequestText.sealed(row.value) : row.value
            return "\(row.isEnabled ? "" : "(off) ")\(row.key)=\(value)"
        }
        .joined(separator: "  ")
    }

    private static func script(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).count
        return lines == 0 ? "Empty" : RequestText.counted(lines, "line", "lines") + "  ·  " + RequestText.folded(text, limit: 80)
    }
}
