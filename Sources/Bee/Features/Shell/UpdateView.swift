import BeeCore
import SwiftUI

/// The update window: what the check found, the notes of the new version, and its installation.
struct UpdateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let updates = model.updates
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            switch updates.phase {
            case .idle, .checking:
                busy("Checking for updates…")
            case .upToDate:
                headline("Bee is up to date")
                words("Version \(installed) is the latest.")
                Spacer(minLength: 0)
                actions { Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
            case .available(let release):
                available(release, updates: updates)
            case .installing(_, let step):
                busy(step.description)
                if step == .downloading {
                    actions { Button("Cancel") { updates.cancelInstall() }.keyboardShortcut(.cancelAction) }
                }
            case .installed(let release):
                headline("Bee \(release.version.description) is in place")
                words("Bee restarts now.")
                Spacer(minLength: 0)
            case .failed(let message, let release):
                failed(message, release: release, updates: updates)
            }
        }
        .padding(Theme.Layout.pageInset)
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
        .task {
            if updates.phase == .idle { await updates.check() }
        }
    }

    private var installed: String { model.updates.installedVersion?.description ?? "unknown" }

    // MARK: States

    @ViewBuilder
    private func available(_ release: AvailableRelease, updates: UpdateModel) -> some View {
        let blocker = updates.installBlocker(for: release)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            headline("Bee \(release.version.description) is available")
            words("You have version \(installed).")
        }
        if let notes = Self.notes(of: release) {
            ScrollView {
                ReleaseNotesView(release: notes, showsHeading: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        } else {
            Spacer(minLength: 0)
        }
        if let blocker {
            words(blocker + " Download it from the release page.")
        } else {
            caption("Bee restarts once the update is in place. macOS may then ask once to let the new version read its key in your Keychain.")
        }
        actions {
            Button("Not Now") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if blocker == nil {
                Button("Install and Restart") { updates.startInstall() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Open Release Page") { openURL(release.pageURL) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func failed(_ message: String, release: AvailableRelease?, updates: UpdateModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            CellMark("xmark", color: Theme.negative, size: Theme.Size.headline)
            headline(release == nil ? "The check did not go through" : "The update was not installed")
        }
        Text(message)
            .font(Theme.text())
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        Spacer(minLength: 0)
        actions {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let page = release?.pageURL ?? UpdateSource.downloadPage {
                Button("Open Release Page") { openURL(page) }
            }
            Button("Try Again") {
                if release == nil {
                    Task { await updates.check() }
                } else {
                    updates.startInstall()
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Parts

    private func busy(_ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            CombSpinner()
            Text(text)
                .font(Theme.text(Theme.Size.headline, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(Theme.text(Theme.Size.headline, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func words(_ text: String) -> some View {
        Text(text)
            .font(Theme.text())
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.text(Theme.Size.caption))
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actions<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack(spacing: Theme.Space.s) {
            Spacer(minLength: 0)
            buttons()
        }
        .buttonStyle(OutlineButtonStyle())
    }

    /// The release notes as groups of changes, without the part that says how to install by hand.
    private static func notes(of release: AvailableRelease) -> Changelog.Release? {
        var parsed = Changelog(markdown: "## \(release.version.description)\n\n\(release.notes)").releases.first
        parsed?.groups.removeAll { $0.title == "Install" || $0.items.isEmpty }
        guard let parsed, !parsed.groups.isEmpty else { return nil }
        return parsed
    }
}
