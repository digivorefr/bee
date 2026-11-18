import AppKit
import BeeCore
import SwiftUI

// MARK: - What the menus need to know about the window

/// The facts the menu bar reads from the main window. The window publishes them as a focused
/// scene value: menus are not rebuilt when the model changes, they are when this value does.
struct ShellFocus: Equatable {
    var hasRequest: Bool
    var canFork: Bool
    var isFork: Bool
    var hasCollection: Bool
    var canAddFolder: Bool
    var responseLayout: ResponseLayout
}

private struct ShellFocusKey: FocusedValueKey {
    typealias Value = ShellFocus
}

extension FocusedValues {
    var shellFocus: ShellFocus? {
        get { self[ShellFocusKey.self] }
        set { self[ShellFocusKey.self] = newValue }
    }
}

extension AppModel {
    var shellFocus: ShellFocus {
        ShellFocus(
            hasRequest: selectedRequestID != nil,
            canFork: forkableRequestID != nil,
            isFork: selectedFork != nil,
            hasCollection: selectedCollectionID != nil,
            canAddFolder: newFolderTarget != nil,
            responseLayout: settings.responseLayout
        )
    }
}

// MARK: - Commands

/// The menu bar commands of the application.
///
/// A command is dimmed only when the window says it cannot run. When the window says nothing
/// (it is not the key window), the command stays available and explains itself if it cannot run.
struct BeeCommands: Commands {
    let model: AppModel
    @FocusedValue(\.shellFocus) private var focus
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Request") { model.newRequest() }
                .keyboardShortcut("n")
            Button("New Collection") { model.newCollection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Folder") { ShellActions.newFolder(model) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(focus?.canAddFolder == false)
            Button("New Environment") { model.newEnvironment() }
            Divider()
            Button("Import…") { ShellActions.importFromPanel(model) }
                .keyboardShortcut("o")
            Button("Import cURL from Clipboard") { ShellActions.importCurlFromClipboard(model) }
            Button("Export Collection…") { ShellActions.exportSelectedCollection(model) }
                .disabled(focus?.hasCollection == false)
        }

        CommandMenu("Request") {
            Button("Duplicate") { duplicateSelectedRequest() }
                .keyboardShortcut("d")
                .disabled(focus?.hasRequest == false)
            Button("Delete") { deleteSelectedRequest() }
                .keyboardShortcut(.delete)
                .disabled(focus?.hasRequest == false)
            Divider()
            Button("Fork") { forkSelectedRequest() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(focus?.canFork == false)
            Button("Merge Fork into Original…") {
                if let fork = model.selectedFork { ShellState.shared.mergingFork = fork.id }
            }
            .disabled(focus?.isFork != true)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                openWindow(id: UpdateModel.windowID)
                Task { await model.updates.check() }
            }
        }

        CommandGroup(replacing: .help) {
            Button("What’s New in Bee") { openWindow(id: WhatsNew.windowID) }
            if let page = WhatsNew.projectPage {
                Button("Bee on GitHub") { openURL(page) }
            }
        }

        CommandGroup(before: .sidebar) {
            if let focus {
                Picker("Response", selection: responseLayout(shown: focus.responseLayout)) {
                    Text("Response Beside").tag(ResponseLayout.beside)
                    Text("Response Below").tag(ResponseLayout.below)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } else {
                Button("Response Beside") { model.settings.responseLayout = .beside }
                Button("Response Below") { model.settings.responseLayout = .below }
            }
        }
    }

    private func responseLayout(shown: ResponseLayout) -> Binding<ResponseLayout> {
        Binding(get: { shown }, set: { model.settings.responseLayout = $0 })
    }

    private func forkSelectedRequest() {
        guard let id = model.forkableRequestID else {
            model.inform("Select a request kept in a collection to fork it.")
            return
        }
        model.forkRequest(id)
    }

    private func duplicateSelectedRequest() {
        guard let id = model.selectedRequestID else {
            model.inform("Select a request to duplicate it.")
            return
        }
        model.duplicateRequest(id)
    }

    /// ⌘⌫ belongs to the text being edited when there is one: it deletes to the start of the line
    /// there, and deletes the selected request everywhere else.
    private func deleteSelectedRequest() {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            // Never delete a request from inside a text view, editable or not (the response body).
            if editor.isEditable { editor.deleteToBeginningOfLine(nil) }
            return
        }
        guard let id = model.selectedRequestID else {
            model.inform("Select a request to delete it.")
            return
        }
        // A fork that changed something is not thrown away on one keystroke.
        if let fork = model.fork(id: id) {
            ShellActions.discardFork(fork, model: model)
            return
        }
        ShellActions.deleteRequest(id, name: model.session(for: id)?.item.name ?? "", model: model)
    }
}
