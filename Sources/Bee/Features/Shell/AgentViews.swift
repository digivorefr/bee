import AppKit
import BeeCore
import SwiftUI

/// The question an agent's call raises: who asks, what for, and the person's answer.
struct AgentQuestionSheet: View {
    @Environment(AppModel.self) private var model
    let question: AgentModel.Question

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(question.title)
                .font(Theme.text(Theme.Size.headline, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            // First what travels or runs (a path, a request line), in the wire voice; then what Bee says.
            let lines = question.detail.split(separator: "\n", maxSplits: 1).map(String.init)
            if let subject = lines.first {
                Text(subject)
                    .font(Theme.mono())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(8)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if lines.count > 1 {
                Text(lines[1])
                    .font(Theme.text())
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What the person did not write and is asked to send: all of it, to read before answering.
            if let content = question.content {
                ScrollView {
                    Text(content)
                        .font(Theme.mono(Theme.Size.caption))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(Theme.Space.s)
                }
                .frame(maxHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.inkSecondary.opacity(0.3)))
                .accessibilityLabel("What the fork changes")
            }
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Button("Deny") { model.agents.resolve(question.id, .deny) }
                    .keyboardShortcut(.cancelAction)
                if question.offersUntilQuit {
                    Button("Allow Until Bee Quits") { model.agents.resolve(question.id, .untilQuit) }
                }
                // No key answers yes: a sheet that comes up while the person types is not allowed by a Return.
                Button("Allow") { model.agents.resolve(question.id, .once) }
            }
            .buttonStyle(OutlineButtonStyle())
        }
        .padding(Theme.Layout.pageInset)
        .frame(width: 520)
        .background(Theme.paper)
        .interactiveDismissDisabled()
    }
}

/// Settings › Agents: whether agents may connect, what they may do, in which collections, and who came.
struct AgentSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Agents") {
            Toggle("Let AI agents use Bee", isOn: $model.settings.agentsEnabled)
            Text("An agent connects through the relay shipped in Bee (MCP). It never gets a secret value, and Bee asks you before it sends anything.")
                .font(Theme.text(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.settings.agentsEnabled {
                Picker("They may", selection: $model.settings.agentAccess) {
                    Text("Read requests").tag(AgentAccess.read)
                    Text("Read, and send when you agree").tag(AgentAccess.run)
                    Text("Read, send, and propose forks they can send").tag(AgentAccess.propose)
                }
                LabeledContent("Collections") {
                    VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                        if model.workspace.collections.isEmpty {
                            Text("No collection yet").foregroundStyle(Theme.inkSecondary)
                        }
                        ForEach(model.workspace.collections) { collection in
                            Toggle(collection.name, isOn: isOpen(collection.id))
                        }
                    }
                }
                LabeledContent("Relay") {
                    VStack(alignment: .trailing, spacing: Theme.Space.s) {
                        Text(AgentModel.relayPath)
                            .font(Theme.mono(Theme.Size.caption))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                        Button("Copy Command for Claude Code") {
                            model.copy("claude mcp add bee -- \"\(AgentModel.relayPath)\"")
                        }
                    }
                }
                if !model.settings.agentPrograms.isEmpty {
                    LabeledContent("Allowed programs") {
                        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                            ForEach(model.settings.agentPrograms, id: \.self) { program in
                                HStack(spacing: Theme.Space.s) {
                                    Text(AgentProgram.shortName(of: program))
                                        .help(program)
                                    Button("Remove") { model.settings.agentPrograms.removeAll { $0 == program } }
                                }
                            }
                        }
                    }
                }
                if let last = model.agents.activity.first {
                    LabeledContent("Last call") {
                        Text("\(last.program) · \(last.tool) · \(last.outcome)")
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func isOpen(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.settings.agentCollections.contains(id) },
            set: { open in
                if open {
                    if !model.settings.agentCollections.contains(id) { model.settings.agentCollections.append(id) }
                } else {
                    model.settings.agentCollections.removeAll { $0 == id }
                }
            }
        )
    }
}
