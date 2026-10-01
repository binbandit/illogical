import SwiftUI

/// The floating pickers: the session picker (Command-K), dropped from the
/// session button, and the command palette (Shift-Command-P) with its
/// scopes for themes, interface styles, font sizes and directories.
struct PaletteOverlay: View {
    let model: WorkspaceModel
    let mode: PaletteMode
    @State private var query = ""
    @State private var selected = 0
    @State private var availableHeight: CGFloat = .infinity
    /// The theme in use when the theme scope opened; moving through the list
    /// previews themes live and leaving without choosing restores it.
    @State private var previewOrigin: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var preferences: Preferences { model.preferences }
    private var colors: ChromeColors { preferences.colors }
    private var isPicker: Bool { mode == .sessions }

    var body: some View {
        let entries = entries
        let items = entries.compactMap(\.item)
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { dismiss() }
            panel(entries: entries, items: items)
                .padding(.leading, isPicker ? pickerLeading : 0)
                .padding(.top, top)
                .frame(maxWidth: .infinity, alignment: isPicker ? .topLeading : .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
        .onAppear(perform: begin)
        .onChange(of: mode) { begin() }
        .onChange(of: query) { selected = query.isEmpty ? initialSelection : 0 }
        .onChange(of: selected) { previewTheme(items) }
    }

    // MARK: Layout

    private var top: CGFloat {
        guard isPicker else { return Chrome.Palette.topOffset }
        return preferences.verticalTabs ? Chrome.Titlebar.sidebarHeight : Chrome.Titlebar.height
    }

    /// The picker's rows line up under the session button's icon.
    private var pickerLeading: CGFloat {
        guard !preferences.verticalTabs else { return Chrome.Sidebar.rowInset }
        let iconLeading = model.window?.styleMask.contains(.fullScreen) == true ? Chrome.Titlebar.fullScreenLeading : Chrome.Titlebar.sessionLeading
        return iconLeading + Chrome.SessionPicker.iconOffset
    }

    private func panel(entries: [PaletteEntry], items: [PaletteItem]) -> some View {
        let metrics = PaletteMetrics(picker: isPicker)
        let fieldBlock = metrics.fieldInset + metrics.fieldHeight + Chrome.Palette.fieldToList
        let room = availableHeight - top - Chrome.Palette.windowMargin - fieldBlock - metrics.rowInset
        let maximum = max(metrics.rowPitch * 2, min(Chrome.Palette.maximumHeight - fieldBlock - metrics.rowInset, room))
        let content = entries.reduce(0) { $0 + metrics.height(of: $1) } + (entries.isEmpty ? metrics.rowPitch : 0)
        return VStack(spacing: 0) {
            field(metrics)
                .padding([.horizontal, .top], metrics.fieldInset)
                .padding(.bottom, Chrome.Palette.fieldToList)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry, items: items, metrics: metrics)
                        }
                        if entries.isEmpty {
                            Text(emptyText).font(Chrome.Palette.rowFont).foregroundStyle(colors.tertiary)
                                .frame(height: metrics.rowPitch)
                        }
                    }
                }
                .scrollIndicators(content > maximum ? .automatic : .never)
                .frame(height: min(content, maximum))
                .onChange(of: selected) { if items.indices.contains(selected) { reader.scrollTo(items[selected].id) } }
            }
            .padding(.bottom, metrics.rowInset)
        }
        .frame(width: isPicker ? Chrome.SessionPicker.width : Chrome.Palette.width)
        .chromePanel(colors, style: preferences.interfaceStyle,
                     radius: isPicker ? Chrome.SessionPicker.cornerRadius : Chrome.Palette.cornerRadius)
    }

    @ViewBuilder
    private func row(_ entry: PaletteEntry, items: [PaletteItem], metrics: PaletteMetrics) -> some View {
        switch entry {
        case .header(let title, let symbol):
            PaletteHeader(title: title, symbol: symbol, colors: colors, metrics: metrics)
        case .separator:
            Rectangle().fill(colors.panelSeparator)
                .frame(height: 1)
                .padding(.horizontal, Chrome.SessionPicker.separatorInset)
                .padding(.vertical, Chrome.SessionPicker.separatorSpacing)
        case .item(let item):
            let index = items.firstIndex { $0.id == item.id } ?? -1
            PaletteRow(item: item, highlighted: index == selected, colors: colors, metrics: metrics)
                .onTapGesture { selected = index;activate(items) }
                .contextMenu {
                    if let rename = item.rename { Button("Rename Session…", action: rename) }
                    if let close = item.close { Button("Close Session…", action: close) }
                }
                .id(item.id)
        }
    }

    private func field(_ metrics: PaletteMetrics) -> some View {
        HStack(spacing: 0) {
            if let chip {
                Text(chip)
                    .font(Chrome.Palette.chipFont)
                    .padding(.horizontal, Chrome.Palette.chipPadding)
                    .frame(height: Chrome.Palette.chipHeight)
                    .background(colors.chipFill, in: RoundedRectangle(cornerRadius: Chrome.Palette.chipRadius, style: .continuous))
                    .padding(.leading, Chrome.Palette.chipInset)
                    .padding(.trailing, Chrome.Palette.chipPlaceholderSpacing)
            } else {
                Image(systemName: isPicker ? Chrome.SessionPicker.fieldSymbol : "magnifyingglass")
                    .font(Chrome.font(Chrome.Palette.fieldSymbolSize))
                    .foregroundStyle(colors.tertiary)
                    .padding(.leading, metrics.fieldSymbolLeading)
                    .frame(width: metrics.fieldTextLeading, alignment: .leading)
            }
            NativeSearchField(text: $query, placeholder: placeholder,
                              onSubmit: { _ in activate(entries.compactMap(\.item)) },
                              onEscape: { dismiss() },
                              onMove: { move($0) },
                              onDeleteCommand: isPicker ? { closeHighlightedSession() } : nil,
                              onCommandDigit: isPicker ? { chooseSession(number: $0) } : nil)
            if !query.isEmpty && !isPicker {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(Chrome.font(Chrome.Palette.clearSymbolSize))
                }
                .buttonStyle(.plain)
                .foregroundStyle(colors.tertiary)
                .padding(.trailing, (metrics.fieldHeight - Chrome.Palette.clearSymbolSize) / 2)
                .accessibilityLabel("Clear")
            }
        }
        .frame(height: metrics.fieldHeight)
        .background {
            if isPicker {
                Capsule().fill(colors.sunkenField).overlay(Capsule().inset(by: 0.5).stroke(colors.panelSeparator, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: Chrome.Palette.fieldRadius, style: .continuous).fill(colors.panelField)
            }
        }
    }

    private var chip: String? {
        switch mode {
        case .themes: "Theme"
        case .interfaceStyle: "Interface Style"
        case .fontSize: "Font Size"
        case .sessions, .commands, .directory: nil
        }
    }

    private var placeholder: String {
        switch mode {
        case .sessions: "Filter or create…"
        case .commands: "Search commands…"
        case .themes: "Select Theme…"
        case .interfaceStyle: "Select Interface Style…"
        case .fontSize: "Select Font Size…"
        case .directory: model.directoryPath.isEmpty ? "Go to Directory…" : (model.directoryPath as NSString).abbreviatingWithTildeInPath
        }
    }

    private var emptyText: String {
        guard mode == .directory else { return "No results" }
        return model.directoryLoading ? "Loading…" : model.directoryError ?? "No results"
    }

    // MARK: Behaviour

    private func begin() {
        query = ""
        previewOrigin = mode == .themes ? preferences.themeName : nil
        selected = initialSelection
    }

    /// The session picker and the scopes start on the current value.
    private var initialSelection: Int {
        let items = entries.compactMap(\.item)
        switch mode {
        case .sessions:
            guard let shown = model.shownSession else { return 0 }
            return items.firstIndex { $0.id == Self.sessionID(shown) } ?? 0
        case .themes, .interfaceStyle, .fontSize:
            return items.firstIndex { $0.isCurrent } ?? 0
        case .commands, .directory:
            return 0
        }
    }

    private func move(_ delta: Int) {
        let count = entries.compactMap(\.item).count
        selected = max(0, min(max(0, count - 1), selected + delta))
    }

    private func activate(_ items: [PaletteItem]) {
        guard items.indices.contains(selected) else { return }
        if mode == .themes { previewOrigin = nil }
        items[selected].action()
    }

    private func dismiss() {
        if let previewOrigin { preferences.themeName = previewOrigin }
        previewOrigin = nil
        model.dismissPalette()
    }

    private func previewTheme(_ items: [PaletteItem]) {
        guard mode == .themes, previewOrigin != nil, items.indices.contains(selected) else { return }
        preferences.themeName = items[selected].id
    }

    /// Command-Delete closes the highlighted session, after confirmation.
    private func closeHighlightedSession() -> Bool {
        let items = entries.compactMap(\.item)
        guard items.indices.contains(selected), let close = items[selected].close else { return false }
        close()
        return true
    }

    /// Command-1 to 9 choose the picker's sessions in order.
    private func chooseSession(number: Int) -> Bool {
        let sessions = entries.compactMap(\.item).filter { $0.close != nil }
        guard sessions.indices.contains(number - 1) else { return false }
        sessions[number - 1].action()
        return true
    }

    // MARK: Entries

    private var entries: [PaletteEntry] {
        switch mode {
        case .sessions: sessionEntries
        case .commands: commandEntries
        case .themes: themeEntries
        case .interfaceStyle: choiceEntries(InterfaceStyle.allCases.map(\.rawValue), current: preferences.interfaceStyle.rawValue) {
            if let style = InterfaceStyle(rawValue: $0) { preferences.interfaceStyle = style }
        }
        case .fontSize: choiceEntries(Self.fontSizes.map { "\($0) pt" }, current: "\(Int(preferences.fontSize)) pt") {
            if let size = Double($0.dropLast(3)) { preferences.fontSize = size }
        }
        case .directory: directoryEntries
        }
    }

    private static let fontSizes = Array(9...24)

    private static func sessionID(_ key: SessionKey) -> String { "\(key.host):\(key.session)" }

    /// Items matching the query, best matches first, with their matched
    /// characters marked.
    private func filtered(_ items: [PaletteItem]) -> [PaletteItem] {
        guard !query.isEmpty else { return items }
        return items.enumerated().compactMap { offset, item -> (PaletteItem, Int, Int)? in
            guard let match = FuzzyMatch(query: query, text: item.title) else { return nil }
            var item = item
            item.matches = match.offsets
            return (item, match.rank, offset)
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .map(\.0)
    }

    private var sessionEntries: [PaletteEntry] {
        var entries: [PaletteEntry] = []
        var number = 0
        for host in model.hosts {
            let sessions = model.pickerSessions.filter { $0.key.host == host.id }
            let rows = filtered(sessions.map { entry in
                PaletteItem(id: Self.sessionID(entry.key), title: entry.session.name,
                            leading: entry.key == model.shownSession ? .checkmark : .blank,
                            elsewhere: model.otherWindow(showing: entry.key) != nil,
                            rename: { model.beginRenameSession(entry.key.session, host: entry.key.host) },
                            close: { model.closeSession(entry.key.session, host: entry.key.host) }) {
                    model.choose(session: entry.key.session, host: entry.key.host)
                }
            })
            guard !rows.isEmpty else { continue }
            entries.append(.header(host.name, symbol: host.isLocal ? Chrome.SessionButton.localSymbol : Chrome.SessionButton.remoteSymbol))
            for var row in rows {
                number += 1
                if number <= 9 { row.trailing = .shortcut("⌘\(number)") }
                entries.append(.item(row))
            }
        }
        let create = query.isEmpty || entries.contains { $0.item?.title.localizedCaseInsensitiveCompare(query) == .orderedSame }
            ? PaletteItem(id: "new", title: "New Session", leading: .symbol("rectangle.stack.badge.plus"),
                          trailing: WorkspaceCommand.newSession.shortcut.map { .shortcut($0.displayText) } ?? .none) { model.newSession() }
            : PaletteItem(id: "new", title: "Create “\(query)”", leading: .symbol("rectangle.stack.badge.plus")) { [query] in
                model.newSession(name: query)
            }
        entries += [.separator("new"), .item(create), .separator("host"),
                    .item(PaletteItem(id: "host", title: "Add Remote Host…", leading: .symbol(Chrome.SessionButton.remoteSymbol)) {
                        model.palette = nil
                        model.showAddHost = true
                    })]
        return entries
    }

    private var commandEntries: [PaletteEntry] {
        let context = CommandContext(model: model, openWindow: openWindow, openSettings: openSettings)
        let searchOpen = model.hasOpenSearch
        let lead: [WorkspaceCommand] = [.switchSession, .renameSession, .renameTab, .addRemoteHost, .newSession, .newTab,
                                        .goToDirectory, .newWindow, .closeTab, .closeSession, .closeWindow]
        let commands = (lead + WorkspaceCommand.allCases.filter { !lead.contains($0) }).filter(\.showsInPalette)
        let ordered = commands.filter { $0.paletteSection == nil }
            + commands.filter { $0.paletteSection == .pane } + commands.filter { $0.paletteSection == .appearance }
        let items = filtered(ordered.map { command in
            PaletteItem(id: command.id, title: command.paletteTitle(preferences), leading: .none,
                        trailing: trailing(for: command, searchOpen: searchOpen), section: command.paletteSection) {
                model.palette = nil
                command.perform(context)
                if !model.hasOverlay { model.requestTerminalFocus() }
            }
        })
        // Section headers only while browsing; a query lists best matches first.
        guard query.isEmpty else { return items.map(PaletteEntry.item) }
        var entries: [PaletteEntry] = []
        var section: PaletteSection?
        for item in items {
            if let next = item.section, next != section { entries.append(.header(next.rawValue, symbol: next.symbol)) }
            section = item.section
            entries.append(.item(item))
        }
        return entries
    }

    private func trailing(for command: WorkspaceCommand, searchOpen: Bool) -> PaletteItem.Trailing {
        if command.isChecked(preferences) { return .checkmark }
        let value = command.paletteValue(model)
        if command.opensScope { return .value(value ?? "", chevron: true) }
        if let value { return .value(value, chevron: false) }
        return command.shortcut(searchOpen: searchOpen).map { .shortcut($0.displayText) } ?? .none
    }

    /// Only the themes of the current appearance, the current one checked.
    private var themeEntries: [PaletteEntry] {
        let current = previewOrigin ?? preferences.themeName
        let isLight = preferences.themes.first { $0.name == current }?.isLight ?? preferences.theme.isLight
        return filtered(preferences.themes.filter { $0.isLight == isLight }.map { theme in
            PaletteItem(id: theme.name, title: theme.name, trailing: theme.name == current ? .checkmark : .none, isCurrent: theme.name == current) {
                preferences.selectTheme(theme.name)
                model.dismissPalette()
            }
        }).map(PaletteEntry.item)
    }

    private func choiceEntries(_ choices: [String], current: String, choose: @escaping (String) -> Void) -> [PaletteEntry] {
        filtered(choices.map { choice in
            PaletteItem(id: choice, title: choice, trailing: choice == current ? .checkmark : .none, isCurrent: choice == current) {
                choose(choice)
                model.dismissPalette()
            }
        }).map(PaletteEntry.item)
    }

    /// "Go to": the current directory, its parent and its subdirectories.
    private var directoryEntries: [PaletteEntry] {
        guard model.canOpenDirectory else { return [] }
        let path = model.directoryPath
        var items = [PaletteItem(id: "open", title: (path as NSString).abbreviatingWithTildeInPath, leading: .symbol("folder")) {
            model.openDirectory()
        }]
        if path != "/" {
            items.append(PaletteItem(id: "parent", title: "..", leading: .symbol("folder")) { [path] in
                query = ""
                model.loadDirectory((path as NSString).deletingLastPathComponent)
            })
        }
        items += model.directories.filter { $0.name != ".." }.map { entry in
            PaletteItem(id: entry.id, title: entry.name, leading: .symbol("folder")) { query = "";model.loadDirectory(entry.path) }
        }
        let shown = query.isEmpty ? items : [items[0]] + filtered(Array(items.dropFirst()))
        return [.header("Go to", symbol: "folder")] + shown.map(PaletteEntry.item)
    }
}

/// Field and row geometry for the command palette or the session picker.
private struct PaletteMetrics {
    let picker: Bool

    var fieldInset: CGFloat { picker ? Chrome.SessionPicker.fieldInset : Chrome.Palette.fieldInset }
    var fieldHeight: CGFloat { picker ? Chrome.SessionPicker.fieldHeight : Chrome.Palette.fieldHeight }
    var fieldSymbolLeading: CGFloat { picker ? Chrome.SessionPicker.iconCentre - fieldInset - Chrome.Palette.fieldSymbolSize / 2 : Chrome.Palette.fieldSymbolLeading }
    var fieldTextLeading: CGFloat { picker ? Chrome.SessionPicker.fieldTextLeading - fieldInset : Chrome.Palette.fieldTextLeading }
    var rowPitch: CGFloat { picker ? Chrome.SessionPicker.rowPitch : Chrome.Palette.rowPitch }
    var rowHighlight: CGFloat { picker ? Chrome.SessionPicker.rowHighlight : Chrome.Palette.rowHighlight }
    var rowRadius: CGFloat { picker ? Chrome.SessionPicker.rowRadius : Chrome.Palette.rowRadius }
    var rowInset: CGFloat { Chrome.Palette.rowInset }
    /// The picker draws checkmarks and icons in a column before every title.
    var iconColumn: CGFloat? { picker ? 2 * (Chrome.SessionPicker.iconCentre - rowInset) : nil }
    var textLeading: CGFloat { picker ? Chrome.SessionPicker.textLeading - rowInset : Chrome.Palette.rowTextLeading }

    func height(of entry: PaletteEntry) -> CGFloat {
        if case .separator = entry { return 1 + 2 * Chrome.SessionPicker.separatorSpacing }
        return rowPitch
    }
}

private enum PaletteEntry: Identifiable {
    case header(String, symbol: String)
    case separator(String)
    case item(PaletteItem)

    var id: String {
        switch self {
        case .header(let title, _): "header:" + title
        case .separator(let id): "separator:" + id
        case .item(let item): item.id
        }
    }

    var item: PaletteItem? {
        if case .item(let item) = self { return item }
        return nil
    }
}

private struct PaletteItem: Identifiable {
    enum Leading { case none, blank, checkmark, symbol(String) }
    enum Trailing { case none, shortcut(String), value(String, chevron: Bool), checkmark }

    let id: String
    let title: String
    var leading = Leading.none
    var trailing = Trailing.none
    var section: PaletteSection?
    var isCurrent = false
    /// Shown in another window; choosing it brings that window forward.
    var elsewhere = false
    /// A session row's context menu actions; Command-Delete also closes.
    var rename: (() -> Void)?
    var close: (() -> Void)?
    /// Character offsets of the title that match the query.
    var matches: [Int] = []
    let action: () -> Void
}

private struct PaletteHeader: View {
    let title: String
    let symbol: String
    let colors: ChromeColors
    let metrics: PaletteMetrics

    var body: some View {
        HStack(spacing: 0) {
            if let column = metrics.iconColumn {
                Image(systemName: symbol).font(Chrome.Palette.sectionFont)
                    .frame(width: column)
                    .padding(.trailing, metrics.textLeading - column)
            } else {
                Image(systemName: symbol).font(Chrome.Palette.sectionFont)
                    .frame(width: Chrome.Palette.rowIconAdvance, alignment: .leading)
                    .padding(.leading, metrics.textLeading)
            }
            Text(title).font(Chrome.Palette.sectionFont).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(colors.tertiary)
        .padding(.trailing, Chrome.Palette.rowTrailing)
        .padding(.horizontal, metrics.rowInset)
        .frame(height: metrics.rowPitch)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool
    let colors: ChromeColors
    let metrics: PaletteMetrics

    var body: some View {
        HStack(spacing: 0) {
            leading
            Text(title).font(Chrome.Palette.rowFont).lineLimit(1).truncationMode(.tail)
            if item.elsewhere {
                Image(systemName: "macwindow").font(Chrome.Palette.sectionFont).opacity(0.6).padding(.leading, 5).help("Open in another window")
            }
            Spacer(minLength: Chrome.Palette.valueChevronSpacing)
            trailing
        }
        .foregroundStyle(highlighted ? Color.white : colors.primary)
        .padding(.trailing, Chrome.Palette.rowTrailing)
        .frame(height: metrics.rowHighlight)
        .background(highlighted ? colors.accentFill : .clear, in: RoundedRectangle(cornerRadius: metrics.rowRadius, style: .continuous))
        .padding(.horizontal, metrics.rowInset)
        .frame(height: metrics.rowPitch)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    /// The title with its matched characters in the accent colour.
    private var title: AttributedString {
        var text = AttributedString(item.title)
        guard !highlighted else { return text }
        let characters = Array(text.characters.indices)
        for offset in item.matches where characters.indices.contains(offset) {
            let start = characters[offset]
            text[start..<text.characters.index(after: start)].foregroundColor = colors.accentText
        }
        return text
    }

    private var detail: Color { highlighted ? .white.opacity(Chrome.Palette.selectedDetailOpacity) : colors.secondary }

    @ViewBuilder private var leading: some View {
        if let column = metrics.iconColumn {
            Group {
                switch item.leading {
                case .checkmark: Image(systemName: "checkmark").font(Chrome.Palette.sectionFont)
                case .symbol(let name): Image(systemName: name).font(Chrome.font(Chrome.Palette.rowIconSize - 2))
                case .none, .blank: Color.clear
                }
            }
            .frame(width: column)
            .padding(.trailing, metrics.textLeading - column)
        } else if case .symbol(let name) = item.leading {
            Image(systemName: name)
                .font(Chrome.font(Chrome.Palette.rowIconSize))
                .foregroundStyle(highlighted ? Color.white : colors.tertiary)
                .frame(width: Chrome.Palette.rowIconAdvance, alignment: .leading)
                .padding(.leading, metrics.textLeading)
        } else {
            Color.clear.frame(width: metrics.textLeading)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.trailing {
        case .none: EmptyView()
        case .shortcut(let text):
            Text(text).font(Chrome.Palette.rowFont).foregroundStyle(detail)
        case .value(let text, let chevron):
            HStack(spacing: Chrome.Palette.valueChevronSpacing) {
                Text(text).font(Chrome.Palette.rowFont).foregroundStyle(detail).lineLimit(1).truncationMode(.head)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(Chrome.font(Chrome.Palette.chevronSize, .semibold))
                        .foregroundStyle(highlighted ? detail : colors.tertiary)
                }
            }
        case .checkmark:
            Image(systemName: "checkmark").font(Chrome.Palette.rowFont).foregroundStyle(highlighted ? Color.white : colors.tertiary)
        }
    }
}

/// Where a query's characters occur in a title, in order and ignoring case:
/// a contiguous run when there is one, otherwise the earliest subsequence.
/// Ranks prefixes, then word starts, then other runs, then scattered matches.
struct FuzzyMatch {
    let offsets: [Int]
    let rank: Int

    init?(query: String, text: String) {
        let needle = Array(query.lowercased())
        let haystack = text.map { Character($0.lowercased()) }
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let lastStart = haystack.count - needle.count
        if let start = (0...lastStart).first(where: { Array(haystack[$0..<$0 + needle.count]) == needle }) {
            offsets = Array(start..<start + needle.count)
            let wordStart = start == 0 || !(haystack[start - 1].isLetter || haystack[start - 1].isNumber)
            rank = start == 0 ? 0 : wordStart ? 1 : 2
            return
        }
        var found: [Int] = []
        var position = 0
        for character in needle {
            guard let index = haystack[position...].firstIndex(of: character) else { return nil }
            found.append(index)
            position = index + 1
        }
        offsets = found
        rank = 3
    }
}
