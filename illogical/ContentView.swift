import AppKit
import SwiftUI

/// One workspace window. It owns the window's model and keeps what it shows
/// in scene storage, so every window restores its own session on relaunch.
struct ContentView: View {
    @State private var model = WorkspaceModel()
    @SceneStorage("workspace.host") private var storedHost = ""
    @SceneStorage("workspace.session") private var storedSession = ""
    @SceneStorage("workspace.tab") private var storedTab = ""

    var body: some View {
        WorkspaceView(model: model)
            .focusedSceneValue(model)
            .onAppear(perform: start)
            .onChange(of: model.selection) { _, selection in
                guard !selection.session.isEmpty else { return }
                storedHost = selection.host
                storedSession = selection.session
                storedTab = selection.tab
            }
    }

    private func start() {
        LaunchMetrics.mark("contentAppeared")
        if LaunchMetrics.tracing { model.onLaunchStage = { LaunchMetrics.mark($0) } }
        let registry = WorkspaceRegistry.shared
        let intent = registry.nextWindowIntent
            ?? (storedSession.isEmpty ? .reopen : .restore(WindowSelection(host: storedHost, session: storedSession, tab: storedTab)))
        registry.nextWindowIntent = nil
        model.start(intent)
    }
}

struct WorkspaceView: View {
    let model: WorkspaceModel
    @State private var isFullScreen = false
    private var preferences: Preferences { model.preferences }
    private var theme: TerminalTheme { preferences.theme }
    /// Translucent themes show the desktop through the chrome and panes.
    private var backgroundOpacity: Double { isFullScreen ? 1 : theme.effectiveBackgroundOpacity }

    var body: some View {
        ZStack(alignment: .top) {
            if preferences.verticalTabs {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        WorkspaceTitlebar(model: model, isFullScreen: isFullScreen)
                        WorkspaceSidebar(model: model)
                    }
                    .frame(width: Chrome.Sidebar.width)
                    WorkspaceArea(model: model)
                }
            } else {
                VStack(spacing: 0) {
                    WorkspaceTitlebar(model: model, isFullScreen: isFullScreen)
                    WorkspaceArea(model: model)
                }
            }
        }
        // An overlay never changes the layout beneath it, however tall it is.
        .overlay { if let mode = model.palette { PaletteOverlay(model: model, mode: mode) } }
        .overlay(alignment: .bottom) { NoticeBanner(model: model) }
        .backgroundPreferenceValue(PaneFrames.self) { panes in
            WindowBackground(theme: theme, style: preferences.interfaceStyle, opacity: backgroundOpacity, panes: panes)
        }
        .foregroundStyle(theme.text)
        .tint(theme.tint)
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .frame(minWidth: 760, minHeight: 480)
        .ignoresSafeArea()
        .background(WindowConfigurator(model: model, title: model.windowTitle, theme: theme, isFullScreen: $isFullScreen))
        .sheet(item: Binding(get: { model.rename }, set: { if $0 == nil { model.cancelRename() } })) { request in
            RenameSheet(request: request, onCommit: model.commitRename, onCancel: model.cancelRename)
        }
        .sheet(isPresented: Binding(get: { model.showAddHost }, set: { model.showAddHost = $0 }),
               onDismiss: { model.requestTerminalFocus() }) {
            AddHostSheet()
        }
        .sheet(isPresented: Binding(get: { !model.migration.isEmpty }, set: { if !$0 { model.migration = [] } }),
               onDismiss: { model.requestTerminalFocus() }) {
            MigrationSheet(themes: model.migration, tint: theme.tint) { adopt in
                if adopt { preferences.adopt(model.migration) }
                model.migration = []
            }
        }
    }
}

/// The terminal area below the titlebar, sliding down to reveal the peek.
private struct WorkspaceArea: View {
    let model: WorkspaceModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if model.peek > 0 {
                    WorkspaceOverview(model: model, expanded: model.peekExpanded)
                        .padding(Chrome.Overview.padding)
                        .opacity(min(1, model.peek * 2))
                }
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(y: model.peekOffset(height: geometry.size.height))
                    .accessibilityHidden(model.peek > 0)
            }
            .clipped()
        }
    }

    @ViewBuilder private var content: some View {
        if let deck = model.activeDeck {
            Group {
                if let zoomed = deck.zoomed, deck.root.contains(zoomed) {
                    TerminalPane(model: model, block: zoomed, host: model.selectedHost, preview: false)
                } else {
                    LayoutView(model: model, node: deck.root, deck: deck.id, host: model.selectedHost, preview: false)
                }
            }
            .padding(model.preferences.density == .comfortable ? Chrome.Pane.comfortablePadding : 0)
            .overlay(alignment: .bottom) {
                if let status = model.statuses[model.selectedHost] { StatusCapsule(text: status) }
            }
        } else {
            VStack(spacing: 18) {
                Image(systemName: "terminal").font(.system(size: 38, weight: .ultraLight)).opacity(0.45)
                Text(model.statuses[model.selectedHost] ?? "Opening a terminal…").font(.system(size: 15))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StatusCapsule: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: Chrome.Notice.fontSize))
            .padding(Chrome.Notice.padding)
            .background(.regularMaterial, in: Capsule())
            .padding(Chrome.Notice.margin)
    }
}

/// Transient messages: failed actions, program notifications.
private struct NoticeBanner: View {
    let model: WorkspaceModel
    var body: some View {
        if let notice = model.notice {
            StatusCapsule(text: notice.message)
                .onTapGesture { model.dismissNotice() }
                .transition(.opacity)
                .id(notice.id)
                .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Where each live pane sits, so a translucent window can leave the panes'
/// areas to the terminal renderer instead of stacking two translucent layers.
struct PaneFrames: PreferenceKey {
    struct Frame {
        let anchor: Anchor<CGRect>
        let radius: CGFloat
    }
    static let defaultValue: [Frame] = []
    static func reduce(value: inout [Frame], nextValue: () -> [Frame]) { value += nextValue() }
}

private struct WindowBackground: View {
    let theme: TerminalTheme
    let style: InterfaceStyle
    let opacity: Double
    let panes: [PaneFrames.Frame]

    var body: some View {
        if opacity >= 1 {
            theme.chromeBackground(style)
        } else {
            GeometryReader { proxy in
                theme.chromeBackground(style)
                    .opacity(opacity)
                    .mask {
                        Rectangle()
                            .overlay {
                                ForEach(panes.indices, id: \.self) { index in
                                    let rect = proxy[panes[index].anchor]
                                    RoundedRectangle(cornerRadius: panes[index].radius)
                                        .frame(width: rect.width, height: rect.height)
                                        .position(x: rect.midX, y: rect.midY)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .compositingGroup()
                    }
            }
        }
    }
}
