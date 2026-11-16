import BeeCore
import SwiftUI

/// The request as a document: only the parts it has, in wire order, then the Add row.
struct RequestPageView: View {
    let session: RequestSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(session.visibleSections) { section in
                    RequestSectionView(session: session, section: section)
                }
                RequestAddRow(session: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Layout.pageInset)
        }
    }
}

// MARK: - One section

private struct RequestSectionView: View {
    @Environment(AppModel.self) private var model
    let session: RequestSession
    let section: RequestSection
    @ViewState private var isHovered = false

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { session.expandedRequestSections.contains(section) },
            set: { isOpen in
                if isOpen {
                    session.expandedRequestSections.insert(section)
                } else {
                    session.expandedRequestSections.remove(section)
                }
            }
        )
    }

    private var count: Int? {
        switch section {
        case .parameters: session.item.queryParams.count
        case .headers: session.item.headers.count
        default: nil
        }
    }

    var body: some View {
        let context = model.variableContext(collectionID: session.collectionID)
        DocumentSection(section.title, count: count, isExpanded: isExpanded) {
            RequestSectionSummary(item: session.item, section: section, context: context)
        } accessory: {
            HStack(spacing: Theme.Space.m) {
                Button("Remove") { session.remove(section) }
                    .buttonStyle(QuietButtonStyle())
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityLabel("Remove \(section.title)")
                    .help("Remove \(section.title) from the request")
                if isExpanded.wrappedValue { actions }
            }
        } content: {
            content(context)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        // A part on the page stays there while it is edited, even emptied; Remove takes it off.
        .onAppear { session.addedRequestSections.insert(section) }
    }

    @ViewBuilder
    private func content(_ context: VariableContext) -> some View {
        @Bindable var session = session
        switch section {
        case .parameters:
            KeyValueTable(rows: $session.item.queryParams, noun: "parameter", context: context)
        case .authorization:
            AuthEditor(auth: $session.item.auth, allowsInherit: true, context: context)
        case .headers:
            KeyValueTable(rows: $session.item.headers, noun: "header", context: context, sealsSensitiveNames: true)
        case .body:
            BodyEditor(body: $session.item.body, context: context)
        case .preRequestScript:
            CodeEditor(text: $session.item.preRequestScript, language: .javascript, context: context)
        case .postResponseScript:
            CodeEditor(text: $session.item.postResponseScript, language: .javascript, context: context)
        case .settings:
            RequestSettingsEditor(settings: $session.item.settings)
        }
    }

    /// What an open section offers beside its heading.
    @ViewBuilder
    private var actions: some View {
        @Bindable var session = session
        switch section {
        case .body:
            RequestPopUp(
                "Body format",
                selection: Binding(
                    get: { BodyFormat(session.item.body) },
                    set: { format in format.apply(to: &session.item.body) }
                ),
                options: BodyFormat.options
            )
        case .preRequestScript:
            ScriptExamplesMenu(examples: ScriptExample.preRequest, script: $session.item.preRequestScript)
        case .postResponseScript:
            ScriptExamplesMenu(examples: ScriptExample.postResponse, script: $session.item.postResponseScript)
        default:
            EmptyView()
        }
    }
}

// MARK: - Resting summaries

/// The one line a closed section rests as.
private struct RequestSectionSummary: View {
    let item: RequestItem
    let section: RequestSection
    let context: VariableContext

    var body: some View {
        switch section {
        case .parameters:
            PairsSummary(rows: item.queryParams, context: context)
        case .headers:
            PairsSummary(rows: item.headers, context: context)
        case .authorization:
            words(AuthEditor.summary(of: item.auth))
        case .body:
            let summary = BodyEditor.summary(of: item.body)
            HStack(spacing: Theme.Space.s) {
                if let wire = summary.wire { TokenText(wire, context: context) }
                if let text = summary.words { words(text) }
            }
        case .preRequestScript:
            scriptSummary(item.preRequestScript)
        case .postResponseScript:
            scriptSummary(item.postResponseScript)
        case .settings:
            words(Self.settingsSummary(item.settings))
        }
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .font(Theme.text())
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
    }

    /// The first line that is not a comment, then how long the script is.
    private func scriptSummary(_ script: String) -> some View {
        let lines = script.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let first = lines.first { line in
            !line.isEmpty && !line.hasPrefix("//") && !line.hasPrefix("/*") && !line.hasPrefix("*")
        }
        return HStack(spacing: Theme.Space.s) {
            if let first {
                Text(first)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            words(lines.isEmpty ? "Empty" : RequestText.counted(lines.count, "line", "lines"))
                .layoutPriority(1)
        }
    }

    static func settingsSummary(_ settings: RequestSettings) -> String {
        var parts: [String] = []
        if let timeout = settings.timeout {
            parts.append("Timeout \(RequestSettingsEditor.describe(timeout)) s")
        }
        if let follows = settings.followRedirects {
            parts.append(follows ? "Follows redirects" : "Does not follow redirects")
        }
        if let verifies = settings.verifyTLS {
            parts.append(verifies ? "Verifies TLS certificates" : "Does not verify TLS certificates")
        }
        return parts.isEmpty ? "Application settings" : parts.joined(separator: " · ")
    }
}

/// `Name value` pairs in the wire voice, secrets sealed, then `N more`.
private struct PairsSummary: View {
    let rows: [KeyValue]
    let context: VariableContext

    var body: some View {
        let sent = rows.filter { $0.isEnabled && !$0.key.isEmpty }
        if sent.isEmpty {
            Text(rows.isEmpty ? "None" : "None turned on")
                .font(Theme.text())
                .foregroundStyle(Theme.inkSecondary)
        } else {
            ViewThatFits(in: .horizontal) {
                line(sent, limit: 2)
                line(sent, limit: 1)
            }
        }
    }

    private func line(_ sent: [KeyValue], limit: Int) -> some View {
        HStack(spacing: Theme.Space.l) {
            ForEach(sent.prefix(limit)) { row in
                HStack(spacing: Theme.Space.s) {
                    Text(row.key)
                        .font(Theme.mono())
                        .foregroundStyle(Theme.inkSecondary)
                    if row.isSecret, !row.value.isEmpty, !RequestText.isPlaceholderOnly(row.value) {
                        Text(URLTemplate.mask).font(Theme.mono()).foregroundStyle(Theme.ink)
                    } else {
                        TokenText(row.value, context: context)
                    }
                }
            }
            if sent.count > limit {
                Text("\(sent.count - limit) more")
                    .font(Theme.text())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Add row

/// The parts the request does not have, waiting in one quiet row.
private struct RequestAddRow: View {
    let session: RequestSession

    var body: some View {
        let absent = session.absentSections
        let isBare = session.visibleSections.isEmpty
        if isBare || !absent.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if isBare {
                    Text("This request sends its line and nothing else. Add the parts it needs.")
                        .font(Theme.text())
                        .foregroundStyle(Theme.inkSecondary)
                }
                RequestFlowLayout(spacing: Theme.Space.s) {
                    Text("Add")
                        .requestCaption()
                        .padding(.trailing, Theme.Space.xs)
                    ForEach(absent) { section in
                        Button(section.title) { session.add(section) }
                            .buttonStyle(RequestChipButtonStyle())
                            .accessibilityLabel("Add \(section.title)")
                    }
                }
            }
            .padding(.leading, Theme.Layout.gutter)
        }
    }
}

// MARK: - Scripts

struct ScriptExample: Identifiable {
    let title: String
    let code: String

    var id: String { title }

    static let preRequest = [
        ScriptExample(
            title: "Set a request header",
            code: #"bee.request.headers.upsert({ key: "X-Request-Id", value: bee.uuid() })"#
        ),
        ScriptExample(
            title: "Log a variable",
            code: #"console.log(bee.variables.get("baseUrl"))"#
        ),
    ]

    static let postResponse = [
        ScriptExample(
            title: "Keep a token as a secret",
            code: #"bee.environment.set("token", bee.response.json().token, { secret: true })"#
        ),
        ScriptExample(
            title: "Test the status",
            code: #"bee.test("Status is 200", () => bee.response.to.have.status(200))"#
        ),
        ScriptExample(
            title: "Log a variable",
            code: #"console.log(bee.variables.get("baseUrl"))"#
        ),
    ]
}

/// A quiet menu that appends a short snippet to the script.
private struct ScriptExamplesMenu: View {
    let examples: [ScriptExample]
    @Binding var script: String

    var body: some View {
        RequestQuietMenu("Examples") {
            ForEach(examples) { example in
                Button(example.title) { insert(example.code) }
            }
        }
        .help("Insert an example at the end of the script")
    }

    private func insert(_ code: String) {
        if script.isEmpty {
            script = code
        } else {
            script += (script.hasSuffix("\n") ? "" : "\n") + code
        }
    }
}

// MARK: - Settings

/// What this request does differently from the application settings.
struct RequestSettingsEditor: View {
    @Binding var settings: RequestSettings

    private static let choices: [RequestPopUpOption<Bool?>] = [
        RequestPopUpOption(value: nil, title: "Application setting"),
        RequestPopUpOption(value: true, title: "Yes"),
        RequestPopUpOption(value: false, title: "No"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
            GridRow {
                label("Timeout")
                HStack(spacing: Theme.Space.s) {
                    TimeoutField(timeout: $settings.timeout)
                    Text("seconds").font(Theme.text()).foregroundStyle(Theme.inkSecondary)
                }
            }
            GridRow {
                label("Follow redirects")
                RequestPopUp("Follow redirects", selection: $settings.followRedirects, options: Self.choices)
            }
            GridRow {
                label("Verify TLS certificates")
                RequestPopUp("Verify TLS certificates", selection: $settings.verifyTLS, options: Self.choices)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.text()).foregroundStyle(Theme.inkSecondary)
    }

    static func describe(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

/// Seconds as typed; empty means the application setting. Keeps its own text so a half-typed
/// number ("1.") is not rewritten under the caret.
private struct TimeoutField: View {
    @Binding private var timeout: TimeInterval?
    @ViewState private var text: String

    init(timeout: Binding<TimeInterval?>) {
        _timeout = timeout
        _text = ViewState(initialValue: timeout.wrappedValue.map(RequestSettingsEditor.describe) ?? "")
    }

    var body: some View {
        TemplateField("Application setting", text: binding, context: VariableContext())
            .frame(width: RequestMetrics.nameWidth + Theme.Space.xxl)
            .accessibilityLabel("Timeout in seconds")
    }

    private var binding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                text = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    timeout = nil
                } else if let seconds = TimeInterval(trimmed), seconds > 0, seconds.isFinite {
                    timeout = seconds
                }
            }
        )
    }
}
