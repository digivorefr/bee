import BeeCore
import SwiftUI

// MARK: - Page furniture

/// A document page: one scrolling column inset from the edges. Section chevrons and row
/// checkboxes hang in the gutter; everything else starts after it.
private struct DocumentPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                content
            }
            .padding(Theme.Layout.pageInset)
            .frame(maxWidth: ShellMetrics.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    /// Starts after the gutter, in line with section headings.
    func afterGutter() -> some View { padding(.leading, Theme.Layout.gutter) }
}

/// The name of the page, editable in place. Its outline shows while it is pointed at or edited.
private struct NameHeadline: View {
    @Binding var name: String
    let label: String
    @FocusState private var isFocused: Bool
    @ViewState private var isHovered = false

    var body: some View {
        TextField(label, text: $name)
            .textFieldStyle(.plain)
            .font(Theme.text(Theme.Size.headline, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .focused($isFocused)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(isFocused ? Theme.focus : Theme.outline, lineWidth: isFocused ? 2 : 1)
                    .opacity(isFocused || isHovered ? 1 : 0)
            )
            .padding(.horizontal, -Theme.Space.s)
            .onHover { isHovered = $0 }
            .accessibilityLabel(label)
    }
}

private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.text(Theme.Size.caption))
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SecretsCaption: View {
    var body: some View {
        Caption(
            "Secrets are encrypted on this Mac with a key kept in your Keychain. "
                + "They are never written to collection files, history or exports."
        )
    }
}

private struct QuietSummary: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.text())
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct NotesField: View {
    @Binding var notes: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Notes")
                .font(Theme.text(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary)
            TextField("Add notes", text: $notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.text())
                .foregroundStyle(Theme.ink)
                .lineLimit(2...12)
                .focused($isFocused)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.s)
                .outlined(isFocused: isFocused)
                .accessibilityLabel("Notes")
        }
    }
}

/// The parts of a collection or folder page.
private enum PagePart: Hashable {
    case variables, authorization, preRequestScript, postResponseScript
}

private func variablesSummary(_ variables: [Variable]) -> String {
    let names = variables.map(\.name).filter { !$0.isEmpty }
    return names.isEmpty ? "None" : names.joined(separator: ", ")
}

private func authorizationSummary(_ auth: AuthConfig) -> String {
    switch auth.kind {
    case .inherit: "Inherited from the parent"
    case .none: "None"
    case .bearer: "Bearer token"
    case .basic: "Basic"
    case .apiKey: "API key"
    }
}

private func scriptSummary(_ script: String) -> String {
    let lines = script.split(separator: "\n", omittingEmptySubsequences: true).count
    return lines == 0 ? "Empty" : (lines == 1 ? "1 line" : "\(lines) lines")
}

/// The table with its checkboxes hanging in the gutter, so names line up with the headings.
private struct HangingVariablesTable: View {
    @Binding var variables: [Variable]
    let context: VariableContext

    var body: some View {
        VariablesTable(variables: $variables, context: context)
            .padding(.leading, -Theme.Space.xl)
    }
}

// MARK: - Environment

struct EnvironmentPageView: View {
    @Environment(AppModel.self) private var model
    let environmentID: UUID

    var body: some View {
        if let environment = model.environment(id: environmentID) {
            let isActive = model.workspace.activeEnvironmentID == environmentID
            DocumentPage {
                Group {
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        NameHeadline(name: binding(\.name, default: ""), label: "Environment name")
                        Spacer(minLength: Theme.Space.m)
                        if isActive {
                            Text("Active")
                                .font(Theme.text())
                                .foregroundStyle(Theme.inkSecondary)
                        } else {
                            Button("Make active") { model.setActiveEnvironment(environmentID) }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    }
                    HangingVariablesTable(
                        variables: binding(\.variables, default: []),
                        context: VariableContext(environment: environment.variables, globals: model.workspace.globals)
                    )
                    SecretsCaption()
                }
                .afterGutter()
            }
        } else {
            EmptyDetailView()
        }
    }

    /// Reads the current value from the model each time, and writes it back at once.
    private func binding<Value>(_ keyPath: WritableKeyPath<BeeCore.Environment, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { model.environment(id: environmentID)?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var current = model.environment(id: environmentID) else { return }
                current[keyPath: keyPath] = value
                model.updateEnvironment(current)
            }
        )
    }
}

// MARK: - Globals

struct GlobalsPageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DocumentPage {
            Group {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Globals")
                        .font(Theme.text(Theme.Size.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Caption("Variables every request can use, whatever the active environment.")
                }
                HangingVariablesTable(
                    variables: Binding(get: { model.workspace.globals }, set: { model.updateGlobals($0) }),
                    context: VariableContext(
                        environment: model.workspace.activeEnvironment?.variables ?? [],
                        globals: model.workspace.globals
                    )
                )
                SecretsCaption()
            }
            .afterGutter()
        }
    }
}

// MARK: - Collection

struct CollectionPageView: View {
    @Environment(AppModel.self) private var model
    let collectionID: UUID
    @ViewState private var expanded: Set<PagePart> = [.variables, .authorization]
    @ViewState private var isSeeded = false

    var body: some View {
        if let collection = model.collection(id: collectionID) {
            let context = model.variableContext(collectionID: collectionID)
            DocumentPage {
                Group {
                    NameHeadline(name: binding(\.name, default: ""), label: "Collection name")
                    NotesField(notes: binding(\.notes, default: ""))
                }
                .afterGutter()

                DocumentSection(
                    "Variables", count: collection.variables.isEmpty ? nil : collection.variables.count,
                    isExpanded: isExpanded(.variables)
                ) {
                    QuietSummary(variablesSummary(collection.variables))
                } content: {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HangingVariablesTable(variables: binding(\.variables, default: []), context: context)
                        SecretsCaption()
                    }
                }

                DocumentSection("Authorization", isExpanded: isExpanded(.authorization)) {
                    QuietSummary(authorizationSummary(collection.auth))
                } content: {
                    AuthEditor(
                        auth: binding(\.auth, default: AuthConfig(kind: .none)), allowsInherit: false, context: context
                    )
                }

                DocumentSection("Pre-request script", isExpanded: isExpanded(.preRequestScript)) {
                    QuietSummary(scriptSummary(collection.preRequestScript))
                } content: {
                    CodeEditor(text: binding(\.preRequestScript, default: ""), language: .javascript, context: context)
                }

                DocumentSection("Post-response script", isExpanded: isExpanded(.postResponseScript)) {
                    QuietSummary(scriptSummary(collection.postResponseScript))
                } content: {
                    CodeEditor(text: binding(\.postResponseScript, default: ""), language: .javascript, context: context)
                }

                Caption("These scripts run for every request in this collection, before the request's own scripts.")
                    .afterGutter()
            }
            .onAppear {
                guard !isSeeded else { return }
                isSeeded = true
                if !collection.preRequestScript.isEmpty { expanded.insert(.preRequestScript) }
                if !collection.postResponseScript.isEmpty { expanded.insert(.postResponseScript) }
            }
        } else {
            EmptyDetailView()
        }
    }

    private func isExpanded(_ part: PagePart) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(part) },
            set: { if $0 { expanded.insert(part) } else { expanded.remove(part) } }
        )
    }

    /// Reads the current value from the model each time; `updateCollection` keeps the tree of items.
    private func binding<Value>(_ keyPath: WritableKeyPath<Collection, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { model.collection(id: collectionID)?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var current = model.collection(id: collectionID) else { return }
                current[keyPath: keyPath] = value
                model.updateCollection(current)
            }
        )
    }
}

// MARK: - Folder

struct FolderPageView: View {
    @Environment(AppModel.self) private var model
    let folderID: UUID
    @ViewState private var expanded: Set<PagePart> = [.authorization]
    @ViewState private var isSeeded = false

    var body: some View {
        if let folder = model.folder(id: folderID) {
            let context = model.variableContext(collectionID: model.workspace.collection(containing: folderID)?.id)
            DocumentPage {
                Group {
                    NameHeadline(name: binding(\.name, default: ""), label: "Folder name")
                    NotesField(notes: binding(\.notes, default: ""))
                }
                .afterGutter()

                DocumentSection("Authorization", isExpanded: isExpanded(.authorization)) {
                    QuietSummary(authorizationSummary(folder.auth))
                } content: {
                    AuthEditor(auth: binding(\.auth, default: AuthConfig()), allowsInherit: true, context: context)
                }

                DocumentSection("Pre-request script", isExpanded: isExpanded(.preRequestScript)) {
                    QuietSummary(scriptSummary(folder.preRequestScript))
                } content: {
                    CodeEditor(text: binding(\.preRequestScript, default: ""), language: .javascript, context: context)
                }

                DocumentSection("Post-response script", isExpanded: isExpanded(.postResponseScript)) {
                    QuietSummary(scriptSummary(folder.postResponseScript))
                } content: {
                    CodeEditor(text: binding(\.postResponseScript, default: ""), language: .javascript, context: context)
                }

                Caption("These scripts run for every request in this folder, after the collection's and before the request's own.")
                    .afterGutter()
            }
            .onAppear {
                guard !isSeeded else { return }
                isSeeded = true
                if !folder.preRequestScript.isEmpty { expanded.insert(.preRequestScript) }
                if !folder.postResponseScript.isEmpty { expanded.insert(.postResponseScript) }
            }
        } else {
            EmptyDetailView()
        }
    }

    private func isExpanded(_ part: PagePart) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(part) },
            set: { if $0 { expanded.insert(part) } else { expanded.remove(part) } }
        )
    }

    /// Reads the current value from the model each time; `updateFolder` keeps the folder's items.
    private func binding<Value>(_ keyPath: WritableKeyPath<Folder, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { model.folder(id: folderID)?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var current = model.folder(id: folderID) else { return }
                current[keyPath: keyPath] = value
                model.updateFolder(current)
            }
        )
    }
}
