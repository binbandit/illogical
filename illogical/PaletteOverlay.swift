import SwiftUI

/// The floating picker: sessions (Command-K), commands (Shift-Command-P),
/// themes and the directory picker.
struct PaletteOverlay: View {
    let model: WorkspaceModel
    let mode: PaletteMode
    @State private var query = ""
    @State private var selected = 0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var theme: TerminalTheme { model.preferences.theme }
    private var items: [PaletteItem] {
        let all: [PaletteItem] = switch mode {
        case .sessions: sessionItems
        case .commands: commandItems
        case .themes: themeItems
        case .directory: directoryItems
        }
        let filtered = query.isEmpty ? all : all.filter { $0.matches(query) }
        guard mode == .sessions else { return filtered }
        let create = PaletteItem(id: "new", title: query.isEmpty ? "New Session" : "Create “\(query)”", icon: .symbol("plus"),
                                 detail: query.isEmpty ? WorkspaceCommand.newSession.shortcut?.displayText ?? "" : "") { [query] in
            model.newSession(name: query)
        }
        return filtered + [create]
    }

    var body: some View {
        ZStack(alignment: mode == .sessions ? .topLeading : .top) {
            Color.clear.contentShape(Rectangle()).onTapGesture { model.dismissPalette() }
            panel
                .padding(.top, mode == .sessions ? Chrome.Palette.sessionsOffset.height : Chrome.Palette.topOffset)
                .padding(.leading, mode == .sessions ? Chrome.Palette.sessionsOffset.width : 0)
        }
        .onAppear { selected = initialSelection }
        .onChange(of: query) { selected = query.isEmpty ? initialSelection : 0 }
        .onChange(of: mode) { query = "";selected = initialSelection }
    }

    /// The session picker highlights the previous session, so Command-K then
    /// Return flips between two projects.
    private var initialSelection: Int {
        guard mode == .sessions, let first = model.pickerSessions.first, first.key == model.shownSession,
              model.pickerSessions.count > 1 else { return 0 }
        return 1
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchRow
            Divider().opacity(0.5)
            if mode == .directory { directoryHeader }
            results
        }
        .frame(width: mode == .sessions ? Chrome.Palette.sessionsWidth : Chrome.Palette.width)
        .background { RoundedRectangle(cornerRadius: Chrome.Palette.cornerRadius).fill(.regularMaterial) }
        .overlay { RoundedRectangle(cornerRadius: Chrome.Palette.cornerRadius).stroke(theme.text.opacity(0.22), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.28), radius: Chrome.Palette.shadowRadius, y: 8)
    }

    private var searchRow: some View {
        let onDelete: (() -> Bool)? = mode == .sessions ? { closeHighlightedSession() } : nil
        return HStack(spacing: 12) {
            Image(systemName: mode == .directory ? "folder" : "magnifyingglass").opacity(0.4)
            NativeSearchField(text: $query, placeholder: placeholder,
                              onSubmit: { _ in activate() },
                              onEscape: { model.dismissPalette() },
                              onMove: { move($0) },
                              onDeleteCommand: onDelete)
                .frame(height: 20)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.4) }.buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private var directoryHeader: some View {
        HStack {
            Text(model.directoryPath).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.directoryLoading { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 10, design: .monospaced))
        .opacity(0.5)
        .padding(12)
    }

    private var results: some View {
        let items = items
        let maximum = mode == .directory ? Chrome.Palette.directoryMaximumHeight : Chrome.Palette.maximumHeight
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: Chrome.Palette.rowSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, highlighted: index == selected, theme: theme, showsDetail: mode != .sessions || model.hosts.count > 1)
                            .onTapGesture { selected = index;activate() }
                            .id(index)
                    }
                    if items.isEmpty {
                        Text(emptyText).font(.system(size: Chrome.Palette.titleSize)).opacity(0.45).padding(24)
                    }
                }
                .padding(7)
            }
            .frame(height: items.isEmpty ? 78 : min(CGFloat(items.count) * (Chrome.Palette.rowHeight + Chrome.Palette.rowSpacing) + 14, maximum))
            .onChange(of: selected) { reader.scrollTo(selected) }
        }
    }

    private var placeholder: String {
        switch mode {
        case .sessions: "Switch session or create…"
        case .commands: "Search commands…"
        case .themes: "Select theme…"
        case .directory: "Go to directory…"
        }
    }

    private var emptyText: String {
        guard mode == .directory else { return "No results" }
        return model.directoryLoading ? "Loading directory…" : model.directoryError ?? "No results"
    }

    private func move(_ delta: Int) {
        selected = max(0, min(max(0, items.count - 1), selected + delta))
    }

    private func activate() {
        let items = items
        guard items.indices.contains(selected) else { return }
        items[selected].action()
    }

    /// Command-Delete closes the highlighted session, after confirmation.
    private func closeHighlightedSession() -> Bool {
        let items = items
        guard items.indices.contains(selected), let close = items[selected].close else { return false }
        close()
        return true
    }

    // MARK: Items

    private var sessionItems: [PaletteItem] {
        model.pickerSessions.map { entry in
            let elsewhere = model.otherWindow(showing: entry.key) != nil
            return PaletteItem(id: "\(entry.key.host):\(entry.key.session)", title: entry.session.name, icon: .symbol("square.stack.3d.up"),
                               detail: "\(entry.host.name) · \(entry.session.windows.count) tabs",
                               current: entry.key == model.shownSession, elsewhere: elsewhere,
                               rename: { model.beginRenameSession(entry.key.session, host: entry.key.host) },
                               close: { model.closeSession(entry.key.session, host: entry.key.host) }) {
                model.choose(session: entry.key.session, host: entry.key.host)
            }
        }
    }

    private var commandItems: [PaletteItem] {
        let context = CommandContext(model: model, openWindow: openWindow, openSettings: openSettings)
        let searchOpen = model.hasOpenSearch
        return WorkspaceCommand.allCases.filter(\.showsInPalette).map { command in
            PaletteItem(id: command.id, title: command.paletteTitle(model.preferences), icon: .symbol(command.symbol),
                        detail: command.shortcut(searchOpen: searchOpen)?.displayText ?? "") {
                model.palette = nil
                command.perform(context)
                if !model.hasOverlay { model.requestTerminalFocus() }
            }
        }
    }

    private var themeItems: [PaletteItem] {
        model.preferences.themes.map { theme in
            PaletteItem(id: theme.id, title: theme.name, icon: .swatch(theme), detail: theme.isLight ? "Light" : "Dark",
                        current: model.preferences.themeName == theme.name) {
                model.preferences.selectTheme(theme.name)
                model.dismissPalette()
            }
        }
    }

    private var directoryItems: [PaletteItem] {
        guard model.canOpenDirectory else { return [] }
        let parent = (model.directoryPath as NSString).deletingLastPathComponent
        let fixed = [
            PaletteItem(id: "open", title: "Open terminal here", icon: .symbol("plus.rectangle"), detail: model.directoryPath) { model.openDirectory() },
            PaletteItem(id: "parent", title: "..", icon: .symbol("arrow.turn.up.left"), detail: "Parent directory") { query = "";model.loadDirectory(parent) },
        ]
        return fixed + model.directories.filter { $0.name != ".." }.map { entry in
            PaletteItem(id: entry.id, title: entry.name, icon: .symbol("folder")) { query = "";model.loadDirectory(entry.path) }
        }
    }
}

private struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String)
        case swatch(TerminalTheme)
    }

    let id: String
    let title: String
    let icon: Icon
    var detail = ""
    var current = false
    /// Shown in another window; choosing it brings that window forward.
    var elsewhere = false
    var rename: (() -> Void)?
    var close: (() -> Void)?
    let action: () -> Void

    func matches(_ query: String) -> Bool { "\(title) \(detail)".localizedCaseInsensitiveContains(query) }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool
    let theme: TerminalTheme
    let showsDetail: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
            Text(item.title).font(.system(size: Chrome.Palette.titleSize)).lineLimit(1)
            if item.elsewhere {
                Image(systemName: "macwindow").font(.system(size: Chrome.Palette.detailSize)).opacity(0.6).help("Open in another window")
            }
            Spacer()
            if showsDetail { Text(item.detail).font(.system(size: Chrome.Palette.detailSize)).opacity(0.45).lineLimit(1) }
            if item.current { Image(systemName: "checkmark").font(.system(size: Chrome.Palette.detailSize)) }
            if let rename = item.rename {
                Button(action: rename) { Image(systemName: "pencil").font(.system(size: 11)).opacity(0.7).frame(width: 22) }
                    .buttonStyle(.plain)
                    .help("Rename Session…")
                    .accessibilityLabel("Rename \(item.title)")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Chrome.Palette.rowHeight)
        .foregroundStyle(highlighted ? Color.white : theme.text)
        .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: Chrome.Palette.rowRadius))
        .contentShape(Rectangle())
        .contextMenu { if let rename = item.rename { Button("Rename Session…", action: rename) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .symbol(let name):
            Image(systemName: name).frame(width: 25).opacity(0.6)
        case .swatch(let theme):
            RoundedRectangle(cornerRadius: 5)
                .fill(theme.color)
                .frame(width: 25, height: 25)
                .overlay(Text("Aa").font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.text))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.15), lineWidth: 0.5))
        }
    }
}
