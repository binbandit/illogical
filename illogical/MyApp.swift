import AppKit
import SwiftUI

@main
struct IllogicalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { LaunchMetrics.mark("appInit") }

    var body: some Scene {
        WindowGroup("illogical", id: WorkspaceScene.id) {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { WorkspaceCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Sessions and tabs are the app's own; hide the system tab bar and
        // its Window menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Quitting only detaches from the service, so always bring every
        // window back on launch, as Ghostty does with window-save-state.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": true])
        KeyAliasMonitor.install()
    }
}
