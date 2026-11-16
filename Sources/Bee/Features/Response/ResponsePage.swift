import AppKit
import BeeCore
import SwiftUI

/// The response as the facing page: the status line, then Headers, Body, Tests, Variables set,
/// Console, Request sent. Only the sections that have content are on the page.
struct ResponsePageView: View {
    let session: RequestSession

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                page
                    .padding(Theme.Layout.pageInset)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
        // Until a response is on the page, the comb waits in its far corner; honey flows through
        // it while the request is in flight.
        .background(alignment: .bottomTrailing) {
            if session.isSending || session.outcome == nil {
                CombField(flowingSince: session.isSending ? session.sendStartedAt ?? Date() : nil)
            }
        }
        .clipped()
    }

    @ViewBuilder private var page: some View {
        if session.isSending {
            SendingStatusLine(startedAt: session.sendStartedAt ?? Date())
        } else if let outcome = session.outcome {
            ArrivingResponse(receivedAt: session.receivedAt) {
                OutcomeView(session: session, outcome: outcome)
            }
            .id(session.receivedAt)
        } else {
            NeverSentLine()
        }
    }
}

// MARK: - Never sent

private struct NeverSentLine: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("Send the request to see its response")
            Text("⌘↩")
                .font(Theme.text(Theme.Size.caption))
                .accessibilityLabel("Command Return")
        }
        .font(Theme.text())
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Arrival

/// Fades a response in when it has just arrived (opacity only). A response that was already there,
/// as when a request is selected again, appears at once.
private struct ArrivingResponse<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var opacity: Double
    private let content: Content

    init(receivedAt: Date?, @ViewBuilder content: () -> Content) {
        let hasJustArrived = receivedAt.map { Date().timeIntervalSince($0) < 0.5 } ?? false
        _opacity = ViewState(initialValue: hasJustArrived ? 0 : 1)
        self.content = content()
    }

    var body: some View {
        content
            .opacity(opacity)
            .onAppear {
                guard opacity < 1 else { return }
                if reduceMotion {
                    opacity = 1
                } else {
                    withAnimation(Theme.Motion.arrive) { opacity = 1 }
                }
            }
    }
}

// MARK: - Status line

private struct FactLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Theme.text(Theme.Size.caption))
            .foregroundStyle(Theme.inkSecondary)
    }
}

/// The status line while the request is on its way: a busy mark and the time counting where it
/// will be read.
private struct SendingStatusLine: View {
    let startedAt: Date

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.s) {
            GridRow {
                FactLabel("Status")
                FactLabel("Time")
            }
            GridRow(alignment: .center) {
                HStack(spacing: Theme.Space.s) {
                    CombSpinner()
                    Text("Sending…")
                        .font(Theme.text(Theme.Size.headline, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                    Text(String(format: "%.1f s", max(context.date.timeIntervalSince(startedAt), 0)))
                        .font(Theme.text())
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("Elapsed time")
            }
        }
    }
}

/// The headline of a response: Status, Time, Size, then where it came from.
private struct StatusLine: View {
    let session: RequestSession
    let outcome: RunOutcome
    let response: HTTPResponse
    @ViewState private var isShowingTimings = false
    @ViewState private var isTimeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.s) {
                GridRow {
                    FactLabel("Status")
                    FactLabel("Time")
                    FactLabel("Size")
                }
                GridRow(alignment: .firstTextBaseline) {
                    StatusMark(code: response.statusCode, text: response.statusText, size: Theme.Size.headline)
                        .textSelection(.enabled)
                    timeFact
                    Text(ResponseFormat.size(response.size))
                        .font(Theme.text())
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                }
            }
            Text(origin)
                .font(Theme.text(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary)
            if !outcome.unresolvedVariables.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Theme.text(Theme.Size.caption))
                        .accessibilityHidden(true)
                    Text("Sent with unknown variables: \(Text(unknownVariables).font(Theme.mono()))")
                        .font(Theme.text())
                        .textSelection(.enabled)
                }
                .foregroundStyle(Theme.warning)
            }
        }
    }

    private var timeFact: some View {
        Button {
            isShowingTimings.toggle()
        } label: {
            Text(ResponseFormat.duration(response.duration))
                .font(Theme.text())
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.Space.xs)
                .background(
                    isTimeHovered || isShowingTimings ? Theme.rowHover : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
                )
                .padding(.horizontal, -Theme.Space.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isTimeHovered = $0 }
        .help("Show the timing details")
        .accessibilityLabel("Time, \(ResponseFormat.duration(response.duration))")
        .accessibilityHint("Shows the timing details")
        .popover(isPresented: $isShowingTimings, arrowEdge: .bottom) {
            TimingDetails(response: response)
        }
    }

    private var origin: String {
        let time = ResponseFormat.clock(session.receivedAt ?? outcome.historyEntry.date)
        if let name = session.sentEnvironmentName, !name.isEmpty {
            return "From \(name) at \(time)"
        }
        return "No environment, at \(time)"
    }

    private var unknownVariables: String {
        outcome.unresolvedVariables.map { "{{\($0)}}" }.joined(separator: ", ")
    }
}

/// Where the time went, as plain rows; only the phases that happened.
private struct TimingDetails: View {
    let response: HTTPResponse

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.s) {
                ForEach(phases, id: \.name) { phase in
                    row(phase.name, ResponseFormat.duration(phase.duration), isWire: false)
                }
                row("Total", ResponseFormat.duration(response.duration), isWire: false)
            }
            if !connection.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.s) {
                    ForEach(connection, id: \.name) { fact in
                        row(fact.name, fact.value, isWire: true)
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .textSelection(.enabled)
    }

    private var phases: [(name: String, duration: TimeInterval)] {
        let timings = response.timings
        let all: [(String, TimeInterval?)] = [
            ("DNS", timings.dns), ("Connect", timings.connect), ("TLS", timings.tls),
            ("First byte", timings.firstByte), ("Download", timings.download),
        ]
        return all.compactMap { name, duration in duration.map { (name: name, duration: $0) } }
    }

    /// The HTTP version and the remote address, when known.
    private var connection: [(name: String, value: String)] {
        var facts: [(name: String, value: String)] = []
        if !response.httpVersion.isEmpty { facts.append((name: "Version", value: response.httpVersion)) }
        if let address = response.remoteAddress, !address.isEmpty {
            facts.append((name: "Remote address", value: address))
        }
        return facts
    }

    private func row(_ name: String, _ value: String, isWire: Bool) -> some View {
        GridRow {
            Text(name)
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
            Text(value)
                .font(isWire ? Theme.mono() : Theme.text())
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .gridColumnAlignment(isWire ? .leading : .trailing)
        }
    }
}

// MARK: - No response

/// What happened and what to do about it, when the exchange gave no response.
private struct FailureHeadline: View {
    let session: RequestSession
    let outcome: RunOutcome

    var body: some View {
        if outcome.wasCancelled {
            Text("Cancelled")
                .font(Theme.text(Theme.Size.headline))
                .foregroundStyle(Theme.inkSecondary)
        } else {
            let copy = FailureCopy(message: outcome.errorMessage, hasOwnPreRequestScript: session.has(.preRequestScript))
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    CellMark("xmark", color: Theme.negative, size: Theme.Size.headline)
                        .accessibilityHidden(false)
                        .accessibilityLabel("Failed")
                    Text(copy.headline)
                        .font(Theme.text(Theme.Size.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
                Text(copy.advice)
                    .font(Theme.text())
                    .foregroundStyle(Theme.inkSecondary)
                if copy.opensPreRequestScript {
                    Button("Open pre-request script") {
                        session.expandedRequestSections.insert(.preRequestScript)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .padding(.top, Theme.Space.xs)
                }
            }
        }
    }
}

/// Splits what the core reports into what happened (the headline) and what to do (one sentence).
struct FailureCopy {
    var headline: String
    var advice: String
    var opensPreRequestScript = false

    init(message: String?, hasOwnPreRequestScript: Bool) {
        let message = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let checkNetwork = "Check the address and your network connection, then send again."
        if message.isEmpty {
            headline = "No response"
            advice = checkNetwork
        } else if message.hasPrefix("Pre-request script failed") {
            headline = message
            if hasOwnPreRequestScript {
                advice = "Open the pre-request script, fix the error, then send again."
                opensPreRequestScript = true
            } else {
                advice = "The script belongs to the collection or a folder of this request. Fix it there, then send again."
            }
        } else if message == TransportError.timedOut.errorDescription {
            headline = message
            advice = "The server took too long to answer. Send again, or allow more time in the request settings."
        } else if message.hasPrefix("The request has no URL") {
            headline = message
            advice = "Enter a URL in the request line, then send."
        } else if message.hasPrefix("Invalid URL") {
            headline = message
            advice = "Check the address and the variables it uses, then send again."
        } else if message.hasPrefix("File not found") {
            headline = message
            advice = "Choose the file again in the request body, then send again."
        } else if message.hasPrefix("Invalid GraphQL variables") {
            headline = message
            advice = "Fix the GraphQL variables in the request body, then send again."
        } else if let split = [". ", "? ", "! "].compactMap({ message.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            // The core already says what to do: its first sentence is the headline.
            headline = String(message[..<message.index(after: split.lowerBound)])
            advice = String(message[split.upperBound...])
        } else {
            headline = message
            advice = checkNetwork
        }
    }
}

// MARK: - Outcome

/// The last exchange: its headline, then its sections.
private struct OutcomeView: View {
    @Environment(AppModel.self) private var model
    let session: RequestSession
    let outcome: RunOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            if let response = outcome.response {
                StatusLine(session: session, outcome: outcome, response: response)
                // Headers and body are drawn, copied and saved from the masked copy: a server may
                // echo a credential back.
                let shown = session.shownResponse ?? response
                if session.hidesEchoedSecrets {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Label("Secrets echoed by the server are hidden in this response.", systemImage: "lock.fill")
                            .font(Theme.text(Theme.Size.caption))
                            .foregroundStyle(Theme.inkSecondary)
                        Button("Reveal") {
                            Task {
                                guard await model.authorizeReveal() else { return }
                                session.shownResponse = outcome.response
                                session.hidesEchoedSecrets = false
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                        .font(Theme.text(Theme.Size.caption))
                        .help("Show the response as received, after Touch ID or your password")
                    }
                }
                if !shown.headers.isEmpty {
                    HeadersSection(headers: shown.headers, isExpanded: isExpanded(.headers))
                }
                if !shown.body.isEmpty {
                    ResponseBodySection(response: shown, isExpanded: isExpanded(.body))
                }
            } else {
                FailureHeadline(session: session, outcome: outcome)
            }
            if !outcome.tests.isEmpty {
                TestsSection(tests: outcome.tests, isExpanded: isExpanded(.tests))
            }
            if !outcome.variableChanges.isEmpty {
                VariablesSetSection(session: session, changes: outcome.variableChanges, isExpanded: isExpanded(.variablesSet))
            }
            if !outcome.console.isEmpty {
                ConsoleSection(entries: outcome.console, isExpanded: isExpanded(.console))
            }
            if let sent = outcome.sentRequest {
                RequestSentSection(sent: sent, isExpanded: isExpanded(.requestSent))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isExpanded(_ section: ResponseSection) -> Binding<Bool> {
        Binding(
            get: { session.expandedResponseSections.contains(section) },
            set: { isOpen in
                if isOpen {
                    session.expandedResponseSections.insert(section)
                } else {
                    session.expandedResponseSections.remove(section)
                }
            }
        )
    }
}
