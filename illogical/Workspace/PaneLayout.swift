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
        return Rectangle()
            .fill(model.preferences.density == .compact ? model.preferences.theme.border : .clear)
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
    @State private var hovering = false
    @State private var cellSize = CGSize(width: 8, height: 19)
    @State private var paneSize = CGSize(width: 1, height: 1)

    private var preferences: Preferences { model.preferences }
    private var theme: TerminalTheme { preferences.theme }
    private var radius: CGFloat {
        if preview { return Chrome.Pane.previewRadius }
        return preferences.density == .comfortable ? Chrome.Pane.comfortableRadius : 0
    }
    private var showsTitle: Bool { !preview && preferences.showPaneTitles }
    private var isFocused: Bool { !preview && model.focusedBlock == block }
    /// Whether this pane's terminal should hold keyboard focus right now.
    private var hasKeyboardFocus: Bool {
        isFocused && model.peek == 0 && model.searchFocusedBlock == nil && !model.hasOverlay
    }
    /// Unfocused panes of a split tab are dimmed, like Ghostty's unfocused splits.
    private var isDimmed: Bool {
        !preview && !isFocused && (model.activeDeck?.root.blocks.count ?? 0) > 1 && preferences.unfocusedPaneOpacity < 1
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsTitle { PaneTitleRow(model: model, block: block, host: host, controlsVisible: hovering) }
            surface
        }
        .background(theme.effectiveBackgroundOpacity == 1 ? theme.color : .clear)
        .overlay {
            if isDimmed { theme.color.opacity(1 - preferences.unfocusedPaneOpacity).allowsHitTesting(false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(theme.text.opacity(isFocused ? Chrome.Pane.focusedBorderOpacity : Chrome.Pane.unfocusedBorderOpacity),
                        lineWidth: Chrome.Pane.borderWidth)
        )
        .overlay {
            if !preview, let search = model.searches[block] {
                TerminalSearchOverlay(model: model, search: search, block: block, cell: cellSize,
                                      titleHeight: showsTitle ? Chrome.PaneTitle.height : 0)
                    .allowsHitTesting(model.peek == 0)
            }
        }
        .anchorPreference(key: PaneFrames.self, value: .bounds) { preview ? [] : [PaneFrames.Frame(anchor: $0, radius: radius)] }
        .onHover { hovering = $0 }
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

/// The optional thin row above a pane: badge, title and pane controls.
private struct PaneTitleRow: View {
    let model: WorkspaceModel
    let block: String
    let host: String
    let controlsVisible: Bool

    private var info: BlockInfo? { model.info(block, host: host) }
    private var theme: TerminalTheme { model.preferences.theme }

    var body: some View {
        HStack(spacing: Chrome.PaneTitle.spacing) {
            ProcessGlyph(badge: model.processBadge(block, host: host))
                .opacity(Chrome.PaneTitle.titleOpacity)
            Text(info?.displayTitle ?? "Terminal")
                .font(.system(size: Chrome.PaneTitle.titleSize, weight: .semibold))
                .lineLimit(1)
                .opacity(Chrome.PaneTitle.titleOpacity)
            if info?.parked == true {
                Image(systemName: "moon.zzz")
                    .font(.system(size: Chrome.PaneTitle.parkedSymbolSize))
                    .opacity(0.35)
                    .help("Emulator parked. Your process is still running.")
            }
            Spacer(minLength: 4)
            HStack(spacing: Chrome.PaneTitle.spacing) {
                control("rectangle.split.2x1", "Split Right") { model.split(.horizontal, block: block) }
                control("rectangle.split.1x2", "Split Down") { model.split(.vertical, block: block) }
                control("arrow.up.left.and.arrow.down.right", "Zoom Pane") { model.zoom(block) }
                control("xmark", "Close Pane") { model.closePane(block) }
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)
        }
        .padding(.horizontal, Chrome.PaneTitle.horizontalPadding)
        .frame(height: Chrome.PaneTitle.height)
        .background(theme.color.opacity(theme.effectiveBackgroundOpacity))
        .contentShape(Rectangle())
        .allowsHitTesting(model.peek == 0)
        .onTapGesture { model.focus(block) }
        .onDrag { NSItemProvider(object: block as NSString) }
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Chrome.PaneTitle.controlSymbolSize))
                .frame(width: Chrome.PaneTitle.control.width, height: Chrome.PaneTitle.control.height)
        }
        .buttonStyle(.plain)
        .opacity(Chrome.PaneTitle.controlOpacity)
        .help(label)
        .accessibilityLabel(label)
    }
}
