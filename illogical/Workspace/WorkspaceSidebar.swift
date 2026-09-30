import SwiftUI

/// Vertical tabs: every session on every host, filterable. Sessions shown in
/// another window carry a window glyph; choosing them brings that window forward.
struct WorkspaceSidebar: View {
    let model: WorkspaceModel

    private var selectionID: String { rowID(host: model.selectedHost, deck: model.selectedDeck) }

    var body: some View {
        VStack(spacing: Chrome.Sidebar.padding) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: Chrome.Sidebar.hostSpacing) {
                        ForEach(model.hosts) { host in
                            HostSection(model: model, host: host, showsHeader: model.hosts.count > 1)
                        }
                    }
                    .padding(Chrome.Sidebar.padding)
                }
                .onChange(of: selectionID) { reader.scrollTo(selectionID, anchor: .center) }
                .onAppear { reader.scrollTo(selectionID, anchor: .center) }
            }
            FilterField(model: model)
        }
    }
}

func rowID(host: String, deck: String) -> String { host + ":" + deck }

private struct HostSection: View {
    let model: WorkspaceModel
    let host: HostProfile
    let showsHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Sidebar.sessionSpacing) {
            if showsHeader {
                Label(host.name, systemImage: host.isLocal ? "desktopcomputer" : "network")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.4)
                    .padding(.horizontal, 9)
            }
            ForEach(model.sessions(on: host.id).filter(matchesFilter)) { session in
                SessionSection(model: model, session: session, host: host.id)
            }
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
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Text(session.name).font(.system(size: Chrome.Sidebar.headerSize, weight: .semibold)).opacity(0.55)
                if elsewhere {
                    Image(systemName: "macwindow").font(.system(size: 9)).opacity(0.45).help("Open in another window")
                }
                Spacer()
                Button {
                    model.choose(session: session.id, host: host)
                    if model.shownSession == SessionKey(host: host, session: session.id) { model.newTab() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("New Tab in \(session.name)")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            ForEach(session.windows) { deck in
                DeckTab(model: model, deck: deck, session: session.id, host: host, vertical: true)
                    .id(rowID(host: host, deck: deck.id))
            }
        }
        .contextMenu {
            Button("Rename Session…") { model.beginRenameSession(session.id, host: host) }
            Button("Close Session…") { model.closeSession(session.id, host: host) }
        }
    }
}

private struct FilterField: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease").opacity(0.5)
            TextField("Filter", text: Binding(get: { model.sidebarFilter }, set: { model.sidebarFilter = $0 }))
                .textFieldStyle(.plain)
                .onSubmit { model.requestTerminalFocus() }
            Button { model.newSession() } label: { Image(systemName: "rectangle.stack.badge.plus") }
                .buttonStyle(.plain)
                .help("New Session (⇧⌘N)")
            Button { model.showAddHost = true } label: { Image(systemName: "globe.badge.chevron.backward") }
                .buttonStyle(.plain)
                .help("Add Remote Host")
        }
        .font(.system(size: Chrome.Sidebar.filterSize))
        .padding(9)
        .background(model.preferences.theme.text.opacity(0.045), in: Capsule())
        .padding(Chrome.Sidebar.padding)
    }
}
