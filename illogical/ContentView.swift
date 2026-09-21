import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = WorkspaceModel()

    var body: some View {
        ZStack(alignment: .top) {
            if model.theme.effectiveBackgroundOpacity == 1 { background }
            if model.verticalTabs {
                HStack(spacing: 0) {
                    VStack(spacing: 0) { WorkspaceTitlebar(model: model); WorkspaceSidebar(model: model) }.frame(width: 238).background(background)
                    workspaceArea
                }
            } else {
                VStack(spacing: 0) { WorkspaceTitlebar(model: model).background(background); workspaceArea }
            }
            if let mode = model.palette { PaletteOverlay(model: model, mode: mode) }
        }
        .foregroundStyle(model.theme.text)
        .tint(model.theme.tint)
        .preferredColorScheme(model.theme.isLight ? .light : .dark)
        .frame(minWidth: 760, minHeight: 480)
        .ignoresSafeArea()
        .background(WindowSetup(model: model))
        .focusedSceneValue(\.workspace, model)
        .onAppear {
            if LaunchMetrics.tracing { model.onLaunchStage = { LaunchMetrics.mark($0) } }
            LaunchMetrics.mark("contentAppeared");model.start()
        }
        .sheet(isPresented: $model.showSettings) { AppearanceSettings(model: model) }
        .sheet(isPresented: $model.showAddHost) { AddHostSheet(model: model) }
        .sheet(isPresented: $model.showRename) { RenameSheet(model: model) }
        .sheet(isPresented: Binding(get: { !model.migration.isEmpty }, set: { if !$0 { model.migration = [] } })) { MigrationSheet(model: model) }
        .alert("illogical", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var workspaceArea: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if model.peek > 0 { WorkspaceOverview(model: model, expanded: model.peek > 1.35).padding(12).opacity(min(1, model.peek * 2)) }
                workspace.frame(width: geometry.size.width, height: geometry.size.height)
                    .offset(y: model.peek > 1.35 ? geometry.size.height + 20 : 190 * model.peek)
                    .allowsHitTesting(model.peek < 0.1)
            }.clipped()
        }
    }

    @ViewBuilder private var background: some View {
        switch model.interfaceStyle {
        case .modern: Rectangle().fill(.ultraThinMaterial)
        case .system: Color(nsColor: .windowBackgroundColor)
        case .themed: model.theme.chrome
        case .blended: Rectangle().fill(.ultraThinMaterial).overlay(model.theme.chrome.opacity(0.65))
        }
    }

    @ViewBuilder private var workspace: some View {
        if let deck = model.activeDeck {
            Group {
                if let zoomed = deck.zoomed, !zoomed.isEmpty {
                    TerminalPane(model: model, block: zoomed, host: model.selectedHost, preview: false)
                } else {
                    LayoutSurface(model: model, node: deck.root, deck: deck.id, host: model.selectedHost, preview: false)
                }
            }
            .padding(model.density == .comfortable ? 9 : 0)
            .overlay(alignment: .bottom) {
                if let status = model.statuses[model.selectedHost] {
                    Text(status).font(.system(size: 12)).padding(10).background(.regularMaterial, in: Capsule()).padding(16)
                }
            }
        } else {
            VStack(spacing: 18) {
                Image(systemName: "terminal").font(.system(size: 38, weight: .ultraLight)).opacity(0.45)
                Text(model.statuses[model.selectedHost] ?? "A little room to think.").font(.system(size: 15))
                Button("Open a Terminal") { model.newSession() }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct WorkspaceTitlebar: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 72)
            if model.verticalTabs {
                Button { model.verticalTabs = false } label: { Image(systemName: "sidebar.left").font(.system(size: 14)) }.buttonStyle(.plain).help("Horizontal tabs")
            } else {
            Button { model.palette = .sessions } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.activeHost.isLocal ? "rectangle.stack" : "globe").font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.currentTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(model.activeHost.name).font(.system(size: 9)).opacity(0.45)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.4)
                }.padding(.horizontal, 6).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Switch session (⌘K)").accessibilityLabel("Switch session")
            }
            if !model.verticalTabs {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(model.activeSession?.windows ?? []) { deck in
                            DeckTab(model: model, deck: deck, session: model.selectedSession, host: model.selectedHost)
                        }
                    }.padding(.vertical, 3)
                }.scrollIndicators(.hidden)
            } else { Spacer() }
            Button { model.newTab() } label: { Image(systemName: "plus").frame(width: 24, height: 28) }
                .buttonStyle(.plain).help("New tab (⌘T)").accessibilityLabel("New tab")
            if !model.verticalTabs { Menu {
                Button("Command Palette") { model.palette = .commands }
                Button("Session Overview") { model.togglePeek(2) }
                Divider()
                Toggle("Vertical Tabs", isOn: $model.verticalTabs)
                Toggle("Show Pane Titles", isOn: $model.showPaneTitles)
                Button("Appearance…") { model.showSettings = true }
                Button("Add Remote Host…") { model.showAddHost = true }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Workspace menu") }
        }.padding(.trailing, 12).frame(height: 44)
            .background(WindowDragArea())
    }
}

struct DeckIcon: View {
    var count = 1
    var symbol = "terminal"
    var body: some View {
        ZStack {
            if count > 1 { RoundedRectangle(cornerRadius: 4).fill(.gray.opacity(0.45)).frame(width: 21, height: 16).offset(x: 3, y: -3) }
            RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.18), lineWidth: 0.5))
            Image(systemName: symbol).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color(red: 0.55, green: 0.91, blue: 0.68))
        }.frame(width: 23, height: 18)
    }
}

struct DeckTab: View {
    @ObservedObject var model: WorkspaceModel
    let deck: Deck
    let session: String
    let host: String
    var vertical = false
    @State private var hovering = false
    private var selected: Bool { deck.id == model.selectedDeck && host == model.selectedHost }
    private var highlightedTitle: AttributedString {
        var text = AttributedString(model.deckTitle(deck, host: host))
        if vertical, !model.sidebarFilter.isEmpty, let range = text.range(of: model.sidebarFilter, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .system(size: 12, weight: .semibold)
        }
        return text
    }
    var body: some View {
        HStack(spacing: 8) {
            DeckIcon(count: deck.root.blocks.count, symbol: deck.root.blocks.first.map { model.processIcon($0, host: host) } ?? "terminal")
            Text(highlightedTitle).font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
            if vertical { Spacer(minLength: 0) }
            if hovering {
                Button { model.send(WireRequest(method: "window.kill", window: deck.id), host: host) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }
                    .buttonStyle(.plain).accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 11).frame(minWidth: vertical ? 0 : 105, maxWidth: vertical ? .infinity : 230).frame(height: 31)
        .background(selected ? (model.theme.isLight ? .white.opacity(0.7) : model.theme.text.opacity(0.09)) : Color.clear, in: Capsule())
        .overlay(Capsule().stroke(selected ? model.theme.border : .clear, lineWidth: 0.5))
        .contentShape(Rectangle()).onTapGesture { model.choose(deck: deck.id, session: session, host: host) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename Tab…") { model.choose(deck: deck.id, session: session, host: host); model.rename("window") }
            Button("Close Tab") { model.send(WireRequest(method: "window.kill", window: deck.id), host: host) }
        }
        .accessibilityElement(children: .combine).accessibilityLabel(model.deckTitle(deck, host: host)).accessibilityAddTraits(.isButton)
    }
}

struct WorkspaceSidebar: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.hosts) { host in
                        VStack(alignment: .leading, spacing: 13) {
                            if model.hosts.count > 1 { Label(host.name, systemImage: host.isLocal ? "desktopcomputer" : "network").font(.system(size: 10, weight: .semibold)).opacity(0.4).padding(.horizontal, 9) }
                            ForEach(model.states[host.id]?.sessions ?? []) { session in
                                if model.sidebarFilter.isEmpty || session.name.localizedCaseInsensitiveContains(model.sidebarFilter) || session.windows.contains(where: { model.deckTitle($0, host: host.id).localizedCaseInsensitiveContains(model.sidebarFilter) }) {
                                    VStack(spacing: 4) {
                                        HStack {
                                            Text(session.name).font(.system(size: 11, weight: .semibold)).opacity(0.55)
                                            Spacer()
                                            Button { model.choose(session: session.id, host: host.id); model.newTab() } label: { Image(systemName: "plus").font(.system(size: 10)) }.buttonStyle(.plain)
                                        }.padding(.horizontal, 10).padding(.bottom, 4)
                                        ForEach(session.windows) { deck in DeckTab(model: model, deck: deck, session: session.id, host: host.id, vertical: true) }
                                    }
                                    .contextMenu {
                                        Button("Rename Session…") { model.rename(session: session.id, host: host.id) }
                                        Button("Close Session") { model.killSession(session.id, host: host.id) }
                                    }
                                }
                            }
                        }
                    }
                }.padding(10)
            }
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").opacity(0.5)
                TextField("Filter", text: $model.sidebarFilter).textFieldStyle(.plain)
                Button { model.newSession() } label: { Image(systemName: "rectangle.stack.badge.plus") }.buttonStyle(.plain).help("New session")
                Button { model.showAddHost = true } label: { Image(systemName: "globe.badge.chevron.backward") }.buttonStyle(.plain).help("Add remote host")
            }.font(.system(size: 12)).padding(9).background(model.theme.text.opacity(0.045), in: Capsule()).padding(10)
        }
    }
}

struct LayoutSurface: View {
    @ObservedObject var model: WorkspaceModel
    let node: SplitLayout
    let deck: String
    let host: String
    let preview: Bool
    var body: some View {
        if let block = node.block { TerminalPane(model: model, block: block, host: host, preview: preview) }
        else if let first = node.first, let second = node.second {
            AnyView(SplitBranches(model: model, node: node, first: first, second: second, deck: deck, host: host, preview: preview))
        }
    }
}

struct SplitBranches: View {
    @ObservedObject var model: WorkspaceModel
    let node: SplitLayout
    let first: SplitLayout
    let second: SplitLayout
    let deck: String
    let host: String
    let preview: Bool
    @State private var dragRatio: Double?
    private var horizontal: Bool { node.axis == "horizontal" }
    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = preview ? 3 : (model.density == .comfortable ? 8 : 1)
            let extent = max(1, (horizontal ? geometry.size.width : geometry.size.height) - gap)
            let ratio = dragRatio ?? node.ratio ?? 0.5
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
            layout {
                LayoutSurface(model: model, node: first, deck: deck, host: host, preview: preview)
                    .frame(width: horizontal ? extent * ratio : nil, height: horizontal ? nil : extent * ratio)
                LayoutSurface(model: model, node: second, deck: deck, host: host, preview: preview)
            }
            if !preview {
                Rectangle().fill(model.density == .compact ? model.theme.border : .clear)
                    .frame(width: horizontal ? max(6, gap) : nil, height: horizontal ? nil : max(6, gap))
                    .contentShape(Rectangle())
                    .position(x: horizontal ? extent * ratio + gap / 2 : geometry.size.width / 2, y: horizontal ? geometry.size.height / 2 : extent * ratio + gap / 2)
                    .gesture(DragGesture(coordinateSpace: .named(node.id)).onChanged { value in
                        dragRatio = max(0.1, min(0.9, (horizontal ? value.location.x : value.location.y) / extent))
                    }.onEnded { _ in
                        if let dragRatio { model.send(WireRequest(method: "layout.resize", window: deck, target: node.id, ratio: dragRatio), host: host) }
                        dragRatio = nil
                    })
                    .onHover { hovering in if hovering { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            }
        }.coordinateSpace(name: node.id)
    }
}

struct TerminalPane: View {
    @ObservedObject var model: WorkspaceModel
    let block: String
    let host: String
    let preview: Bool
    @State private var hovering = false
    private var info: BlockInfo? { model.info(block, host: host) }
    @State private var cellSize = CGSize(width: 8, height: 19)
    @State private var paneSize = CGSize(width: 1, height: 1)
    private var radius: CGFloat { preview ? 5 : (model.density == .comfortable ? 9 : 0) }
    var body: some View {
        VStack(spacing: 0) {
            if !preview && model.showPaneTitles {
                HStack(spacing: 6) {
                    Image(systemName: model.processIcon(block, host: host)).font(.system(size: 10)).opacity(0.5)
                    Text(info?.displayTitle ?? "Terminal").font(.system(size: 11, weight: .medium)).lineLimit(1).opacity(0.55)
                    if info?.parked == true { Image(systemName: "moon.zzz").font(.system(size: 9)).opacity(0.35).help("Emulator parked. Your process is still running.") }
                    Spacer(minLength: 4)
                    if hovering {
                        paneButton("rectangle.split.2x1", label: "Split right") { model.split("horizontal", block: block) }
                        paneButton("rectangle.split.1x2", label: "Split down") { model.split("vertical", block: block) }
                        paneButton("arrow.up.left.and.arrow.down.right", label: "Zoom pane") { model.zoom(block) }
                        paneButton("xmark", label: "Close pane") { model.closeBlock(block) }
                    }
                }.padding(.horizontal, 10).frame(height: 30).background(model.theme.color.opacity(model.theme.effectiveBackgroundOpacity)).contentShape(Rectangle())
                    .onTapGesture { model.focus(block) }
                    .onDrag { NSItemProvider(object: block as NSString) }
            }
            TerminalSurface(engine: model.engine(for: block, host: host), fontSize: model.fontSize, fontName: model.fontName, focused: !preview && model.focusedBlock == block && model.searchFocusedBlock == nil && model.palette == nil && !model.showSettings && !model.showAddHost && !model.showRename, focusToken: model.focusToken, interactive: !preview, contrast: model.contrastCorrection, fontOptions: model.fontOptions, onFocus: { model.focus(block) }, onPeek: { model.setPeek($0, finished: $1) }, onCellSize: { cellSize = $0 }, copyOnSelection: model.copyOnSelection,
                            onCopy: { text in model.send(WireRequest(method: "block.event", block: block, label: "selection_copied", data: Data(text.utf8)), host: host) },
                            onLink: { url in model.send(WireRequest(method: "block.event", block: block, label: "url_clicked", data: Data(url.absoluteString.utf8)), host: host) })
                .id(block + (preview ? ".preview" : ".terminal"))
        }
        .background(model.theme.effectiveBackgroundOpacity == 1 ? model.theme.color : .clear)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(model.theme.text.opacity(model.focusedBlock == block && !preview ? 0.13 : 0.065), lineWidth: 0.5))
        .overlay {
            if !preview, let search = model.searches[block] {
                TerminalSearchOverlay(model: model, search: search, block: block, cell: cellSize,
                                      titleHeight: model.showPaneTitles ? 30 : 0)
            }
        }
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { paneSize = $0 }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers, location in
            guard !preview, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value, value != block else { return }
                Task { @MainActor in
                    guard model.states[host]?.blocks.contains(where: { $0.id == value }) == true else { return }
                    let horizontal = abs(location.x / max(1, paneSize.width) - 0.5) >= abs(location.y / max(1, paneSize.height) - 0.5)
                    model.move(value, to: block, axis: horizontal ? "horizontal" : "vertical")
                }
            }
            return true
        }
    }
    private func paneButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 9)).frame(width: 19, height: 20) }.buttonStyle(.plain).opacity(0.55).help(label).accessibilityLabel(label)
    }
}

struct TerminalSearch: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var search: TerminalSearchState
    let block: String
    var compact = false

    private var field: some View {
        NativeSearchField(text: $search.query, placeholder: "Find in terminal", size: 11,
                          onSubmit: { model.updateSearch(block, direction: 1) },
                          onEscape: { model.closeSearch(block) },
                          onMove: { model.updateSearch(block, direction: Int32($0)) },
                          autoFocus: model.searchFocusedBlock == block, focusToken: search.focusToken,
                          onFocus: { model.focusSearch(block) }).frame(minWidth: 24, maxWidth: .infinity).frame(height: 16)
            .onChange(of: search.query) { model.updateSearch(block) }
    }
    private var navigation: some View {
        Group {
            Text(search.result.count == 0 ? "0" : "\(search.result.selected)/\(search.result.count)").monospacedDigit().opacity(0.45).lineLimit(1)
            Button { model.updateSearch(block, direction: -1) } label: { Image(systemName: "chevron.up") }.help("Previous match").accessibilityLabel("Previous match")
            Button { model.updateSearch(block, direction: 1) } label: { Image(systemName: "chevron.down") }.help("Next match").accessibilityLabel("Next match")
        }
    }
    private var close: some View {
        Button { model.closeSearch(block) } label: { Image(systemName: "xmark") }.help("Close search").accessibilityLabel("Close search")
    }
    var body: some View {
        Group {
            if compact {
                VStack(spacing: 7) {
                    HStack(spacing: 8) { field;close }
                    HStack(spacing: 9) { navigation;Spacer(minLength: 0) }
                }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").opacity(0.5)
                    field;navigation;close
                }
            }
        }.font(.system(size: 11)).buttonStyle(.plain).padding(11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .onExitCommand { model.closeSearch(block) }
    }
}

struct TerminalSearchOverlay: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var search: TerminalSearchState
    let block: String
    let cell: CGSize
    let titleHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 280
            let size = CGSize(width: max(80, min(330, geometry.size.width - 24)), height: compact ? 61 : 38)
            let origin = SearchOverlayPlacement.origin(viewport: geometry.size, bar: size, cell: cell,
                                                       titleHeight: titleHeight, spans: search.spans)
            TerminalSearch(model: model, search: search, block: block, compact: compact)
                .frame(width: size.width, height: size.height)
                .offset(x: origin.x, y: origin.y)
        }
    }
}

struct WorkspaceOverview: View {
    @ObservedObject var model: WorkspaceModel
    let expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(expanded ? "Sessions" : model.currentTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.animateNavigation { model.peek = 0 } } label: { Image(systemName: "xmark.circle.fill").opacity(0.4) }.buttonStyle(.plain).accessibilityLabel("Close overview")
            }
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(model.hosts) { host in
                            ForEach(model.states[host.id]?.sessions ?? []) { session in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("\(session.name) · \(host.name)").font(.system(size: 11, weight: .medium)).opacity(0.5)
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 16)], spacing: 16) {
                                        ForEach(session.windows) { deck in card(deck, session: session.id, host: host.id) }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ScrollView(.horizontal) { HStack(spacing: 14) { ForEach(model.activeSession?.windows ?? []) { deck in card(deck, session: model.selectedSession, host: model.selectedHost).frame(width: 245) } } }.scrollIndicators(.hidden)
            }
        }
    }
    private func card(_ deck: Deck, session: String, host: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LayoutSurface(model: model, node: deck.root, deck: deck.id, host: host, preview: true).frame(height: expanded ? 165 : 112).allowsHitTesting(false)
            HStack(spacing: 7) { DeckIcon(count: deck.root.blocks.count, symbol: deck.root.blocks.first.map { model.processIcon($0, host: host) } ?? "terminal"); Text(model.deckTitle(deck, host: host)).font(.system(size: 11)).lineLimit(1) }
        }.padding(8).background(model.theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedDeck == deck.id ? model.theme.tint.opacity(0.6) : model.theme.border, lineWidth: 1))
            .contentShape(Rectangle()).onTapGesture { model.animateNavigation { model.choose(deck: deck.id, session: session, host: host) } }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) } }
    }
}

private struct WindowSetup: NSViewRepresentable {
    let model: WorkspaceModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = "illogical"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = model.theme.effectiveBackgroundOpacity == 1
            window.backgroundColor = window.isOpaque ? NSColor(hex: model.theme.background) : .clear
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.setFrameAutosaveName("illogical.workspace")
            context.coordinator.observe(window)
        }
    }
    @MainActor final class Coordinator {
        let model: WorkspaceModel
        var token: NSObjectProtocol?
        init(model: WorkspaceModel) { self.model = model }
        func observe(_ window: NSWindow) {
            guard token == nil else { return }
            model.onRequestActivation = { [weak window] in
                window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps: true)
            }
            token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model.close() } }
        }
        isolated deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
