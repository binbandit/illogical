import SwiftUI

/// Live previews revealed behind the terminal: the current session's tabs
/// as a strip of cards (peek) or every session as a grid (overview).
/// Choosing a card opens that tab; Escape closes.
struct WorkspaceOverview: View {
    let model: WorkspaceModel
    let expanded: Bool
    @FocusState private var dismissFocused: Bool

    var body: some View {
        Group {
            if expanded { allSessions } else { currentSessionTabs }
        }
        .background {
            // Present only while the overview is open, so Escape never
            // leaves the terminal otherwise.
            Button("Close Overview") { model.dismissPeek() }
                .keyboardShortcut(.cancelAction)
                .focused($dismissFocused)
                .opacity(0)
                .accessibilityLabel("Close overview")
        }
        .onAppear { dismissFocused = true }
    }

    private var allSessions: some View {
        let columns = Array(repeating: GridItem(.fixed(Chrome.Overview.cardSize.width), spacing: Chrome.Overview.gap),
                            count: Chrome.Overview.columns)
        return ScrollView {
            VStack(alignment: .leading, spacing: Chrome.Overview.labelSpacing) {
                ForEach(model.hosts) { host in
                    ForEach(model.sessions(on: host.id)) { session in
                        VStack(alignment: .leading, spacing: Chrome.Overview.labelSpacing) {
                            Text(model.hosts.count > 1 ? "\(session.name) · \(host.name)" : session.name)
                                .font(Chrome.Overview.labelFont)
                                .foregroundStyle(model.preferences.colors.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Chrome.Overview.gap) {
                                ForEach(session.windows) { deck in
                                    OverviewCard(model: model, deck: deck, session: session.id, host: host.id,
                                                 titleFont: Chrome.Overview.cardTitleFont)
                                        .frame(height: Chrome.Overview.cardSize.height)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private var currentSessionTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Chrome.Overview.gap) {
                ForEach(model.activeSession?.windows ?? []) { deck in
                    OverviewCard(model: model, deck: deck, session: model.selectedSession, host: model.selectedHost,
                                 titleFont: Chrome.Overview.peekCardTitleFont)
                        .frame(width: Chrome.Overview.peekCardSize.width, height: Chrome.Overview.peekCardSize.height)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// A tab's card: badges and title on top, its live layout below. Hovering
/// lifts the card and offers to close the tab.
private struct OverviewCard: View {
    let model: WorkspaceModel
    let deck: Deck
    let session: String
    let host: String
    let titleFont: Font
    @State private var hovering = false

    var body: some View {
        let colors = model.preferences.colors
        let shape = RoundedRectangle(cornerRadius: Chrome.Overview.cardRadius, style: .continuous)
        let emphasised = hovering || (model.selectedDeck == deck.id && model.selectedHost == host)
        VStack(spacing: 0) {
            HStack(spacing: Chrome.Tab.badgeTitleSpacing) {
                ProcessBadgeStack(badges: model.tabBadges(deck, host: host), isLight: colors.isLight)
                FadingTitle(text: AttributedString(model.deckTitle(deck, host: host)), font: titleFont, fade: Chrome.Tab.titleFade)
                    .foregroundStyle(emphasised ? colors.primary : colors.secondary)
                if hovering {
                    Button { model.closeTab(deck.id) } label: {
                        Image(systemName: "xmark").font(Chrome.font(Chrome.Overview.closeSymbolSize, .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(colors.secondary)
                    .accessibilityLabel("Close tab")
                }
            }
            .padding(.horizontal, Chrome.Tab.leadingPadding)
            .frame(height: Chrome.Overview.cardHeader)
            LayoutView(model: model, node: deck.root, deck: deck.id, host: host, preview: true)
                .allowsHitTesting(false)
                .padding([.horizontal, .bottom], Chrome.Overview.previewInset)
        }
        .background(emphasised ? colors.hoveredCardFill : colors.cardFill, in: shape)
        .overlay { if hovering { shape.inset(by: 0.5).stroke(colors.selectedTabStroke, lineWidth: 1) } }
        .contentShape(shape)
        .onTapGesture { model.animateNavigation { model.choose(deck: deck.id, session: session, host: host) } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.deckTitle(deck, host: host))
        .accessibilityHint("Open tab")
        .accessibilityAddTraits(.isButton)
    }
}
