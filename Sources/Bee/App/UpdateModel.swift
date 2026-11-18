import AppKit
import BeeCore
import Foundation
import Observation

/// Where updates come from and how they are told to be genuine.
enum UpdateSource {
    static let repository = "digivorefr/bee"
    static let applicationName = "Bee.app"
    static let product = "Bee"
    /// An archive larger than this is not one of ours.
    static let archiveSizeLimit = 300 * 1024 * 1024

    static let installedVersion = WhatsNew.installedVersion.flatMap(SemanticVersion.init)

    /// GitHub's description of the latest release.
    static var feed: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BEE_UPDATE_FEED"], !override.isEmpty {
            return URL(string: override)
        }
        #endif
        return UpdateFeed.gitHubLatestRelease(repository: repository)
    }

    /// True for a local feed set up by a test, whose files may be anywhere.
    static var isLocalFeed: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BEE_UPDATE_FEED"]?.isEmpty == false
        #else
        return false
        #endif
    }

    static let downloadPage = UpdateFeed.gitHubDownloadPage(repository: repository)

    /// The public half of the key releases are signed with, shipped in the bundle by the build script.
    /// Without it this copy cannot tell a genuine update, so it never installs one by itself.
    static let publicKey: String? = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BEE_UPDATE_PUBLIC_KEY"], !override.isEmpty { return override }
        #endif
        guard let file = Bundle.main.url(forResource: "update-key", withExtension: "txt"),
              let text = try? String(contentsOf: file, encoding: .utf8)
        else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }()
}

/// Whether a newer version is published, and its installation: download, check that it is genuine,
/// put it in place of this copy, restart.
@Observable
final class UpdateModel {
    static let windowID = "update"
    static let windowTitle = "Software Update"

    enum Step: Equatable {
        case downloading, verifying, replacing

        var description: String {
            switch self {
            case .downloading: "Downloading…"
            case .verifying: "Checking that the update is genuine…"
            case .replacing: "Putting the new version in place…"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableRelease)
        case installing(AvailableRelease, Step)
        /// The new version is in place; Bee is about to restart (or, in a test, stays as it is).
        case installed(AvailableRelease)
        /// `release` is set when the failure is about installing that release.
        case failed(message: String, release: AvailableRelease?)
    }

    private(set) var phase: Phase = .idle
    /// When the update server last answered a check.
    @ObservationIgnored private(set) var lastAnswer: Date?

    @ObservationIgnored private let restartsAfterInstall: Bool
    /// No cookies, no cache. A request that stalls is dropped after 30 s, a download after 5 min in all.
    @ObservationIgnored private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()
    @ObservationIgnored private var installTask: Task<Void, Never>?
    /// Called right before the application is replaced, so nothing unsaved is lost.
    @ObservationIgnored var beforeReplacing: () async -> Void = {}

    init(restartsAfterInstall: Bool) {
        self.restartsAfterInstall = restartsAfterInstall
    }

    var installedVersion: SemanticVersion? { UpdateSource.installedVersion }

    /// True when this copy asks by itself. A test run only does against a local feed.
    func checksAutomatically(isEphemeral: Bool) -> Bool {
        installedVersion != nil && (!isEphemeral || UpdateSource.isLocalFeed)
    }

    /// Why this copy cannot install the release by itself, or `nil` when it can.
    func installBlocker(for release: AvailableRelease) -> String? {
        if UpdateSource.publicKey == nil {
            return "This copy of Bee cannot check that an update is genuine, so it does not install one by itself."
        }
        if release.archive == nil || release.signature == nil {
            return "This release has no signed archive that Bee can install by itself."
        }
        return UpdateInstaller.blocker(forReplacing: Bundle.main.bundleURL)?.errorDescription
    }

    // MARK: Checking

    /// - Parameter quietly: asked by Bee itself rather than by the person: a check that does not go
    ///   through then leaves what was known untouched.
    func check(quietly: Bool = false) async {
        switch phase {
        case .checking, .installing, .installed: return
        default: break
        }
        let known = phase
        guard let installed = installedVersion, let feed = UpdateSource.feed else {
            phase = .failed(message: "This copy of Bee has no version, so it cannot be compared with the latest one.", release: nil)
            return
        }
        phase = .checking
        do {
            let data = try await fetch(feed, limit: 2 * 1024 * 1024, accepting: "application/vnd.github+json")
            let release = try UpdateFeed.release(
                fromGitHub: data, repository: UpdateSource.repository, product: UpdateSource.product,
                trustsAnyLocation: UpdateSource.isLocalFeed
            )
            phase = release.version > installed ? .available(release) : .upToDate
            lastAnswer = Date()
        } catch {
            phase = quietly ? known : .failed(message: Self.describe(error), release: nil)
        }
    }

    // MARK: Installing

    /// Starts the installation; ``cancelInstall()`` stops it while it downloads.
    func startInstall() {
        guard installTask == nil else { return }
        installTask = Task { [weak self] in
            await self?.install()
            self?.installTask = nil
        }
    }

    /// Stops a download in progress. Once the new version is being put in place, nothing is stopped.
    func cancelInstall() {
        guard case .installing(_, .downloading) = phase else { return }
        installTask?.cancel()
    }

    func install() async {
        let release: AvailableRelease
        switch phase {
        case .available(let found): release = found
        case .failed(_, let found?): release = found
        default: return
        }
        do {
            guard let installed = installedVersion, release.version > installed else {
                throw Failure("The release is not newer than this copy of Bee.")
            }
            if let blocker = installBlocker(for: release) { throw Failure(blocker) }
            guard let publicKey = UpdateSource.publicKey, let archive = release.archive, let signature = release.signature,
                  let identifier = Bundle.main.bundleIdentifier
            else { throw Failure("This release cannot be installed by Bee itself.") }
            guard archive.size > 0, archive.size <= UpdateSource.archiveSizeLimit else {
                throw Failure("The size the release gives for its archive is not the size of a version of Bee.")
            }

            phase = .installing(release, .downloading)
            let signatureText = String(decoding: try await fetch(signature.url, limit: 4096), as: UTF8.self)
            // Never more than the release said: the download stops at the first byte beyond.
            let data = try await fetch(archive.url, limit: archive.size)
            guard data.count == archive.size else { throw Failure("The download is incomplete. Try again.") }

            phase = .installing(release, .verifying)
            let app = Bundle.main.bundleURL
            let version = release.version
            let applicationName = UpdateSource.applicationName
            let prepared = try await Task.detached(priority: .userInitiated) { () throws -> (app: URL, folder: URL) in
                // Nothing is unpacked, let alone run, before the archive is known to come from the publisher.
                guard UpdateSignature.isValid(signature: signatureText, of: data, publicKey: publicKey) else {
                    throw Failure("The update is not signed by the publisher of Bee. Nothing was installed.")
                }
                let folder = try UpdateInstaller.workFolder(for: app)
                do {
                    let file = folder.appendingPathComponent(archive.name)
                    try data.write(to: file)
                    let unpacked = try UpdateInstaller.unpack(
                        file, into: folder.appendingPathComponent("unpacked"), applicationName: applicationName
                    )
                    try UpdateInstaller.validate(unpacked, bundleIdentifier: identifier, version: version)
                    return (unpacked, folder)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
            }.value

            phase = .installing(release, .replacing)
            await beforeReplacing()
            defer { try? FileManager.default.removeItem(at: prepared.folder) }
            try UpdateInstaller.replace(app, with: prepared.app)
            phase = .installed(release)
            guard restartsAfterInstall else { return }
            try UpdateInstaller.openAfterExit(of: ProcessInfo.processInfo.processIdentifier, app: app)
            NSApp.terminate(nil)
        } catch {
            let wasCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            phase = wasCancelled ? .available(release) : .failed(message: Self.describe(error), release: release)
        }
    }

    // MARK: Network

    private nonisolated struct Failure: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }

    private func fetch(_ url: URL, limit: Int, accepting mediaType: String? = nil) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bee/\(installedVersion?.description ?? "0")", forHTTPHeaderField: "User-Agent")
        if let mediaType { request.setValue(mediaType, forHTTPHeaderField: "Accept") }
        // Read as it arrives, so an answer larger than expected is dropped instead of filling the memory.
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(
                http.statusCode == 403 || http.statusCode == 429
                    ? "GitHub is not answering update checks from this network for now. Try again in an hour."
                    : "The update server answered with status \(http.statusCode). Try again later."
            )
        }
        let tooLarge = Failure("The update server sent more than expected.")
        guard response.expectedContentLength <= Int64(limit) else { throw tooLarge }
        var data = Data()
        data.reserveCapacity(max(0, min(Int(response.expectedContentLength), limit)))
        for try await byte in bytes {
            guard data.count < limit else { throw tooLarge }
            data.append(byte)
        }
        return data
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
                return "Bee could not reach the update server. Check your connection and try again."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
