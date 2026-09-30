import SwiftUI

/// Places a pane's search bar where it does not cover the active match.
struct TerminalSearchOverlay: View {
    let model: WorkspaceModel
    let search: TerminalSearchState
    let block: String
    let cell: CGSize
    let titleHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < Chrome.Search.compactThreshold
            let size = CGSize(width: max(80, min(Chrome.Search.width, geometry.size.width - 24)),
                              height: compact ? Chrome.Search.compactHeight : Chrome.Search.height)
            let origin = SearchOverlayPlacement.origin(viewport: geometry.size, bar: size, cell: cell,
                                                       titleHeight: titleHeight, spans: search.spans)
            TerminalSearchBar(model: model, search: search, block: block, compact: compact)
                .frame(width: size.width, height: size.height)
                .offset(x: origin.x, y: origin.y)
        }
    }
}

/// Query field, match counter and previous/next/close controls. Return
/// finds the next match, Shift-Return the previous, Escape closes.
private struct TerminalSearchBar: View {
    let model: WorkspaceModel
    @Bindable var search: TerminalSearchState
    let block: String
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 7) {
                    HStack(spacing: 8) { field; closeButton }
                    HStack(spacing: 9) { navigation; Spacer(minLength: 0) }
                }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").opacity(0.5)
                    field
                    navigation
                    closeButton
                }
            }
        }
        .font(Chrome.Search.font)
        .buttonStyle(.plain)
        .padding(Chrome.Search.padding)
        .background { RoundedRectangle(cornerRadius: Chrome.Search.cornerRadius).fill(.regularMaterial) }
        .shadow(color: .black.opacity(Chrome.Search.shadowOpacity), radius: Chrome.Search.shadowRadius, y: 4)
    }

    private var field: some View {
        NativeSearchField(text: $search.query, placeholder: "Find in terminal", size: Chrome.Search.fieldSize,
                          onSubmit: { backwards in model.updateSearch(block, direction: backwards ? -1 : 1) },
                          onEscape: { model.closeSearch(block) },
                          onMove: { model.updateSearch(block, direction: Int32($0)) },
                          autoFocus: model.searchFocusedBlock == block, focusToken: search.focusToken,
                          onFocus: { model.focusSearch(block) })
            .frame(minWidth: 24, maxWidth: .infinity)
            .frame(height: 16)
            .onChange(of: search.query) { model.updateSearch(block) }
    }

    @ViewBuilder private var navigation: some View {
        Text(search.result.count == 0 ? "0" : "\(search.result.selected)/\(search.result.count)")
            .monospacedDigit()
            .opacity(0.45)
            .lineLimit(1)
        Button { model.updateSearch(block, direction: -1) } label: { Image(systemName: "chevron.up") }
            .help("Previous Match (⇧⌘G)")
            .accessibilityLabel("Previous match")
        Button { model.updateSearch(block, direction: 1) } label: { Image(systemName: "chevron.down") }
            .help("Next Match (⌘G)")
            .accessibilityLabel("Next match")
    }

    private var closeButton: some View {
        Button { model.closeSearch(block) } label: { Image(systemName: "xmark") }
            .help("Close Search")
            .accessibilityLabel("Close search")
    }
}
