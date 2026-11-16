import Foundation
import Testing
@testable import BeeCore

@Suite struct ChangelogTests {
    @Test func readsVersionsGroupsAndItems() {
        let changelog = Changelog(markdown: """
        # Changelog

        Introduction, left out.
        - not an item of any version

        ## [1.1.0] - 2026-12-01

        A sentence
        on two lines.

        ### Added

        - First item with `code`
          continued on the next line.
        - Second item

        ### Fixed
        * Starred item

        ## 1.0.0 — 2026-11-16
        - Item without a group

        ## 0.9.0
        """)

        #expect(changelog.releases.map(\.version) == ["1.1.0", "1.0.0", "0.9.0"])
        #expect(changelog.currentVersion == "1.1.0")

        let latest = changelog.releases[0]
        #expect(latest.date == DateComponents(year: 2026, month: 12, day: 1))
        #expect(latest.summary == "A sentence on two lines.")
        #expect(latest.groups.map(\.title) == ["Added", "Fixed"])
        #expect(latest.groups[0].items == ["First item with `code` continued on the next line.", "Second item"])
        #expect(latest.groups[1].items == ["Starred item"])

        #expect(changelog.releases[1].date == DateComponents(year: 2026, month: 11, day: 16))
        #expect(changelog.releases[1].groups == [Changelog.Group(title: "", items: ["Item without a group"])])
        #expect(changelog.releases[2].date == nil)
        #expect(changelog.releases[2].groups.isEmpty)
    }

    @Test func anEmptyOrForeignTextHasNoRelease() {
        #expect(Changelog(markdown: "").releases.isEmpty)
        #expect(Changelog(markdown: "# Title\n\nSome text\n- an item").currentVersion == nil)
    }

    /// The file shipped with the application: its first version is the one the build script stamps.
    @Test func theProjectChangelogIsWellFormed() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let changelog = Changelog(markdown: try String(contentsOf: file, encoding: .utf8))
        let current = try #require(changelog.releases.first)

        let numbers = current.version.split(separator: ".")
        #expect(numbers.count == 3)
        #expect(numbers.allSatisfy { Int($0) != nil })
        #expect(current.date != nil)
        #expect(Set(changelog.releases.map(\.version)).count == changelog.releases.count)
        for release in changelog.releases {
            #expect(!release.groups.isEmpty)
            #expect(release.groups.allSatisfy { !$0.items.isEmpty })
        }
    }
}
