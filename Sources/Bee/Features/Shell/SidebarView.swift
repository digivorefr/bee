import AppKit
import BeeCore
import SwiftUI
import UniformTypeIdentifiers

/// New request, Drafts, Collections, Environments, History.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var shell: ShellState { .shared }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            NewRequestRow()
            if !model.workspace.scratchRequests.isEmpty {
                Section("Drafts") {
                    ForEach(model.workspace.scratchRequests) { draft in
                        requestRow(draft, depth: 0, isInCollection: false)
                    }
                }
                .collapsible(false)
            }
            Section {
                ForEach(treeRows) { row in
                    treeRow(row)
                }
            } header: {
                SidebarSectionHeader(title: "Collections", addLabel: "New collection", order: $model.settings.collectionOrder) {
                    model.newCollection()
                }
            }
            .collapsible(false)
            Section {
                ForEach(model.shownEnvironments) { environment in
                    environmentRow(environment)
                }
                SidebarRow(selection: .globals, name: "Globals", depth: 0, kind: .leaf(glyph: "curlybraces"))
                    .tag(SidebarSelection.globals)
                    // An environment dropped here goes last, right above it.
                    .dropDestination(for: String.self) { items, _ in
                        guard let last = model.shownEnvironments.last else { return false }
                        return dropEnvironment(items, on: last.id)
                    } isTargeted: { isOver in
                        guard let last = model.shownEnvironments.last else { return }
                        shell.hover(.environments, over: last.id, isOver: isOver, order: model.shownEnvironments.map(\.id))
                    }
            } header: {
                SidebarSectionHeader(title: "Environments", addLabel: "New environment", order: $model.settings.environmentOrder) {
                    model.newEnvironment()
                }
            }
            .collapsible(false)
            Section {
                SidebarRow(selection: .history, name: "History", depth: 0, kind: .leaf(glyph: "clock"))
                    .tag(SidebarSelection.history)
            }
            .collapsible(false)
        }
        .listStyle(.sidebar)
        .onKeyPress(.return) { beginRenameOfSelection() }
        // A double-click renames the row it lands on. The list consumes mouse-downs for selection,
        // so a SwiftUI double-tap gesture on a row never fires: the click count is read from the
        // event itself.
        .onAppear { installClickMonitor() }
        .onDisappear { removeClickMonitor() }
        .dropDestination(for: URL.self) { urls, _ in
            ShellActions.importFiles(urls, model: model)
        }
        .onChange(of: model.selection, initial: true) { _, selection in
            shell.reveal(selection, in: model.workspace)
        }
        .confirmationDialog(
            shell.pendingDelete?.title ?? "",
            isPresented: Binding(
                get: { shell.pendingDelete != nil },
                set: { if !$0 { shell.pendingDelete = nil } }
            ),
            presenting: shell.pendingDelete
        ) { pending in
            Button(pending.confirmLabel, role: .destructive) { ShellActions.confirm(pending, model: model) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    // MARK: Tree

    struct TreeRow: Identifiable {
        enum Content {
            case collection(Collection)
            case folder(Folder)
            case request(RequestItem)
            case fork(RequestFork)
        }

        let content: Content
        let collectionID: UUID
        let depth: Int

        var id: UUID {
            switch content {
            case .collection(let collection): collection.id
            case .folder(let folder): folder.id
            case .request(let request): request.id
            case .fork(let fork): fork.id
            }
        }
    }

    /// The collections tree as the rows on screen: closed rows hide what they hold.
    static func treeRows(model: AppModel, shell: ShellState = .shared) -> [TreeRow] {
        var rows: [TreeRow] = []
        func walk(_ nodes: [CollectionNode], collectionID: UUID, depth: Int) {
            for node in model.requestOrder(of: collectionID).arranged(nodes) {
                switch node {
                case .folder(let folder):
                    rows.append(TreeRow(content: .folder(folder), collectionID: collectionID, depth: depth))
                    if shell.isFolderExpanded(folder.id) {
                        walk(folder.items, collectionID: collectionID, depth: depth + 1)
                    }
                case .request(let request):
                    rows.append(TreeRow(content: .request(request), collectionID: collectionID, depth: depth))
                    // Its forks stand right under it.
                    for fork in model.workspace.forks(of: request.id) {
                        rows.append(TreeRow(content: .fork(fork), collectionID: collectionID, depth: depth + 1))
                    }
                }
            }
        }
        for collection in model.shownCollections {
            rows.append(TreeRow(content: .collection(collection), collectionID: collection.id, depth: 0))
            if shell.isCollectionExpanded(collection.id) {
                walk(collection.items, collectionID: collection.id, depth: 1)
            }
        }
        return rows
    }

    private var treeRows: [TreeRow] { Self.treeRows(model: model, shell: shell) }

    @ViewBuilder
    private func treeRow(_ row: TreeRow) -> some View {
        switch row.content {
        case .collection(let collection): collectionRow(collection)
        case .folder(let folder): folderRow(folder, collectionID: row.collectionID, depth: row.depth)
        case .request(let request): requestRow(request, depth: row.depth, isInCollection: true)
        case .fork(let fork): forkRow(fork, depth: row.depth)
        }
    }

    // MARK: Landing

    /// What a request or a folder dragged over a row of a collection does there.
    private func nodeDrop(over row: UUID, as kind: ShellState.NodeTarget, collection: UUID, folder: UUID? = nil) -> RowDrop {
        let shell = shell, model = model
        return RowDrop(
            hover: { fraction in
                // A collection dragged over what another one holds is over that collection.
                if shell.picked?.list == .collections {
                    shell.hover(
                        .collections, over: collection, isOver: fraction != nil, order: model.shownCollections.map(\.id),
                        lastRow: { Self.lastRow(of: $0, model: model) }
                    )
                } else {
                    shell.hoverNode(over: row, at: fraction, as: kind, in: model)
                }
            },
            perform: { texts in
                if shell.drop(.collections, move: { model.moveCollection($0, toPlaceOf: collection) }) { return true }
                if shell.dropNode(in: model) { return true }
                // Not dragged from the sidebar: a file, dropped into a folder.
                guard let folder else { return false }
                Task { @MainActor in drop(await texts(), onCollection: collection, folder: folder) }
                return true
            },
            takesFiles: folder != nil
        )
    }

    /// The last row a collection fills on screen: itself when closed, what it holds last when open.
    static func lastRow(of collectionID: UUID, model: AppModel) -> UUID {
        treeRows(model: model).last { $0.collectionID == collectionID }?.id ?? collectionID
    }

    // MARK: Rows

    private func requestRow(_ request: RequestItem, depth: Int, isInCollection: Bool) -> some View {
        let selection = SidebarSelection.request(request.id)
        let collection = isInCollection ? model.workspace.collection(containing: request.id)?.id : nil
        return SidebarRow(
            selection: selection, name: request.name, depth: depth, kind: .request(request.method),
            landing: shell.mark(of: request.id),
            hasForks: isInCollection && !model.workspace.forks(of: request.id).isEmpty,
            rename: { model.renameRequest(request.id, to: $0) },
            drop: collection.map { nodeDrop(over: request.id, as: .request, collection: $0) }
        )
        .tag(selection)
        .draggable(shell.picking(.nodes, request.id, as: SidebarDrag.payload(for: request.id)))
        .contextMenu {
            if isInCollection {
                Button("Fork") { model.forkRequest(request.id) }
            }
            Button("Duplicate") { model.duplicateRequest(request.id) }
            Button("Rename") { beginRename(selection, name: request.name) }
            if isInCollection { moveItems(request.id) }
            Divider()
            Button("Delete", role: .destructive) {
                ShellActions.deleteRequest(request.id, name: request.name, model: model)
            }
        }
    }

    private func forkRow(_ fork: RequestFork, depth: Int) -> some View {
        let selection = SidebarSelection.request(fork.id)
        return SidebarRow(
            selection: selection, name: fork.name, depth: depth, kind: .fork,
            landing: shell.mark(of: fork.id),
            rename: { model.renameFork(fork.id, to: $0) },
            drop: model.workspace.collection(containing: fork.originID).map {
                nodeDrop(over: fork.id, as: .fork(original: fork.originID), collection: $0.id)
            }
        )
        .tag(selection)
        .contextMenu {
            Button("Merge into Original…") { shell.mergingFork = fork.id }
            Button("Keep as New Request") { model.keepForkAsRequest(fork.id) }
            Button("Rename") { beginRename(selection, name: fork.name) }
            Divider()
            Button("Discard", role: .destructive) { ShellActions.discardFork(fork, model: model) }
        }
    }

    private func folderRow(_ folder: Folder, collectionID: UUID, depth: Int) -> some View {
        let selection = SidebarSelection.folder(folder.id)
        return SidebarRow(
            selection: selection, name: folder.name, depth: depth,
            kind: .container(glyph: "folder", isExpanded: shell.isFolderExpanded(folder.id)) {
                shell.toggle(folder.id)
            },
            landing: shell.mark(of: folder.id),
            rename: { name in
                guard var current = model.folder(id: folder.id) else { return }
                current.name = name
                model.updateFolder(current)
            },
            drop: nodeDrop(over: folder.id, as: .folder(collection: collectionID), collection: collectionID, folder: folder.id)
        )
        .tag(selection)
        .draggable(shell.picking(.nodes, folder.id, as: SidebarDrag.payload(for: folder.id)))
        .contextMenu {
            Button("New request") { ShellActions.newRequest(model, inCollection: collectionID, folder: folder.id) }
            Button("New folder") { ShellActions.newFolder(model, inCollection: collectionID, parent: folder.id) }
            Divider()
            Button("Rename") { beginRename(selection, name: folder.name) }
            moveItems(folder.id)
            Divider()
            Button("Delete", role: .destructive) { ShellActions.deleteFolder(folder, model: model) }
        }
    }

    private func collectionRow(_ collection: Collection) -> some View {
        let selection = SidebarSelection.collection(collection.id)
        return SidebarRow(
            selection: selection, name: collection.name, depth: 0,
            kind: .container(glyph: "hexagon", isExpanded: shell.isCollectionExpanded(collection.id)) {
                shell.toggle(collection.id)
            },
            isLifted: shell.landing != nil && shell.picked?.id == collection.id,
            landing: shell.mark(of: collection.id),
            rename: { name in
                guard var current = model.collection(id: collection.id) else { return }
                current.name = name
                model.updateCollection(current)
            },
            requestOrder: requestOrder(of: collection.id)
        )
        .tag(selection)
        // `draggable`, not `onDrag`: SwiftUI calls an `onDrag` for the first drag of a row only. What it
        // drags is asked for as the drag begins, which tells the shell what was picked up.
        .draggable(shell.picking(.collections, collection.id, as: SidebarDrag.payload(collection: collection.id)))
        .dropDestination(for: String.self) { items, _ in
            drop(items, onCollection: collection.id, folder: nil)
        } isTargeted: { isOver in
            if shell.picked?.list == .nodes {
                shell.hoverNode(over: collection.id, at: isOver ? 0.5 : nil, as: .collection, in: model)
            } else {
                shell.hover(
                    .collections, over: collection.id, isOver: isOver, order: model.shownCollections.map(\.id),
                    lastRow: { Self.lastRow(of: $0, model: model) }
                )
            }
        }
        .contextMenu {
            Button("New request") { ShellActions.newRequest(model, inCollection: collection.id, folder: nil) }
            Button("New folder") { ShellActions.newFolder(model, inCollection: collection.id, parent: nil) }
            Divider()
            Button("Rename") { beginRename(selection, name: collection.name) }
            Button("Export…") { ShellActions.exportCollection(collection.id, model: model) }
            Menu("Sort Requests") { OrderPicker(order: requestOrder(of: collection.id)) }
            Divider()
            let shown = model.shownCollections.map(\.id)
            moveButtons(isFirst: shown.first == collection.id, isLast: shown.last == collection.id) {
                model.moveCollection(collection.id, by: $0)
            }
            Divider()
            Button("Delete", role: .destructive) { ShellActions.deleteCollection(collection, model: model) }
        }
    }

    private func environmentRow(_ environment: BeeCore.Environment) -> some View {
        let selection = SidebarSelection.environment(environment.id)
        let isActive = model.workspace.activeEnvironmentID == environment.id
        return SidebarRow(
            selection: selection, name: environment.name, depth: 0, kind: .leaf(glyph: "globe"),
            isActive: isActive, isLifted: shell.landing != nil && shell.picked?.id == environment.id,
            landing: shell.mark(of: environment.id),
            rename: { name in
                guard var current = model.environment(id: environment.id) else { return }
                current.name = name
                model.updateEnvironment(current)
            }
        )
        .tag(selection)
        .draggable(shell.picking(.environments, environment.id, as: SidebarDrag.payload(environment: environment.id)))
        .dropDestination(for: String.self) { items, _ in
            dropEnvironment(items, on: environment.id)
        } isTargeted: { isOver in
            shell.hover(.environments, over: environment.id, isOver: isOver, order: model.shownEnvironments.map(\.id))
        }
        .contextMenu {
            Button("Make active") { model.setActiveEnvironment(environment.id) }
                .disabled(isActive)
            Divider()
            Button("Rename") { beginRename(selection, name: environment.name) }
            Button("Duplicate") { model.duplicateEnvironment(environment.id) }
            Button("Export…") { ShellActions.exportEnvironment(environment.id, model: model) }
            Divider()
            let shown = model.shownEnvironments.map(\.id)
            moveButtons(isFirst: shown.first == environment.id, isLast: shown.last == environment.id) {
                model.moveEnvironment(environment.id, by: $0)
            }
            Divider()
            Button("Delete", role: .destructive) {
                shell.pendingDelete = .environment(id: environment.id, name: environment.name)
            }
        }
    }

    private func requestOrder(of collectionID: UUID) -> Binding<ListOrder> {
        Binding(get: { model.requestOrder(of: collectionID) }, set: { model.setRequestOrder($0, of: collectionID) })
    }

    /// Move Up and Move Down, among what holds a request or a folder.
    @ViewBuilder
    private func moveItems(_ nodeID: UUID) -> some View {
        let position = model.position(of: nodeID)
        Divider()
        moveButtons(isFirst: position.map { $0.index == 0 } ?? true, isLast: position.map { $0.index == $0.count - 1 } ?? true) {
            model.moveNode(nodeID, by: $0)
        }
    }

    /// Move Up and Move Down: `move` takes the row one place up (`-1`) or down (`1`) its list as shown.
    @ViewBuilder
    private func moveButtons(isFirst: Bool, isLast: Bool, move: @escaping (Int) -> Void) -> some View {
        Button("Move Up") { move(-1) }
            .disabled(isFirst)
        Button("Move Down") { move(1) }
            .disabled(isLast)
    }

    // MARK: Rename

    private func beginRename(_ selection: SidebarSelection, name: String) {
        model.selection = selection
        shell.beginRename(selection, name: name)
    }

    private func installClickMonitor() {
        guard shell.clickMonitor == nil else { return }
        shell.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let frame = event.window?.contentView?.superview,
                  let hit = frame.hitTest(event.locationInWindow) else { return event }
            // A click anywhere but in the name being edited ends the rename and keeps what was typed
            // (a click on bare paper does not take the focus away, so the field cannot tell by itself).
            if shell.renaming != nil {
                // A click in the name being edited places the caret. SwiftUI routes clicks itself (the
                // hit view is the row's hosting view), so the field is told by where its editor is.
                if let editor = event.window?.firstResponder as? NSText,
                   editor.convert(editor.bounds, to: nil).insetBy(dx: -8, dy: -6).contains(event.locationInWindow) {
                    return event
                }
                shell.commitRename?()
            }
            guard event.clickCount == 2 else { return event }
            // Only rows of the sidebar's list count: walk up to its table view.
            var view: NSView? = hit
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView,
                  table.row(at: table.convert(event.locationInWindow, from: nil)) >= 0 else { return event }
            // The first click selected the row; rename once that selection has settled.
            DispatchQueue.main.async { _ = beginRenameOfSelection() }
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = shell.clickMonitor { NSEvent.removeMonitor(monitor) }
        shell.clickMonitor = nil
    }

    private func beginRenameOfSelection() -> KeyPress.Result {
        guard shell.renaming == nil, let selection = model.selection else { return .ignored }
        let name: String? = switch selection {
        case .request(let id): model.fork(id: id)?.name ?? model.session(for: id)?.item.name
        case .folder(let id): model.folder(id: id)?.name
        case .collection(let id): model.collection(id: id)?.name
        case .environment(let id): model.environment(id: id)?.name
        case .globals, .history: nil
        }
        guard let name else { return .ignored }
        shell.beginRename(selection, name: name)
        return .handled
    }

    // MARK: Drop

    /// An environment dropped on another takes its place; a dropped file path is imported.
    @discardableResult
    private func dropEnvironment(_ items: [String], on target: UUID) -> Bool {
        if let dragged = items.lazy.compactMap(SidebarDrag.environmentID(from:)).first {
            // Without a pick-up seen (none was seen to start), it takes the target's place all the same.
            let move = { (id: UUID) in model.moveEnvironment(id, toPlaceOf: target) }
            if !shell.drop(.environments, move: move) { move(dragged) }
            return true
        }
        let files = items.compactMap(SidebarDrag.fileURL(from:))
        return !files.isEmpty && ShellActions.importFiles(files, model: model)
    }

    /// Moves the dragged requests and folders into the target; a dropped file path is imported. A
    /// collection dropped on another one, or on one of its folders, takes its place.
    @discardableResult
    private func drop(_ items: [String], onCollection collectionID: UUID, folder folderID: UUID?) -> Bool {
        var handled = false
        for item in items {
            if let dragged = SidebarDrag.collectionID(from: item) {
                let move = { (id: UUID) in model.moveCollection(id, toPlaceOf: collectionID) }
                if !shell.drop(.collections, move: move) { move(dragged) }
                return true
            }
            if let nodeID = SidebarDrag.nodeID(from: item) {
                // Where the mark said, once the drag is over; without one seen, into the target all the same.
                if !shell.dropNode(in: model) { model.moveNode(nodeID, toCollection: collectionID, folder: folderID) }
                handled = true
            } else if let url = SidebarDrag.fileURL(from: item) {
                handled = ShellActions.importFiles([url], model: model) || handled
            }
        }
        if handled {
            shell.expandCollection(collectionID)
            if let folderID { shell.expandFolder(folderID) }
        }
        return handled
    }
}

// MARK: - Row drop

/// What a row does with a drag over it.
struct RowDrop {
    /// The pointer over the row at this fraction of its height from the top; `nil` once it leaves.
    let hover: (CGFloat?) -> Void
    /// Dropped. `texts` reads what was dragged in, for a drag from elsewhere (a file).
    let perform: (_ texts: @escaping () async -> [String]) -> Bool
    /// True when a file dropped on the row is taken (a folder imports it).
    var takesFiles = false
}

private struct RowDropModifier: ViewModifier {
    let drop: RowDrop?
    let height: CGFloat

    func body(content: Content) -> some View {
        if let drop {
            content.onDrop(of: drop.takesFiles ? [.utf8PlainText, .fileURL] : [.utf8PlainText], delegate: RowDropDelegate(drop: drop, height: height))
        } else {
            content
        }
    }
}

/// Follows the pointer over a row: unlike a plain drop destination, it says where on the row it is.
private struct RowDropDelegate: DropDelegate {
    let drop: RowDrop
    let height: CGFloat

    func dropEntered(info: DropInfo) { drop.hover(fraction(of: info)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drop.hover(fraction(of: info))
        return DropProposal(operation: ShellState.shared.picked == nil ? .copy : .move)
    }

    func dropExited(info: DropInfo) { drop.hover(nil) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL, .utf8PlainText])
        return drop.perform { await Self.texts(of: providers) }
    }

    private func fraction(of info: DropInfo) -> CGFloat {
        height > 0 ? min(max(info.location.y / height, 0), 1) : 0.5
    }

    /// What was dragged in, as text: a file as its URL, anything else as its text.
    private static func texts(of providers: [NSItemProvider]) async -> [String] {
        var texts: [String] = []
        for provider in providers {
            let isFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let text: String? = await withCheckedContinuation { continuation in
                if isFile {
                    _ = provider.loadObject(ofClass: NSURL.self) { url, _ in continuation.resume(returning: (url as? NSURL)?.absoluteString) }
                } else {
                    _ = provider.loadObject(ofClass: NSString.self) { text, _ in continuation.resume(returning: text as? String) }
                }
            }
            if let text { texts.append(text) }
        }
        return texts
    }
}

// MARK: - Drag payload

/// A dragged request, folder, collection or environment travels as text so the sidebar needs no
/// exported type.
enum SidebarDrag {
    private static let prefix = "bee-node:"
    private static let collectionPrefix = "bee-collection:"
    private static let environmentPrefix = "bee-environment:"

    static func payload(for nodeID: UUID) -> String { prefix + nodeID.uuidString }
    static func payload(collection id: UUID) -> String { collectionPrefix + id.uuidString }
    static func payload(environment id: UUID) -> String { environmentPrefix + id.uuidString }

    static func nodeID(from payload: String) -> UUID? { identifier(in: payload, after: prefix) }
    static func collectionID(from payload: String) -> UUID? { identifier(in: payload, after: collectionPrefix) }
    static func environmentID(from payload: String) -> UUID? { identifier(in: payload, after: environmentPrefix) }

    private static func identifier(in payload: String, after prefix: String) -> UUID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }

    /// A file dragged from Finder may arrive as its path or its file URL in text form.
    static func fileURL(from payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("file://") { return URL(string: text) }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        return nil
    }
}

// MARK: - New request

private struct NewRequestRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.newRequest()
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "plus")
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: ShellMetrics.glyphColumn, alignment: .leading)
                Text("New request")
                    .font(Theme.text())
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Space.s)
                Text("⌘N")
                    .font(Theme.text(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }
}

// MARK: - Section header

private struct SidebarSectionHeader: View {
    let title: String
    let addLabel: String
    @Binding var order: ListOrder
    let add: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
            Spacer(minLength: Theme.Space.s)
            // How the list is ordered, said in the heading when it is by name.
            OrderMenu(order: $order, subject: title.lowercased(), holdsFolders: false)
            Button(action: add) {
                Image(systemName: "plus")
                    .font(Theme.text(Theme.Size.caption, weight: .medium))
                    .frame(width: Theme.Space.xl, height: Theme.Space.l)
            }
            .buttonStyle(QuietButtonStyle())
            .help(addLabel)
            .accessibilityLabel(addLabel)
        }
    }
}

/// The orders a list can take, as the items of a menu.
private struct OrderPicker: View {
    @Binding var order: ListOrder

    var body: some View {
        Picker("Order", selection: $order) {
            Text("Manual").tag(ListOrder.manual)
            Text("Name, A to Z").tag(ListOrder.nameAscending)
            Text("Name, Z to A").tag(ListOrder.nameDescending)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// How a list is ordered: a quiet menu that reads A–Z or Z–A when it is by name.
private struct OrderMenu: View {
    @Binding var order: ListOrder
    /// What is ordered, for help and accessibility: "collections", "requests of Bee Basics".
    let subject: String
    /// True for what a collection holds, whose folders come first when sorted by name.
    let holdsFolders: Bool

    var body: some View {
        Menu {
            OrderPicker(order: $order)
        } label: {
            Group {
                switch order {
                case .manual: Image(systemName: "arrow.up.arrow.down")
                case .nameAscending: Text("A–Z")
                case .nameDescending: Text("Z–A")
                }
            }
            // As quiet as the add button beside it, which it looks and answers like.
            .font(Theme.text(Theme.Size.caption, weight: .medium))
            .frame(minWidth: Theme.Space.xl, minHeight: Theme.Space.l)
        }
        .menuStyle(.button)
        .buttonStyle(QuietButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Order of the \(subject): \(described)")
        .accessibilityLabel("Order of the \(subject)")
        .accessibilityValue(described)
    }

    private var described: String {
        let folders = holdsFolders ? ", folders first" : ""
        return switch order {
        case .manual: "manual, drag to move"
        case .nameAscending: "by name, A to Z" + folders
        case .nameDescending: "by name, Z to A" + folders
        }
    }
}

// MARK: - Row

/// One sidebar line: indentation, a disclosure chevron and glyph (or the method), the name, which
/// turns into a field while it is renamed.
private struct SidebarRow: View {
    enum Kind {
        case container(glyph: String, isExpanded: Bool, toggle: () -> Void)
        case leaf(glyph: String)
        case request(HTTPMethod)
        /// A fork of the request above it.
        case fork
    }

    @Environment(AppModel.self) private var model
    @FocusState private var isFieldFocused: Bool
    @ViewState private var renameStartedAt = Date.distantPast

    let selection: SidebarSelection
    let name: String
    let depth: Int
    let kind: Kind
    var isActive = false
    /// True for the collection or environment being dragged over the list: it waits, faded, to move.
    var isLifted = false
    /// Where a drag in flight would land on this row: a line of honey above or below it, or round it.
    var landing: ShellState.Landing.Mark?
    /// True for a request that has forks: the full cell says which one is the original.
    var hasForks = false
    /// `nil` when the row has a fixed name.
    var rename: ((String) -> Void)?
    /// What the row does with a drag over it, told where the pointer is on it.
    var drop: RowDrop?
    /// For a collection: how what it holds is ordered, offered under the pointer and said when by name.
    var requestOrder: Binding<ListOrder>?

    @ViewState private var height: CGFloat = 0
    @ViewState private var isHovered = false

    private var shell: ShellState { .shared }
    private var isRenaming: Bool { rename != nil && shell.renaming == selection }
    private var isSelected: Bool { model.selection == selection }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(depth) * ShellMetrics.indent, height: 1)
            leading
            if isRenaming {
                renameField
            } else {
                Text(name.isEmpty ? "Untitled" : name)
                    .font(Theme.text(weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Space.s)
            if let requestOrder, requestOrder.wrappedValue != .manual || isHovered {
                OrderMenu(order: requestOrder, subject: "requests of \(name)", holdsFolders: true)
            }
            if isActive { activeMark }
            if hasForks {
                CellMark(color: Theme.inkSecondary, size: Theme.Size.caption - 2)
                    .accessibilityHidden(false)
                    .accessibilityLabel("Original, has forks")
                    .help("The original. Its forks are listed under it.")
            }
        }
        .contentShape(Rectangle())
        .opacity(isLifted ? 0.45 : 1)
        // Where the dragged one would land: a line of honey between this row and the next, or round this
        // row when it would go into it, drawn over the rows so that none of them moves under the pointer.
        .overlay(alignment: landing == .below ? .bottom : .top) {
            if let landing, landing != .into {
                // On the very edge of the row (a row draws nothing past it), a cell of honey resting on it.
                HStack(alignment: landing == .below ? .bottom : .top, spacing: 0) {
                    CellMark(color: Theme.honey, size: Theme.Size.caption - 4)
                    Capsule().fill(Theme.honey).frame(height: 2)
                }
                .offset(y: landing == .below ? ShellMetrics.rowGap - 0.5 : 0.5 - ShellMetrics.rowGap)
                .padding(.leading, CGFloat(depth) * ShellMetrics.indent - Theme.Space.xs)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay {
            if landing == .into {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .strokeBorder(Theme.honey, lineWidth: 2)
                    .padding(.horizontal, -Theme.Space.s)
                    .padding(.vertical, 1.5 - ShellMetrics.rowGap)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // Only a collection offers something under the pointer: its order.
        .onHover { isOver in if requestOrder != nil { isHovered = isOver } }
        .modifier(RowDropModifier(drop: drop, height: height))
    }

    @ViewBuilder
    private var leading: some View {
        switch kind {
        case .container(let glyph, let isExpanded, let toggle):
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(Theme.text(Theme.Size.caption, weight: .semibold))
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: ShellMetrics.chevronColumn, height: ShellMetrics.chevronColumn, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
            glyphImage(glyph)
        case .leaf(let glyph):
            glyphImage(glyph)
        case .request(let method):
            MethodLabel(method: method)
                .lineLimit(1)
                .frame(width: ShellMetrics.methodColumn, alignment: .leading)
        case .fork:
            // An empty cell: a request being tried, not the one of the collection.
            CellMark(color: Theme.forkInk, size: Theme.Size.caption, isHollow: true)
                .frame(width: ShellMetrics.glyphColumn, alignment: .leading)
                .accessibilityHidden(false)
                .accessibilityLabel("Fork")
        }
    }

    private func glyphImage(_ glyph: String) -> some View {
        Image(systemName: glyph)
            .foregroundStyle(Theme.inkSecondary)
            .frame(width: ShellMetrics.glyphColumn, alignment: .leading)
            .accessibilityHidden(true)
    }

    private var activeMark: some View {
        HStack(spacing: Theme.Space.xs) {
            // A cell of honey: the environment requests are sent with.
            CellMark(color: Theme.honey, size: Theme.Size.caption - 2)
            Text("Active")
                .font(Theme.text(Theme.Size.caption))
        }
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityElement(children: .combine)
    }

    private var renameField: some View {
        @Bindable var shell = ShellState.shared
        return TextField("Name", text: $shell.renameText)
            .textFieldStyle(.plain)
            .font(Theme.text())
            .foregroundStyle(Theme.ink)
            .focused($isFieldFocused)
            .onSubmit { commit() }
            .onExitCommand { shell.cancelRename() }
            .onChange(of: isFieldFocused) { _, focused in
                guard !focused else { return }
                // Focus asked while the row appears can be dropped: ask again instead of closing.
                if Date().timeIntervalSince(renameStartedAt) < 0.5 {
                    Task { isFieldFocused = true }
                } else {
                    commit()
                }
            }
            .onAppear {
                renameStartedAt = Date()
                isFieldFocused = true
                shell.commitRename = { commit() }
            }
            // Focus set while the row appears can be dropped; ask again once it is on screen.
            .task { isFieldFocused = true }
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xs / 2)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .outlined(isFocused: true, radius: Theme.Radius.row)
            .accessibilityLabel("Name")
    }

    private func beginRename() {
        guard rename != nil, shell.renaming != selection else { return }
        shell.beginRename(selection, name: name)
    }

    private func commit() {
        guard shell.renaming == selection else { return }
        let text = shell.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        shell.cancelRename()
        if !text.isEmpty, text != name { rename?(text) }
    }
}
