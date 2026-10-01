import SwiftUI

/// Places a pane's search bar at its top-right, moving it when it would
/// cover the active match.
struct TerminalSearchOverlay: View {
    let model: WorkspaceModel
    let search: TerminalSearchState
    let block: String
    let cell: CGSize
    let titleHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: max(80, min(Chrome.Search.size.width, geometry.size.width - 2 * Chrome.Search.trailingInset)),
                              height: Chrome.Search.size.height)
            let origin = SearchOverlayPlacement.origin(viewport: geometry.size, bar: size, cell: cell,
                                                       titleHeight: titleHeight, spans: search.spans)
            TerminalSearchBar(model: model, search: search, block: block)
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

    var body: some View {
        let colors = model.preferences.colors
        let shape = RoundedRectangle(cornerRadius: Chrome.Search.cornerRadius, style: .continuous)
        HStack(spacing: 0) {
            field
            if !search.query.isEmpty {
                Text("\(search.result.selected)/\(search.result.count)")
                    .font(Chrome.Search.countFont)
                    .foregroundStyle(colors.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, Chrome.Search.countToDivider)
            }
            Rectangle().fill(colors.panelSeparator)
                .frame(width: Chrome.Search.divider.width, height: Chrome.Search.divider.height)
                .padding(.leading, Chrome.Search.countToDivider)
            control("chevron.up", size: Chrome.Search.chevronSize, label: "Previous match", help: "Previous Match (⇧⌘G)") {
                model.updateSearch(block, direction: -1)
            }
            control("chevron.down", size: Chrome.Search.chevronSize, label: "Next match", help: "Next Match (⌘G)") {
                model.updateSearch(block, direction: 1)
            }
            control("xmark", size: Chrome.Search.closeSize, label: "Close search", help: "Close Search") { model.closeSearch(block) }
        }
        .foregroundStyle(colors.tertiary)
        .padding(.leading, Chrome.Search.textLeading)
        .padding(.trailing, Chrome.Search.lastControlCentreInset - Chrome.Search.controlPitch / 2)
        .background(colors.searchFill, in: shape)
        .overlay { shape.inset(by: Chrome.Search.strokeWidth / 2).stroke(colors.searchStroke, lineWidth: Chrome.Search.strokeWidth) }
    }

    private var field: some View {
        NativeSearchField(text: $search.query, placeholder: "Find", size: Chrome.Search.fieldSize,
                          onSubmit: { backwards in model.updateSearch(block, direction: backwards ? -1 : 1) },
                          onEscape: { model.closeSearch(block) },
                          onMove: { model.updateSearch(block, direction: Int32($0)) },
                          autoFocus: model.searchFocusedBlock == block, focusToken: search.focusToken,
                          onFocus: { model.focusSearch(block) })
            .frame(minWidth: 24, maxWidth: .infinity)
            .onChange(of: search.query) { model.updateSearch(block) }
    }

    private func control(_ symbol: String, size: CGFloat, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.font(size, .medium))
                .frame(width: Chrome.Search.controlPitch, height: Chrome.Search.size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}
