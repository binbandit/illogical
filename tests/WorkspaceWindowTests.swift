import AppKit
import SwiftUI

// Hosts the production workspace view in an invisible window wired to a
// scripted service, then drives it with real AppKit events.
@MainActor
private final class TestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

@main
struct WorkspaceWindowTests {
    typealias F = Fixture

    static func main() {
        let domain = "dev.illogical.window-tests"
        Check.that(Bundle.main.bundleIdentifier == domain, "The test needs its private defaults domain")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        // An accessory app never activates or takes focus from the desktop.
        NSApplication.shared.setActivationPolicy(.accessory)

        let peer = ServicePeer(name: "window", state: F.state(1, sessions: [F.session("s", [F.tab("t", F.leaf("b"))])], blocks: ["b"]))
        setenv("ILLOGICAL_SOCKET", peer.path, 1)
        // Transparent, click-through and far off screen: never visible.
        let window = TestWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ContentView())
        defer { window.contentView = nil }

        Check.eventually("The workspace must mount a terminal for the restored pane") { terminals(in: window).count == 1 }
        let terminal = terminals(in: window)[0]
        Check.eventually("The terminal must take keyboard focus on launch") { window.firstResponder === terminal }

        func writes() -> [Data] { peer.requests("block.write").compactMap(\.data) }
        let before = writes().count
        let escape = key(window, code: 53, "\u{1b}")
        // NSApplication offers every key-down to the window as a key
        // equivalent before the first responder sees it.
        Check.that(!window.performKeyEquivalent(with: escape), "A SwiftUI key equivalent swallowed Escape")
        window.sendEvent(escape)
        Check.eventually("Escape must reach the shell") { writes().count > before }
        Check.that(writes().last == Data([0x1b]), "Escape wrote \(writes().last.map { Array($0) } ?? [])")

        // AppKit puts the traffic lights back at their defaults whenever it
        // lays the titlebar out again, as a new title or a resize does.
        let centre = NSPoint(x: Chrome.Titlebar.trafficLightX, y: Chrome.Titlebar.height / 2)
        Check.eventually("The traffic lights must centre in the titlebar") { trafficLightsCentred(in: window, at: centre) }
        window.title = "nvim"
        window.setContentSize(NSSize(width: 960, height: 640))
        Check.settle(0.2)
        Check.that(trafficLightsCentred(in: window, at: centre), "The traffic lights moved when AppKit relaid the titlebar out")
        print("Workspace window: launch focus, Escape delivery and traffic light placement passed.")
    }

    static func terminals(in window: NSWindow) -> [NativeTerminalView] {
        func collect(_ view: NSView) -> [NativeTerminalView] {
            (view as? NativeTerminalView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return window.contentView.map(collect) ?? []
    }

    /// Whether the close button's centre, measured from the window's top-left, is `centre`.
    static func trafficLightsCentred(in window: NSWindow, at centre: NSPoint) -> Bool {
        guard let close = window.standardWindowButton(.closeButton), let superview = close.superview,
              let frameView = window.contentView?.superview else { return false }
        let frame = frameView.convert(close.frame, from: superview)
        return abs(frame.midX - centre.x) <= 0.5 && abs(frameView.bounds.height - frame.midY - centre.y) <= 0.5
    }

    static func key(_ window: NSWindow, code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                         isARepeat: false, keyCode: code)!
    }
}
