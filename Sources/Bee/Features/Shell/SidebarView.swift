import AppKit
import BeeCore
import SwiftUI

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
                        requestRow(draft, depth: 0)
                    }
                }
                .collapsible(false)
            }
            Section {
                ForEach(treeRows) { row in
                    treeRow(row)
                }
            } header: {
                SidebarSectionHeader(title: "Collections", addLabel: "New collection") {
                    model.newCollection()
                }
            }
            .collapsible(false)
            Section {
                ForEach(model.workspace.environments) { environment in
                    environmentRow(environment)
                }
                SidebarRow(selection: .globals, name: "Globals", depth: 0, kind: .leaf(glyph: "curlybraces"))
                    .tag(SidebarSelection.globals)
            } header: {
                SidebarSectionHeader(title: "Environments", addLabel: "New environment") {
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

    private struct TreeRow: Identifiable {
        enum Content {
            case collection(Collection)
            case folder(Folder)
            case request(RequestItem)
        }

        let content: Content
        let collectionID: UUID
        let depth: Int

        var id: UUID {
            switch content {
            case .collection(let collection): collection.id
            case .folder(let folder): folder.id
            case .request(let request): request.id
            }
        }
    }

    /// The collections tree as the rows on screen: closed rows hide what they hold.
    private var treeRows: [TreeRow] {
        var rows: [TreeRow] = []
        func walk(_ nodes: [CollectionNode], collectionID: UUID, depth: Int) {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    rows.append(TreeRow(content: .folder(folder), collectionID: collectionID, depth: depth))
                    if shell.isFolderExpanded(folder.id) {
                        walk(folder.items, collectionID: collectionID, depth: depth + 1)
                    }
                case .request(let request):
                    rows.append(TreeRow(content: .request(request), collectionID: collectionID, depth: depth))
                }
            }
        }
        for collection in model.workspace.collections {
            rows.append(TreeRow(content: .collection(collection), collectionID: collection.id, depth: 0))
            if shell.isCollectionExpanded(collection.id) {
                walk(collection.items, collectionID: collection.id, depth: 1)
            }
        }
        return rows
    }

    @ViewBuilder
    private func treeRow(_ row: TreeRow) -> some View {
        switch row.content {
        case .collection(let collection): collectionRow(collection)
        case .folder(let folder): folderRow(folder, collectionID: row.collectionID, depth: row.depth)
        case .request(let request): requestRow(request, depth: row.depth)
        }
    }

    // MARK: Rows

    private func requestRow(_ request: RequestItem, depth: Int) -> some View {
        let selection = SidebarSelection.request(request.id)
        return SidebarRow(
            selection: selection, name: request.name, depth: depth, kind: .request(request.method),
            rename: { model.renameRequest(request.id, to: $0) }
        )
        .tag(selection)
        .draggable(SidebarDrag.payload(for: request.id))
        .contextMenu {
            Button("Duplicate") { model.duplicateRequest(request.id) }
            Button("Rename") { beginRename(selection, name: request.name) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteNode(request.id) }
        }
    }

    private func folderRow(_ folder: Folder, collectionID: UUID, depth: Int) -> some View {
        let selection = SidebarSelection.folder(folder.id)
        return SidebarRow(
            selection: selection, name: folder.name, depth: depth,
            kind: .container(glyph: "folder", isExpanded: shell.isFolderExpanded(folder.id)) {
                shell.toggle(folder.id)
            },
            rename: { name in
                guard var current = model.folder(id: folder.id) else { return }
                current.name = name
                model.updateFolder(current)
            }
        )
        .tag(selection)
        .draggable(SidebarDrag.payload(for: folder.id))
        .dropDestination(for: String.self) { items, _ in
            drop(items, onCollection: collectionID, folder: folder.id)
        }
        .contextMenu {
            Button("New request") { ShellActions.newRequest(model, inCollection: collectionID, folder: folder.id) }
            Button("New folder") { ShellActions.newFolder(model, inCollection: collectionID, parent: folder.id) }
            Divider()
            Button("Rename") { beginRename(selection, name: folder.name) }
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
            rename: { name in
                guard var current = model.collection(id: collection.id) else { return }
                current.name = name
                model.updateCollection(current)
            }
        )
        .tag(selection)
        .dropDestination(for: String.self) { items, _ in
            drop(items, onCollection: collection.id, folder: nil)
        }
        .contextMenu {
            Button("New request") { ShellActions.newRequest(model, inCollection: collection.id, folder: nil) }
            Button("New folder") { ShellActions.newFolder(model, inCollection: collection.id, parent: nil) }
            Divider()
            Button("Rename") { beginRename(selection, name: collection.name) }
            Button("Export…") { ShellActions.exportCollection(collection.id, model: model) }
            Divider()
            Button("Delete", role: .destructive) { ShellActions.deleteCollection(collection, model: model) }
        }
    }

    private func environmentRow(_ environment: BeeCore.Environment) -> some View {
        let selection = SidebarSelection.environment(environment.id)
        let isActive = model.workspace.activeEnvironmentID == environment.id
        return SidebarRow(
            selection: selection, name: environment.name, depth: 0, kind: .leaf(glyph: "globe"),
            isActive: isActive,
            rename: { name in
                guard var current = model.environment(id: environment.id) else { return }
                current.name = name
                model.updateEnvironment(current)
            }
        )
        .tag(selection)
        .contextMenu {
            Button("Make active") { model.setActiveEnvironment(environment.id) }
                .disabled(isActive)
            Divider()
            Button("Rename") { beginRename(selection, name: environment.name) }
            Button("Duplicate") { model.duplicateEnvironment(environment.id) }
            Button("Export…") { ShellActions.exportEnvironment(environment.id, model: model) }
            Divider()
            Button("Delete", role: .destructive) {
                shell.pendingDelete = .environment(id: environment.id, name: environment.name)
            }
        }
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
        case .request(let id): model.session(for: id)?.item.name
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

    /// Moves the dragged requests and folders into the target; a dropped file path is imported.
    @discardableResult
    private func drop(_ items: [String], onCollection collectionID: UUID, folder folderID: UUID?) -> Bool {
        var handled = false
        for item in items {
            if let nodeID = SidebarDrag.nodeID(from: item) {
                model.moveNode(nodeID, toCollection: collectionID, folder: folderID)
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

// MARK: - Drag payload

/// A dragged request or folder travels as text so the sidebar needs no exported type.
enum SidebarDrag {
    private static let prefix = "bee-node:"

    static func payload(for nodeID: UUID) -> String { prefix + nodeID.uuidString }

    static func nodeID(from payload: String) -> UUID? {
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
    let add: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
            Spacer(minLength: Theme.Space.s)
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

// MARK: - Row

/// One sidebar line: indentation, a disclosure chevron and glyph (or the method), the name, which
/// turns into a field while it is renamed.
private struct SidebarRow: View {
    enum Kind {
        case container(glyph: String, isExpanded: Bool, toggle: () -> Void)
        case leaf(glyph: String)
        case request(HTTPMethod)
    }

    @Environment(AppModel.self) private var model
    @FocusState private var isFieldFocused: Bool
    @ViewState private var renameStartedAt = Date.distantPast

    let selection: SidebarSelection
    let name: String
    let depth: Int
    let kind: Kind
    var isActive = false
    /// `nil` when the row has a fixed name.
    var rename: ((String) -> Void)?

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
            if isActive { activeMark }
        }
        .contentShape(Rectangle())
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
