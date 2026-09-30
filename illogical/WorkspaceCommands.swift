import AppKit
import SwiftUI

/// Every workspace command in one registry. Menus, command palette hints,
/// extra key chords and the README shortcut table all come from here.
enum WorkspaceCommand: String, CaseIterable, Identifiable {
    case newWindow, newSession, newTab, goToDirectory
    case closePane, closeTab, closeWindow, closeAllWindows, closeSession
    case find, findNext, findPrevious, clearScreen
    case toggleVerticalTabs, togglePaneTitles, showAllTabs, sessionOverview
    case biggerText, smallerText, actualSize
    case scrollToTop, scrollToBottom, pageUp, pageDown, toggleFullScreen
    case switchSession, commandPalette, renameSession, chooseTheme, importGhosttyThemes, addRemoteHost, settings
    case nextTab, previousTab, moveTabLeft, moveTabRight, renameTab
    case splitRight, splitDown, zoomPane, nextPane, previousPane, equalizePanes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newWindow: "New Window"
        case .newSession: "New Session"
        case .newTab: "New Tab"
        case .goToDirectory: "Go to Directory…"
        case .closePane: "Close Pane"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .closeAllWindows: "Close All Windows"
        case .closeSession: "Close Session…"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .clearScreen: "Clear Screen and Scrollback"
        case .toggleVerticalTabs: "Vertical Tabs"
        case .togglePaneTitles: "Pane Titles"
        case .showAllTabs: "Show All Tabs"
        case .sessionOverview: "Session Overview"
        case .biggerText: "Bigger"
        case .smallerText: "Smaller"
        case .actualSize: "Actual Size"
        case .scrollToTop: "Scroll to Top"
        case .scrollToBottom: "Scroll to Bottom"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .toggleFullScreen: "Toggle Full Screen"
        case .switchSession: "Switch Session…"
        case .commandPalette: "Command Palette…"
        case .renameSession: "Rename Session…"
        case .chooseTheme: "Choose Theme…"
        case .importGhosttyThemes: "Import Ghostty Themes…"
        case .addRemoteHost: "Add Remote Host…"
        case .settings: "Settings…"
        case .nextTab: "Show Next Tab"
        case .previousTab: "Show Previous Tab"
        case .moveTabLeft: "Move Tab Left"
        case .moveTabRight: "Move Tab Right"
        case .renameTab: "Rename Tab…"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .zoomPane: "Zoom Pane"
        case .nextPane: "Select Next Pane"
        case .previousPane: "Select Previous Pane"
        case .equalizePanes: "Equalize Panes"
        }
    }

    /// Titles that describe the action a toggle will take, for the palette.
    @MainActor
    func paletteTitle(_ preferences: Preferences) -> String {
        switch self {
        case .toggleVerticalTabs: preferences.verticalTabs ? "Switch to Horizontal Tabs" : "Switch to Vertical Tabs"
        case .togglePaneTitles: preferences.showPaneTitles ? "Hide Pane Titles" : "Show Pane Titles"
        default: title.replacingOccurrences(of: "…", with: "")
        }
    }

    var symbol: String {
        switch self {
        case .newWindow: "macwindow.badge.plus"
        case .newSession: "square.stack.3d.up.badge.fill"
        case .newTab: "plus"
        case .goToDirectory: "folder"
        case .closePane, .closeTab, .closeWindow, .closeAllWindows, .closeSession: "xmark"
        case .find, .findNext, .findPrevious: "magnifyingglass"
        case .clearScreen: "eraser"
        case .toggleVerticalTabs: "sidebar.left"
        case .togglePaneTitles: "text.alignleft"
        case .showAllTabs: "rectangle.grid.1x2"
        case .sessionOverview: "square.grid.2x2"
        case .biggerText: "textformat.size.larger"
        case .smallerText: "textformat.size.smaller"
        case .actualSize: "textformat.size"
        case .scrollToTop, .pageUp: "arrow.up.to.line"
        case .scrollToBottom, .pageDown: "arrow.down.to.line"
        case .toggleFullScreen: "arrow.up.left.and.arrow.down.right"
        case .switchSession: "square.stack.3d.up"
        case .commandPalette: "command"
        case .renameSession, .renameTab: "pencil"
        case .chooseTheme: "paintpalette"
        case .importGhosttyThemes: "square.and.arrow.down"
        case .addRemoteHost: "network"
        case .settings: "slider.horizontal.3"
        case .nextTab: "arrow.right"
        case .previousTab: "arrow.left"
        case .moveTabLeft: "arrow.left.to.line"
        case .moveTabRight: "arrow.right.to.line"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .zoomPane: "arrow.up.left.and.arrow.down.right"
        case .nextPane, .previousPane: "rectangle.2.swap"
        case .equalizePanes: "equal.square"
        }
    }

    /// The menu shortcut. Shift-Command-G belongs to Find Previous while the
    /// focused pane has a search open, and to Go to Directory otherwise.
    @MainActor
    func shortcut(searchOpen: Bool) -> KeyboardShortcut? {
        switch self {
        case .findPrevious: searchOpen ? KeyboardShortcut("g", modifiers: [.command, .shift]) : nil
        case .goToDirectory: searchOpen ? nil : KeyboardShortcut("g", modifiers: [.command, .shift])
        default: shortcut
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .newWindow: KeyboardShortcut("n")
        case .newSession: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .newTab: KeyboardShortcut("t")
        case .goToDirectory, .findPrevious: KeyboardShortcut("g", modifiers: [.command, .shift])
        case .closePane: KeyboardShortcut("w")
        case .closeTab: KeyboardShortcut("w", modifiers: [.command, .option])
        case .closeWindow: KeyboardShortcut("w", modifiers: [.command, .shift])
        case .closeAllWindows: KeyboardShortcut("w", modifiers: [.command, .option, .shift])
        case .find: KeyboardShortcut("f")
        case .findNext: KeyboardShortcut("g")
        case .clearScreen: KeyboardShortcut("k", modifiers: [.command, .option])
        case .toggleVerticalTabs: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .showAllTabs: KeyboardShortcut("\\", modifiers: [.command, .shift])
        case .sessionOverview: KeyboardShortcut("o", modifiers: [.command, .shift])
        case .biggerText: KeyboardShortcut("=")
        case .smallerText: KeyboardShortcut("-")
        case .actualSize: KeyboardShortcut("0")
        case .scrollToTop: KeyboardShortcut(.home)
        case .scrollToBottom: KeyboardShortcut(.end)
        case .pageUp: KeyboardShortcut(.pageUp)
        case .pageDown: KeyboardShortcut(.pageDown)
        case .toggleFullScreen: KeyboardShortcut(.return)
        case .switchSession: KeyboardShortcut("k")
        case .commandPalette: KeyboardShortcut("p", modifiers: [.command, .shift])
        case .renameSession: KeyboardShortcut("i", modifiers: [.command, .option, .shift])
        case .renameTab: KeyboardShortcut("i", modifiers: [.command, .shift])
        case .settings: KeyboardShortcut(",")
        case .nextTab: KeyboardShortcut("]", modifiers: [.command, .shift])
        case .previousTab: KeyboardShortcut("[", modifiers: [.command, .shift])
        case .moveTabLeft: KeyboardShortcut("[", modifiers: [.command, .option, .shift])
        case .moveTabRight: KeyboardShortcut("]", modifiers: [.command, .option, .shift])
        case .splitRight: KeyboardShortcut("d")
        case .splitDown: KeyboardShortcut("d", modifiers: [.command, .shift])
        case .zoomPane: KeyboardShortcut(.return, modifiers: [.command, .shift])
        case .nextPane: KeyboardShortcut("]")
        case .previousPane: KeyboardShortcut("[")
        case .equalizePanes: KeyboardShortcut("=", modifiers: [.command, .control])
        case .closeSession, .chooseTheme, .importGhosttyThemes, .addRemoteHost, .togglePaneTitles: nil
        }
    }

    /// Further chords for the same command, handled by `KeyAliasMonitor`
    /// because a menu item holds only one shortcut.
    var aliases: [KeyboardShortcut] {
        switch self {
        case .biggerText: [KeyboardShortcut("+")]
        case .nextTab: [KeyboardShortcut(.tab, modifiers: .control)]
        case .previousTab: [KeyboardShortcut(.tab, modifiers: [.control, .shift])]
        default: []
        }
    }

    var showsInPalette: Bool {
        switch self {
        case .commandPalette, .findNext, .findPrevious, .pageUp, .pageDown: false
        default: true
        }
    }

    @MainActor
    func perform(_ context: CommandContext) {
        let model = context.model
        let preferences = Preferences.shared
        switch self {
        case .newWindow: context.openNewWindow()
        case .newSession: if let model { model.newSession() } else { context.openNewWindow() }
        case .newTab: if let model { model.newTab() } else { context.openNewWindow() }
        case .goToDirectory: model?.showDirectory()
        case .closePane: if let model { model.closeFocusedPane() } else { NSApp.keyWindow?.performClose(nil) }
        case .closeTab: model?.closeTab()
        case .closeWindow: (model?.window ?? NSApp.keyWindow)?.performClose(nil)
        case .closeAllWindows: WorkspaceRegistry.shared.models.forEach { $0.window?.close() }
        case .closeSession: if let model, !model.selectedSession.isEmpty { model.closeSession(model.selectedSession, host: model.selectedHost) }
        case .find: model?.find()
        case .findNext: model?.findNext(1)
        case .findPrevious: model?.findNext(-1)
        case .clearScreen: model?.clearScreen()
        case .toggleVerticalTabs: preferences.verticalTabs.toggle()
        case .togglePaneTitles: preferences.showPaneTitles.toggle()
        case .showAllTabs: model?.togglePeek(1)
        case .sessionOverview: model?.togglePeek(2)
        case .biggerText: model?.adjustFontSize(by: 1)
        case .smallerText: model?.adjustFontSize(by: -1)
        case .actualSize: model?.resetFontSize()
        case .scrollToTop: model?.scrollToTop()
        case .scrollToBottom: model?.scrollToBottom()
        case .pageUp: model?.scrollPage(-1)
        case .pageDown: model?.scrollPage(1)
        case .toggleFullScreen: (model?.window ?? NSApp.keyWindow)?.toggleFullScreen(nil)
        case .switchSession: model?.togglePalette(.sessions)
        case .commandPalette: model?.togglePalette(.commands)
        case .renameSession: model?.beginRenameSession()
        case .chooseTheme: model?.palette = .themes
        case .importGhosttyThemes: model?.importGhosttyThemes()
        case .addRemoteHost: model?.showAddHost = true
        case .settings: context.openSettings()
        case .nextTab: model?.selectAdjacentTab(1)
        case .previousTab: model?.selectAdjacentTab(-1)
        case .moveTabLeft: model?.moveTab(-1)
        case .moveTabRight: model?.moveTab(1)
        case .renameTab: model?.beginRenameTab()
        case .splitRight: model?.split(.horizontal)
        case .splitDown: model?.split(.vertical)
        case .zoomPane: model?.zoom()
        case .nextPane: model?.cyclePane(1)
        case .previousPane: model?.cyclePane(-1)
        case .equalizePanes: model?.equalizePanes()
        }
    }
}

/// What a command needs from the app beyond the focused window's model.
struct CommandContext {
    let model: WorkspaceModel?
    let openNewWindow: () -> Void
    let openSettings: () -> Void

    @MainActor
    init(model: WorkspaceModel?, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        self.model = model
        self.openNewWindow = { WorkspaceScene.openNewWindow(from: model, using: openWindow) }
        self.openSettings = { openSettings() }
    }
}

enum WorkspaceScene {
    static let id = "workspace"

    /// Command-N: a new window with a new session on the key window's host,
    /// starting in the focused pane's directory and cascading from it.
    @MainActor
    static func openNewWindow(from model: WorkspaceModel?, using openWindow: OpenWindowAction) {
        let registry = WorkspaceRegistry.shared
        registry.nextWindowIntent = .newSession(host: model?.selectedHost ?? HostProfile.local.id,
                                                parentBlock: model.flatMap { $0.focusedBlock.isEmpty ? nil : $0.focusedBlock })
        if let frame = (model?.window ?? NSApp.keyWindow)?.frame {
            registry.nextWindowTopLeft = NSPoint(x: frame.minX + 22, y: frame.maxY - 22)
        }
        openWindow(id: id)
    }
}

extension KeyboardShortcut {
    /// How menus print the shortcut, such as ⇧⌘N.
    var displayText: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .return: text += "↩"
        case .tab: text += "⇥"
        case .space: text += "Space"
        case .home: text += "↖"
        case .end: text += "↘"
        case .pageUp: text += "⇞"
        case .pageDown: text += "⇟"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .delete: text += "⌫"
        case .escape: text += "⎋"
        default: text += String(key.character).uppercased()
        }
        return text
    }
}

/// The app's menus, built from `WorkspaceCommand`. Items are never
/// disabled: an inapplicable command does nothing, so its chord can never
/// fall through to the terminal.
struct WorkspaceCommands: Commands {
    @FocusedValue(WorkspaceModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var context: CommandContext { CommandContext(model: model, openWindow: openWindow, openSettings: openSettings) }
    private var searchOpen: Bool { model?.hasOpenSearch == true }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items(.newWindow, .newSession, .newTab)
            Divider()
            item(.goToDirectory)
        }
        CommandGroup(replacing: .saveItem) {
            items(.closePane, .closeTab, .closeWindow, .closeAllWindows)
            Divider()
            item(.closeSession)
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") { items(.find, .findNext, .findPrevious) }
            Divider()
            item(.clearScreen)
        }
        CommandGroup(before: .toolbar) {
            Toggle(WorkspaceCommand.toggleVerticalTabs.title, isOn: Binding(get: { Preferences.shared.verticalTabs },
                                                                            set: { Preferences.shared.verticalTabs = $0 }))
                .keyboardShortcut(WorkspaceCommand.toggleVerticalTabs.shortcut)
            Toggle(WorkspaceCommand.togglePaneTitles.title, isOn: Binding(get: { Preferences.shared.showPaneTitles },
                                                                          set: { Preferences.shared.showPaneTitles = $0 }))
            items(.showAllTabs, .sessionOverview)
            Divider()
            items(.biggerText, .smallerText, .actualSize)
            Divider()
            items(.scrollToTop, .scrollToBottom, .pageUp, .pageDown)
            Divider()
            item(.toggleFullScreen)
            Divider()
        }
        CommandMenu("Session") {
            items(.switchSession, .commandPalette)
            Divider()
            item(.renameSession)
            Divider()
            items(.chooseTheme, .importGhosttyThemes, .addRemoteHost)
        }
        CommandMenu("Tab") {
            items(.nextTab, .previousTab)
            items(.moveTabLeft, .moveTabRight)
            Menu("Select Tab") {
                ForEach(0..<9) { index in
                    Button(index == 8 ? "Last Tab" : "Tab \(index + 1)") { model?.selectTab(index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            Divider()
            item(.renameTab)
        }
        CommandMenu("Pane") {
            items(.splitRight, .splitDown, .zoomPane)
            Divider()
            items(.nextPane, .previousPane)
            Menu("Select Pane") {
                directionItems(modifiers: [.command, .option]) { model?.focusAdjacentPane($0) }
            }
            Menu("Resize Pane") {
                directionItems(modifiers: [.command, .control]) { model?.resizePane($0) }
            }
            item(.equalizePanes)
        }
    }

    private func item(_ command: WorkspaceCommand) -> some View {
        Button(command.title) { command.perform(context) }
            .keyboardShortcut(command.shortcut(searchOpen: searchOpen))
    }

    @ViewBuilder
    private func items(_ commands: WorkspaceCommand...) -> some View {
        ForEach(commands) { item($0) }
    }

    @ViewBuilder
    private func directionItems(modifiers: EventModifiers, action: @escaping (PaneDirection) -> Void) -> some View {
        Button("Left") { action(.left) }.keyboardShortcut(.leftArrow, modifiers: modifiers)
        Button("Right") { action(.right) }.keyboardShortcut(.rightArrow, modifiers: modifiers)
        Button("Up") { action(.up) }.keyboardShortcut(.upArrow, modifiers: modifiers)
        Button("Down") { action(.down) }.keyboardShortcut(.downArrow, modifiers: modifiers)
    }
}

/// Handles `WorkspaceCommand.aliases` for workspace windows, before the
/// terminal sees the key.
@MainActor
enum KeyAliasMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let model = WorkspaceRegistry.shared.model(for: event.window),
                  let command = WorkspaceCommand.allCases.first(where: { $0.aliases.contains { matches(event, $0) } }) else { return event }
            command.perform(CommandContext(model: model))
            return nil
        }
    }

    static func matches(_ event: NSEvent, _ shortcut: KeyboardShortcut) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch shortcut.key {
        case .tab: return event.keyCode == 48 && modifiers == NSEvent.ModifierFlags(shortcut.modifiers)
        case .space: return event.keyCode == 49 && modifiers == NSEvent.ModifierFlags(shortcut.modifiers)
        case .return: return event.keyCode == 36 && modifiers == NSEvent.ModifierFlags(shortcut.modifiers)
        default:
            // A shifted character such as "+" may arrive with Shift held.
            guard event.charactersIgnoringModifiers == String(shortcut.key.character) else { return false }
            let expected = NSEvent.ModifierFlags(shortcut.modifiers)
            return modifiers == expected || modifiers == expected.union(.shift)
        }
    }
}

private extension NSEvent.ModifierFlags {
    init(_ modifiers: EventModifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.control) { insert(.control) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.shift) { insert(.shift) }
    }
}

private extension CommandContext {
    /// Alias chords only act on a window's model.
    init(model: WorkspaceModel) {
        self.model = model
        openNewWindow = {}
        openSettings = {}
    }
}
