import SwiftUI

/// Every window-chrome measurement and chrome colour rule, grouped by
/// surface, so matching the reference design is a one-line change per value.
/// Values marked "measured" come from Superlogical frames (1 Oct 2026, traffic
/// lights 20 pt apart as the scale); the rest await the visual spec.
enum Chrome {
    enum Titlebar {
        /// Measured: window top to the hairline under the tab strip.
        static let height: CGFloat = 36
        /// Measured: from the window's left edge to the session button.
        static let trafficLightWidth: CGFloat = 78
        static let spacing: CGFloat = 10
        static let trailingPadding: CGFloat = 12
        static let newTabButton = CGSize(width: 24, height: 24)
        /// The only separation between titlebar and terminal.
        static let separatorWidth: CGFloat = 1
    }

    enum SessionButton {
        static let symbol = "laptopcomputer"
        static let remoteSymbol = "network"
        static let symbolSize: CGFloat = 15
        static let spacing: CGFloat = 8
        static let titleSize: CGFloat = 13
        static let titleOpacity = 0.75
        static let subtitleSize: CGFloat = 11
        static let subtitleOpacity = 0.45
        static let horizontalPadding: CGFloat = 4
    }

    enum Tab {
        /// Measured: selected capsule width and height.
        static let width: CGFloat = 191
        static let height: CGFloat = 23
        static let spacing: CGFloat = 2
        static let horizontalPadding: CGFloat = 7
        static let contentSpacing: CGFloat = 7
        static let titleSize: CGFloat = 13
        /// Width of the fade that ends a long title instead of an ellipsis.
        static let titleFade: CGFloat = 18
        static let closeSymbolSize: CGFloat = 8
        static let closeButton = CGSize(width: 12, height: 18)
        static let borderWidth: CGFloat = 0.5
        static let dividerHeight: CGFloat = 14
        static let dividerOpacity = 0.12
        static let selectedFillLight = Color.white.opacity(0.7)
        static let selectedFillDarkOpacity = 0.09
    }

    enum Badge {
        /// Measured: the rounded-square badge in a tab.
        static let size = CGSize(width: 19, height: 19)
        static let cornerRadius: CGFloat = 5
        static let glyphSize: CGFloat = 10
        /// The monochrome glyph used in pane title rows.
        static let plainGlyphSize: CGFloat = 14
        static let borderOpacity = 0.18
        /// Offset of the card behind a badge for a tab with several panes.
        static let stackOffset = CGSize(width: 3, height: -3)
        static let stackOpacity = 0.45
    }

    enum Pane {
        static let comfortablePadding: CGFloat = 9
        static let comfortableGap: CGFloat = 8
        static let compactGap: CGFloat = 1
        static let comfortableRadius: CGFloat = 9
        static let previewRadius: CGFloat = 5
        static let previewGap: CGFloat = 3
        static let dividerHitWidth: CGFloat = 6
        static let focusedBorderOpacity = 0.13
        static let unfocusedBorderOpacity = 0.065
        static let borderWidth: CGFloat = 0.5
    }

    enum PaneTitle {
        /// Measured: hairline to first cell is 31 pt, less the terminal's 8 pt inset.
        static let height: CGFloat = 23
        static let horizontalPadding: CGFloat = 8
        static let spacing: CGFloat = 6
        static let titleSize: CGFloat = 13
        static let titleOpacity = 0.6
        static let controlSymbolSize: CGFloat = 9
        static let control = CGSize(width: 19, height: 20)
        static let controlOpacity = 0.55
        static let parkedSymbolSize: CGFloat = 9
    }

    enum Sidebar {
        static let width: CGFloat = 238
        static let padding: CGFloat = 10
        static let hostSpacing: CGFloat = 18
        static let sessionSpacing: CGFloat = 13
        static let headerSize: CGFloat = 11
        static let filterSize: CGFloat = 12
    }

    enum Palette {
        static let width: CGFloat = 360
        static let sessionsWidth: CGFloat = 280
        static let rowHeight: CGFloat = 29
        static let rowSpacing: CGFloat = 3
        static let cornerRadius: CGFloat = 13
        static let rowRadius: CGFloat = 6
        static let topOffset: CGFloat = 76
        /// The session picker drops from the session button.
        static let sessionsOffset = CGSize(width: 86, height: 43)
        static let maximumHeight: CGFloat = 380
        static let directoryMaximumHeight: CGFloat = 440
        static let titleSize: CGFloat = 12
        static let detailSize: CGFloat = 10
        static let shadowRadius: CGFloat = 20
    }

    enum Search {
        static let width: CGFloat = 330
        static let height: CGFloat = 38
        static let compactHeight: CGFloat = 61
        static let compactThreshold: CGFloat = 280
        static let cornerRadius: CGFloat = 10
        static let fontSize: CGFloat = 11
    }

    enum Overview {
        static let padding: CGFloat = 12
        static let cardWidth: CGFloat = 245
        static let compactPreviewHeight: CGFloat = 112
        static let expandedPreviewHeight: CGFloat = 165
        static let cardRadius: CGFloat = 12
    }

    enum Notice {
        static let fontSize: CGFloat = 12
        static let padding: CGFloat = 10
        static let margin: CGFloat = 16
    }
}

extension TerminalTheme {
    /// The window's chrome colour for an interface style.
    @ViewBuilder
    func chromeBackground(_ style: InterfaceStyle) -> some View {
        switch style {
        case .modern: Rectangle().fill(.ultraThinMaterial)
        case .system: Color(nsColor: .windowBackgroundColor)
        // Measured: the titlebar is the terminal's own surface.
        case .themed: color
        case .blended: Rectangle().fill(.ultraThinMaterial).overlay(color.opacity(0.65))
        }
    }

    var selectedTabFill: Color { isLight ? Chrome.Tab.selectedFillLight : text.opacity(Chrome.Tab.selectedFillDarkOpacity) }
}

extension ProcessBadge {
    fileprivate var glyph: Glyph {
        switch self {
        case .shell: .text(">_", italic: false)
        case .neovim: .text("N", italic: false)
        case .vim: .text("V", italic: false)
        case .claude: .symbol("asterisk")
        case .codex: .symbol("chevron.left.forwardslash.chevron.right")
        case .fx: .text("fx", italic: true)
        case .git: .symbol("point.3.connected.trianglepath.dotted")
        case .ssh: .symbol("network")
        case .monitor: .symbol("chart.bar.xaxis")
        case .python: .text("py", italic: false)
        case .node: .text("js", italic: false)
        case .generic(let name): .text(String(name.prefix(1)).uppercased(), italic: false)
        }
    }

    fileprivate var fill: Color {
        switch self {
        case .neovim: Color(red: 0.16, green: 0.55, blue: 0.56)
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .git: Color(red: 0.84, green: 0.36, blue: 0.24)
        case .python: Color(red: 0.23, green: 0.42, blue: 0.62)
        case .node: Color(red: 0.34, green: 0.55, blue: 0.27)
        default: Color(white: 0.12)
        }
    }

    fileprivate var ink: Color {
        switch self {
        case .shell, .monitor, .ssh, .generic: Color(red: 0.55, green: 0.91, blue: 0.68)
        default: .white
        }
    }

    fileprivate enum Glyph {
        case text(String, italic: Bool)
        case symbol(String)
    }
}

/// A tab's coloured badge tile.
struct ProcessBadgeView: View {
    let badge: ProcessBadge
    /// Several panes: draws a card behind the badge.
    var stacked = false

    var body: some View {
        ZStack {
            if stacked {
                RoundedRectangle(cornerRadius: Chrome.Badge.cornerRadius)
                    .fill(.gray.opacity(Chrome.Badge.stackOpacity))
                    .offset(Chrome.Badge.stackOffset)
            }
            RoundedRectangle(cornerRadius: Chrome.Badge.cornerRadius)
                .fill(badge.fill.gradient)
                .overlay(RoundedRectangle(cornerRadius: Chrome.Badge.cornerRadius).stroke(.white.opacity(Chrome.Badge.borderOpacity), lineWidth: 0.5))
            ProcessGlyph(badge: badge, size: Chrome.Badge.glyphSize).foregroundStyle(badge.ink)
        }
        .frame(width: Chrome.Badge.size.width, height: Chrome.Badge.size.height)
        .accessibilityHidden(true)
    }
}

/// The badge's glyph alone, drawn in the current foreground style, as pane
/// title rows show it.
struct ProcessGlyph: View {
    let badge: ProcessBadge
    var size: CGFloat = Chrome.Badge.plainGlyphSize

    var body: some View {
        switch badge.glyph {
        case .text(let text, let italic):
            Text(text).font(.system(size: size, weight: .bold, design: .monospaced)).italic(italic)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size, weight: .semibold))
        }
    }
}
