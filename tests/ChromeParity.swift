import AppKit
import SwiftUI

// Renders the real workspace window chrome offscreen, once per appearance
// variant, so it can be compared with the reference design frames. It is a
// review tool, not a pixel assertion: the Metal terminal draws nothing here.

/// Reports itself key so the traffic lights draw in colour, as in the
/// reference frames, while staying far off screen and invisible.
@MainActor
private final class ParityWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@main
struct ChromeParity {
    static func main() {
        let domain = "dev.illogical.parity"
        Check.that(Bundle.main.bundleIdentifier == domain, "The renderer needs its private defaults domain")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/parity", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let peer = ServicePeer(name: "parity", state: Scene.state)
        peer.respond { request in
            guard request.method == "directory.list" else { return nil }
            return [Scene.directoryReply(request.id)]
        }
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        let window = ParityWindow(contentRect: NSRect(x: -20000, y: -20000, width: 880, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ContentView())
        defer { window.contentView = nil }

        Check.eventually("The workspace must show the fixture session", timeout: 5) {
            WorkspaceRegistry.shared.models.first?.activeDeck != nil
        }
        let model = WorkspaceRegistry.shared.models[0]
        let preferences = Preferences.shared

        func shoot(_ name: String, _ configure: () -> Void) {
            preferences.themeName = TerminalTheme.merinoDark.name
            preferences.density = .compact
            preferences.showPaneTitles = false
            preferences.verticalTabs = false
            preferences.interfaceStyle = .themed
            model.palette = nil
            for block in Array(model.searches.keys) { model.closeSearch(block) }
            model.choose(deck: "t1", session: "electric-lagoon", host: HostProfile.local.id)
            configure()
            Check.settle(0.4)
            render(window, to: output.appendingPathComponent(name + ".png"))
        }

        shoot("titlebar-dark") {}
        shoot("single-pane-titles") {
            model.choose(deck: "t5", session: "bold-dune", host: HostProfile.local.id)
            preferences.showPaneTitles = true
        }
        shoot("titlebar-light") { preferences.themeName = TerminalTheme.merinoLight.name }
        shoot("panes-compact-titles") { preferences.showPaneTitles = true }
        shoot("panes-comfortable") { preferences.density = .comfortable }
        shoot("panes-comfortable-titles") { preferences.density = .comfortable; preferences.showPaneTitles = true }
        shoot("panes-compact-light-titles") { preferences.themeName = TerminalTheme.merinoLight.name; preferences.showPaneTitles = true }
        for style in InterfaceStyle.allCases {
            shoot("style-\(style.rawValue.lowercased())") { preferences.interfaceStyle = style }
        }
        shoot("palette-commands") { model.palette = .commands }
        shoot("palette-themes") { model.palette = .themes }
        shoot("palette-themes-light") { preferences.themeName = TerminalTheme.merinoLight.name; model.palette = .themes }
        shoot("palette-interface-style") { model.palette = .interfaceStyle }
        shoot("palette-sessions") { model.palette = .sessions }
        shoot("palette-directory") { model.showDirectory() }
        shoot("search") { model.find() }
        shoot("vertical-tabs") { preferences.verticalTabs = true }
        shoot("vertical-tabs-light") { preferences.verticalTabs = true; preferences.themeName = TerminalTheme.merinoLight.name }
        shoot("overview") { model.togglePeek(2) }
        model.togglePeek(2)
        print("Parity renders written to \(output.path)")
    }

    /// Draws the whole window, titlebar buttons included, at 2x.
    static func render(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                            pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The fixture workspace: the tabs and titles seen in the reference frames.
private enum Scene {
    static let blocks: [(String, String)] = [
        ("b1", "~/apps/replay-web - fish"),
        ("b2", "~/apps/replay-web: nvim apps/license-lookup-app/src/types/License.ts - nvim"),
        ("b3", "✳ Claude Code"),
        ("b4", "fx Simplify PR Diff and Remove Dead Code"),
        ("b5", "~: lg - lg"),
        ("b6", "~/apps/replay-web - fish"),
        ("b7", "~ - fish"),
    ]

    static var state: String {
        let tabs = [
            Fixture.tab("t1", Fixture.split("s1", "horizontal", Fixture.leaf("b1"), Fixture.leaf("b2"))),
            Fixture.tab("t2", Fixture.leaf("b3")),
            Fixture.tab("t3", Fixture.leaf("b4")),
            Fixture.tab("t4", Fixture.leaf("b5")),
        ]
        let sessions = [
            Fixture.session("electric-lagoon", tabs),
            Fixture.session("bold-dune", [Fixture.tab("t5", Fixture.leaf("b6"))]),
            Fixture.session("ping-vercel", [Fixture.tab("t6", Fixture.leaf("b7"))]),
        ]
        let blockJSON = blocks.map { Fixture.block($0.0, title: $0.1, cwd: "/Users/alasdair/Apps/replay-web") }
        return #"{"revision":1,"sessions":[\#(sessions.joined(separator: ","))],"blocks":[\#(blockJSON.joined(separator: ","))],"clients":1}"#
    }

    static func directoryReply(_ id: String) -> String {
        let names = ["apps", "docs", "node_modules", "packages", "scripts", "src"]
        let entries = names.map { #"{"name":"\#($0)","path":"/Users/alasdair/Apps/replay-web/\#($0)"}"# }
        return #"{"type":"reply","id":"\#(id)","path":"/Users/alasdair/Apps/replay-web","entries":[\#(entries.joined(separator: ","))]}"#
    }
}
