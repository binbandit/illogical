import SwiftUI

@main struct IllogicalApp: App {
    init() { LaunchMetrics.mark("appInit") }
    var body: some Scene {
        WindowGroup("illogical", id: "workspace") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { WorkspaceCommands() }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var model
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { model?.newSession() }.keyboardShortcut("n")
            Button("New Tab") { model?.newTab() }.keyboardShortcut("t")
            Button("New Window") { openWindow(id: "workspace") }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) { Button("Appearance…") { model?.showSettings = true }.keyboardShortcut(",") }
        CommandMenu("Workspace") {
            Button("Switch Session…") { model?.palette = .sessions }.keyboardShortcut("k")
            Button("Command Palette…") { model?.palette = .commands }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Open from Directory…") { model?.showDirectory() }.keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Split Right") { model?.split("horizontal") }.keyboardShortcut("d")
            Button("Split Down") { model?.split("vertical") }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Zoom Pane") { model?.zoom() }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Close Pane") { model?.closeBlock() }.keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Peek at Tabs") { model?.togglePeek(1) }.keyboardShortcut(.space, modifiers: [.command, .shift])
            Button("Session Overview") { model?.togglePeek(2) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Toggle Vertical Tabs") { model?.verticalTabs.toggle() }.keyboardShortcut("v", modifiers: [.command, .control])
            Divider()
            Button("Rename Session…") { model?.rename("session") }
            Button("Add Remote Host…") { model?.showAddHost = true }
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Terminal…") { model?.find() }.keyboardShortcut("f")
            Button("Increase Text Size") { if let model { model.fontSize = min(32, model.fontSize + 1) } }.keyboardShortcut("+")
            Button("Decrease Text Size") { if let model { model.fontSize = max(8, model.fontSize - 1) } }.keyboardShortcut("-")
            Button("Reset Text Size") { model?.fontSize = 13 }.keyboardShortcut("0")
        }
    }
}
