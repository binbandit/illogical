import SwiftUI

/// Vertical tabs: the window's left column, holding the traffic lights, every
/// session on every host as a filterable list, and the new-session and
/// add-host buttons. Sessions shown in another window carry a window glyph;
/// choosing them brings that window forward.
struct WorkspaceSidebar: View {
    let model: WorkspaceModel
    let isFullScreen: Bool

    private var selectionID: String { rowID(host: model.selectedHost, deck: model.selectedDeck) }

    var body: some View {
        VStack(spacing: 0) {
            SidebarTopRow(model: model)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.hosts) { host in
                            HostSection(model: model, host: host)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: selectionID) { reader.scrollTo(selectionID, anchor: .center) }
                .onAppear { reader.scrollTo(selectionID, anchor: .center) }
            }
            SidebarFooter(model: model)
        }
    }
}

func rowID(host: String, deck: String) -> String { host + ":" + deck }

/// Traffic lights (placed by the window), the sidebar toggle and `+`.
private struct SidebarTopRow: View {
    let model: WorkspaceModel

    var body: some View {
        let colors = model.preferences.colors
        ZStack(alignment: .leading) {
            WindowDragArea()
            Button { model.preferences.verticalTabs = false } label: {
                Image(systemName: "sidebar.left")
                    .font(Chrome.font(Chrome.Sidebar.toggleSymbolSize))
                    .foregroundStyle(colors.secondary)
                    .frame(width: Chrome.Titlebar.newTabButton, height: Chrome.Titlebar.newTabButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Switch to Horizontal Tabs (⇧⌘S)")
            .accessibilityLabel("Switch to horizontal tabs")
            .offset(x: toggleCentre - Chrome.Titlebar.newTabButton / 2)
            NewTabButton(model: model)
                .offset(x: Chrome.Sidebar.width - Chrome.Sidebar.newTabCentreInset - Chrome.Titlebar.newTabButton / 2)
        }
        .frame(height: Chrome.Titlebar.sidebarHeight)
    }

    private var toggleCentre: CGFloat {
        Chrome.Titlebar.trafficLightX + 2 * Chrome.Titlebar.trafficLightSpacing + Chrome.Sidebar.toggleOffset
    }
}

private struct HostSection: View {
    let model: WorkspaceModel
    let host: HostProfile

    var body: some View {
        ForEach(model.sessions(on: host.id).filter(matchesFilter)) { session in
            SessionSection(model: model, session: session, host: host.id)
        }
    }

    private func matchesFilter(_ session: Session) -> Bool {
        let filter = model.sidebarFilter
        return filter.isEmpty || session.name.localizedCaseInsensitiveContains(filter)
            || session.windows.contains { model.deckTitle($0, host: host.id).localizedCaseInsensitiveContains(filter) }
    }
}

private struct SessionSection: View {
    let model: WorkspaceModel
    let session: Session
    let host: String

    private var elsewhere: Bool { model.otherWindow(showing: SessionKey(host: host, session: session.id)) != nil }

    var body: some View {
        let colors = model.preferences.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(session.name).font(Chrome.Sidebar.sessionFont)
                if elsewhere {
                    Image(systemName: "macwindow").font(Chrome.Sidebar.sessionFont).help("Open in another window")
                }
            }
            .foregroundStyle(colors.secondary)
            .padding(.leading, Chrome.Sidebar.sessionLeading)
            .frame(height: Chrome.Sidebar.sessionHeight, alignment: .bottomLeading)
            .padding(.bottom, (Chrome.Sidebar.rowPitch - Chrome.Sidebar.rowHeight) / 2)
            ForEach(session.windows) { deck in
                SidebarTabRow(model: model, deck: deck, session: session.id, host: host)
                    .id(rowID(host: host, deck: deck.id))
            }
        }
        .contextMenu {
            Button("Rename Session…") { model.beginRenameSession(session.id, host: host) }
            Button("Close Session…") { model.closeSession(session.id, host: host) }
        }
    }
}

/// A tab in the sidebar: badges and a fading title; the selected tab is a
/// raised capsule.
private struct SidebarTabRow: View {
    let model: WorkspaceModel
    let deck: Deck
    let session: String
    let host: String

    private var selected: Bool { deck.id == model.selectedDeck && host == model.selectedHost && session == model.selectedSession }
    private var title: String { model.deckTitle(deck, host: host) }

    var body: some View {
        let colors = model.preferences.colors
        HStack(spacing: Chrome.Sidebar.rowBadgeTitleSpacing) {
            ProcessBadgeStack(badges: model.tabBadges(deck, host: host), size: Chrome.Badge.sidebarSize, isLight: colors.isLight)
            FadingTitle(text: highlightedTitle, font: Chrome.Sidebar.rowFont, fade: Chrome.Tab.titleFade)
                .foregroundStyle(selected ? colors.primary : colors.secondary)
        }
        .padding(.leading, Chrome.Sidebar.rowBadgeLeading)
        .padding(.trailing, Chrome.Tab.titleTrailingInset)
        .frame(height: Chrome.Sidebar.rowHeight)
        .background {
            if selected {
                Capsule().fill(colors.selectedTabFill)
                    .overlay(Capsule().stroke(colors.selectedTabStroke, lineWidth: Chrome.Sidebar.selectedStrokeWidth))
                    .shadow(color: .black.opacity(colors.isLight ? 0.08 : 0), radius: Chrome.Sidebar.selectedShadowRadius, y: 0.5)
            }
        }
        .contentShape(Capsule())
        .padding(.horizontal, Chrome.Sidebar.rowInset)
        .padding(.vertical, (Chrome.Sidebar.rowPitch - Chrome.Sidebar.rowHeight) / 2)
        .onTapGesture { model.choose(deck: deck.id, session: session, host: host) }
        .contextMenu {
            Button("Rename Tab…") {
                model.choose(deck: deck.id, session: session, host: host)
                model.beginRenameTab(deck.id)
            }
            Button("Close Tab") { model.closeTab(deck.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Emphasises the sidebar filter's match.
    private var highlightedTitle: AttributedString {
        var text = AttributedString(title)
        if !model.sidebarFilter.isEmpty,
           let range = text.range(of: model.sidebarFilter, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = Chrome.Sidebar.rowMatchFont
        }
        return text
    }
}

/// The filter capsule and the new-session and add-host buttons.
private struct SidebarFooter: View {
    let model: WorkspaceModel

    var body: some View {
        let colors = model.preferences.colors
        ZStack(alignment: .leading) {
            HStack(spacing: Chrome.Sidebar.filterSpacing) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(colors.secondary)
                TextField("Filter", text: Binding(get: { model.sidebarFilter }, set: { model.sidebarFilter = $0 }))
                    .textFieldStyle(.plain)
                    .onSubmit { model.requestTerminalFocus() }
            }
            .font(Chrome.Sidebar.filterFont)
            .padding(.horizontal, Chrome.Sidebar.filterPadding)
            .frame(width: Chrome.Sidebar.filterSize.width, height: Chrome.Sidebar.filterSize.height)
            .background(colors.filterFill, in: Capsule())
            .offset(x: Chrome.Sidebar.filterLeading)
            footerButton("rectangle.stack.badge.plus", help: "New Session (⇧⌘N)", inset: Chrome.Sidebar.footerCentreInsets.newSession) {
                model.newSession()
            }
            footerButton("globe", help: "Add Remote Host…", inset: Chrome.Sidebar.footerCentreInsets.addHost) {
                model.showAddHost = true
            }
        }
        .frame(height: 2 * Chrome.Sidebar.filterCentreInset, alignment: .leading)
    }

    private func footerButton(_ symbol: String, help: String, inset: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.font(Chrome.Sidebar.footerSymbolSize))
                .foregroundStyle(model.preferences.colors.secondary)
                .frame(width: Chrome.Titlebar.newTabButton, height: Chrome.Titlebar.newTabButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .offset(x: Chrome.Sidebar.width - inset - Chrome.Titlebar.newTabButton / 2)
    }
}
