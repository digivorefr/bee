import Foundation

/// Whether secret values can currently be read from and written to the vault.
public enum VaultState: Equatable, Sendable {
    case unlocked
    /// The vault could not be read; `reason` is a sentence for the person.
    case locked(reason: String)
}

/// The outcome of `WorkspaceStore.load()`.
public struct LoadedWorkspace: Sendable {
    public var workspace: Workspace
    public var vaultState: VaultState
    /// One sentence per file that could not be loaded.
    public var warnings: [String]
    /// True when the directory held no workspace at all.
    public var isFirstLaunch: Bool

    public init(workspace: Workspace, vaultState: VaultState, warnings: [String] = [], isFirstLaunch: Bool = false) {
        self.workspace = workspace
        self.vaultState = vaultState
        self.warnings = warnings
        self.isFirstLaunch = isFirstLaunch
    }
}

/// Persists the workspace as JSON files and its secret values in the vault.
///
/// Layout: `workspace.json` (orders, globals, active environment, scratch requests, forks),
/// `collections/<id>.json`, `environments/<id>.json`, `history.json`, `settings.json`.
/// No JSON file ever holds a secret value: the models do not encode them, and the store sends
/// them to the vault only.
public actor WorkspaceStore {
    private struct Manifest: Codable {
        var version = 1
        var collectionOrder: [UUID] = []
        var environmentOrder: [UUID] = []
        var globals: [Variable] = []
        var activeEnvironmentID: UUID?
        var scratchRequests: [RequestItem] = []
        var forks: [RequestFork] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            collectionOrder = try container.decodeIfPresent([UUID].self, forKey: .collectionOrder) ?? []
            environmentOrder = try container.decodeIfPresent([UUID].self, forKey: .environmentOrder) ?? []
            globals = try container.decodeIfPresent([Variable].self, forKey: .globals) ?? []
            activeEnvironmentID = try container.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
            scratchRequests = try container.decodeIfPresent([RequestItem].self, forKey: .scratchRequests) ?? []
            // One fork that cannot be read is left out; it never costs the rest of the file.
            forks = ((try? container.decodeIfPresent([Lossy<RequestFork>].self, forKey: .forks)) ?? [])
                .compactMap(\.value)
        }
    }

    /// Decodes to `nil` instead of failing.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private static let corruptMarker = ".corrupt-"

    private let directory: URL
    private let vault: any SecretVault
    private let encoder = StorageCoding.encoder()
    private let decoder = StorageCoding.decoder()

    private var history: [HistoryEntry]?
    private var didRestrictDirectories = false
    /// Slot ids found in files moved aside, by file path.
    private var quarantinedSlots: [String: Set<UUID>] = [:]
    /// Names of document files that exist but could not be read or moved aside at load. They are
    /// never deleted, and while one exists the vault is never pruned: its secrets cannot be listed.
    private var unreadableDocuments: Set<String> = []

    /// `.locked` after a load that could not read the vault, until `unlockVault` succeeds.
    public private(set) var vaultState: VaultState = .unlocked

    public init(directory: URL, vault: any SecretVault) {
        self.directory = directory
        self.vault = vault
    }

    private var workspaceFile: URL { directory.appendingPathComponent("workspace.json") }
    private var historyFile: URL { directory.appendingPathComponent("history.json") }
    private var settingsFile: URL { directory.appendingPathComponent("settings.json") }
    private var collectionsDirectory: URL { directory.appendingPathComponent("collections", isDirectory: true) }
    private var environmentsDirectory: URL { directory.appendingPathComponent("environments", isDirectory: true) }

    // MARK: Workspace

    /// Reads the workspace and fills every secret slot from the vault.
    ///
    /// Never fails: an undecodable file is moved aside as `<name>.corrupt-<timestamp>` and reported,
    /// and an unreadable vault leaves the secret values empty with `vaultState` locked.
    public func load() -> LoadedWorkspace {
        var warnings: [String] = []
        let collectionFiles = documentFiles(in: collectionsDirectory)
        let environmentFiles = documentFiles(in: environmentsDirectory)
        let isFirstLaunch = !FileManager.default.fileExists(atPath: workspaceFile.path)
            && collectionFiles.isEmpty && environmentFiles.isEmpty

        let manifest = decode(Manifest.self, at: workspaceFile, warnings: &warnings) ?? Manifest()
        var workspace = Workspace(
            collections: loadDocuments(
                Collection.self, kind: "collection", order: manifest.collectionOrder,
                files: collectionFiles, warnings: &warnings
            ),
            environments: loadDocuments(
                Environment.self, kind: "environment", order: manifest.environmentOrder,
                files: environmentFiles, warnings: &warnings
            ),
            globals: manifest.globals,
            activeEnvironmentID: manifest.activeEnvironmentID,
            scratchRequests: manifest.scratchRequests,
            forks: manifest.forks
        )
        // A fork whose original is gone is not lost: it becomes a one-off request. Not while a file
        // could not be read, though: its requests may be back at the next launch, and their forks with them.
        if unreadableDocuments.isEmpty {
            for orphan in workspace.removeForksWithoutOriginal() {
                var request = orphan.item
                request.name = "\(request.name) (\(orphan.name))"
                workspace.scratchRequests.append(request)
            }
        }
        vaultState = hydrate(&workspace)
        return LoadedWorkspace(
            workspace: workspace, vaultState: vaultState, warnings: warnings, isFirstLaunch: isFirstLaunch
        )
    }

    /// Writes the files whose content changed, removes those of deleted collections and environments,
    /// then replaces the vault content with the non-empty secret slots of the workspace.
    ///
    /// While the vault is locked the vault is left untouched: the workspace was loaded without its
    /// secret values, and writing those blanks would erase the stored ones. A vault failure is thrown
    /// after the JSON files were written.
    ///
    /// - Parameter secretsHydrated: false when `workspace` was captured while the vault was locked.
    ///   Its secret slots are blank, so the vault is left untouched even if it was unlocked since.
    public func save(_ workspace: Workspace, secretsHydrated: Bool = true) throws {
        try prepareDirectories()

        var collectionNames: Set<String> = []
        for collection in workspace.collections {
            let name = Self.fileName(for: collection.id)
            try write(collection, to: collectionsDirectory.appendingPathComponent(name))
            collectionNames.insert(name)
        }
        var environmentNames: Set<String> = []
        for environment in workspace.environments {
            let name = Self.fileName(for: environment.id)
            try write(environment, to: environmentsDirectory.appendingPathComponent(name))
            environmentNames.insert(name)
        }

        var manifest = Manifest()
        manifest.collectionOrder = workspace.collections.map(\.id)
        manifest.environmentOrder = workspace.environments.map(\.id)
        manifest.globals = workspace.globals
        manifest.activeEnvironmentID = workspace.activeEnvironmentID
        manifest.scratchRequests = workspace.scratchRequests
        manifest.forks = workspace.forks
        try write(manifest, to: workspaceFile)

        try removeDocuments(in: collectionsDirectory, except: collectionNames.union(unreadableDocuments))
        try removeDocuments(in: environmentsDirectory, except: environmentNames.union(unreadableDocuments))

        guard vaultState == .unlocked, secretsHydrated else { return }
        var secrets = workspace.secretSlots().filter { !$0.value.isEmpty }
        // A file that could not be read may hold secret slots nobody can list: prune nothing.
        if !unreadableDocuments.isEmpty {
            for (id, value) in try vault.allSecrets() where secrets[id] == nil {
                secrets[id] = value
            }
        }
        // A file moved aside may be repaired and put back: keep the secrets it refers to.
        let quarantined = quarantinedSlotIDs()
        if !quarantined.isEmpty {
            for (id, value) in try vault.allSecrets() where quarantined.contains(id) && secrets[id] == nil {
                secrets[id] = value
            }
        }
        try vault.replaceAll(secrets)
    }

    /// Retries the vault after a locked load and fills the empty secret slots of the workspace.
    /// A slot filled in while the vault was locked keeps its value.
    /// - Returns: the workspace (unchanged when the vault is still locked) and the new state.
    public func unlockVault(hydrating workspace: Workspace) -> (workspace: Workspace, state: VaultState) {
        var hydrated = workspace
        vaultState = hydrate(&hydrated)
        return (hydrated, vaultState)
    }

    // MARK: Settings

    /// The saved settings, or the defaults when none were saved.
    public func loadSettings() -> AppSettings {
        var warnings: [String] = []
        return decode(AppSettings.self, at: settingsFile, warnings: &warnings) ?? AppSettings()
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try prepareDirectories()
        try write(settings, to: settingsFile)
    }

    // MARK: History

    /// The history, newest first.
    public func loadHistory() -> [HistoryEntry] {
        if let history { return history }
        var warnings: [String] = []
        let loaded = decode([HistoryEntry].self, at: historyFile, warnings: &warnings) ?? []
        history = loaded
        return loaded
    }

    /// Puts the entry first and drops the oldest entries beyond `limit`.
    public func appendHistory(_ entry: HistoryEntry, limit: Int) throws {
        var entries = loadHistory()
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        try saveHistory(Array(entries.prefix(max(limit, 0))))
    }

    public func removeHistory(id: UUID) throws {
        try saveHistory(loadHistory().filter { $0.id != id })
    }

    public func clearHistory() throws {
        try saveHistory([])
    }

    private func saveHistory(_ entries: [HistoryEntry]) throws {
        try prepareDirectories()
        try write(entries, to: historyFile)
        history = entries
    }

    // MARK: Secrets

    /// Fills the empty secret slots from the vault and reports whether the vault could be read.
    private func hydrate(_ workspace: inout Workspace) -> VaultState {
        do {
            let secrets = try vault.allSecrets()
            workspace.forEachSecret { id, value in
                if value.isEmpty, let stored = secrets[id] { value = stored }
            }
            return .unlocked
        } catch let error as VaultError {
            return .locked(reason: Self.reason(for: error))
        } catch {
            return .locked(reason: "Your saved secrets could not be read. \(error.localizedDescription)")
        }
    }

    private static func reason(for error: VaultError) -> String {
        switch error {
        case .accessDenied:
            "Bee was not allowed to read its key from the Keychain, so your saved secrets stay locked."
        case .keyMissing:
            "The key that protects your saved secrets is no longer in the Keychain, so they cannot be decrypted."
        case .corrupted:
            "The secret vault is damaged or was encrypted with another key, so your saved secrets cannot be read."
        case .keychain(_, let message):
            "The Keychain reported an error, so your saved secrets stay locked. \(message)"
        case .io(let message):
            "The secret vault file could not be read. \(message)"
        }
    }

    /// The slot ids mentioned by the files moved aside that are still in the data directory.
    private func quarantinedSlotIDs() -> Set<UUID> {
        var current: [String: Set<UUID>] = [:]
        for folder in [directory, collectionsDirectory, environmentsDirectory] {
            for name in fileNames(in: folder) where name.contains(Self.corruptMarker) {
                let url = folder.appendingPathComponent(name)
                if let known = quarantinedSlots[url.path] {
                    current[url.path] = known
                } else if let data = try? Data(contentsOf: url) {
                    current[url.path] = Self.identifiers(in: String(decoding: data, as: UTF8.self))
                }
            }
        }
        quarantinedSlots = current
        return current.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
    }

    private static func identifiers(in text: String) -> Set<UUID> {
        let pattern = /[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/
        return Set(text.matches(of: pattern).compactMap { UUID(uuidString: String($0.output)) })
    }

    // MARK: Files

    private static func fileName(for id: UUID) -> String { "\(id.uuidString).json" }

    private func prepareDirectories() throws {
        let folders = [directory, collectionsDirectory, environmentsDirectory]
        for folder in folders { try SecureFile.createDirectory(at: folder) }
        guard !didRestrictDirectories else { return }
        for folder in folders { try SecureFile.restrictDirectory(at: folder) }
        didRestrictDirectories = true
    }

    /// Writes the value unless the file already holds exactly that content.
    private func write(_ value: some Encodable, to url: URL) throws {
        let data = try encoder.encode(value)
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try SecureFile.write(data, to: url)
    }

    private func fileNames(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The `<uuid>.json` files of a folder, by id.
    private func documentFiles(in folder: URL) -> [UUID: URL] {
        var files: [UUID: URL] = [:]
        for name in fileNames(in: folder) where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(".json".count))) else { continue }
            files[id] = folder.appendingPathComponent(name)
        }
        return files
    }

    private func removeDocuments(in folder: URL, except kept: Set<String>) throws {
        for (_, url) in documentFiles(in: folder) where !kept.contains(url.lastPathComponent) {
            try SecureFile.remove(url)
        }
    }

    /// Loads the documents in manifest order, then any file the manifest does not list
    /// (a manifest lost or written before a crash must not hide data that is on disk).
    private func loadDocuments<Document: Decodable & Identifiable>(
        _ type: Document.Type, kind: String, order: [UUID], files: [UUID: URL], warnings: inout [String]
    ) -> [Document] where Document.ID == UUID {
        let listed = Set(order)
        let unlisted = files.keys.filter { !listed.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        var documents: [Document] = []
        var seen: Set<UUID> = []
        for id in order + unlisted {
            guard let url = files[id] else {
                warnings.append("The \(kind) \(id.uuidString) is listed in the workspace but its file is missing.")
                continue
            }
            guard let document = decode(type, at: url, warnings: &warnings), seen.insert(document.id).inserted else {
                continue
            }
            documents.append(document)
        }
        return documents
    }

    /// Decodes a file. A missing file is `nil`; an undecodable one is moved aside and reported.
    private func decode<Value: Decodable>(_ type: Value.Type, at url: URL, warnings: inout [String]) -> Value? {
        let name = relativeName(of: url)
        let data: Data
        do {
            guard let content = try SecureFile.read(url) else { return nil }
            data = content
        } catch {
            warnings.append("\(name) could not be read. \(error.message)")
            unreadableDocuments.insert(url.lastPathComponent)
            return nil
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            if let aside = moveAside(url) {
                warnings.append("\(name) could not be read and was moved aside as \(aside).")
            } else {
                warnings.append("\(name) could not be read.")
                unreadableDocuments.insert(url.lastPathComponent)
            }
            return nil
        }
    }

    /// Renames the file to `<name>.corrupt-<timestamp>`. Returns the new name, `nil` when the move failed.
    private func moveAside(_ url: URL) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.lastPathComponent + Self.corruptMarker + formatter.string(from: Date())
        let folder = url.deletingLastPathComponent()
        var name = base
        var attempt = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            attempt += 1
            name = "\(base)-\(attempt)"
        }
        guard rename(url.path, folder.appendingPathComponent(name).path) == 0 else { return nil }
        return name
    }

    private func relativeName(of url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        let isNested = parent == collectionsDirectory.lastPathComponent || parent == environmentsDirectory.lastPathComponent
        return isNested ? "\(parent)/\(url.lastPathComponent)" : url.lastPathComponent
    }
}
