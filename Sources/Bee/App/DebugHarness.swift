#if DEBUG
import AppKit
import BeeCore
import SwiftUI

/// Drives the application without a person, for visual checks during development. Debug builds only.
///
/// `BEE_DATA_DIR=<dir>` makes the data throwaway (in-memory vault, no Keychain, no prompts).
/// `BEE_SCENARIO="step;step;…"` runs steps in order once the workspace is loaded:
///
///     select:<request name>      collection:<name>   folder:<name>   environment:<name>
///     globals   history   none   activate:<environment name>
///     send                       wait:<seconds>
///     url:<address>              begin (sends without waiting for the response)
///     add:<request section>      open:<request section>     close:<request section>
///     ropen:<response section>   rclose:<response section>
///     layout:beside|below        appearance:light|dark      size:<width>x<height>
///     snapshot:<png path>        sidebarshot:<png path>     quit
///     click:<x>,<y>   doubleclick:<x>,<y>   type:<text>   selectall   key:return|tab|escape|delete   focus
///     cmd:<key>   windowshot:<png path>   front
///     menu:<menu item title>     shot:<window title>|<png path>
///
/// Clicks and shortcuts reach SwiftUI controls only when the app is frontmost: start it with
/// `open -n dist/Bee.app --env BEE_SCENARIO=… --env BEE_HARNESS_LOG=<file>`.
///
/// Sections use the raw values of `RequestSection` and `ResponseSection`. `snapshot` renders the
/// window (the glass sidebar comes out blank); `sidebarshot` renders the sidebar alone on paper.
enum DebugHarness {
    static func runIfRequested(model: AppModel) {
        guard let scenario = ProcessInfo.processInfo.environment["BEE_SCENARIO"], !scenario.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            for step in scenario.split(separator: ";") {
                await perform(step.trimmingCharacters(in: .whitespaces), model: model)
            }
        }
    }

    private static func perform(_ step: String, model: AppModel) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let command = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        switch command {
        case "select":
            let drafts = model.workspace.scratchRequests
            let saved = model.workspace.collections.flatMap(\.allRequests)
            if let request = (saved + drafts).first(where: { $0.name == argument }) {
                model.selection = .request(request.id)
            } else {
                log("no request named \(argument)")
            }
        case "collection":
            if let collection = model.workspace.collections.first(where: { $0.name == argument }) {
                model.selection = .collection(collection.id)
            }
        case "folder":
            for collection in model.workspace.collections {
                if let folder = firstFolder(named: argument, in: collection.items) {
                    model.selection = .folder(folder.id)
                }
            }
        case "environment":
            if let environment = model.workspace.environments.first(where: { $0.name == argument }) {
                model.selection = .environment(environment.id)
            }
        case "activate":
            model.setActiveEnvironment(model.workspace.environments.first { $0.name == argument }?.id)
        case "globals":
            model.selection = .globals
        case "history":
            model.selection = .history
        case "none":
            model.selection = nil
        case "send":
            guard let session = currentSession(model) else { return log("send: no request selected") }
            model.send(session)
            let deadline = Date().addingTimeInterval(25)
            while session.isSending, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        case "url":
            currentSession(model)?.item.url = argument
        case "begin":
            guard let session = currentSession(model) else { return log("begin: no request selected") }
            model.send(session)
        case "wait":
            try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
        case "add":
            if let section = RequestSection(rawValue: argument) { currentSession(model)?.add(section) }
        case "open":
            if let section = RequestSection(rawValue: argument) {
                currentSession(model)?.expandedRequestSections.insert(section)
            }
        case "close":
            if let section = RequestSection(rawValue: argument) {
                currentSession(model)?.expandedRequestSections.remove(section)
            }
        case "ropen":
            if let section = ResponseSection(rawValue: argument) {
                currentSession(model)?.expandedResponseSections.insert(section)
            }
        case "rclose":
            if let section = ResponseSection(rawValue: argument) {
                currentSession(model)?.expandedResponseSections.remove(section)
            }
        case "layout":
            if let layout = ResponseLayout(rawValue: argument) { model.settings.responseLayout = layout }
        case "appearance":
            NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
        case "size":
            let numbers = argument.split(separator: "x").compactMap { Double($0) }
            if numbers.count == 2, let window = mainWindow() {
                window.setContentSize(NSSize(width: numbers[0], height: numbers[1]))
            }
        case "snapshot":
            try? await Task.sleep(for: .milliseconds(350))
            snapshot(to: argument)
        case "click", "doubleclick":
            // Window points from the top-left corner (a snapshot pixel divided by the backing scale).
            let numbers = argument.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == 2, let window = mainWindow() else { return log("click: bad arguments") }
            // The harness app is never frontmost, so events are handed straight to the view under
            // the point instead of going through the window (which would only try to activate).
            let location = NSPoint(x: numbers[0], y: window.frame.height - numbers[1])
            guard let frame = window.contentView?.superview, let target = frame.hitTest(location) else {
                return log("click: nothing at \(argument)")
            }
            func event(_ type: NSEvent.EventType, _ clickCount: Int) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
                )
            }
            // Launched with `open`, the app is frontmost and its window is key: real events through
            // the queue reach everything, SwiftUI controls included.
            let isFrontmost = NSApp.isActive && window.isKeyWindow
            for clickCount in 1...(command == "doubleclick" ? 2 : 1) {
                guard let down = event(.leftMouseDown, clickCount), let up = event(.leftMouseUp, clickCount) else { continue }
                if isFrontmost {
                    NSApp.postEvent(down, atStart: false)
                    NSApp.postEvent(up, atStart: false)
                    // Space the clicks of a double-click as a hand would.
                    try? await Task.sleep(for: .milliseconds(90))
                } else {
                    // A text view tracks the mouse in a nested loop: its mouse-up must already be queued.
                    NSApp.postEvent(up, atStart: false)
                    if target.acceptsFirstResponder { window.makeFirstResponder(target) }
                    target.mouseDown(with: down)
                    target.mouseUp(with: up)
                }
            }
            log("clicked \(type(of: target)) frontmost: \(isFrontmost)")
            try? await Task.sleep(for: .milliseconds(250))
        case "type":
            // Inserts text where the caret is, as typing would.
            guard let responder = mainWindow()?.firstResponder as? NSTextView else {
                return log("type: no text view has focus")
            }
            responder.insertText(argument, replacementRange: responder.selectedRange())
        case "selectall":
            (mainWindow()?.firstResponder as? NSText)?.selectAll(nil)
        case "key":
            let codes: [String: UInt16] = ["return": 36, "tab": 48, "escape": 53, "delete": 51]
            guard let code = codes[argument], let window = mainWindow() else { return log("key: unknown \(argument)") }
            let characters = ["return": "\r", "tab": "\t", "escape": "\u{1B}", "delete": "\u{7F}"][argument] ?? ""
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                ) {
                    window.sendEvent(event)
                }
            }
        case "cmd":
            // A ⌘ shortcut, e.g. `cmd:n`, `cmd:shift+n`, `cmd:delete`, `cmd:,`.
            var flags: NSEvent.ModifierFlags = [.command]
            var key = argument
            if key.hasPrefix("shift+") {
                flags.insert(.shift)
                key.removeFirst("shift+".count)
            }
            let special: [String: (String, UInt16)] = ["delete": ("\u{7F}", 51), "return": ("\r", 36)]
            let (characters, code) = special[key] ?? (key, 0)
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ) {
                NSApp.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(300))
        case "windowshot":
            // Snapshots whichever window is key (the Settings window, for instance).
            try? await Task.sleep(for: .milliseconds(350))
            snapshot(to: argument, window: NSApp.keyWindow)
        case "front":
            // Asks to become the frontmost application, so that clicks go through the event queue.
            NSApp.activate(ignoringOtherApps: true)
            mainWindow()?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            log("front: active \(NSApp.isActive) key \(mainWindow()?.isKeyWindow ?? false)")
        case "menu":
            // Chooses a menu bar item by its title, wherever it is.
            func find(_ title: String, in menu: NSMenu?) -> (NSMenu, Int)? {
                guard let menu else { return nil }
                for (index, item) in menu.items.enumerated() {
                    if item.title == title, !item.hasSubmenu { return (menu, index) }
                    if let found = find(title, in: item.submenu) { return found }
                }
                return nil
            }
            guard let (menu, index) = find(argument, in: NSApp.mainMenu) else { return log("menu: no item titled \(argument)") }
            menu.performActionForItem(at: index)
            try? await Task.sleep(for: .milliseconds(600))
        case "shot":
            // Snapshots the window with the given title.
            let parts = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let window = NSApp.windows.first(where: { $0.title == parts[0] }) else {
                return log("shot: no window titled \(parts.first ?? "")")
            }
            try? await Task.sleep(for: .milliseconds(350))
            snapshot(to: parts[1], window: window)
        case "focus":
            let window = mainWindow()
            log("first responder: \(String(describing: window?.firstResponder)) key: \(window?.isKeyWindow ?? false) active: \(NSApp.isActive)")
        case "sidebarshot":
            await sidebarSnapshot(to: argument, model: model)
        case "quit":
            await model.saveNow()
            exit(0)
        default:
            log("unknown step \(step)")
        }
        // Let SwiftUI settle between steps.
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func currentSession(_ model: AppModel) -> RequestSession? {
        guard case .request(let id) = model.selection else { return nil }
        return model.session(for: id)
    }

    private static func firstFolder(named name: String, in nodes: [CollectionNode]) -> Folder? {
        for node in nodes {
            guard case .folder(let folder) = node else { continue }
            if folder.name == name { return folder }
            if let nested = firstFolder(named: name, in: folder.items) { return nested }
        }
        return nil
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    /// Renders the window's own view tree to a PNG. Needs no screen recording permission;
    /// system materials (glass, vibrancy) may render flat.
    private static func snapshot(to path: String, window: NSWindow? = nil) {
        guard let window = window ?? mainWindow(), let view = window.contentView?.superview ?? window.contentView else {
            return log("snapshot: no window")
        }
        window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return log("snapshot: no bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return log("snapshot: no PNG data")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            log("snapshot written to \(path)")
        } catch {
            log("snapshot failed: \(error.localizedDescription)")
        }
    }

    /// Renders the sidebar alone in an off-screen window, since system glass does not snapshot.
    private static func sidebarSnapshot(to path: String, model: AppModel) async {
        let size = NSSize(width: 280, height: 760)
        let host = NSHostingView(rootView: SidebarView().environment(model).background(Theme.paper))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                log("sidebar snapshot written to \(path)")
            }
        }
        window.orderOut(nil)
    }

    /// Writes to standard error, and to `BEE_HARNESS_LOG` when set (an app started with `open`
    /// has no terminal).
    private static func log(_ message: String) {
        let line = Data("[harness] \(message)\n".utf8)
        FileHandle.standardError.write(line)
        guard let path = ProcessInfo.processInfo.environment["BEE_HARNESS_LOG"] else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        }
    }
}
#endif
