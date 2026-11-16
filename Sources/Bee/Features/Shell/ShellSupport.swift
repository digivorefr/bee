import AppKit
import BeeCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Metrics

/// Sizes the shell needs that `Theme` does not name yet, built on its values.
enum ShellMetrics {
    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 280
    static let sidebarMaxWidth: CGFloat = 360
    /// One step of the collections tree.
    static let indent: CGFloat = Theme.Space.l
    static let chevronColumn: CGFloat = Theme.Space.l
    static let glyphColumn: CGFloat = Theme.Space.xl
    /// Holds the longest method (`OPTIONS`) at caption size.
    static let methodColumn: CGFloat = Theme.Space.xxl + Theme.Space.xl
    /// A bare table row.
    static let tableRow: CGFloat = Theme.Space.xl + Theme.Space.xs
    static let variableNameColumn: CGFloat = 220
    static let settingsWidth: CGFloat = 460
    static let pageMaxWidth: CGFloat = 860
    static let noticeLifetime: Duration = .seconds(5)
}

// MARK: - Shell state

/// What the window remembers while the application runs: which tree rows are open, the row being
/// renamed, and the deletion waiting for confirmation.
@Observable
final class ShellState {
    static let shared = ShellState()

    /// The event monitor that turns a double-click on a sidebar row into a rename.
    @ObservationIgnored var doubleClickMonitor: Any?

    enum PendingDelete: Identifiable, Equatable {
        case collection(id: UUID, name: String, requestCount: Int)
        case folder(id: UUID, name: String, requestCount: Int)
        case environment(id: UUID, name: String)

        var id: UUID {
            switch self {
            case .collection(let id, _, _), .folder(let id, _, _), .environment(let id, _): id
            }
        }

        var title: String {
            switch self {
            case .collection(_, let name, let count):
                "Delete the collection “\(name)” and its \(Self.requests(count))?"
            case .folder(_, let name, let count):
                "Delete the folder “\(name)” and its \(Self.requests(count))?"
            case .environment(_, let name):
                "Delete the environment “\(name)”?"
            }
        }

        var message: String {
            switch self {
            case .collection, .folder: "This cannot be undone."
            case .environment: "Its variables and secrets are removed from this Mac. This cannot be undone."
            }
        }

        var confirmLabel: String {
            switch self {
            case .collection: "Delete collection"
            case .folder: "Delete folder"
            case .environment: "Delete environment"
            }
        }

        private static func requests(_ count: Int) -> String {
            count == 1 ? "1 request" : "\(count) requests"
        }
    }

    /// Collections are open unless listed here; folders are closed unless listed here.
    private var toggled: Set<UUID> = []
    var renaming: SidebarSelection?
    var renameText = ""
    var pendingDelete: PendingDelete?

    func isCollectionExpanded(_ id: UUID) -> Bool { !toggled.contains(id) }
    func isFolderExpanded(_ id: UUID) -> Bool { toggled.contains(id) }

    func toggle(_ id: UUID) {
        if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
    }

    func expandCollection(_ id: UUID) { toggled.remove(id) }
    func expandFolder(_ id: UUID) { toggled.insert(id) }

    /// Opens every row above the selected one so it is on screen.
    func reveal(_ selection: SidebarSelection?, in workspace: Workspace) {
        let nodeID: UUID
        switch selection {
        case .request(let id), .folder(let id): nodeID = id
        default: return
        }
        guard let collection = workspace.collection(containing: nodeID) else { return }
        expandCollection(collection.id)
        for folder in collection.ancestry(of: nodeID) ?? [] { expandFolder(folder.id) }
    }

    func beginRename(_ selection: SidebarSelection, name: String) {
        renameText = name
        renaming = selection
    }

    func cancelRename() { renaming = nil }
}

// MARK: - Model conveniences

extension AppModel {
    /// The name of what is selected, for the window title.
    var selectionTitle: String {
        switch selection {
        case .request(let id): session(for: id)?.item.name ?? "Bee"
        case .folder(let id): folder(id: id)?.name ?? "Bee"
        case .collection(let id): collection(id: id)?.name ?? "Bee"
        case .environment(let id): environment(id: id)?.name ?? "Bee"
        case .globals: "Globals"
        case .history: "History"
        case nil: "Bee"
        }
    }

    /// Where the selected thing lives, or what it is.
    var selectionBreadcrumb: String {
        switch selection {
        case .request(let id):
            guard let collection = workspace.collection(containing: id) else { return "Draft" }
            return path(in: collection, to: id)
        case .folder(let id):
            guard let collection = workspace.collection(containing: id) else { return "Folder" }
            return path(in: collection, to: id)
        case .collection: return "Collection"
        case .environment: return "Environment"
        case .globals: return "Variables for every environment"
        case .history, nil: return ""
        }
    }

    private func path(in collection: Collection, to nodeID: UUID) -> String {
        ([collection.name] + (collection.ancestry(of: nodeID) ?? []).map(\.name)).joined(separator: " › ")
    }

    func environment(id: UUID) -> BeeCore.Environment? {
        workspace.environments.first { $0.id == id }
    }

    /// Where a new folder goes for the current selection: the selected collection or folder, or
    /// the folder that holds the selected request.
    var newFolderTarget: (collectionID: UUID, folderID: UUID?)? {
        switch selection {
        case .collection(let id):
            return collection(id: id).map { ($0.id, nil) }
        case .folder(let id):
            return workspace.collection(containing: id).map { ($0.id, id) }
        case .request(let id):
            guard let collection = workspace.collection(containing: id) else { return nil }
            return (collection.id, collection.ancestry(of: id)?.last?.id)
        default:
            return nil
        }
    }

    /// The collection the selection belongs to.
    var selectedCollectionID: UUID? {
        switch selection {
        case .collection(let id): collection(id: id)?.id
        case .folder(let id), .request(let id): workspace.collection(containing: id)?.id
        default: nil
        }
    }

    var selectedRequestID: UUID? {
        if case .request(let id) = selection { return id }
        return nil
    }

    /// Shows an error the shell words itself.
    func reportProblem(_ message: String) {
        notice = Notice(kind: .error, message: message)
    }
}

extension Folder {
    /// Every request in the folder, at any depth.
    var requestCount: Int {
        items.reduce(0) { total, node in
            switch node {
            case .request: total + 1
            case .folder(let folder): total + folder.requestCount
            }
        }
    }
}

// MARK: - Actions shared by the sidebar and the menus

enum ShellActions {
    // MARK: Creating

    static func newFolder(_ model: AppModel) {
        guard let target = model.newFolderTarget else {
            model.inform("A folder lives in a collection. Select a collection or a folder first.")
            return
        }
        let shell = ShellState.shared
        shell.expandCollection(target.collectionID)
        if let folderID = target.folderID { shell.expandFolder(folderID) }
        model.newFolder(inCollection: target.collectionID, parent: target.folderID)
    }

    static func newRequest(_ model: AppModel, inCollection collectionID: UUID, folder folderID: UUID?) {
        let shell = ShellState.shared
        shell.expandCollection(collectionID)
        if let folderID { shell.expandFolder(folderID) }
        model.addRequest(RequestItem(), toCollection: collectionID, folder: folderID)
    }

    static func newFolder(_ model: AppModel, inCollection collectionID: UUID, parent folderID: UUID?) {
        let shell = ShellState.shared
        shell.expandCollection(collectionID)
        if let folderID { shell.expandFolder(folderID) }
        model.newFolder(inCollection: collectionID, parent: folderID)
    }

    // MARK: Deleting

    /// Deletes a folder at once when it holds no request; asks first otherwise.
    static func deleteFolder(_ folder: Folder, model: AppModel) {
        let count = folder.requestCount
        if count == 0 {
            model.deleteNode(folder.id)
        } else {
            ShellState.shared.pendingDelete = .folder(id: folder.id, name: folder.name, requestCount: count)
        }
    }

    static func deleteCollection(_ collection: Collection, model: AppModel) {
        let count = collection.allRequests.count
        if count == 0 {
            model.deleteCollection(collection.id)
        } else {
            ShellState.shared.pendingDelete = .collection(id: collection.id, name: collection.name, requestCount: count)
        }
    }

    static func confirm(_ pending: ShellState.PendingDelete, model: AppModel) {
        switch pending {
        case .collection(let id, _, _): model.deleteCollection(id)
        case .folder(let id, _, _): model.deleteNode(id)
        case .environment(let id, _): model.deleteEnvironment(id)
        }
    }

    // MARK: Import

    static func importFromPanel(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.title = "Import"
        panel.prompt = "Import"
        panel.message = "Choose Postman exports or Bee archives."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, model: model)
    }

    /// Imports each file; the notice tells what the last one added, or what went wrong.
    @discardableResult
    static func importFiles(_ urls: [URL], model: AppModel) -> Bool {
        let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "json" }
        guard !files.isEmpty else {
            model.reportProblem("Bee imports .json files: Postman exports and Bee archives. Drop one of those.")
            return false
        }
        var imported = false
        for url in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                model.inform(try model.importData(data))
                imported = true
            } catch let error as ImportError {
                model.reportProblem("“\(url.lastPathComponent)” was not imported. \(error.localizedDescription)")
            } catch {
                model.reportProblem(
                    "Bee could not read “\(url.lastPathComponent)”: \(error.localizedDescription) Check the file, then try again."
                )
            }
        }
        return imported
    }

    static func importCurlFromClipboard(_ model: AppModel) {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            model.reportProblem("The clipboard holds no text. Copy a cURL command, then try again.")
            return
        }
        do {
            try model.importCurl(text)
            model.inform("Created a draft from the cURL command.")
        } catch {
            model.reportProblem(
                "The clipboard does not hold a cURL command Bee can read. Copy a command that starts with “curl”, then try again."
            )
        }
    }

    // MARK: Export

    static func exportSelectedCollection(_ model: AppModel) {
        guard let id = model.selectedCollectionID else {
            model.inform("Select a collection to export it.")
            return
        }
        exportCollection(id, model: model)
    }

    static func exportCollection(_ collectionID: UUID, model: AppModel) {
        guard let collection = model.collection(id: collectionID) else { return }
        export(named: collection.name, kind: "collection", model: model) {
            try model.exportData(forCollection: collectionID)
        }
    }

    static func exportEnvironment(_ environmentID: UUID, model: AppModel) {
        guard let environment = model.environment(id: environmentID) else { return }
        export(named: environment.name, kind: "environment", model: model) {
            try model.exportData(forEnvironment: environmentID)
        }
    }

    private static func export(named name: String, kind: String, model: AppModel, data: () throws -> Data?) {
        let panel = NSSavePanel()
        panel.title = "Export \(kind)"
        panel.prompt = "Export"
        panel.message = "Secret values are not written to the file."
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let content = try data() else { return }
            try content.write(to: url, options: .atomic)
            model.inform("Exported the \(kind) “\(name)” to \(url.lastPathComponent), without its secrets.")
        } catch {
            model.reportProblem(
                "Bee could not export “\(name)”: \(error.localizedDescription) Choose another location, then try again."
            )
        }
    }

    private static func fileName(for name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Untitled" : cleaned) + ".json"
    }
}
