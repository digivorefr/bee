import AppKit
import BeeCore
import SwiftUI

@main
struct BeeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var model: AppModel

    init() {
        let model = AppModel()
        _model = ViewState(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        Window("Bee", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    await model.load()
                    #if DEBUG
                    DebugHarness.runIfRequested(model: model)
                    #endif
                    await model.checkForUpdatesIfDue()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { BeeCommands(model: model) }

        Window(WhatsNew.windowTitle, id: WhatsNew.windowID) {
            WhatsNewView()
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentMinSize)

        Window(UpdateModel.windowTitle, id: UpdateModel.windowID) {
            UpdateView()
                .environment(model)
        }
        .defaultSize(width: 520, height: 420)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Flushes pending changes to disk before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        model.clearCopiedSecret()
        Task {
            await model.saveNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
