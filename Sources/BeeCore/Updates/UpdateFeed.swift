import Foundation

/// The latest published version of the application, as GitHub describes it.
public struct AvailableRelease: Hashable, Sendable {
    public struct Asset: Hashable, Sendable {
        public var name: String
        public var url: URL
        /// Bytes.
        public var size: Int

        public init(name: String, url: URL, size: Int) {
            self.name = name
            self.url = url
            self.size = size
        }
    }

    public var version: SemanticVersion
    /// The release notes, in Markdown.
    public var notes: String
    /// The page of the release, for a person to read or download from.
    public var pageURL: URL
    /// The archive of the application (`Bee-1.2.0.zip`), when the release has one.
    public var archive: Asset?
    /// The signature of the archive (`Bee-1.2.0.zip.sig`), when the release has one.
    public var signature: Asset?

    public init(version: SemanticVersion, notes: String, pageURL: URL, archive: Asset? = nil, signature: Asset? = nil) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.archive = archive
        self.signature = signature
    }
}

public enum UpdateFeedError: Error, Equatable, Sendable, LocalizedError {
    /// The answer is not a release description.
    case unreadable
    /// The release cannot be offered: its version is not a version, or it is a draft.
    case notARelease(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The update server sent something Bee could not read."
        case .notARelease(let detail): "The latest release cannot be used: \(detail)"
        }
    }
}

/// Reads the latest release of a GitHub repository.
public enum UpdateFeed {
    /// `https://api.github.com/repos/<owner>/<name>/releases/latest`
    public static func gitHubLatestRelease(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// The page a person downloads the latest version from.
    public static func gitHubDownloadPage(repository: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases/latest")
    }

    /// Reads GitHub's answer to ``gitHubLatestRelease(repository:)``.
    ///
    /// Only what belongs to the repository is kept: an asset or a page elsewhere than
    /// `https://github.com/<repository>/releases/` is ignored, so the answer cannot send the application
    /// to download from another place.
    ///
    /// - Parameters:
    ///   - product: the name the archive starts with (`Bee` for `Bee-1.2.0.zip`).
    ///   - trustsAnyLocation: accept assets anywhere, for tests against a local feed.
    public static func release(
        fromGitHub data: Data, repository: String, product: String, trustsAnyLocation: Bool = false
    ) throws(UpdateFeedError) -> AvailableRelease {
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw .unreadable }
        guard answer.draft != true, answer.prerelease != true else { throw .notARelease("it is not published yet.") }
        guard let version = SemanticVersion(answer.tagName) else {
            throw .notARelease("its tag \"\(answer.tagName)\" is not a version.")
        }

        let home = "/\(repository)/releases/"
        func belongs(_ url: URL) -> Bool {
            if trustsAnyLocation { return true }
            return url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix(home)
                && !url.path.contains("/../")
        }
        func asset(named name: String) -> AvailableRelease.Asset? {
            guard let found = answer.assets?.first(where: { $0.name == name }),
                  let url = URL(string: found.browserDownloadURL), belongs(url)
            else { return nil }
            return AvailableRelease.Asset(name: name, url: url, size: found.size ?? 0)
        }

        // The archive is named after the tag as written (`v1.2.0` gives `Bee-1.2.0.zip`).
        let tag = answer.tagName.trimmingCharacters(in: .whitespaces)
        let archiveName = "\(product)-\(tag.first == "v" || tag.first == "V" ? String(tag.dropFirst()) : tag).zip"
        let page = answer.htmlURL.flatMap(URL.init(string:)).flatMap { belongs($0) ? $0 : nil }
            ?? gitHubDownloadPage(repository: repository)
        guard let page else { throw .unreadable }

        return AvailableRelease(
            version: version, notes: answer.body ?? "", pageURL: page,
            archive: asset(named: archiveName), signature: asset(named: archiveName + ".sig")
        )
    }

    private struct Answer: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: String
            var size: Int?

            enum CodingKeys: String, CodingKey {
                case name, size
                case browserDownloadURL = "browser_download_url"
            }
        }

        var tagName: String
        var body: String?
        var htmlURL: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case body, draft, prerelease, assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
