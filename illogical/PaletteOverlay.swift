import SwiftUI

struct PaletteOverlay: View {
    @ObservedObject var model: WorkspaceModel
    let mode: PaletteMode
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        var detail = ""
        var icon = "terminal"
        var theme: TerminalTheme?
        var rename: (() -> Void)?
        let action: () -> Void
    }

    private var items: [Item] {
        let all: [Item]
        switch mode {
        case .sessions:
            all = model.hosts.flatMap { host in
                (model.states[host.id]?.sessions ?? []).map { session in
                    Item(id: "\(host.id):\(session.id)", title: session.name, detail: "\(host.name) · \(session.windows.count) tabs", icon: "square.stack.3d.up", rename: { model.rename(session: session.id, host: host.id) }, action: { model.choose(session: session.id, host: host.id) })
                }
            }
        case .themes:
            all = model.themes.map { theme in Item(id: theme.id, title: theme.name, detail: theme.isLight ? "Light" : "Dark", icon: "paintpalette", theme: theme, action: { model.selectTheme(theme.name); model.palette = nil }) }
        case .directory:
            let parent = (model.directoryPath as NSString).deletingLastPathComponent
            all = [Item(id: "open", title: "Open terminal here", detail: model.directoryPath, icon: "plus.rectangle", action: { model.newTab(cwd: model.directoryPath); model.palette = nil }), Item(id: "parent", title: "..", detail: "Parent directory", icon: "arrow.turn.up.left", action: { query = ""; model.loadDirectory(parent) })] + model.directories.filter { $0.name != ".." }.map { entry in
                Item(id: entry.id, title: entry.name, icon: "folder", action: { query = ""; model.loadDirectory(entry.path) })
            }
        case .commands:
            all = [
                Item(id: "session", title: "New Session", detail: "⌘N", icon: "square.stack.3d.up.badge.fill", action: { model.newSession() }),
                Item(id: "tab", title: "New Tab", detail: "⌘T", icon: "plus", action: { model.newTab() }),
                Item(id: "right", title: "Split Right", detail: "⌘D", icon: "rectangle.split.2x1", action: { model.split("horizontal") }),
                Item(id: "down", title: "Split Down", detail: "⇧⌘D", icon: "rectangle.split.1x2", action: { model.split("vertical") }),
                Item(id: "zoom", title: "Zoom Pane", detail: "⇧⌘↩", icon: "arrow.up.left.and.arrow.down.right", action: { model.zoom() }),
                Item(id: "switch", title: "Switch Session", detail: "⌘K", icon: "square.stack.3d.up", action: { model.palette = .sessions }),
                Item(id: "overview", title: "Session Overview", detail: "⇧⌘O", icon: "square.grid.2x2", action: { model.peek = 2 }),
                Item(id: "directory", title: "Open from Directory", detail: "⇧⌘G", icon: "folder", action: { model.showDirectory() }),
                Item(id: "find", title: "Find in Terminal", detail: "⌘F", icon: "magnifyingglass", action: { model.find() }),
                Item(id: "theme", title: "Choose Theme", icon: "paintpalette", action: { model.palette = .themes }),
                Item(id: "orientation", title: model.verticalTabs ? "Use Horizontal Tabs" : "Use Vertical Tabs", icon: "sidebar.left", action: { model.verticalTabs.toggle() }),
                Item(id: "density", title: model.density == .comfortable ? "Use Compact Panes" : "Use Comfortable Panes", icon: "rectangle.compress.vertical", action: { model.density = model.density == .comfortable ? .compact : .comfortable }),
                Item(id: "rename", title: "Rename Session", icon: "pencil", action: { model.rename("session") }),
                Item(id: "remote", title: "Add Remote Host", icon: "network", action: { model.showAddHost = true }),
                Item(id: "import", title: "Import Ghostty Themes", icon: "square.and.arrow.down", action: { model.importGhostty() }),
                Item(id: "settings", title: "Appearance", detail: "⌘,", icon: "slider.horizontal.3", action: { model.showSettings = true })
            ]
        }
        var filtered = query.isEmpty ? all : all.filter { ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
        if mode == .sessions {
            filtered.append(Item(id: "new", title: query.isEmpty ? "New session…" : "Create “\(query)”", icon: "plus", action: { model.newSession(name: query) }))
        }
        return filtered
    }

    private var placeholder: String {
        switch mode { case .sessions: "Filter or create…"; case .commands: "Search commands…"; case .themes: "Select Theme…"; case .directory: "Go to directory…" }
    }

    var body: some View {
        ZStack(alignment: mode == .sessions ? .topLeading : .top) {
            Color.clear.contentShape(Rectangle()).onTapGesture { dismiss() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: mode == .directory ? "folder" : "magnifyingglass").opacity(0.4)
                    NativeSearchField(text: $query, placeholder: placeholder, onSubmit: { activate() }, onEscape: { dismiss() }, onMove: { delta in selected = max(0, min(max(0, items.count - 1), selected + delta)) }).frame(height: 20)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.4) }.buttonStyle(.plain) }
                }.padding(12)
                Divider().opacity(0.5)
                if mode == .directory {
                    HStack { Text(model.directoryPath).lineLimit(1).truncationMode(.middle); Spacer(); if model.directoryLoading { ProgressView().controlSize(.mini) } }.font(.system(size: 10, design: .monospaced)).opacity(0.5).padding(12)
                }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 0) {
                                    Button { selected = index; activate() } label: {
                                        HStack(spacing: 12) {
                                            if let theme = item.theme {
                                                RoundedRectangle(cornerRadius: 5).fill(theme.color).frame(width: 25, height: 25)
                                                    .overlay(Text("Aa").font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.text))
                                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.15), lineWidth: 0.5))
                                            } else { Image(systemName: item.icon).frame(width: 25).opacity(0.6) }
                                            Text(item.title).font(.system(size: 12)).lineLimit(1)
                                            Spacer()
                                            if mode != .sessions || model.hosts.count > 1 { Text(item.detail).font(.system(size: 10)).opacity(0.4).lineLimit(1) }
                                            if mode == .themes && model.themeName == item.title { Image(systemName: "checkmark").font(.system(size: 10)) }
                                        }.padding(.horizontal, 9).frame(height: 29).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if let rename = item.rename {
                                        Button(action: rename) {
                                            Image(systemName: "pencil").font(.system(size: 11)).opacity(0.7)
                                                .frame(width: 28, height: 29).contentShape(Rectangle())
                                        }.buttonStyle(.plain).help("Rename Session…").accessibilityLabel("Rename \(item.title)")
                                    }
                                }.foregroundStyle(selected == index ? Color.white : model.theme.text)
                                    .background(selected == index ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    .contextMenu { if let rename = item.rename { Button("Rename Session…", action: rename) } }.id(index)
                            }
                            if items.isEmpty { Text("No results").font(.system(size: 12)).opacity(0.45).padding(24) }
                        }.padding(7)
                    }.frame(height: min(CGFloat(items.count * 32 + 14), mode == .directory ? 440 : 380))
                        .onChange(of: selected) { reader.scrollTo(selected) }
                }
            }.frame(width: mode == .sessions ? 280 : 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(model.theme.text.opacity(0.22), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 20, y: 8).padding(.top, mode == .sessions ? 43 : 76).padding(.leading, mode == .sessions ? 86 : 0)
        }
        .onAppear { focused = true }.onChange(of: query) { selected = 0 }.onChange(of: mode) { query = ""; selected = 0; focused = true }
        .onExitCommand { dismiss() }
        .onKeyPress(.downArrow) { selected = min(max(0, items.count - 1), selected + 1); return .handled }
        .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
    }

    private func dismiss() { model.palette = nil; model.focusToken = UUID() }
    private func activate() {
        let values = items
        guard values.indices.contains(selected) else { return }
        let item = values[selected]
        if mode != .directory { model.palette = nil }
        item.action()
        if model.palette == nil { model.focusToken = UUID() }
    }
}
