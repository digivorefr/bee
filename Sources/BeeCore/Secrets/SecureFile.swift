import Foundation

/// A file-system failure with a message fit for display.
struct FileFailure: Error, Equatable, LocalizedError {
    var message: String

    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }

    init(operation: String, path: String, code: Int32) {
        self.init("\(operation) \(path) failed: \(String(cString: strerror(code)))")
    }
}

/// File primitives shared by the vault and the workspace store: owner-only permissions and atomic replacement.
enum SecureFile {
    static let filePermissions: mode_t = 0o600
    static let directoryPermissions: mode_t = 0o700

    /// Creates the directory and its missing parents, readable by the owner only. An existing directory is left as is.
    static func createDirectory(at url: URL) throws(FileFailure) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw FileFailure("\(url.path) is not a directory") }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: directoryPermissions)]
            )
        } catch {
            throw FileFailure("Creating \(url.path) failed: \(error.localizedDescription)")
        }
    }

    /// Restricts an existing directory to its owner.
    static func restrictDirectory(at url: URL) throws(FileFailure) {
        guard chmod(url.path, directoryPermissions) == 0 else {
            throw FileFailure(operation: "Securing", path: url.path, code: errno)
        }
    }

    /// The content of the file, or `nil` when it does not exist.
    static func read(_ url: URL) throws(FileFailure) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw FileFailure("Reading \(url.path) failed: \(error.localizedDescription)")
        }
    }

    /// Replaces the file atomically: the content goes to an owner-only temporary sibling that is synced
    /// to disk and then renamed over the target, so a reader sees the old or the new content, never a mix,
    /// and the content is never readable by another account.
    static func write(_ data: Data, to url: URL) throws(FileFailure) {
        let directory = url.deletingLastPathComponent()
        try createDirectory(at: directory)
        let temporaryPath = directory
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path

        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, filePermissions)
        guard descriptor >= 0 else {
            throw FileFailure(operation: "Creating", path: temporaryPath, code: errno)
        }
        var failure: FileFailure?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = FileFailure(operation: "Writing", path: temporaryPath, code: errno)
                    return
                }
                offset += written
            }
        }
        // The creation mode is filtered by the process umask; make the result exact.
        if failure == nil, fchmod(descriptor, filePermissions) != 0 {
            failure = FileFailure(operation: "Securing", path: temporaryPath, code: errno)
        }
        if failure == nil, fsync(descriptor) != 0 {
            failure = FileFailure(operation: "Syncing", path: temporaryPath, code: errno)
        }
        close(descriptor)
        if failure == nil, rename(temporaryPath, url.path) != 0 {
            failure = FileFailure(operation: "Replacing", path: url.path, code: errno)
        }
        if let failure {
            unlink(temporaryPath)
            throw failure
        }
    }

    /// Removes the file. A missing file is not an error.
    static func remove(_ url: URL) throws(FileFailure) {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw FileFailure(operation: "Removing", path: url.path, code: errno)
        }
    }
}
