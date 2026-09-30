import SwiftUI

/// Live previews revealed behind the terminal: the current session's tabs
/// (peek) or every session (overview). Choosing a card opens that tab.
struct WorkspaceOverview: View {
    let model: WorkspaceModel
    let expanded: Bool
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(expanded ? "Sessions" : model.activeSession?.name ?? "Tabs").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.dismissPeek() } label: {
                    Image(systemName: "xmark.circle.fill").opacity(0.4).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                // Present only while the overview is open, so Escape never
                // leaves the terminal otherwise.
                .keyboardShortcut(.cancelAction)
                .focused($closeFocused)
                .help("Close Overview (Esc)")
                .accessibilityLabel("Close overview")
            }
            if expanded { allSessions } else { currentSessionTabs }
        }
        .onAppear { closeFocused = true }
    }

    private var allSessions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(model.hosts) { host in
                    ForEach(model.sessions(on: host.id)) { session in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(session.name) · \(host.name)").font(.system(size: 11, weight: .medium)).opacity(0.5)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 16)], spacing: 16) {
                                ForEach(session.windows) { deck in
                                    OverviewCard(model: model, deck: deck, session: session.id, host: host.id, expanded: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var currentSessionTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(model.activeSession?.windows ?? []) { deck in
                    OverviewCard(model: model, deck: deck, session: model.selectedSession, host: model.selectedHost, expanded: false)
                        .frame(width: Chrome.Overview.cardWidth)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct OverviewCard: View {
    let model: WorkspaceModel
    let deck: Deck
    let session: String
    let host: String
    let expanded: Bool

    private var theme: TerminalTheme { model.preferences.theme }
    private var selected: Bool { model.selectedDeck == deck.id && model.selectedHost == host }

    var body: some View {
        Button { model.animateNavigation { model.choose(deck: deck.id, session: session, host: host) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                LayoutView(model: model, node: deck.root, deck: deck.id, host: host, preview: true)
                    .frame(height: expanded ? Chrome.Overview.expandedPreviewHeight : Chrome.Overview.compactPreviewHeight)
                    .allowsHitTesting(false)
                HStack(spacing: 7) {
                    ProcessBadgeView(badge: model.processBadge(model.preferredBlock(in: deck, host: host), host: host),
                                     stacked: deck.root.blocks.count > 1)
                    Text(model.deckTitle(deck, host: host)).font(.system(size: 11)).lineLimit(1)
                }
            }
            .padding(8)
            .background(theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: Chrome.Overview.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Chrome.Overview.cardRadius)
                .stroke(selected ? theme.tint.opacity(0.6) : theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.deckTitle(deck, host: host))
        .accessibilityHint("Open tab")
    }
}
