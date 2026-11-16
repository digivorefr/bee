import Foundation

/// The list of changes of each version, read from `CHANGELOG.md`.
///
/// The file is plain Markdown: one `## 1.2.0 — 2026-01-31` heading per version, newest first, an optional
/// sentence under it, then `### Group` headings each followed by `- ` items. Anything before the first
/// version heading is the file's own introduction and is left out.
public struct Changelog: Hashable, Sendable {
    public struct Release: Hashable, Sendable, Identifiable {
        public var version: String
        /// The day of the release when the heading gives one as `yyyy-MM-dd`.
        public var date: DateComponents?
        /// The sentences written under the heading, before the first group or item.
        public var summary: String
        public var groups: [Group]

        public var id: String { version }
    }

    public struct Group: Hashable, Sendable {
        /// Empty for items written directly under the version.
        public var title: String
        /// Each item on one line, with its inline Markdown (`code`, **bold**) as written.
        public var items: [String]
    }

    public var releases: [Release]

    /// The version the application is built as: the first one listed.
    public var currentVersion: String? { releases.first?.version }

    public init(markdown: String) {
        var releases: [Release] = []
        // True while the last thing read is an item, so an indented line continues it.
        var isInItem = false

        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let heading = Self.text(of: line, after: "## ") {
                releases.append(Self.release(from: heading))
                isInItem = false
                continue
            }
            guard !releases.isEmpty else { continue }
            let last = releases.count - 1

            if let title = Self.text(of: line, after: "### ") {
                releases[last].groups.append(Group(title: title, items: []))
                isInItem = false
            } else if let item = Self.text(of: line, after: "- ") ?? Self.text(of: line, after: "* ") {
                if releases[last].groups.isEmpty { releases[last].groups.append(Group(title: "", items: [])) }
                releases[last].groups[releases[last].groups.count - 1].items.append(item)
                isInItem = true
            } else if line.isEmpty {
                isInItem = false
            } else if isInItem, rawLine.first?.isWhitespace == true {
                let group = releases[last].groups.count - 1
                let item = releases[last].groups[group].items.count - 1
                releases[last].groups[group].items[item] += " " + line
            } else if releases[last].groups.isEmpty {
                releases[last].summary += (releases[last].summary.isEmpty ? "" : " ") + line
                isInItem = false
            }
        }
        self.releases = releases
    }

    // MARK: Parsing

    private static func text(of line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// `1.2.0`, `[1.2.0]`, `1.2.0 — 2026-01-31`, `[1.2.0] - 2026-01-31`.
    private static func release(from heading: String) -> Release {
        let words = heading.split(whereSeparator: \.isWhitespace).map(String.init)
        let version = (words.first ?? heading).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let date = words.dropFirst().lazy.compactMap(Self.day).first
        return Release(version: version, date: date, summary: "", groups: [])
    }

    private static func day(_ word: String) -> DateComponents? {
        let parts = word.split(separator: "-").map { Int($0) }
        guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2],
              year > 1999, (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}
