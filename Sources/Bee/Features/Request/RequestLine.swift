import BeeCore
import SwiftUI

/// The request line at full width: Method, URL, Send, and under it where the request goes.
struct RequestLineView: View {
    @Environment(AppModel.self) private var model
    let session: RequestSession
    /// The address as typed. The model holds it split (base + parameter rows), which cannot
    /// represent a half-typed query, so the field edits this text and writes the split form through.
    @ViewState private var addressText: String

    init(session: RequestSession) {
        self.session = session
        _addressText = ViewState(
            initialValue: URLTemplate.join(base: session.item.url, params: session.item.queryParams)
        )
    }

    /// Wide enough for the longest method, so the line does not move when the method changes.
    private static let methodWidth = Theme.Space.xxl * 3 + Theme.Space.s

    private var address: String {
        URLTemplate.join(base: session.item.url, params: session.item.queryParams)
    }

    private var isAddressEmpty: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var session = session
        let context = model.variableContext(collectionID: session.collectionID)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text("Method").requestCaption().frame(width: Self.methodWidth, alignment: .leading)
                Text("URL").requestCaption()
            }
            HStack(spacing: Theme.Space.s) {
                RequestPopUp(
                    "Method", selection: $session.item.method,
                    options: HTTPMethod.allCases.map { RequestPopUpOption(value: $0, title: $0.rawValue) },
                    font: Theme.mono(Theme.Size.headline, weight: .semibold), isStretched: true
                )
                .frame(width: Self.methodWidth)
                TemplateField(
                    "https://api.example.com/path", text: addressBinding, context: context,
                    size: Theme.Size.headline, pathVariables: session.item.pathVariables
                ) { send() }
                sendButton
                moreMenu
            }
            .fixedSize(horizontal: false, vertical: true)
            DestinationCaption(destination: destination(in: context))
                .padding(.leading, Self.methodWidth + Theme.Space.s)
        }
        // The line starts on the text column of the pages below (their chevrons hang in the gutter).
        .padding(.leading, Theme.Layout.pageInset + Theme.Layout.gutter)
        .padding(.trailing, Theme.Layout.pageInset)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
        .onChange(of: address) { _, newValue in resync(with: newValue) }
    }

    // MARK: Address

    private var addressBinding: Binding<String> {
        Binding(
            get: { addressText },
            set: { newValue in
                guard newValue != addressText else { return }
                let isPaste = newValue.count - addressText.count > 1
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if isPaste, trimmed.lowercased().hasPrefix("curl ") {
                    replaceContent(withCurl: trimmed)
                } else {
                    addressText = newValue
                    write(newValue)
                }
            }
        )
    }

    /// Writes the typed address back as base + rows; rows keep their identity and secrets stay masked.
    private func write(_ text: String) {
        let parsed = URLTemplate.split(text)
        var item = session.item
        item.pathVariables = session.pathVariables(for: parsed.base)
        item.url = parsed.base
        let previous = item.queryParams
        item.queryParams = URLTemplate.merge(parsed: parsed.params, into: previous).map { row in
            // Typing next to the mask of a secret must not store the mask: secrets are edited in
            // the Parameters table, where they stay sealed.
            guard row.isSecret, row.value.contains("•"),
                  let kept = previous.first(where: { $0.id == row.id }) else { return row }
            var row = row
            row.value = kept.value
            return row
        }
        session.item = item
    }

    /// Takes a change made elsewhere (the Parameters table) unless the typed text already means it.
    private func resync(with joined: String) {
        let parsed = URLTemplate.split(addressText)
        let typed = URLTemplate.join(
            base: parsed.base, params: URLTemplate.merge(parsed: parsed.params, into: session.item.queryParams)
        )
        let showsSecret = session.item.queryParams.contains { $0.isSecret && $0.isEnabled }
        // With a secret row the field always shows the joined (masked) form, never what was typed.
        if typed != joined || (showsSecret && addressText != joined) { addressText = joined }
    }

    /// A pasted cURL command replaces the request's content; the request keeps its id and name.
    private func replaceContent(withCurl command: String) {
        do {
            var parsed = try CurlCodec.parse(command)
            parsed.id = session.item.id
            parsed.name = session.item.name
            session.item = parsed
            addressText = URLTemplate.join(base: parsed.url, params: parsed.queryParams)
        } catch {
            model.report(error)
        }
    }

    // MARK: Send

    private func send() {
        guard !isAddressEmpty, !session.isSending else { return }
        model.send(session)
    }

    private var sendButton: some View {
        Button {
            if session.isSending { model.cancel(session) } else { send() }
        } label: {
            // Both words are laid out so the capsule keeps its width when Send becomes Cancel.
            ZStack {
                Text("Cancel").hidden()
                Text("Send").hidden()
                Text(session.isSending ? "Cancel" : "Send")
            }
        }
        .buttonStyle(SendButtonStyle())
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!session.isSending && isAddressEmpty)
        .help(session.isSending ? "Cancel the request" : "Send the request (⌘↩)")
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy as cURL") { model.copy(model.curlCommand(for: session)) }
            Button("Duplicate") { model.duplicateRequest(session.id) }
            if session.collectionID == nil, !model.workspace.collections.isEmpty {
                Menu("Keep in collection") {
                    ForEach(model.workspace.collections) { collection in
                        Button(collection.name) {
                            model.moveNode(session.id, toCollection: collection.id, folder: nil)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.text(Theme.Size.headline))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: Theme.Space.xl, height: Theme.Space.xl)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions")
        .help("More actions")
    }

    // MARK: Destination

    /// Where the request goes, with every secret sealed before anything is drawn.
    private func destination(in context: VariableContext) -> Destination {
        let joined = address
        guard !isAddressEmpty else { return .empty }
        let pathVariables = session.item.pathVariables
        // The address and the templates that give its path variables their values.
        let templates = [joined] + PathVariables.names(in: joined).map {
            PathVariables.valueTemplate(for: $0, in: pathVariables)
        }
        let usesVariables = templates.contains { template in
            TemplateEngine.tokens(in: template).contains { token in
                if case .variable = token.kind { true } else { false }
            }
        }
        // What is drawn is the masked twin of the render: a secret is hidden where it is put in, so a
        // short one cannot slip past the redactor.
        let result = PathVariables.render(joined, rows: pathVariables, in: context)

        let hasEnvironment = model.workspace.activeEnvironment != nil
        if !result.unresolved.isEmpty {
            return hasEnvironment || !usesVariables
                ? .unknown(result.unresolved) : .noEnvironment(result.unresolved)
        }
        let secrets = (context.environment + context.collection + context.globals)
            .filter(\.isSecret).map(\.value) + session.item.secretValues()
        return .resolved(Redactor(secrets: secrets).redact(result.shown))
    }
}

// MARK: - Destination caption

private enum Destination: Equatable {
    case empty
    case resolved(String)
    case unknown([String])
    case noEnvironment([String])
}

/// The one line under the request line. It always holds its height so nothing moves.
private struct DestinationCaption: View {
    let destination: Destination

    var body: some View {
        Group {
            switch destination {
            case .empty:
                Text("Enter a URL, or paste a cURL command.")
                    .foregroundStyle(Theme.inkTertiary)
            case .resolved(let address):
                Text("Sends to \(Text(address).font(Theme.mono(Theme.Size.caption)))")
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
            case .unknown(let names):
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(names.count == 1 ? "Unknown variable" : "Unknown variables") \(wire(names))")
                }
                .foregroundStyle(Theme.warning)
            case .noEnvironment(let names):
                Text("No active environment, so \(wire(names)) \(names.count == 1 ? "has" : "have") no value.")
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .font(Theme.text(Theme.Size.caption))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wire(_ names: [String]) -> Text {
        Text(names.map { "{{\($0)}}" }.joined(separator: ", ")).font(Theme.mono(Theme.Size.caption))
    }
}
