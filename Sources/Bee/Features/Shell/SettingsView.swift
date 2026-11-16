import AppKit
import BeeCore
import SwiftUI

/// The settings window: how requests are sent, the layout, the history and the secrets.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private static let timeoutRange: ClosedRange<TimeInterval> = 1...600
    private static let historyRange = 1...10_000

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Requests") {
                LabeledContent("Timeout") {
                    HStack(spacing: Theme.Space.s) {
                        TextField("Timeout", value: timeout, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: Theme.Space.xxl * 2)
                        Text("seconds").foregroundStyle(Theme.inkSecondary)
                        Stepper("Timeout", value: timeout, in: Self.timeoutRange, step: 5)
                            .labelsHidden()
                    }
                }
                Toggle("Follow redirects", isOn: $model.settings.followRedirects)
                Toggle("Verify TLS certificates", isOn: $model.settings.verifyTLS)
            }

            Section("Layout") {
                Picker("Response", selection: $model.settings.responseLayout) {
                    Text("Beside the request").tag(ResponseLayout.beside)
                    Text("Below the request").tag(ResponseLayout.below)
                }
                .pickerStyle(.radioGroup)
            }

            Section("History") {
                LabeledContent("Keep the last") {
                    HStack(spacing: Theme.Space.s) {
                        TextField("Requests kept in history", value: historyLimit, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: Theme.Space.xxl * 2)
                        Text("requests").foregroundStyle(Theme.inkSecondary)
                        Stepper("Requests kept in history", value: historyLimit, in: Self.historyRange, step: 50)
                            .labelsHidden()
                    }
                }
            }

            Section("Secrets") {
                Toggle(
                    "Require Touch ID or password to reveal a secret",
                    isOn: $model.settings.requireAuthenticationToReveal
                )
                LabeledContent("Vault") {
                    VStack(alignment: .trailing, spacing: Theme.Space.s) {
                        Text(vaultDescription)
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isVaultLocked {
                            Button("Unlock") { Task { await model.retryVaultUnlock() } }
                        }
                    }
                }
                LabeledContent("Data folder") {
                    VStack(alignment: .trailing, spacing: Theme.Space.s) {
                        Text(dataFolderPath)
                            .font(Theme.mono(Theme.Size.caption))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.environment.dataDirectory])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: ShellMetrics.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var timeout: Binding<TimeInterval> {
        Binding(
            get: { model.settings.timeout },
            set: { model.settings.timeout = min(max($0, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound) }
        )
    }

    private var historyLimit: Binding<Int> {
        Binding(
            get: { model.settings.historyLimit },
            set: { model.settings.historyLimit = min(max($0, Self.historyRange.lowerBound), Self.historyRange.upperBound) }
        )
    }

    private var vaultDescription: String {
        if model.environment.isEphemeral {
            return "Temporary. Secrets are kept in memory for this session only."
        }
        switch model.vaultState {
        case .unlocked:
            return "Unlocked. Secrets are encrypted on this Mac with a key kept in your Keychain."
        case .locked(let reason):
            return "Locked. \(reason)"
        }
    }

    private var dataFolderPath: String {
        (model.environment.dataDirectory.path as NSString).abbreviatingWithTildeInPath
    }
}
