import AppKit
import SwiftUI

@MainActor
private final class HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

@main
struct TerminalSurfaceInputHostedTests {
    @MainActor
    static func main() {
        // Queued events are only routed to a process that may own windows.
        NSApplication.shared.setActivationPolicy(.accessory)
        let engine = TerminalEngine(blockID: "hosted-keys", theme: .merinoDark)
        var output = Data()
        engine.onInput = { output.append($0) }
        var exitCommands = 0
        // Mirrors the workspace: the terminal sits under SwiftUI ancestors
        // that own Escape (`onExitCommand`) and keyboard focus navigation.
        let root = VStack(spacing: 0) {
            Text("pane title")
            TerminalSurface(engine: engine, fontSize: 13, fontName: "Menlo", focused: true, focusToken: UUID())
        }
        .onExitCommand { exitCommands += 1 }
        let window = HostWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        // AppKit only routes queued events to ordered-in windows. Keep it far
        // off screen and never activate the test process.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        guard let surface = window.firstResponder as? NativeTerminalView else {
            fatalError("The focused hosted terminal must become first responder, got \(String(describing: window.firstResponder))")
        }

        // Post through the application queue so dispatch follows the real
        // path: event monitors, NSApplication, the window, then responders.
        func press(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> Data {
            output.removeAll()
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: keyCode)!
            NSApp.postEvent(event, atStart: false)
            // The queue can hand the event back on a later pass; wait for it.
            let deadline = Date(timeIntervalSinceNow: 2)
            while let next = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                NSApp.sendEvent(next)
                if next.type == .keyDown, next.timestamp == event.timestamp { break }
            }
            return output
        }
        func expect(_ actual: Data, _ expected: String, _ name: String) {
            precondition(actual == Data(expected.utf8), "\(name): got \(actual as NSData)")
        }

        expect(press(53, "\u{1b}"), "\u{1b}", "Escape reaches the PTY under an onExitCommand ancestor")
        precondition(exitCommands == 0, "The focused terminal owns Escape")
        expect(press(48, "\t"), "\t", "Tab is terminal input, not focus navigation")
        expect(press(48, "\u{19}", .shift), "\u{1b}[Z", "Shift-Tab is terminal input, not reverse focus navigation")
        expect(press(36, "\r"), "\r", "Return")
        expect(press(51, "\u{7f}"), "\u{7f}", "Backspace")
        for (code, character, final) in [(UInt16(126), "\u{f700}", "A"), (125, "\u{f701}", "B"), (124, "\u{f703}", "C"), (123, "\u{f702}", "D")] {
            expect(press(code, character, [.numericPad, .function]), "\u{1b}[\(final)", "Arrow \(final)")
        }
        expect(press(0, "a"), "a", "Plain text")
        precondition(window.firstResponder === surface, "Keys must not move focus away from the terminal")
        window.orderOut(nil)
        window.contentView = nil
        print("Hosted keys: Escape, Tab, Shift-Tab, Return, Backspace and arrows reach a terminal under SwiftUI onExitCommand.")
    }
}
