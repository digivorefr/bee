import BeeCore
import SwiftUI

/// What the application knows about its own version and its list of changes.
enum WhatsNew {
    static let windowID = "whats-new"
    static let windowTitle = "What’s New in Bee"
    static let projectPage = URL(string: "https://github.com/digivorefr/bee")

    /// The version written in the bundle by the build script; `nil` when Bee runs outside a bundle.
    static let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// `CHANGELOG.md` as shipped in the bundle; without releases when Bee runs outside a bundle.
    static let changelog: Changelog = {
        guard let file = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: file, encoding: .utf8)
        else { return Changelog(markdown: "") }
        return Changelog(markdown: text)
    }()
}

/// The changes of each version, newest first, as one document. The version that is running holds
/// the cell of honey.
struct WhatsNewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                if WhatsNew.changelog.releases.isEmpty {
                    Text("The list of changes is not part of this build.")
                        .font(Theme.text())
                        .foregroundStyle(Theme.inkSecondary)
                }
                ForEach(WhatsNew.changelog.releases) { release in
                    ReleaseNotesView(release: release, isInstalled: release.version == WhatsNew.installedVersion)
                }
            }
            .padding(Theme.Layout.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, minHeight: 320)
        .background(Theme.paper)
    }
}

/// The notes of one version: its heading, then its groups of changes.
struct ReleaseNotesView: View {
    let release: Changelog.Release
    var isInstalled = false
    /// False where the version is already said above the notes.
    var showsHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if showsHeading { heading }
            groups
        }
        .textSelection(.enabled)
    }

    private var heading: some View {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Text(release.version)
                        .font(Theme.mono(Theme.Size.headline, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let day = formattedDay {
                        Text(day)
                            .font(Theme.text())
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if isInstalled {
                        HStack(spacing: Theme.Space.xs) {
                            CellMark(color: Theme.honey, size: Theme.Size.caption - 2)
                            Text("Installed")
                                .font(Theme.text(Theme.Size.caption))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !release.summary.isEmpty {
                    Text(Self.inline(release.summary))
                        .font(Theme.text())
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ForEach(release.groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if !group.title.isEmpty {
                        Text(group.title)
                            .font(Theme.text(weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text("–")
                                .foregroundStyle(Theme.inkTertiary)
                                .accessibilityHidden(true)
                            Text(Self.inline(item))
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Theme.text())
                    }
                }
            }
        }
    }

    private var formattedDay: String? {
        guard let components = release.date, let date = Calendar(identifier: .gregorian).date(from: components) else {
            return nil
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    /// Inline Markdown (`code`, **bold**) of a line; the text as written when it does not parse.
    /// Links are not made clickable: the notes of an update are read before it is known to be genuine.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var line = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        line.link = nil
        return line
    }
}
