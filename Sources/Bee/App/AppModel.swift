import AppKit
import BeeCore
import LocalAuthentication
import Observation
import SwiftUI

// MARK: - Navigation

/// What the sidebar selects and the detail area shows.
enum SidebarSelection: Hashable, Sendable {
    case request(UUID)
    case folder(UUID)
    case collection(UUID)
    case environment(UUID)
    case globals
    case history
}

/// The parts of a request, in wire order. A part is on the page only when the request has it
/// or the person just added it.
enum RequestSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case pathVariables, parameters, authorization, headers, body, preRequestScript, postResponseScript, settings

    var id: String { rawValue }

    /// True for a part that follows the address: it can be neither added nor removed.
    var followsAddress: Bool { self == .pathVariables }

    var title: String {
        switch self {
        case .pathVariables: "Path variables"
        case .parameters: "Parameters"
        case .authorization: "Authorization"
        case .headers: "Headers"
        case .body: "Body"
        case .preRequestScript: "Pre-request script"
        case .postResponseScript: "Post-response script"
        case .settings: "Settings"
        }
    }
}

enum ResponseSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case headers, body, tests, variablesSet, console, requestSent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .headers: "Headers"
        case .body: "Body"
        case .tests: "Tests"
        case .variablesSet: "Variables set"
        case .console: "Console"
        case .requestSent: "Request sent"
        }
    }
}

/// A short message shown at the bottom of the window, then dismissed.
struct Notice: Identifiable, Equatable {
    enum Kind { case info, error }

    let id = UUID()
    var kind: Kind
    var message: String
}

// MARK: - Request session

/// The live state of one open request: its editable content, its last exchange and its page layout.
/// Views bind to `item`; every change is committed to the workspace and saved by the model.
@Observable
final class RequestSession: Identifiable {
    let id: UUID
    var item: RequestItem {
        didSet { if item != oldValue { onChange?(self) } }
    }
    /// `nil` for a draft (a request not kept in a collection).
    var collectionID: UUID?

    var isSending = false
    var sendStartedAt: Date?
    var outcome: RunOutcome?
    /// The response as it may be drawn, copied or saved: secrets the server echoed back are masked.
    var shownResponse: HTTPResponse?
    /// True when `shownResponse` differs from what was received.
    var hidesEchoedSecrets = false
    var receivedAt: Date?
    /// Name of the environment the last exchange used.
    var sentEnvironmentName: String?

    var expandedRequestSections: Set<RequestSection>
    /// Parts the person added that are still empty.
    var addedRequestSections: Set<RequestSection> = []
    var expandedResponseSections: Set<ResponseSection> = [.body, .tests, .variablesSet]

    /// Path variable rows whose name left the address while this request was open. They come back
    /// with their value if the name does (an undo, a cut then paste); they are never saved.
    @ObservationIgnored private var retiredPathVariables: [KeyValue] = []

    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var onChange: ((RequestSession) -> Void)?

    init(item: RequestItem, collectionID: UUID?) {
        id = item.id
        self.item = item
        self.collectionID = collectionID
        expandedRequestSections = Set(RequestSection.allCases.filter { $0 != .settings })
    }

    /// The path variable rows to keep once the address becomes `address`. A row follows its variable
    /// through a rename typed one character at a time; a row whose name is gone is set aside.
    func pathVariables(for address: String) -> [KeyValue] {
        let result = PathVariables.reconcile(
            stored: item.pathVariables, aside: retiredPathVariables, address: address, previous: item.url
        )
        retiredPathVariables = result.aside
        return result.stored
    }

    /// True when the request has content for the part.
    func has(_ section: RequestSection) -> Bool {
        switch section {
        case .pathVariables: !PathVariables.names(in: item.url).isEmpty
        case .parameters: !item.queryParams.isEmpty
        case .authorization: item.auth.kind != .inherit
        case .headers: !item.headers.isEmpty
        case .body: item.body.mode != .none
        case .preRequestScript: !item.preRequestScript.isEmpty
        case .postResponseScript: !item.postResponseScript.isEmpty
        case .settings: item.settings != RequestSettings()
        }
    }

    func isVisible(_ section: RequestSection) -> Bool {
        has(section) || addedRequestSections.contains(section)
    }

    var visibleSections: [RequestSection] { RequestSection.allCases.filter(isVisible) }
    var absentSections: [RequestSection] {
        RequestSection.allCases.filter { !$0.followsAddress && !isVisible($0) }
    }

    /// Puts an absent part on the page, open.
    func add(_ section: RequestSection) {
        addedRequestSections.insert(section)
        expandedRequestSections.insert(section)
        if section == .authorization, item.auth.kind == .inherit { item.auth.kind = .bearer }
        if section == .body, item.body.mode == .none { item.body.mode = .raw }
    }

    /// Takes a part off the page and clears its content.
    func remove(_ section: RequestSection) {
        addedRequestSections.remove(section)
        switch section {
        case .pathVariables: break
        case .parameters: item.queryParams = []
        case .authorization: item.auth.kind = .inherit
        case .headers: item.headers = []
        case .body: item.body.mode = .none
        case .preRequestScript: item.preRequestScript = ""
        case .postResponseScript: item.postResponseScript = ""
        case .settings: item.settings = RequestSettings()
        }
    }
}

// MARK: - Application model

/// Where the application keeps its data and how it protects secrets.
struct AppEnvironment {
    var dataDirectory: URL
    var vault: any SecretVault
    /// True when the data is throwaway (debug harness): no Keychain, no authentication prompts.
    var isEphemeral: Bool

    static func resolve() -> AppEnvironment {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["BEE_DATA_DIR"], !path.isEmpty {
            return AppEnvironment(dataDirectory: URL(fileURLWithPath: path), vault: InMemoryVault(), isEphemeral: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = support.appendingPathComponent("Bee", isDirectory: true)
        let vault = EncryptedFileVault(
            fileURL: directory.appendingPathComponent("secrets.vault"), keyProvider: KeychainKeyProvider()
        )
        return AppEnvironment(dataDirectory: directory, vault: vault, isEphemeral: false)
    }
}

@Observable
final class AppModel {
    private(set) var workspace = Workspace()
    var settings = AppSettings() {
        didSet {
            guard isLoaded, settings != oldValue else { return }
            // Turning the reveal gate off is itself gated: put it back, ask, then apply.
            if oldValue.requireAuthenticationToReveal, !settings.requireAuthenticationToReveal,
               !isRevealGateChangeAuthorized, !environment.isEphemeral {
                settings.requireAuthenticationToReveal = true
                Task { await disableRevealGate() }
                return
            }
            persistSettings()
        }
    }
    private(set) var history: [HistoryEntry] = []
    private(set) var vaultState: VaultState = .unlocked
    private(set) var isLoaded = false
    var selection: SidebarSelection?
    var notice: Notice?

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let transport = URLSessionTransport()
    @ObservationIgnored private let runner: RequestRunner
    @ObservationIgnored private var sessions: [UUID: RequestSession] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastRevealAuthorization: Date?
    @ObservationIgnored private var isRevealGateChangeAuthorized = false
    @ObservationIgnored private var clipboardClearTask: Task<Void, Never>?
    /// Change count of the pasteboard right after a secret was copied; `nil` when none is there.
    @ObservationIgnored private var copiedSecretChangeCount: Int?

    private static let saveDelay: Duration = .milliseconds(600)
    private static let revealGracePeriod: TimeInterval = 30
    private static let clipboardLifetime: Duration = .seconds(60)

    init(environment: AppEnvironment = .resolve()) {
        self.environment = environment
        store = WorkspaceStore(directory: environment.dataDirectory, vault: environment.vault)
        runner = RequestRunner(transport: transport, scripts: JSScriptEngine(transport: transport))
    }

    // MARK: Loading and saving

    func load() async {
        guard !isLoaded else { return }
        let loaded = await store.load()
        workspace = loaded.isFirstLaunch ? SampleData.workspace() : loaded.workspace
        vaultState = loaded.vaultState
        settings = await store.loadSettings()
        history = await store.loadHistory()
        isLoaded = true
        if loaded.isFirstLaunch { scheduleSave() }
        if let warning = loaded.warnings.first {
            notice = Notice(kind: .error, message: warning)
        }
        if selection == nil, let first = workspace.collections.first?.allRequests.first {
            selection = .request(first.id)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Writes the workspace to disk immediately. Called before quitting.
    func saveNow() async {
        saveTask?.cancel()
        guard isLoaded else { return }
        do {
            // The lock state is captured with the snapshot: blanks loaded while locked must never
            // reach the vault, even if it is unlocked before this save runs.
            try await store.save(workspace, secretsHydrated: !isVaultLocked)
        } catch {
            notice = Notice(kind: .error, message: "Bee could not save your changes: \(error.localizedDescription)")
        }
    }

    private func persistSettings() {
        let snapshot = settings
        Task { [store] in try? await store.saveSettings(snapshot) }
    }

    /// Every change to the workspace goes through here so it is saved.
    private func mutate(_ body: (inout Workspace) -> Void) {
        body(&workspace)
        scheduleSave()
    }

    // MARK: Vault

    var isVaultLocked: Bool {
        if case .locked = vaultState { return true }
        return false
    }

    /// Tries again to read the secrets (the person may have denied the Keychain prompt).
    func retryVaultUnlock() async {
        saveTask?.cancel()
        let (hydrated, state) = await store.unlockVault(hydrating: workspace)
        vaultState = state
        if state == .unlocked {
            workspace = hydrated
            for session in sessions.values { refresh(session) }
            scheduleSave()
        }
    }

    // MARK: Sessions

    /// The live session of a request, created on first use. `nil` when the request no longer exists.
    func session(for requestID: UUID) -> RequestSession? {
        if let session = sessions[requestID] { return session }
        guard let located = locate(requestID) else { return nil }
        let session = RequestSession(item: located.item, collectionID: located.collectionID)
        session.onChange = { [weak self] session in self?.commit(session) }
        sessions[requestID] = session
        return session
    }

    private func locate(_ requestID: UUID) -> (item: RequestItem, collectionID: UUID?)? {
        if let draft = workspace.scratchRequests.first(where: { $0.id == requestID }) {
            return (draft, nil)
        }
        for collection in workspace.collections {
            if let item = collection.request(id: requestID) { return (item, collection.id) }
        }
        return nil
    }

    private func commit(_ session: RequestSession) {
        if let previous = locate(session.id)?.item {
            let guarded = guardingSecrets(in: session.item, previous: previous)
            if guarded != session.item {
                let handler = session.onChange
                session.onChange = nil
                session.item = guarded
                session.onChange = handler
            }
        }
        mutate { workspace in
            if let collectionID = session.collectionID,
               let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) {
                workspace.collections[index].update(session.item)
            } else if let index = workspace.scratchRequests.firstIndex(where: { $0.id == session.id }) {
                workspace.scratchRequests[index] = session.item
            }
        }
    }

    /// Re-reads a session's request from the workspace after a change made elsewhere.
    private func refresh(_ session: RequestSession) {
        guard let located = locate(session.id) else {
            sessions[session.id] = nil
            return
        }
        session.collectionID = located.collectionID
        if session.item != located.item {
            let handler = session.onChange
            session.onChange = nil
            session.item = located.item
            session.onChange = handler
        }
    }

    private func dropSessions(in node: CollectionNode) {
        switch node {
        case .request(let request):
            sessions[request.id]?.task?.cancel()
            sessions[request.id] = nil
        case .folder(let folder):
            folder.items.forEach(dropSessions)
        }
    }

    // MARK: Secret downgrades

    /// True when a secret may be shown right now without asking again.
    private var isRevealAuthorized: Bool {
        if environment.isEphemeral || !settings.requireAuthenticationToReveal { return true }
        guard let last = lastRevealAuthorization else { return false }
        return Date().timeIntervalSince(last) < Self.revealGracePeriod
    }

    /// Turning a secret back into a plain value would draw it. Unless the person just authenticated,
    /// the value is cleared instead, so unticking "secret" can never be a way to read one.
    private func guardingSecrets(in item: RequestItem, previous: RequestItem) -> RequestItem {
        guard !isRevealAuthorized else { return item }
        let downgraded = Set(previous.secretSlots().keys).subtracting(item.secretSlots().keys)
        guard !downgraded.isEmpty else { return item }
        var item = item
        func clear(_ rows: inout [KeyValue]) {
            for index in rows.indices where downgraded.contains(rows[index].id) { rows[index].value = "" }
        }
        clear(&item.pathVariables)
        clear(&item.queryParams)
        clear(&item.headers)
        clear(&item.body.urlEncoded)
        for index in item.body.formData.indices where downgraded.contains(item.body.formData[index].id) {
            item.body.formData[index].value = ""
        }
        return item
    }

    private func guardingSecrets(in variables: [Variable], previous: [Variable]) -> [Variable] {
        guard !isRevealAuthorized else { return variables }
        let wasSecret = Set(previous.filter(\.isSecret).map(\.id))
        return variables.map { variable in
            guard wasSecret.contains(variable.id), !variable.isSecret else { return variable }
            var variable = variable
            variable.value = ""
            return variable
        }
    }

    // MARK: Variables

    /// The variables visible to a request of the given collection, for placeholders in editors.
    func variableContext(collectionID: UUID?) -> VariableContext {
        VariableContext(
            environment: workspace.activeEnvironment?.variables ?? [],
            collection: workspace.collections.first { $0.id == collectionID }?.variables ?? [],
            globals: workspace.globals
        )
    }

    // MARK: Requests

    /// Creates a request in the selected collection or folder, or as a draft, and selects it.
    @discardableResult
    func newRequest() -> UUID {
        let item = RequestItem()
        switch selection {
        case .collection(let id):
            addRequest(item, toCollection: id, folder: nil)
        case .folder(let id):
            if let collection = workspace.collection(containing: id) {
                addRequest(item, toCollection: collection.id, folder: id)
            } else {
                addDraft(item)
            }
        case .request(let id):
            if let collection = workspace.collection(containing: id) {
                addRequest(item, toCollection: collection.id, folder: collection.ancestry(of: id)?.last?.id)
            } else {
                addDraft(item)
            }
        default:
            addDraft(item)
        }
        return item.id
    }

    func addDraft(_ item: RequestItem) {
        mutate { $0.scratchRequests.append(item) }
        selection = .request(item.id)
    }

    func addRequest(_ item: RequestItem, toCollection collectionID: UUID, folder folderID: UUID?) {
        mutate { workspace in
            guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
            workspace.collections[index].insert(.request(item), inFolder: folderID)
        }
        selection = .request(item.id)
    }

    func duplicateRequest(_ requestID: UUID) {
        guard let located = locate(requestID) else { return }
        let copy = located.item.duplicated(name: located.item.name + " copy")
        if let collectionID = located.collectionID,
           let collection = workspace.collections.first(where: { $0.id == collectionID }) {
            addRequest(copy, toCollection: collectionID, folder: collection.ancestry(of: requestID)?.last?.id)
        } else {
            addDraft(copy)
        }
    }

    func renameRequest(_ requestID: UUID, to name: String) {
        guard let session = session(for: requestID) else { return }
        session.item.name = name
    }

    // MARK: Collections and folders

    @discardableResult
    func newCollection() -> UUID {
        let collection = Collection()
        mutate { $0.collections.append(collection) }
        selection = .collection(collection.id)
        return collection.id
    }

    @discardableResult
    func newFolder(inCollection collectionID: UUID, parent folderID: UUID?) -> UUID {
        let folder = Folder()
        mutate { workspace in
            guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
            workspace.collections[index].insert(.folder(folder), inFolder: folderID)
        }
        selection = .folder(folder.id)
        return folder.id
    }

    func collection(id: UUID) -> Collection? {
        workspace.collections.first { $0.id == id }
    }

    /// Replaces a collection's own fields (name, notes, variables, authorization, scripts).
    /// The tree of items is kept from the workspace so a stale copy can never drop requests.
    func updateCollection(_ collection: Collection) {
        mutate { workspace in
            guard let index = workspace.collections.firstIndex(where: { $0.id == collection.id }) else { return }
            var updated = collection
            updated.items = workspace.collections[index].items
            updated.variables = guardingSecrets(
                in: collection.variables, previous: workspace.collections[index].variables
            )
            workspace.collections[index] = updated
        }
    }

    func folder(id: UUID) -> Folder? {
        workspace.collection(containing: id)?.folder(id: id)
    }

    /// Replaces a folder's own fields; its items are kept from the workspace.
    func updateFolder(_ folder: Folder) {
        mutate { workspace in
            guard let index = workspace.collections.firstIndex(where: { $0.node(id: folder.id) != nil }),
                  let current = workspace.collections[index].folder(id: folder.id) else { return }
            var updated = folder
            updated.items = current.items
            workspace.collections[index].update(updated)
        }
    }

    func deleteCollection(_ collectionID: UUID) {
        guard let collection = collection(id: collectionID) else { return }
        collection.items.forEach(dropSessions)
        mutate { $0.collections.removeAll { $0.id == collectionID } }
        repairSelection()
    }

    /// Deletes a request, a folder or a draft.
    func deleteNode(_ nodeID: UUID) {
        if workspace.scratchRequests.contains(where: { $0.id == nodeID }) {
            sessions[nodeID]?.task?.cancel()
            sessions[nodeID] = nil
            mutate { $0.scratchRequests.removeAll { $0.id == nodeID } }
        } else if let index = workspace.collections.firstIndex(where: { $0.node(id: nodeID) != nil }) {
            mutate { workspace in
                if let removed = workspace.collections[index].remove(id: nodeID) {
                    dropSessions(in: removed)
                }
            }
        }
        repairSelection()
    }

    /// Moves a request, a folder or a draft into a collection (root when `folderID` is nil).
    func moveNode(_ nodeID: UUID, toCollection collectionID: UUID, folder folderID: UUID?, at position: Int? = nil) {
        guard let targetIndex = workspace.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        // A folder cannot move into itself or one of its descendants.
        if let folderID, folderID == nodeID { return }
        if let folderID, let source = workspace.collection(containing: nodeID),
           let path = source.ancestry(of: folderID), path.contains(where: { $0.id == nodeID }) {
            return
        }
        mutate { workspace in
            var node: CollectionNode?
            if let draftIndex = workspace.scratchRequests.firstIndex(where: { $0.id == nodeID }) {
                node = .request(workspace.scratchRequests.remove(at: draftIndex))
            } else if let sourceIndex = workspace.collections.firstIndex(where: { $0.node(id: nodeID) != nil }) {
                node = workspace.collections[sourceIndex].remove(id: nodeID)
            }
            guard let node else { return }
            if !workspace.collections[targetIndex].insert(node, inFolder: folderID, at: position) {
                workspace.collections[targetIndex].insert(node, inFolder: nil)
            }
        }
        for session in sessions.values { refresh(session) }
    }

    private func repairSelection() {
        switch selection {
        case .request(let id) where locate(id) == nil,
             .folder(let id) where folder(id: id) == nil,
             .collection(let id) where collection(id: id) == nil,
             .environment(let id) where !workspace.environments.contains(where: { $0.id == id }):
            selection = nil
        default:
            break
        }
    }

    // MARK: Environments

    @discardableResult
    func newEnvironment() -> UUID {
        let environment = BeeCore.Environment()
        mutate { workspace in
            workspace.environments.append(environment)
            if workspace.activeEnvironmentID == nil { workspace.activeEnvironmentID = environment.id }
        }
        selection = .environment(environment.id)
        return environment.id
    }

    func updateEnvironment(_ environment: BeeCore.Environment) {
        mutate { workspace in
            guard let index = workspace.environments.firstIndex(where: { $0.id == environment.id }) else { return }
            var updated = environment
            updated.variables = guardingSecrets(
                in: environment.variables, previous: workspace.environments[index].variables
            )
            workspace.environments[index] = updated
        }
    }

    func duplicateEnvironment(_ environmentID: UUID) {
        guard let source = workspace.environments.first(where: { $0.id == environmentID }) else { return }
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " copy"
        copy.variables = source.variables.map { var variable = $0; variable.id = UUID(); return variable }
        mutate { $0.environments.append(copy) }
        selection = .environment(copy.id)
    }

    func deleteEnvironment(_ environmentID: UUID) {
        mutate { workspace in
            workspace.environments.removeAll { $0.id == environmentID }
            if workspace.activeEnvironmentID == environmentID {
                workspace.activeEnvironmentID = workspace.environments.first?.id
            }
        }
        repairSelection()
    }

    func setActiveEnvironment(_ environmentID: UUID?) {
        mutate { $0.activeEnvironmentID = environmentID }
    }

    func updateGlobals(_ variables: [Variable]) {
        mutate { $0.globals = guardingSecrets(in: variables, previous: $0.globals) }
    }

    // MARK: Sending

    func send(_ session: RequestSession) {
        guard !session.isSending else { return }
        let input = RunInput(
            item: session.item, collectionID: session.collectionID, workspace: workspace, settings: settings
        )
        let environmentName = workspace.activeEnvironment?.name
        session.isSending = true
        session.sendStartedAt = Date()
        session.task = Task { [weak self, runner] in
            let outcome = await runner.run(input)
            let shown = await Task.detached { AppModel.masking(outcome.response, with: outcome.redactor) }.value
            guard let self else { return }
            session.isSending = false
            session.sendStartedAt = nil
            session.task = nil
            session.shownResponse = shown
            session.hidesEchoedSecrets = shown?.headers != outcome.response?.headers
                || shown?.body != outcome.response?.body
            // The address a response came from can carry a secret (a path variable, a parameter):
            // it is then never used to name a saved file.
            if let sent = outcome.sentRequest?.url, sent.contains(Redactor.mask) { session.shownResponse?.finalURL = nil }
            session.outcome = outcome
            session.receivedAt = Date()
            session.sentEnvironmentName = environmentName
            if !outcome.variableChanges.isEmpty {
                mutate { $0.apply(outcome.variableChanges, collectionID: session.collectionID) }
            }
            record(outcome.historyEntry)
        }
    }

    func cancel(_ session: RequestSession) {
        session.task?.cancel()
    }

    /// A copy of the response where every secret known to the run is masked in headers and in a
    /// textual body. Binary bodies are left as received.
    nonisolated static func masking(_ response: HTTPResponse?, with redactor: Redactor) -> HTTPResponse? {
        guard var response, !redactor.isEmpty else { return response }
        if let address = response.finalURL?.absoluteString, redactor.redact(address) != address {
            response.finalURL = nil
        }
        response.headers = response.headers.map { HeaderEntry(name: $0.name, value: redactor.redact($0.value)) }
        if !response.body.prefix(1024).contains(0), let text = String(data: response.body, encoding: .utf8) {
            let masked = redactor.redact(text)
            if masked != text { response.body = Data(masked.utf8) }
        }
        return response
    }

    // MARK: History

    private func record(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        let limit = max(settings.historyLimit, 1)
        if history.count > limit { history.removeLast(history.count - limit) }
        Task { [store] in try? await store.appendHistory(entry, limit: limit) }
    }

    /// Opens what was sent as a new draft, ready to send again.
    func reopen(_ entry: HistoryEntry) {
        if let sourceID = entry.sourceRequestID, locate(sourceID) != nil {
            selection = .request(sourceID)
        } else {
            addDraft(entry.request.duplicated())
        }
    }

    func removeHistory(_ entryID: UUID) {
        history.removeAll { $0.id == entryID }
        Task { [store] in try? await store.removeHistory(id: entryID) }
    }

    func clearHistory() {
        history = []
        Task { [store] in try? await store.clearHistory() }
    }

    // MARK: Import and export

    /// Imports a Postman or Bee file. Returns a sentence describing what was added.
    @discardableResult
    func importData(_ data: Data) throws -> String {
        switch Importer.detect(data) {
        case .postmanCollection, .beeCollection:
            let collection = try Importer.collection(from: data)
            mutate { $0.collections.append(collection) }
            selection = .collection(collection.id)
            return "Imported collection “\(collection.name)” (\(collection.allRequests.count) requests)."
        case .postmanEnvironment, .beeEnvironment:
            let environment = try Importer.environment(from: data)
            mutate { $0.environments.append(environment) }
            selection = .environment(environment.id)
            return "Imported environment “\(environment.name)” (\(environment.variables.count) variables)."
        case nil:
            throw ImportError.unrecognizedFormat
        }
    }

    /// Creates a draft from a cURL command.
    func importCurl(_ command: String) throws {
        addDraft(try CurlCodec.parse(command))
    }

    func exportData(forCollection collectionID: UUID) throws -> Data? {
        guard let collection = collection(id: collectionID) else { return nil }
        return try BeeArchive.data(for: collection)
    }

    func exportData(forEnvironment environmentID: UUID) throws -> Data? {
        guard let environment = workspace.environments.first(where: { $0.id == environmentID }) else { return nil }
        return try BeeArchive.data(for: environment)
    }

    /// The request as a cURL command in template form; secret values are never included.
    func curlCommand(for session: RequestSession) -> String {
        let collection = session.collectionID.flatMap { collection(id: $0) }
        let folders = collection?.ancestry(of: session.id) ?? []
        let auth = RequestBuilder.effectiveAuth(for: session.item, folders: folders, collection: collection)
        return CurlCodec.command(for: session.item, auth: auth)
    }

    // MARK: Secrets

    /// Asks for Touch ID or the account password before a secret is shown or copied.
    func authorizeReveal() async -> Bool {
        if environment.isEphemeral || !settings.requireAuthenticationToReveal { return true }
        if let last = lastRevealAuthorization, Date().timeIntervalSince(last) < Self.revealGracePeriod {
            return true
        }
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // Only a Mac with no password at all has nothing to ask; any other failure denies.
            return policyError?.code == LAError.passcodeNotSet.rawValue
        }
        do {
            let granted = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "reveal a secret"
            )
            if granted { lastRevealAuthorization = Date() }
            return granted
        } catch {
            return false
        }
    }

    /// Turns the reveal gate off after the person authenticated.
    private func disableRevealGate() async {
        lastRevealAuthorization = nil
        guard await authorizeReveal() else { return }
        isRevealGateChangeAuthorized = true
        settings.requireAuthenticationToReveal = false
        isRevealGateChangeAuthorized = false
    }

    /// Copies text to the clipboard. A secret stays on this Mac (no Universal Clipboard), is marked
    /// concealed in the same write (clipboard managers skip it), and is removed after a minute or
    /// when Bee quits, if it is still there.
    func copy(_ text: String, isSecret: Bool = false) {
        let pasteboard = NSPasteboard.general
        clipboardClearTask?.cancel()
        copiedSecretChangeCount = nil
        guard isSecret else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
        copiedSecretChangeCount = pasteboard.changeCount
        clipboardClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.clipboardLifetime)
            guard !Task.isCancelled else { return }
            self?.clearCopiedSecret()
        }
    }

    /// Removes a copied secret from the clipboard if nothing replaced it since.
    func clearCopiedSecret() {
        guard let changeCount = copiedSecretChangeCount else { return }
        copiedSecretChangeCount = nil
        if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
    }

    // MARK: Notices

    func report(_ error: any Error) {
        notice = Notice(kind: .error, message: error.localizedDescription)
    }

    func inform(_ message: String) {
        notice = Notice(kind: .info, message: message)
    }
}
