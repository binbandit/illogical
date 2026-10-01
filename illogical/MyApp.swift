import AppKit
import SwiftUI

@main
struct IllogicalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        LaunchMetrics.mark("appInit")
        // Registered here because SwiftUI builds the menus before the app
        // delegate hears that launching began.
        UserDefaults.standard.register(defaults: [
            // Quitting only detaches from the service, so always bring every
            // window back on launch, as Ghostty does with window-save-state.
            "NSQuitAlwaysKeepsWindows": true,
            // View has Toggle Full Screen on Command-Return; AppKit must not
            // add its own Enter Full Screen beside it.
            "NSFullScreenMenuItemEverywhere": false,
        ])
    }

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Sessions and tabs are the app's own; hide the system tab bar and
        // its Window menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        KeyAliasMonitor.install()
        applyGhosttyKeyboardConfiguration()
    }

    /// Terminal keys follow the user's Ghostty configuration: its `keybind`
    /// entries (such as `shift+enter=text:\x1b\r`) and `macos-option-as-alt`.
    private func applyGhosttyKeyboardConfiguration() {
        let entries = (try? GhosttyThemeImporter.configurationEntries()) ?? []
        TerminalKeybindings.shared = .ghostty(configuration: entries)
        let optionAsAlt = entries.last { $0.0 == "macos-option-as-alt" }?.1.trimmingCharacters(in: .whitespaces)
        TerminalEngine.defaultOptionAsAlt = switch optionAsAlt {
        case "true": .both
        case "left": .left
        case "right": .right
        default: .disabled
        }
    }
}
