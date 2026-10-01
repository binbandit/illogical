import AppKit
import SwiftUI

/// Every window-chrome measurement, grouped by surface, so matching the
/// reference design is a one-line change per value. All values are points
/// measured on 2x captures of the 26/30 Sep reference build unless noted.
/// Colours live in `ChromeColors`, which derives them from the settings.
enum Chrome {
    /// The UI typeface: the system font (SF Pro) at every size.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    enum Titlebar {
        /// Window top to the separator under the tab strip.
        static let height: CGFloat = 42
        /// With vertical tabs the traffic lights sit in the sidebar's top row.
        static let sidebarHeight: CGFloat = 50
        static let separator: CGFloat = 1
        /// Close button centre from the window's top-left corner; the three
        /// buttons are this far apart, centre to centre.
        static let trafficLightX: CGFloat = 24
        static let trafficLightSpacing: CGFloat = 23
        /// Zoom button's right edge (70 + 7) plus 26: where the session icon starts.
        static let sessionLeading: CGFloat = 103
        /// Leading space when full screen hides the traffic lights.
        static let fullScreenLeading: CGFloat = 16
        static let sessionToTabs: CGFloat = 22
        /// Room inside the tab strip's scroll clip so the selected capsule's
        /// rounded edge is never cut into a hard vertical line.
        static let stripClipSlack: CGFloat = 2
        /// Minimum gap between an overflowing tab strip and the `+` button.
        static let tabsToNewTab: CGFloat = 8
        static let newTabSymbolSize: CGFloat = 11
        static let newTabButton: CGFloat = 26
        /// From the window's right edge to the `+` centre.
        static let newTabCentreInset: CGFloat = 26
    }

    enum SessionButton {
        static let localSymbol = "laptopcomputer"
        static let remoteSymbol = "globe"
        static let symbolSize: CGFloat = 13
        static let symbolWidth: CGFloat = 16
        static let symbolTextSpacing: CGFloat = 10.5
        static let nameFont = Chrome.font(12, .semibold)
        static let subtitleFont = Chrome.font(10)
        /// Baselines 20 and 31 from the window top.
        static let lineSpacing: CGFloat = -1.5
    }

    enum Tab {
        /// Every tab has this fixed slot, selected or not.
        static let width: CGFloat = 220
        static let height: CGFloat = 28
        static let leadingPadding: CGFloat = 8
        static let badgeTitleSpacing: CGFloat = 8
        static let titleFont = Chrome.font(13)
        /// Long titles fade out over this width instead of an ellipsis...
        static let titleFade: CGFloat = 16
        /// ...ending this far before the tab's edge.
        static let titleTrailingInset: CGFloat = 12
        static let closeSymbolSize: CGFloat = 8.5
        static let closeButton: CGFloat = 18
        /// Close button centre from the tab's trailing edge.
        static let closeCentreInset: CGFloat = 16
        /// The title's fade moves left to make room for the close button.
        static let hoverTitleTrailingInset: CGFloat = 28
        static let strokeWidth: CGFloat = 1
        static let divider = CGSize(width: 1, height: 20)
        static let hoverAnimation: Animation = .easeOut(duration: 0.12)
    }

    enum Badge {
        /// The rounded card in a tab.
        static let size = CGSize(width: 21, height: 17)
        static let cornerRadius: CGFloat = 4.5
        static let ringWidth: CGFloat = 0.5
        /// Glyph box inside a tab badge; pane title rows draw it bare.
        static let glyphSize = CGSize(width: 10, height: 8)
        static let plainGlyphSize = CGSize(width: 12, height: 10)
        /// Composer: other processes of a tab peek out to the right of the
        /// front badge, each smaller and turned, showing part of its glyph.
        static let stackLimit = 2
        static let stackScale: CGFloat = 0.85
        static let stackRotation: Angle = .degrees(5)
        static let stackReveal: CGFloat = 5
        static let stackGlyphOffset: CGFloat = 0.3
        /// Sidebar rows use a slightly larger badge.
        static let sidebarSize = CGSize(width: 22, height: 18)
    }

    enum Pane {
        /// Comfortable islands: inset from the window, gap, radius and stroke.
        static let comfortableInsets = EdgeInsets(top: 2, leading: 7, bottom: 7, trailing: 7)
        static let comfortableGap: CGFloat = 8
        static let comfortableRadius: CGFloat = 10
        static let strokeWidth: CGFloat = 1
        /// Compact panes are split by a hairline.
        static let compactGap: CGFloat = 1
        static let dividerHitWidth: CGFloat = 6
        static let previewRadius: CGFloat = 5
        static let previewGap: CGFloat = 3

        /// Space between the window and the panes: none for compact panes
        /// under a titlebar, island margins otherwise.
        static func areaInsets(density: Density, verticalTabs: Bool) -> EdgeInsets {
            if verticalTabs {
                return EdgeInsets(top: Sidebar.islandInset, leading: 0, bottom: Sidebar.islandInset, trailing: Sidebar.islandInset)
            }
            return density == .comfortable ? comfortableInsets : EdgeInsets()
        }
    }

    enum PaneTitle {
        static let height: CGFloat = 32
        /// The first terminal row starts 36 below the pane top, so the row
        /// overlaps half of the terminal's own 8 pt padding.
        static let terminalOverlap: CGFloat = 4
        static let leadingInset: CGFloat = 12.5
        static let glyphTitleSpacing: CGFloat = 6
        static let titleFont = Chrome.font(12, .medium)
        static let controlSymbolSize: CGFloat = 11
        /// Control centres are this far apart; the last is this far from the edge.
        static let controlPitch: CGFloat = 24
        static let lastControlCentreInset: CGFloat = 17.5
    }

    enum Sidebar {
        /// Window edge to the terminal island.
        static let width: CGFloat = 240
        static let islandInset: CGFloat = 8
        static let islandRadius: CGFloat = 10
        static let toggleSymbolSize: CGFloat = 15
        /// Sidebar toggle centre, right of the zoom button's centre.
        static let toggleOffset: CGFloat = 35.5
        /// `+` centre from the sidebar's trailing edge.
        static let newTabCentreInset: CGFloat = 24
        static let sessionFont = Chrome.font(11, .semibold)
        static let sessionLeading: CGFloat = 22.5
        static let sessionHeight: CGFloat = 34
        static let rowPitch: CGFloat = 34
        static let rowInset: CGFloat = 9.5
        static let rowHeight: CGFloat = 32.5
        static let rowBadgeLeading: CGFloat = 9.5
        static let rowBadgeTitleSpacing: CGFloat = 8.5
        static let rowFont = Chrome.font(13)
        static let selectedStrokeWidth: CGFloat = 0.5
        static let selectedShadowRadius: CGFloat = 1.5
        static let filterSize = CGSize(width: 165, height: 30)
        static let filterLeading: CGFloat = 8
        /// Filter capsule centre from the window's bottom edge.
        static let filterCentreInset: CGFloat = 23
        static let filterFont = Chrome.font(13)
        static let filterPadding: CGFloat = 8
        static let filterSpacing: CGFloat = 6
        static let rowMatchFont = Chrome.font(13, .semibold)
        static let footerSymbolSize: CGFloat = 16
        /// Footer button centres from the sidebar's trailing edge.
        static let footerCentreInsets: (newSession: CGFloat, addHost: CGFloat) = (53.5, 23)
    }

    enum Palette {
        static let width: CGFloat = 331
        static let cornerRadius: CGFloat = 18
        /// Panel top below the window top, centred horizontally.
        static let topOffset: CGFloat = 76
        static let maximumHeight: CGFloat = 498
        /// Kept free around the panel in small windows.
        static let windowMargin: CGFloat = 16
        static let fieldInset: CGFloat = 8
        static let fieldHeight: CGFloat = 30
        static let fieldRadius: CGFloat = 9
        static let fieldSymbolSize: CGFloat = 13
        static let fieldSymbolLeading: CGFloat = 10
        static let fieldTextLeading: CGFloat = 27
        static let clearSymbolSize: CGFloat = 15
        static let fieldToList: CGFloat = 6
        static let chipHeight: CGFloat = 20
        static let chipRadius: CGFloat = 5
        static let chipPadding: CGFloat = 7.5
        static let chipInset: CGFloat = 5
        static let chipFont = Chrome.font(13, .semibold)
        static let chipPlaceholderSpacing: CGFloat = 6.5
        static let rowPitch: CGFloat = 28
        static let rowHighlight: CGFloat = 26
        static let rowRadius: CGFloat = 8
        /// Highlight inset from the panel's edges.
        static let rowInset: CGFloat = 6
        static let rowTextLeading: CGFloat = 12
        /// Rows with an icon start their title this far after the icon's left edge.
        static let rowIconAdvance: CGFloat = 18.5
        static let rowIconSize: CGFloat = 15
        static let rowTrailing: CGFloat = 10
        static let rowFont = Chrome.font(13)
        static let sectionFont = Chrome.font(12, .semibold)
        static let chevronSize: CGFloat = 9
        static let valueChevronSpacing: CGFloat = 8
        static let selectedDetailOpacity = 0.75
        static let rimWidth: CGFloat = 0.5
        static let innerRimWidth: CGFloat = 1
        static let shadowRadius: CGFloat = 15
        static let shadowY: CGFloat = 3
    }

    enum SessionPicker {
        static let width: CGFloat = 195
        static let cornerRadius: CGFloat = 14
        /// Panel left edge relative to the session icon's left edge.
        static let iconOffset: CGFloat = -14
        static let fieldInset: CGFloat = 6
        static let fieldHeight: CGFloat = 26
        static let fieldSymbol = "line.3.horizontal.decrease.circle"
        /// Field text from the panel's left edge.
        static let fieldTextLeading: CGFloat = 30.5
        static let rowPitch: CGFloat = 26
        static let rowHighlight: CGFloat = 24
        static let rowRadius: CGFloat = 7
        /// Icon column (checkmark, host, footer icons) and text column.
        static let iconCentre: CGFloat = 19
        static let textLeading: CGFloat = 38.5
        static let separatorInset: CGFloat = 12
        static let separatorSpacing: CGFloat = 6
    }

    enum Search {
        static let size = CGSize(width: 300, height: 38)
        /// From the pane's right edge and top.
        static let trailingInset: CGFloat = 8
        static let topInset: CGFloat = 6
        static let cornerRadius: CGFloat = 10
        static let strokeWidth: CGFloat = 1
        static let fieldSize: CGFloat = 13
        static let textLeading: CGFloat = 12
        static let countFont = Chrome.font(13).monospacedDigit()
        static let countToDivider: CGFloat = 10
        static let divider = CGSize(width: 1, height: 18)
        static let chevronSize: CGFloat = 10
        static let closeSize: CGFloat = 9.5
        static let controlPitch: CGFloat = 26
        static let lastControlCentreInset: CGFloat = 18
        /// The pane dims while a query is typed, fading in this fast.
        static let paneDim = 0.5
        static let dimAnimation: Animation = .easeOut(duration: 0.25)
    }

    enum Overview {
        static let columns = 2
        static let cardSize = CGSize(width: 302, height: 168)
        static let gap: CGFloat = 15
        static let labelFont = Chrome.font(13, .semibold)
        static let labelSpacing: CGFloat = 21
        static let cardRadius: CGFloat = 12
        static let cardHeader: CGFloat = 32
        static let cardTitleFont = Chrome.font(14)
        static let previewInset: CGFloat = 6
        static let peekCardSize = CGSize(width: 190, height: 130)
        static let peekCardTitleFont = Chrome.font(13)
        static let padding: CGFloat = 12
        static let closeSymbolSize: CGFloat = 9
    }

    enum EmptyState {
        static let symbolFont = Chrome.font(38, .ultraLight)
        static let messageFont = Chrome.font(15)
    }

    enum Notice {
        static let font = Chrome.font(12)
        static let padding: CGFloat = 10
        static let margin: CGFloat = 16
    }
}

/// The chrome's colour roles for a theme. Every role is the theme's
/// foreground, or black or white, at an alpha over the surface beneath it,
/// which is how the reference design's samples fit across themes.
struct ChromeColors: Equatable {
    let theme: TerminalTheme
    var colorspace: TerminalColorspace = .srgb

    var isLight: Bool { theme.isLight }

    func color(_ hex: UInt32) -> Color { Color(hex: hex, colorspace: colorspace) }
    func text(_ opacity: Double) -> Color { color(theme.foreground).opacity(opacity) }
    private func ink(_ opacity: Double) -> Color { isLight ? Color.black.opacity(opacity) : text(opacity) }

    // MARK: Surfaces

    /// The terminal's own surface.
    var terminal: Color { color(theme.background) }
    /// Titlebar and the space around islands: darker than the terminal in
    /// dark themes (measured 0.82 of it), a hair lighter in light ones.
    var titlebarHex: UInt32 { isLight ? theme.background.mixed(with: 0xffffff, by: 0.3) : theme.background.mixed(with: 0, by: 0.18) }
    var titlebar: Color { color(titlebarHex) }
    /// Black laid over an unfocused pane, so its surface matches the titlebar
    /// in dark themes and sits a touch below the terminal in light ones.
    var unfocusedShade: Double { isLight ? 0.025 : 0.18 }
    var unfocusedPane: Color { color(theme.background.mixed(with: 0, by: unfocusedShade)) }

    // MARK: Text

    var primary: Color { text(isLight ? 1 : 0.97) }
    var secondary: Color { text(isLight ? 0.75 : 0.7) }
    var tertiary: Color { text(isLight ? 0.5 : 0.45) }
    /// Pane title controls.
    var control: Color { text(0.3) }
    var disabledControl: Color { text(0.1) }

    // MARK: Lines and accents

    /// Titlebar separator and compact split dividers.
    var hairline: Color { ink(0.07) }
    var tabDivider: Color { text(isLight ? 0.25 : 0.17) }
    var selectedTabFill: Color { isLight ? .white : text(0.06) }
    var selectedTabStroke: Color { ink(isLight ? 0.09 : 0.12) }
    var hoveredTabFill: Color { ink(isLight ? 0.04 : 0.07) }
    var islandStroke: Color { ink(0.1) }
    var focusedIslandStroke: Color { color(theme.chromeAccent).opacity(0.55) }
    /// The theme's accent as a fill under white text, darkened only when a
    /// theme's accent is too light to carry it.
    var accentFill: Color { color(theme.chromeAccent.mixed(with: 0, by: Self.darkening(theme.chromeAccent, toLuminance: 0.3))) }
    var accentText: Color { color(theme.chromeAccent) }

    // MARK: Panels

    /// Palette panels: the terminal lifted toward white.
    var panel: Color { color(theme.background.mixed(with: 0xffffff, by: isLight ? 0.7 : 0.045)) }
    var panelField: Color { ink(isLight ? 0.05 : 0.08) }
    var sunkenField: Color { Color.black.opacity(isLight ? 0.04 : 0.18) }
    var panelSeparator: Color { ink(0.1) }
    var panelRim: Color { Color.black.opacity(isLight ? 0.18 : 0.5) }
    var panelInnerRim: Color { Color.white.opacity(isLight ? 0.6 : 0.1) }
    var panelShadow: Color { Color.black.opacity(isLight ? 0.15 : 0.25) }
    var chipFill: Color { ink(isLight ? 0.1 : 0.16) }
    /// Search bar: opaque, the terminal lifted toward its foreground.
    var searchFill: Color { color(theme.background.mixed(with: theme.foreground, by: 0.08)) }
    var searchStroke: Color { ink(0.16) }
    var cardFill: Color { ink(isLight ? 0.035 : 0.05) }
    var filterFill: Color { ink(0.06) }
    var hoveredCardFill: Color { ink(isLight ? 0.06 : 0.09) }

    /// How far toward black `hex` must move for its relative luminance to
    /// fall to `target`, keeping white text on it legible.
    private static func darkening(_ hex: UInt32, toLuminance target: Double) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        let (red, green, blue) = hex.rgbComponents
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        guard luminance > target else { return 0 }
        return 1 - pow(target / luminance, 1 / 2.2)
    }

    /// The window's surface for an interface style.
    @ViewBuilder
    func chromeBackground(_ style: InterfaceStyle) -> some View {
        switch style {
        case .modern: Rectangle().fill(.ultraThinMaterial)
        case .system: Color(nsColor: .windowBackgroundColor)
        case .themed: titlebar
        case .blended: Rectangle().fill(.ultraThinMaterial).overlay(titlebar.opacity(0.65))
        }
    }

    /// A floating panel's surface: opaque for Themed, translucent otherwise.
    @ViewBuilder
    func panelBackground(_ style: InterfaceStyle) -> some View {
        switch style {
        case .modern, .blended: Rectangle().fill(.regularMaterial).overlay(panel.opacity(0.5))
        case .system: Color(nsColor: .windowBackgroundColor)
        case .themed: panel
        }
    }
}

extension Preferences {
    /// The window chrome's colours for the current theme and colour space.
    var colors: ChromeColors { ChromeColors(theme: theme, colorspace: fontOptions.colorspace) }
}

extension View {
    /// The floating-panel look: surface, a dark outer rim with a light inner
    /// one, and a soft shadow.
    func chromePanel(_ colors: ChromeColors, style: InterfaceStyle, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background { colors.panelBackground(style).clipShape(shape) }
            .overlay { shape.inset(by: Chrome.Palette.innerRimWidth / 2).stroke(colors.panelInnerRim, lineWidth: Chrome.Palette.innerRimWidth) }
            .overlay { shape.stroke(colors.panelRim, lineWidth: Chrome.Palette.rimWidth) }
            .shadow(color: colors.panelShadow, radius: Chrome.Palette.shadowRadius, y: Chrome.Palette.shadowY)
    }
}

extension Color {
    /// A theme colour in the terminal's colour space. Display P3 terminals
    /// (Ghostty's `window-colorspace`) read the same values in P3, so the
    /// chrome next to them does too and matches exactly.
    nonisolated init(hex: UInt32, colorspace: TerminalColorspace) {
        let (red, green, blue) = hex.rgbComponents
        self.init(colorspace == .displayP3 ? .displayP3 : .sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

extension NSColor {
    nonisolated convenience init(hex: UInt32, colorspace: TerminalColorspace) {
        let (red, green, blue) = hex.rgbComponents
        switch colorspace {
        case .srgb: self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
        case .displayP3: self.init(displayP3Red: red, green: green, blue: blue, alpha: 1)
        }
    }
}
