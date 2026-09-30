import SwiftUI

/// The top bar: traffic-light space, the session button, the tab strip and
/// the new-tab button. Empty space drags the window.
struct WorkspaceTitlebar: View {
    let model: WorkspaceModel
    let isFullScreen: Bool

    var body: some View {
        HStack(spacing: Chrome.Titlebar.spacing) {
            if !isFullScreen { Color.clear.frame(width: Chrome.Titlebar.trafficLightWidth) }
            if !model.preferences.verticalTabs {
                SessionButton(model: model)
                TabStrip(model: model)
            }
            Spacer(minLength: 0)
            Button { model.newTab() } label: {
                Image(systemName: "plus").frame(width: Chrome.Titlebar.newTabButton.width, height: Chrome.Titlebar.newTabButton.height)
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New tab")
        }
        .padding(.trailing, Chrome.Titlebar.trailingPadding)
        .frame(height: Chrome.Titlebar.height)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(model.preferences.theme.border).frame(height: Chrome.Titlebar.separatorWidth)
        }
    }
}

/// Shows the current session and host; opens the session picker.
private struct SessionButton: View {
    let model: WorkspaceModel

    var body: some View {
        Button { model.togglePalette(.sessions) } label: {
            HStack(spacing: Chrome.SessionButton.spacing) {
                Image(systemName: model.activeHost.isLocal ? Chrome.SessionButton.symbol : Chrome.SessionButton.remoteSymbol)
                    .font(Chrome.font(Chrome.SessionButton.symbolSize))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.activeSession?.name ?? "illogical")
                        .font(Chrome.font(Chrome.SessionButton.titleSize, .semibold))
                        .opacity(Chrome.SessionButton.titleOpacity)
                        .lineLimit(1)
                    Text(model.activeHost.name)
                        .font(Chrome.font(Chrome.SessionButton.subtitleSize))
                        .opacity(Chrome.SessionButton.subtitleOpacity)
                }
            }
            .padding(.leading, Chrome.SessionButton.horizontalPadding)
            .padding(.trailing, Chrome.SessionButton.horizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch Session (⌘K)")
        .accessibilityLabel("Switch session")
    }
}

/// The current session's tabs. The strip is only as wide as its tabs so the
/// space after them stays a window drag area.
private struct TabStrip: View {
    let model: WorkspaceModel
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let tabs = model.activeSession?.windows ?? []
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: Chrome.Tab.spacing) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, deck in
                        DeckTab(model: model, deck: deck, session: model.selectedSession, host: model.selectedHost)
                            .id(deck.id)
                        if index < tabs.count - 1 {
                            TabDivider(hidden: deck.id == model.selectedDeck || tabs[index + 1].id == model.selectedDeck)
                        }
                    }
                }
                .padding(.vertical, 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: contentWidth)
            .onChange(of: model.selectedDeck) { reader.scrollTo(model.selectedDeck, anchor: .center) }
            .onChange(of: tabs.map(\.id)) { reader.scrollTo(model.selectedDeck, anchor: .center) }
            .onAppear { reader.scrollTo(model.selectedDeck, anchor: .center) }
        }
    }
}

private struct TabDivider: View {
    let hidden: Bool
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(hidden ? 0 : Chrome.Tab.dividerOpacity))
            .frame(width: 1, height: Chrome.Tab.dividerHeight)
    }
}

/// A tab: process badge, a title that fades out when long, and a close
/// button on hover. Also used as a sidebar row.
struct DeckTab: View {
    let model: WorkspaceModel
    let deck: Deck
    let session: String
    let host: String
    var vertical = false
    @State private var hovering = false

    private var selected: Bool { deck.id == model.selectedDeck && host == model.selectedHost && session == model.selectedSession }
    private var theme: TerminalTheme { model.preferences.theme }
    private var title: String { model.deckTitle(deck, host: host) }

    var body: some View {
        HStack(spacing: Chrome.Tab.contentSpacing) {
            ProcessBadgeView(badge: model.processBadge(model.preferredBlock(in: deck, host: host), host: host),
                             stacked: deck.root.blocks.count > 1)
            FadingTitle(text: highlightedTitle)
            Button { model.closeTab(deck.id) } label: {
                Image(systemName: "xmark")
                    .font(Chrome.font(Chrome.Tab.closeSymbolSize, .semibold))
                    .frame(width: Chrome.Tab.closeButton.width, height: Chrome.Tab.closeButton.height)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, Chrome.Tab.horizontalPadding)
        .frame(width: vertical ? nil : Chrome.Tab.width, height: Chrome.Tab.height)
        .frame(maxWidth: vertical ? .infinity : nil)
        .background(selected ? theme.selectedTabFill : .clear, in: Capsule())
        .overlay(Capsule().stroke(selected ? theme.border : .clear, lineWidth: Chrome.Tab.borderWidth))
        .contentShape(Rectangle())
        .onTapGesture { model.choose(deck: deck.id, session: session, host: host) }
        .onHover { hovering = $0 }
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
        .accessibilityAction(named: Text("Close tab")) { model.closeTab(deck.id) }
    }

    /// Emphasises the sidebar filter match.
    private var highlightedTitle: AttributedString {
        var text = AttributedString(title)
        if vertical, !model.sidebarFilter.isEmpty,
           let range = text.range(of: model.sidebarFilter, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = Chrome.font(Chrome.Tab.titleSize, .semibold)
        }
        return text
    }
}

/// A single-line title that fades out at the trailing edge instead of
/// truncating with an ellipsis.
struct FadingTitle: View {
    let text: AttributedString
    var size: CGFloat = Chrome.Tab.titleSize
    var weight: Font.Weight = .medium

    var body: some View {
        Text(text)
            .font(Chrome.font(size, weight))
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Chrome.Tab.titleFade)
                }
            }
    }
}
