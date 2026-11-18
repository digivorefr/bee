import Foundation

public enum UpdateInstallError: Error, Equatable, Sendable, LocalizedError {
    /// macOS runs the application from a hidden read-only copy until it is moved by hand.
    case translocated
    /// The folder that holds the application cannot be written to.
    case notWritable(String)
    /// What is running is not an application bundle (a development build).
    case notAnApplication
    case unpackFailed(String)
    /// The archive does not hold the application it should.
    case wrongApplication(String)
    case wrongVersion(found: String, expected: String)
    /// The application in the archive is incomplete or was altered.
    case brokenApplication
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .translocated:
            "Bee is running from the folder it was downloaded to. Quit it, move Bee to your Applications folder, then open it again."
        case .notWritable(let folder):
            "Bee cannot write to \(folder). Move Bee to a folder you own, or install the update by hand."
        case .notAnApplication:
            "This copy of Bee was not installed as an application, so it cannot replace itself."
        case .unpackFailed(let detail):
            "The update could not be unpacked. \(detail)"
        case .wrongApplication(let detail):
            "The update does not hold the application it should. \(detail)"
        case .wrongVersion(let found, let expected):
            "The update holds version \(found) instead of \(expected)."
        case .brokenApplication:
            "The application in the update is incomplete or was altered."
        case .replaceFailed(let detail):
            "The new version could not be put in place. \(detail)"
        }
    }
}

/// Puts a downloaded version of the application in place of the running one.
///
/// The caller checks the archive's signature first (`UpdateSignature`): nothing here is done to an archive
/// that is not known to come from the publisher.
public enum UpdateInstaller {
    /// Why the application at `app` cannot be replaced where it is, or `nil` when it can.
    public static func blocker(forReplacing app: URL) -> UpdateInstallError? {
        guard app.pathExtension == "app" else { return .notAnApplication }
        if app.path.contains("/AppTranslocation/") { return .translocated }
        let folder = app.deletingLastPathComponent()
        let files = FileManager.default
        guard files.isWritableFile(atPath: folder.path), files.isWritableFile(atPath: app.path) else {
            return .notWritable(folder.path)
        }
        return nil
    }

    /// A new folder on the volume of `app`, so the new version is moved in place rather than copied.
    public static func workFolder(for app: URL) throws(UpdateInstallError) -> URL {
        do {
            return try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true
            )
        } catch {
            throw .replaceFailed(error.localizedDescription)
        }
    }

    /// Unpacks the archive into `folder` and returns the application it holds, at the top or one folder down.
    public static func unpack(_ archive: URL, into folder: URL, applicationName: String) throws(UpdateInstallError) -> URL {
        let result = run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
        guard result.status == 0 else { throw .unpackFailed(result.output) }
        let files = FileManager.default
        var candidates = [folder.appendingPathComponent(applicationName)]
        for child in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            candidates.append(child.appendingPathComponent(applicationName))
        }
        var isFolder: ObjCBool = false
        guard let app = candidates.first(where: { files.fileExists(atPath: $0.path, isDirectory: &isFolder) && isFolder.boolValue }) else {
            throw .wrongApplication("\(applicationName) is not in the archive.")
        }
        return app
    }

    /// Checks that `app` is the expected application at the expected version, whole and as it was signed.
    public static func validate(
        _ app: URL, bundleIdentifier: String, version: SemanticVersion
    ) throws(UpdateInstallError) {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw .wrongApplication("It has no readable Info.plist.") }

        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == bundleIdentifier else {
            throw .wrongApplication("Its identifier is \"\(identifier)\".")
        }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard SemanticVersion(found) == version else {
            throw .wrongVersion(found: found, expected: version.description)
        }
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else { throw .brokenApplication }
        // Every file of the bundle is sealed by its signature: one that changed or is missing fails here.
        guard run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0 else {
            throw .brokenApplication
        }
    }

    /// Replaces the application at `app` by `newApp`. The running process keeps working from what it has
    /// already loaded; it should relaunch right after.
    public static func replace(_ app: URL, with newApp: URL) throws(UpdateInstallError) {
        do {
            _ = try FileManager.default.replaceItemAt(app, withItemAt: newApp)
        } catch {
            throw .replaceFailed(error.localizedDescription)
        }
    }

    /// Opens `app` once the process `pid` has ended. Returns at once; the wait happens in a shell that
    /// outlives the caller.
    public static func openAfterExit(of pid: Int32, app: URL) throws(UpdateInstallError) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path travels as an argument, never inside the script.
        process.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "bee-relaunch", String(pid), app.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .replaceFailed("Bee was updated but could not restart itself: open it again.")
        }
    }

    // MARK: Tools

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
