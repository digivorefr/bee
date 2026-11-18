import CryptoKit
import Foundation
import Testing
@testable import BeeCore

@Suite struct SemanticVersionTests {
    @Test(arguments: ["1.0.0", "v1.2.3", "V2", "10.20.30.40", " 1.2 "])
    func readsVersions(text: String) {
        #expect(SemanticVersion(text) != nil)
    }

    @Test(arguments: ["", "v", "1.", ".1", "1..2", "1.2.3.4.5", "1.2-beta", "a.b", "-1.0", "１.0", "1.9999999999"])
    func refusesWhatIsNotAVersion(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test func ordersNumberByNumber() throws {
        func version(_ text: String) throws -> SemanticVersion { try #require(SemanticVersion(text)) }
        #expect(try version("1.0.0") < version("1.0.1"))
        #expect(try version("1.9.0") < version("1.10.0"))
        #expect(try version("1.10") < version("2"))
        #expect(try version("1.2") == version("v1.2.0"))
        #expect(try version("1.2").hashValue == version("1.2.0").hashValue)
        #expect(try !(version("1.2.0") < version("1.2")))
        #expect(try version("1.2.0.1") > version("1.2"))
        #expect(try version("v1.02.3").description == "1.2.3")
    }
}

@Suite struct UpdateFeedTests {
    private func answer(
        tag: String = "v1.2.0", draft: Bool = false, prerelease: Bool = false,
        page: String = "https://github.com/digivorefr/bee/releases/tag/v1.2.0",
        assets: [(String, String)] = [
            ("Bee-1.2.0.zip", "https://github.com/digivorefr/bee/releases/download/v1.2.0/Bee-1.2.0.zip"),
            ("Bee-1.2.0.zip.sig", "https://github.com/digivorefr/bee/releases/download/v1.2.0/Bee-1.2.0.zip.sig"),
        ]
    ) -> Data {
        let list = assets.map { "{\"name\": \"\($0.0)\", \"size\": 2017987, \"browser_download_url\": \"\($0.1)\"}" }
        return Data("""
        {"tag_name": "\(tag)", "name": "Bee", "draft": \(draft), "prerelease": \(prerelease), "html_url": "\(page)",
         "body": "Notes\\n\\n### Added\\n\\n- One thing", "assets": [\(list.joined(separator: ","))], "unknown": 1}
        """.utf8)
    }

    private func release(_ data: Data, anyLocation: Bool = false) throws(UpdateFeedError) -> AvailableRelease {
        try UpdateFeed.release(fromGitHub: data, repository: "digivorefr/bee", product: "Bee", trustsAnyLocation: anyLocation)
    }

    @Test func readsTheLatestRelease() throws {
        let release = try release(answer())
        #expect(release.version == SemanticVersion("1.2.0"))
        #expect(release.notes.hasPrefix("Notes"))
        #expect(release.pageURL.absoluteString == "https://github.com/digivorefr/bee/releases/tag/v1.2.0")
        #expect(release.archive?.name == "Bee-1.2.0.zip")
        #expect(release.archive?.size == 2_017_987)
        #expect(release.signature?.url.absoluteString.hasSuffix("/Bee-1.2.0.zip.sig") == true)
    }

    @Test func aReleaseWithoutArchiveIsStillARelease() throws {
        let release = try release(answer(assets: [("Other.zip", "https://github.com/digivorefr/bee/releases/download/v1.2.0/Other.zip")]))
        #expect(release.archive == nil)
        #expect(release.signature == nil)
    }

    @Test(arguments: [
        "http://github.com/digivorefr/bee/releases/download/v1.2.0/Bee-1.2.0.zip",
        "https://github.com.evil.example/digivorefr/bee/releases/download/v1.2.0/Bee-1.2.0.zip",
        "https://github.com/someone/else/releases/download/v1.2.0/Bee-1.2.0.zip",
        "https://github.com/digivorefr/bee/releases/../../../someone/else/Bee-1.2.0.zip",
        "https://evil.example/Bee-1.2.0.zip",
        "file:///tmp/Bee-1.2.0.zip",
    ])
    func anArchiveOutsideTheRepositoryIsIgnored(location: String) throws {
        let data = answer(page: "https://evil.example/phish", assets: [("Bee-1.2.0.zip", location)])
        let release = try release(data)
        #expect(release.archive == nil)
        // A page elsewhere is replaced by the repository's own.
        #expect(release.pageURL.absoluteString == "https://github.com/digivorefr/bee/releases/latest")
        // A local feed, used by tests, may point anywhere.
        #expect(try self.release(data, anyLocation: true).archive?.url.absoluteString == location)
    }

    @Test func refusesWhatIsNotAPublishedVersion() {
        #expect(throws: UpdateFeedError.unreadable) { try release(Data("<html>rate limited</html>".utf8)) }
        #expect(throws: UpdateFeedError.unreadable) { try release(Data("{\"message\": \"Not Found\"}".utf8)) }
        #expect(throws: UpdateFeedError.self) { try release(answer(tag: "nightly")) }
        #expect(throws: UpdateFeedError.self) { try release(answer(draft: true)) }
        #expect(throws: UpdateFeedError.self) { try release(answer(prerelease: true)) }
    }

    @Test func addresses() {
        #expect(UpdateFeed.gitHubLatestRelease(repository: "digivorefr/bee")?.absoluteString == "https://api.github.com/repos/digivorefr/bee/releases/latest")
        #expect(UpdateFeed.gitHubDownloadPage(repository: "digivorefr/bee")?.absoluteString == "https://github.com/digivorefr/bee/releases/latest")
    }
}

@Suite struct UpdateSignatureTests {
    @Test func acceptsOnlyTheSignatureOfThatDataByThatKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("the archive".utf8)
        let signature = try key.signature(for: data).base64EncodedString()

        #expect(UpdateSignature.isValid(signature: signature, of: data, publicKey: publicKey))
        #expect(UpdateSignature.isValid(signature: " \(signature)\n", of: data, publicKey: "\(publicKey)\n"))
        #expect(!UpdateSignature.isValid(signature: signature, of: Data("the archive.".utf8), publicKey: publicKey))

        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(!UpdateSignature.isValid(signature: signature, of: data, publicKey: other))
        #expect(!UpdateSignature.isValid(signature: "", of: data, publicKey: publicKey))
        #expect(!UpdateSignature.isValid(signature: "not base64", of: data, publicKey: publicKey))
        #expect(!UpdateSignature.isValid(signature: signature, of: data, publicKey: ""))
        #expect(!UpdateSignature.isValid(signature: Data(count: 64).base64EncodedString(), of: data, publicKey: publicKey))
    }
}

@Suite struct UpdateInstallerTests {
    private let files = FileManager.default

    private func temporaryFolder() throws -> URL {
        let folder = files.temporaryDirectory.appendingPathComponent("bee-update-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A small signed application: a real executable, an Info.plist and one resource.
    private func makeApplication(in folder: URL, version: String, identifier: String = "com.example.app") throws -> URL {
        let app = folder.appendingPathComponent("Bee.app")
        try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try files.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Bee"))
        try Data("notes of \(version)".utf8).write(to: app.appendingPathComponent("Contents/Resources/CHANGELOG.md"))
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Bee",
            "CFBundlePackageType": "APPL", "CFBundleName": "Bee",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(try run("/usr/bin/codesign", "--force", "--sign", "-", app.path) == 0)
        return app
    }

    private func version(of app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleShortVersionString"] as? String
    }

    @Test func unpacksValidatesAndReplaces() throws {
        let root = try temporaryFolder()
        defer { try? files.removeItem(at: root) }
        let installedFolder = root.appendingPathComponent("Applications")
        let stage = root.appendingPathComponent("stage/Bee-2.0.0")
        try files.createDirectory(at: installedFolder, withIntermediateDirectories: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        let installed = try makeApplication(in: installedFolder, version: "1.0.0")
        _ = try makeApplication(in: stage, version: "2.0.0")
        try Data("license".utf8).write(to: stage.appendingPathComponent("LICENSE.md"))

        // Packaged as the release script does.
        let archive = root.appendingPathComponent("Bee-2.0.0.zip")
        #expect(try run("/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", stage.path, archive.path) == 0)

        #expect(UpdateInstaller.blocker(forReplacing: installed) == nil)
        let work = try UpdateInstaller.workFolder(for: installed)
        defer { try? files.removeItem(at: work) }
        let unpacked = try UpdateInstaller.unpack(archive, into: work, applicationName: "Bee.app")
        #expect(unpacked.lastPathComponent == "Bee.app")
        let expected = try #require(SemanticVersion("2.0.0"))
        try UpdateInstaller.validate(unpacked, bundleIdentifier: "com.example.app", version: expected)

        try UpdateInstaller.replace(installed, with: unpacked)
        #expect(try version(of: installed) == "2.0.0")
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/Resources/CHANGELOG.md"), encoding: .utf8) == "notes of 2.0.0")
        #expect(try run("/usr/bin/codesign", "--verify", "--strict", installed.path) == 0)
        #expect(!files.fileExists(atPath: unpacked.path))
    }

    @Test func refusesAnotherApplicationAnotherVersionOrAnAlteredOne() throws {
        let root = try temporaryFolder()
        defer { try? files.removeItem(at: root) }
        let app = try makeApplication(in: root, version: "2.0.0")
        let expected = try #require(SemanticVersion("2.0.0"))
        let other = try #require(SemanticVersion("2.0.1"))

        try UpdateInstaller.validate(app, bundleIdentifier: "com.example.app", version: expected)
        #expect(throws: UpdateInstallError.wrongApplication("Its identifier is \"com.example.app\".")) {
            try UpdateInstaller.validate(app, bundleIdentifier: "com.digivore.bee", version: expected)
        }
        #expect(throws: UpdateInstallError.wrongVersion(found: "2.0.0", expected: "2.0.1")) {
            try UpdateInstaller.validate(app, bundleIdentifier: "com.example.app", version: other)
        }

        // One resource changed after signing.
        try Data("altered".utf8).write(to: app.appendingPathComponent("Contents/Resources/CHANGELOG.md"))
        #expect(throws: UpdateInstallError.brokenApplication) {
            try UpdateInstaller.validate(app, bundleIdentifier: "com.example.app", version: expected)
        }
        #expect(throws: UpdateInstallError.self) {
            try UpdateInstaller.validate(root, bundleIdentifier: "com.example.app", version: expected)
        }
    }

    @Test func anArchiveWithoutTheApplicationIsRefused() throws {
        let root = try temporaryFolder()
        defer { try? files.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage")
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stage.appendingPathComponent("readme.txt"))
        let archive = root.appendingPathComponent("a.zip")
        #expect(try run("/usr/bin/ditto", "-c", "-k", "--keepParent", stage.path, archive.path) == 0)
        let out = root.appendingPathComponent("out")
        #expect(throws: UpdateInstallError.wrongApplication("Bee.app is not in the archive.")) {
            try UpdateInstaller.unpack(archive, into: out, applicationName: "Bee.app")
        }
        #expect(throws: UpdateInstallError.self) {
            try UpdateInstaller.unpack(root.appendingPathComponent("missing.zip"), into: out, applicationName: "Bee.app")
        }
    }

    @Test func saysWhyACopyCannotBeReplaced() throws {
        let root = try temporaryFolder()
        defer {
            try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
            try? files.removeItem(at: root)
        }
        #expect(UpdateInstaller.blocker(forReplacing: URL(fileURLWithPath: "/usr/local/bin/bee")) == .notAnApplication)
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Bee.app")
        #expect(UpdateInstaller.blocker(forReplacing: translocated) == .translocated)

        let locked = root.appendingPathComponent("locked")
        try files.createDirectory(at: locked, withIntermediateDirectories: true)
        let app = try makeApplication(in: locked, version: "1.0.0")
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        #expect(UpdateInstaller.blocker(forReplacing: app) == .notWritable(locked.path))
    }
}

/// Launches a throwaway background application through LaunchServices, as the restart after an update
/// does. Off by default (it registers a temporary application with the system): run with
/// `BEE_RELAUNCH_SELFTEST=1 swift test --filter UpdateRelaunchSelfTest`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BEE_RELAUNCH_SELFTEST"] == "1"))
struct UpdateRelaunchSelfTest {
    @Test func opensTheApplicationOnlyOnceTheProcessHasEnded() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("bee-relaunch-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let app = root.appendingPathComponent("Marker.app")
        let marker = root.appendingPathComponent("launched")
        try files.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = app.appendingPathComponent("Contents/MacOS/Marker")
        try Data("#!/bin/sh\necho launched > \"\(marker.path)\"\n".utf8).write(to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.digivore.bee.relaunch-selftest", "CFBundleExecutable": "Marker",
            "CFBundlePackageType": "APPL", "LSBackgroundOnly": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        // Stands for the application that is quitting.
        let quitting = Process()
        quitting.executableURL = URL(fileURLWithPath: "/bin/sleep")
        quitting.arguments = ["1.5"]
        try quitting.run()

        try UpdateInstaller.openAfterExit(of: quitting.processIdentifier, app: app)
        try await Task.sleep(for: .milliseconds(700))
        #expect(!files.fileExists(atPath: marker.path))

        quitting.waitUntilExit()
        var launched = false
        for _ in 0..<50 where !launched {
            try await Task.sleep(for: .milliseconds(200))
            launched = files.fileExists(atPath: marker.path)
        }
        #expect(launched)
    }
}
