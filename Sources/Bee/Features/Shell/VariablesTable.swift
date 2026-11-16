import BeeCore
import SwiftUI

/// The variables of an environment, a collection or the globals: bare rows, no grid lines.
/// A secret value is never drawn; making it plain again asks for authentication first.
struct VariablesTable: View {
    @Environment(AppModel.self) private var model
    @Binding private var variables: [Variable]
    private let context: VariableContext?
    /// Rows added here whose lock the person has not set: their name decides it.
    @ViewState private var undecided: Set<UUID> = []
    @FocusState private var focusedName: UUID?

    init(variables: Binding<[Variable]>, context: VariableContext? = nil) {
        _variables = variables
        self.context = context
    }

    /// Rows are bound by id: an index binding can outlive its row when one is removed mid-edit.
    private func binding(for variable: Variable) -> Binding<Variable> {
        let id = variable.id
        return Binding(
            get: { variables.first { $0.id == id } ?? variable },
            set: { updated in
                if let index = variables.firstIndex(where: { $0.id == id }) { variables[index] = updated }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !variables.isEmpty { captions }
            ForEach(variables) { variable in
                VariableRow(
                    variable: binding(for: variable),
                    context: context ?? model.variableContext(collectionID: nil),
                    focusedName: $focusedName,
                    onNameChange: { name in applyHeuristics(to: variable.id, name: name) },
                    onToggleSecret: { toggleSecret(variable.id) },
                    onRemove: { remove(variable.id) }
                )
            }
            Button {
                add()
            } label: {
                Label("Add variable", systemImage: "plus")
                    .frame(height: ShellMetrics.tableRow)
                    .padding(.leading, Theme.Space.xl)
            }
            .buttonStyle(QuietButtonStyle())
        }
    }

    private var captions: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Variable")
                .frame(width: ShellMetrics.variableNameColumn, alignment: .leading)
            Text("Value")
            Spacer(minLength: 0)
        }
        .font(Theme.text(Theme.Size.caption))
        .foregroundStyle(Theme.inkSecondary)
        .padding(.leading, Theme.Space.xl)
        .frame(height: Theme.Space.xl)
    }

    private func add() {
        let variable = Variable()
        undecided.insert(variable.id)
        variables.append(variable)
        // The row exists on the next pass; focus it then.
        Task { focusedName = variable.id }
    }

    private func remove(_ id: UUID) {
        undecided.remove(id)
        variables.removeAll { $0.id == id }
    }

    /// A new variable named like a credential starts as a secret. The lock only opens again by
    /// itself while no value was typed, so a value never becomes readable without the person.
    private func applyHeuristics(to id: UUID, name: String) {
        guard undecided.contains(id), let index = variables.firstIndex(where: { $0.id == id }) else { return }
        let sensitive = CredentialHeuristics.looksSensitive(name: name)
        if sensitive, !variables[index].isSecret {
            variables[index].isSecret = true
        } else if !sensitive, variables[index].isSecret, variables[index].value.isEmpty {
            variables[index].isSecret = false
        }
    }

    private func toggleSecret(_ id: UUID) {
        guard let index = variables.firstIndex(where: { $0.id == id }) else { return }
        undecided.remove(id)
        guard variables[index].isSecret else {
            variables[index].isSecret = true
            return
        }
        guard !model.isVaultLocked else {
            model.reportProblem("Secrets are locked, so this value cannot be made plain. Unlock them, then try again.")
            return
        }
        guard !variables[index].value.isEmpty else {
            variables[index].isSecret = false
            return
        }
        Task {
            guard await model.authorizeReveal(),
                  let current = variables.firstIndex(where: { $0.id == id }) else { return }
            variables[current].isSecret = false
        }
    }
}

// MARK: - Row

private struct VariableRow: View {
    @Binding var variable: Variable
    let context: VariableContext
    let focusedName: FocusState<UUID?>.Binding
    let onNameChange: (String) -> Void
    let onToggleSecret: () -> Void
    let onRemove: () -> Void

    @ViewState private var isHovered = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Toggle("Use \(displayName)", isOn: $variable.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .opacity(isHovered || !variable.isEnabled ? 1 : 0)
                    .frame(width: Theme.Space.l)
                    .help(variable.isEnabled ? "Turn off this variable" : "Turn on this variable")
                TextField("name", text: $variable.name)
                    .textFieldStyle(.plain)
                    .font(Theme.mono())
                    .foregroundStyle(variable.isEnabled ? Theme.ink : Theme.inkTertiary)
                    .focused(focusedName, equals: variable.id)
                    .onChange(of: variable.name) { _, name in onNameChange(name) }
                    .accessibilityLabel("Variable name")
            }
            .frame(width: ShellMetrics.variableNameColumn + Theme.Space.xl, alignment: .leading)

            Group {
                if variable.isSecret {
                    SecretValueField("Secret value", text: $variable.value, context: context, isBordered: false)
                } else {
                    TemplateField("value", text: $variable.value, context: context, isBordered: false)
                }
            }
            .opacity(variable.isEnabled ? 1 : 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggleSecret) {
                Image(systemName: variable.isSecret ? "lock.fill" : "lock.open")
                    .foregroundStyle(variable.isSecret ? Theme.ink : Theme.inkTertiary)
                    .frame(width: Theme.Space.xl, height: Theme.Space.xl)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(variable.isSecret ? "Secret: the value is encrypted and never shown. Click to make it plain." : "Make this value a secret")
            .accessibilityLabel("Secret")
            .accessibilityValue(variable.isSecret ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .frame(width: Theme.Space.xl, height: Theme.Space.xl)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .opacity(isHovered ? 1 : 0)
            .help("Remove \(displayName)")
            .accessibilityLabel("Remove \(displayName)")
        }
        .frame(height: ShellMetrics.tableRow)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var displayName: String {
        variable.name.isEmpty ? "variable" : variable.name
    }
}
