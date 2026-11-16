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
                    ReleaseNotes(release: release, isInstalled: release.version == WhatsNew.installedVersion)
                }
            }
            .padding(Theme.Layout.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, minHeight: 320)
        .background(Theme.paper)
    }
}

private struct ReleaseNotes: View {
    let release: Changelog.Release
    let isInstalled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
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
        .textSelection(.enabled)
    }

    private var formattedDay: String? {
        guard let components = release.date, let date = Calendar(identifier: .gregorian).date(from: components) else {
            return nil
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }

    /// Inline Markdown (`code`, **bold**) of a line; the text as written when it does not parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
