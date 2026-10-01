import SwiftUI

/// The top bar with horizontal tabs: the session button, fixed-width tabs
/// and the new-tab button, on one centre line with the traffic lights.
/// Empty space drags the window.
struct WorkspaceTitlebar: View {
    let model: WorkspaceModel
    let isFullScreen: Bool

    var body: some View {
        HStack(spacing: 0) {
            SessionButton(model: model)
            TabStrip(model: model)
                .padding(.leading, Chrome.Titlebar.sessionToTabs - Chrome.Titlebar.stripClipSlack)
            Spacer(minLength: Chrome.Titlebar.tabsToNewTab)
            NewTabButton(model: model)
        }
        .padding(.leading, isFullScreen ? Chrome.Titlebar.fullScreenLeading : Chrome.Titlebar.sessionLeading)
        .padding(.trailing, Chrome.Titlebar.newTabCentreInset - Chrome.Titlebar.newTabButton / 2)
        .frame(height: Chrome.Titlebar.height)
        .background(WindowDragArea())
    }
}

struct NewTabButton: View {
    let model: WorkspaceModel

    var body: some View {
        Button { model.newTab() } label: {
            Image(systemName: "plus")
                .font(Chrome.font(Chrome.Titlebar.newTabSymbolSize))
                .foregroundStyle(model.preferences.colors.secondary)
                .frame(width: Chrome.Titlebar.newTabButton, height: Chrome.Titlebar.newTabButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Tab (⌘T)")
        .accessibilityLabel("New tab")
    }
}

/// The current session and its host; opens the session picker below it.
private struct SessionButton: View {
    let model: WorkspaceModel

    var body: some View {
        let colors = model.preferences.colors
        Button { model.togglePalette(.sessions) } label: {
            HStack(spacing: Chrome.SessionButton.symbolTextSpacing) {
                Image(systemName: model.activeHost.isLocal ? Chrome.SessionButton.localSymbol : Chrome.SessionButton.remoteSymbol)
                    .font(Chrome.font(Chrome.SessionButton.symbolSize))
                    .frame(width: Chrome.SessionButton.symbolWidth)
                VStack(alignment: .leading, spacing: Chrome.SessionButton.lineSpacing) {
                    Text(model.activeSession?.name ?? "illogical").font(Chrome.SessionButton.nameFont)
                    Text(model.activeHost.name)
                        .font(Chrome.SessionButton.subtitleFont)
                        .foregroundStyle(colors.tertiary)
                }
                .lineLimit(1)
            }
            .foregroundStyle(colors.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename Session…") { model.beginRenameSession() }
            Button("Close Session…") { model.closeSession(model.selectedSession, host: model.selectedHost) }
        }
        .help("Change Session (⌘K)")
        .accessibilityLabel("Change session")
    }
}

/// The current session's tabs, scrolled to keep the selected one in view.
/// The strip is only as wide as its tabs so the space after them stays a
/// window drag area.
private struct TabStrip: View {
    let model: WorkspaceModel
    @State private var contentWidth: CGFloat = 0
    @State private var hovered: String?

    var body: some View {
        let tabs = model.activeSession?.windows ?? []
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, deck in
                        let next = tabs.indices.contains(index + 1) ? tabs[index + 1].id : nil
                        DeckTab(model: model, deck: deck, hovered: hovered == deck.id) { hovered = $0 ? deck.id : (hovered == deck.id ? nil : hovered) }
                            .overlay(alignment: .trailing) {
                                // Dividers sit only between two plain tabs.
                                if let next, !isEmphasised(deck.id), !isEmphasised(next) {
                                    Rectangle().fill(model.preferences.colors.tabDivider)
                                        .frame(width: Chrome.Tab.divider.width, height: Chrome.Tab.divider.height)
                                        .offset(x: Chrome.Tab.divider.width / 2)
                                }
                            }
                            .id(deck.id)
                    }
                }
                .padding(.horizontal, Chrome.Titlebar.stripClipSlack)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: contentWidth)
            .onChange(of: model.selectedDeck) { reader.scrollTo(model.selectedDeck) }
            .onChange(of: tabs.map(\.id)) { reader.scrollTo(model.selectedDeck) }
            .onAppear { reader.scrollTo(model.selectedDeck) }
        }
    }

    private func isEmphasised(_ deck: String) -> Bool { deck == model.selectedDeck || deck == hovered }
}

/// A tab: process badges, a title that fades out when long, and a close
/// button on hover. The selected tab is a capsule; a hovered one is filled.
private struct DeckTab: View {
    let model: WorkspaceModel
    let deck: Deck
    let hovered: Bool
    let onHover: (Bool) -> Void

    private var selected: Bool { deck.id == model.selectedDeck }
    private var title: String { model.deckTitle(deck) }

    var body: some View {
        let colors = model.preferences.colors
        HStack(spacing: Chrome.Tab.badgeTitleSpacing) {
            ProcessBadgeStack(badges: model.tabBadges(deck), isLight: colors.isLight)
            FadingTitle(text: AttributedString(title), font: Chrome.Tab.titleFont, fade: Chrome.Tab.titleFade)
                .foregroundStyle(selected ? colors.primary : colors.secondary)
        }
        .padding(.leading, Chrome.Tab.leadingPadding)
        .padding(.trailing, hovered ? Chrome.Tab.hoverTitleTrailingInset : Chrome.Tab.titleTrailingInset)
        .frame(width: Chrome.Tab.width, height: Chrome.Tab.height, alignment: .leading)
        .background {
            let shape = Capsule()
            if selected {
                shape.fill(colors.selectedTabFill)
                    .overlay(shape.strokeBorder(colors.selectedTabStroke, lineWidth: Chrome.Tab.strokeWidth))
            } else if hovered {
                shape.fill(colors.hoveredTabFill)
            }
        }
        .overlay(alignment: .trailing) {
            if hovered { closeButton(colors).transition(.opacity) }
        }
        .animation(Chrome.Tab.hoverAnimation, value: hovered)
        .contentShape(Capsule())
        .onTapGesture { model.choose(deck: deck.id, session: model.selectedSession, host: model.selectedHost) }
        .onHover(perform: onHover)
        .contextMenu {
            Button("Rename Tab…") {
                model.choose(deck: deck.id, session: model.selectedSession, host: model.selectedHost)
                model.beginRenameTab(deck.id)
            }
            Button("Close Tab") { model.closeTab(deck.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Close tab")) { model.closeTab(deck.id) }
    }

    private func closeButton(_ colors: ChromeColors) -> some View {
        Button { model.closeTab(deck.id) } label: {
            Image(systemName: "xmark")
                .font(Chrome.font(Chrome.Tab.closeSymbolSize, .medium))
                .foregroundStyle(colors.secondary)
                .frame(width: Chrome.Tab.closeButton, height: Chrome.Tab.closeButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, Chrome.Tab.closeCentreInset - Chrome.Tab.closeButton / 2)
        .accessibilityLabel("Close tab")
    }
}

/// A single-line title that fades out at its trailing edge instead of
/// truncating with an ellipsis.
struct FadingTitle: View {
    let text: AttributedString
    let font: Font
    let fade: CGFloat

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            // Zero minimum width lets the title give way to its container;
            // otherwise a long title widens every column it sits in.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade)
                }
            }
    }
}
