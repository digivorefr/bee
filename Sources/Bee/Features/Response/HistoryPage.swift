import AppKit
import BeeCore
import SwiftUI

/// The record of what was sent, newest first, grouped by day.
struct HistoryPageView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var isConfirmingClear = false
    @FocusState private var focusedEntry: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack(alignment: .firstTextBaseline) {
                    Text("History")
                        .font(Theme.text(Theme.Size.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Theme.Space.l)
                    if !model.history.isEmpty {
                        Button("Clear history") { isConfirmingClear = true }
                            .buttonStyle(OutlineButtonStyle())
                    }
                }
                if model.history.isEmpty {
                    Text("Requests you send are kept here, ready to open again.")
                        .font(Theme.text())
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    ForEach(days, id: \.start) { day in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(ResponseFormat.day(day.start))
                                .font(Theme.text(Theme.Size.caption, weight: .semibold))
                                .foregroundStyle(Theme.inkSecondary)
                                .accessibilityAddTraits(.isHeader)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(day.entries) { entry in
                                    HistoryRow(entry: entry, isFocused: focusedEntry == entry.id) {
                                        model.reopen(entry)
                                    }
                                    .focusable()
                                    .focused($focusedEntry, equals: entry.id)
                                    .focusEffectDisabled()
                                    .onKeyPress(.return) {
                                        model.reopen(entry)
                                        return .handled
                                    }
                                    .onKeyPress(.downArrow) { moveFocus(by: 1) }
                                    .onKeyPress(.upArrow) { moveFocus(by: -1) }
                                    .contextMenu {
                                        Button("Open") { model.reopen(entry) }
                                        Button("Delete", role: .destructive) { model.removeHistory(entry.id) }
                                    }
                                }
                            }
                            // The ground of a row extends into the margin so its text stays on the page edge.
                            .padding(.horizontal, -Theme.Space.s)
                        }
                    }
                }
            }
            .padding(Theme.Layout.pageInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("Clear the history?", isPresented: $isConfirmingClear) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(model.history.count == 1 ? "1 entry" : "\(model.history.count) entries"). Your collections are not changed. This cannot be undone.")
        }
    }

    private var days: [(start: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var result: [(start: Date, entries: [HistoryEntry])] = []
        for entry in model.history {
            let start = calendar.startOfDay(for: entry.date)
            if let last = result.indices.last, result[last].start == start {
                result[last].entries.append(entry)
            } else {
                result.append((start: start, entries: [entry]))
            }
        }
        return result
    }

    private func moveFocus(by offset: Int) -> KeyPress.Result {
        guard let current = focusedEntry, let index = model.history.firstIndex(where: { $0.id == current }) else {
            return .ignored
        }
        let target = index + offset
        guard model.history.indices.contains(target) else { return .handled }
        focusedEntry = model.history[target].id
        return .handled
    }
}

/// One exchange on one bare line: when, the method, the address called, how it ended, how long it took.
private struct HistoryRow: View {
    let entry: HistoryEntry
    let isFocused: Bool
    let open: () -> Void
    @ViewState private var isHovered = false

    private static let timeWidth = Theme.Space.xxl * 2
    private static let methodWidth = Theme.Space.xxl + Theme.Space.xl
    private static let durationWidth = Theme.Space.xxl * 2
    private static let errorMaxWidth = Theme.Space.xxl * 9

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(ResponseFormat.clock(entry.date))
                .font(Theme.text())
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: Self.timeWidth, alignment: .leading)
            MethodLabel(method: entry.request.method)
                .frame(width: Self.methodWidth, alignment: .leading)
            Text(entry.resolvedURL.isEmpty ? entry.request.url : entry.resolvedURL)
                .font(Theme.mono())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            result
            Text(entry.duration.map(ResponseFormat.duration) ?? "")
                .font(Theme.text())
                .monospacedDigit()
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: Self.durationWidth, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(
            isHovered || isFocused ? Theme.rowHover : .clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the request")
        .accessibilityAction(.default, open)
    }

    @ViewBuilder private var result: some View {
        if let code = entry.statusCode {
            StatusMark(code: code, text: entry.statusText ?? "", size: Theme.Size.caption)
                .lineLimit(1)
        } else if entry.errorMessage == TransportError.cancelled.errorDescription {
            Text("Cancelled")
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
        } else {
            let message = entry.errorMessage ?? "No response"
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Image(systemName: "xmark.circle.fill")
                    .font(Theme.text(Theme.Size.caption))
                    .accessibilityHidden(true)
                Text(message)
                    .font(Theme.text())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(Theme.negative)
            .frame(maxWidth: Self.errorMaxWidth, alignment: .trailing)
            .help(message)
        }
    }
}
