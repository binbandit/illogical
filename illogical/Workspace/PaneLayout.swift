import SwiftUI
import UniformTypeIdentifiers

/// Renders a tab's split tree.
struct LayoutView: View {
    let model: WorkspaceModel
    let node: SplitLayout
    let deck: String
    let host: String
    let preview: Bool

    var body: some View {
        if let block = node.block {
            TerminalPane(model: model, block: block, host: host, preview: preview)
        } else if let first = node.first, let second = node.second {
            // The tree is recursive; type erasure ends the recursion in the view type.
            AnyView(SplitView(model: model, node: node, first: first, second: second, deck: deck, host: host, preview: preview))
        }
    }
}

/// Two children and a draggable divider. Double-clicking the divider
/// shares the space equally.
private struct SplitView: View {
    let model: WorkspaceModel
    let node: SplitLayout
    let first: SplitLayout
    let second: SplitLayout
    let deck: String
    let host: String
    let preview: Bool
    @State private var dragRatio: Double?

    private var sideBySide: Bool { node.axis != .vertical }
    private var gap: CGFloat {
        if preview { return Chrome.Pane.previewGap }
        return model.preferences.density == .comfortable ? Chrome.Pane.comfortableGap : Chrome.Pane.compactGap
    }

    var body: some View {
        GeometryReader { geometry in
            let extent = max(1, (sideBySide ? geometry.size.width : geometry.size.height) - gap)
            let ratio = dragRatio ?? node.clampedRatio
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
            layout {
                LayoutView(model: model, node: first, deck: deck, host: host, preview: preview)
                    .frame(width: sideBySide ? extent * ratio : nil, height: sideBySide ? nil : extent * ratio)
                LayoutView(model: model, node: second, deck: deck, host: host, preview: preview)
            }
            if !preview {
                divider(extent: extent, ratio: ratio, size: geometry.size)
            }
        }
        .coordinateSpace(name: node.id)
    }

    private func divider(extent: CGFloat, ratio: Double, size: CGSize) -> some View {
        let thickness = max(Chrome.Pane.dividerHitWidth, gap)
        let offset = extent * ratio + gap / 2
        let line = model.preferences.density == .compact ? model.preferences.colors.hairline : .clear
        return Color.clear
            .overlay {
                Rectangle().fill(line)
                    .frame(width: sideBySide ? Chrome.Pane.compactGap : nil, height: sideBySide ? nil : Chrome.Pane.compactGap)
            }
            .frame(width: sideBySide ? thickness : nil, height: sideBySide ? nil : thickness)
            .contentShape(Rectangle())
            .position(x: sideBySide ? offset : size.width / 2, y: sideBySide ? size.height / 2 : offset)
            .pointerStyle(sideBySide ? .columnResize : .rowResize)
            .gesture(
                DragGesture(coordinateSpace: .named(node.id))
                    .onChanged { value in
                        dragRatio = max(0.1, min(0.9, (sideBySide ? value.location.x : value.location.y) / extent))
                    }
                    .onEnded { _ in
                        if let dragRatio { model.resizeSplit(node.id, ratio: dragRatio, deck: deck) }
                        dragRatio = nil
                    }
            )
            .onTapGesture(count: 2) {
                if let equal = node.equalizedRatios().first(where: { $0.split == node.id }) {
                    model.resizeSplit(node.id, ratio: equal.ratio, deck: deck)
                }
            }
    }
}

/// One terminal with its optional title row, search bar and focus styling.
struct TerminalPane: View {
    let model: WorkspaceModel
    let block: String
    let host: String
    let preview: Bool
    @State private var cellSize = CGSize(width: 8, height: 19)
    @State private var paneSize = CGSize(width: 1, height: 1)

    private var preferences: Preferences { model.preferences }
    private var theme: TerminalTheme { preferences.theme }
    private var colors: ChromeColors { preferences.colors }
    private var islands: Bool { preferences.density == .comfortable }
    private var radius: CGFloat {
        if preview { return Chrome.Pane.previewRadius }
        return islands ? Chrome.Pane.comfortableRadius : 0
    }
    private var showsTitle: Bool { !preview && preferences.showPaneTitles }
    private var isFocused: Bool { !preview && model.focusedBlock == block }
    /// Whether this pane's terminal should hold keyboard focus right now.
    private var hasKeyboardFocus: Bool {
        isFocused && model.peek == 0 && model.searchFocusedBlock == nil && !model.hasOverlay
    }
    /// Panes of a split tab that do not have focus sit a shade darker.
    private var isUnfocusedSplit: Bool {
        !preview && !isFocused && (model.activeDeck?.root.blocks.count ?? 0) > 1
    }
    /// Ghostty's optional `unfocused-split-opacity` fade, on top of the shade.
    private var fadeOpacity: Double { isUnfocusedSplit ? preferences.unfocusedPaneOpacity : 1 }
    private var searchDimmed: Bool { !preview && model.searches[block]?.query.isEmpty == false }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .top) {
            surface
                .overlay {
                    if isUnfocusedSplit { Color.black.opacity(colors.unfocusedShade).allowsHitTesting(false) }
                }
                .overlay {
                    if searchDimmed { Color.black.opacity(Chrome.Search.paneDim).allowsHitTesting(false).transition(.opacity) }
                }
                .animation(Chrome.Search.dimAnimation, value: searchDimmed)
                .padding(.top, showsTitle ? Chrome.PaneTitle.height - Chrome.PaneTitle.terminalOverlap : 0)
            if showsTitle {
                PaneTitleRow(model: model, block: block, host: host,
                             background: isUnfocusedSplit ? colors.unfocusedPane : colors.terminal.opacity(theme.effectiveBackgroundOpacity))
            }
        }
        .background(theme.effectiveBackgroundOpacity == 1 ? colors.terminal : .clear)
        .overlay {
            if fadeOpacity < 1 { colors.terminal.opacity(1 - fadeOpacity).allowsHitTesting(false) }
        }
        .clipShape(shape)
        .overlay {
            if islands && !preview {
                shape.inset(by: Chrome.Pane.strokeWidth / 2)
                    .stroke(isFocused ? colors.focusedIslandStroke : colors.islandStroke, lineWidth: Chrome.Pane.strokeWidth)
            }
        }
        .overlay {
            if !preview, let search = model.searches[block] {
                TerminalSearchOverlay(model: model, search: search, block: block, cell: cellSize,
                                      titleHeight: showsTitle ? Chrome.PaneTitle.height - Chrome.PaneTitle.terminalOverlap : 0)
                    .allowsHitTesting(model.peek == 0)
            }
        }
        .anchorPreference(key: PaneFrames.self, value: .bounds) { preview ? [] : [PaneFrames.Frame(anchor: $0, radius: radius)] }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { paneSize = $0 }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers, location in dropPane(providers, at: location) }
    }

    private var surface: some View {
        TerminalSurface(
            engine: model.engine(for: block, host: host),
            fontSize: model.fontSize,
            fontName: preferences.fontName,
            focused: !preview && hasKeyboardFocus,
            focusToken: model.focusToken,
            interactive: !preview,
            peekProgress: preview ? 0 : model.peek,
            contrast: preferences.contrastCorrection,
            fontOptions: preferences.fontOptions,
            onFocus: { model.focus(block) },
            onRequestEditorFocus: { model.consumeKeyboardFocusIntent($0) },
            onPeek: { progress, finished in
                guard model.selectedHost == host, model.activeDeck?.root.contains(block) == true else { return }
                model.setPeek(progress, finished: finished)
            },
            onCellSize: { cellSize = $0 },
            copyOnSelection: preferences.copyOnSelection,
            onCopy: { text in model.send(WireRequest(method: .blockEvent, block: block, label: "selection_copied", data: Data(text.utf8)), host: host) },
            onLink: { url in model.send(WireRequest(method: .blockEvent, block: block, label: "url_clicked", data: Data(url.absoluteString.utf8)), host: host) }
        )
        .id(block + (preview ? ".preview" : ".terminal"))
    }

    /// Dropping another pane's title row here moves that pane beside this one,
    /// on the side nearest the drop point's axis.
    private func dropPane(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
        guard !preview, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value, value != block else { return }
            Task { @MainActor in
                guard model.states[host]?.blocks.contains(where: { $0.id == value }) == true else { return }
                let sideBySide = abs(location.x / max(1, paneSize.width) - 0.5) >= abs(location.y / max(1, paneSize.height) - 0.5)
                model.move(value, to: block, axis: sideBySide ? .horizontal : .vertical)
            }
        }
        return true
    }
}

/// The optional row above a pane: the process glyph, the title and the
/// pane controls, on the pane's own surface.
private struct PaneTitleRow: View {
    let model: WorkspaceModel
    let block: String
    let host: String
    let background: Color

    private var info: BlockInfo? { model.info(block, host: host) }
    private var colors: ChromeColors { model.preferences.colors }
    /// Closing the only pane closes its tab, so that control is muted.
    private var isOnlyPane: Bool { (model.activeDeck?.root.blocks.count ?? 1) <= 1 }

    var body: some View {
        HStack(spacing: Chrome.PaneTitle.glyphTitleSpacing) {
            ProcessGlyph(badge: model.processBadge(block, host: host))
            Text(info?.displayTitle ?? "shell")
                .font(Chrome.PaneTitle.titleFont)
                .lineLimit(1)
                .accessibilityHint(info?.parked == true ? "Emulator parked. Your process is still running." : "")
            Spacer(minLength: Chrome.PaneTitle.glyphTitleSpacing)
            HStack(spacing: 0) {
                control("rectangle.split.2x1", "Split Pane Right") { model.split(.horizontal, block: block) }
                control("rectangle.split.1x2", "Split Pane Down") { model.split(.vertical, block: block) }
                control("arrow.up.left.and.arrow.down.right", "Zoom Pane") { model.zoom(block) }
                control("xmark", "Close Pane", muted: isOnlyPane) { model.closePane(block) }
            }
        }
        .foregroundStyle(colors.primary)
        .padding(.leading, Chrome.PaneTitle.leadingInset)
        .padding(.trailing, Chrome.PaneTitle.lastControlCentreInset - Chrome.PaneTitle.controlPitch / 2)
        .frame(height: Chrome.PaneTitle.height)
        .background(background)
        .contentShape(Rectangle())
        .allowsHitTesting(model.peek == 0)
        .onTapGesture { model.focus(block) }
        .onDrag { NSItemProvider(object: block as NSString) }
    }

    private func control(_ symbol: String, _ label: String, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.font(Chrome.PaneTitle.controlSymbolSize))
                .foregroundStyle(muted ? colors.disabledControl : colors.control)
                .frame(width: Chrome.PaneTitle.controlPitch, height: Chrome.PaneTitle.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
