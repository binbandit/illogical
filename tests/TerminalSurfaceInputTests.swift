import AppKit

@main
struct TerminalSurfaceInputTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let engine = TerminalEngine(blockID: "surface-keyboard-test", theme: .merinoDark)
        let surface = NativeTerminalView(engine: engine)
        defer { surface.detach() }
        var output = Data()
        engine.onInput = { output.append($0) }
        let kitty = Data("\u{1b}[>31u".utf8)
        kitty.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, kitty.count) }
        func event(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 1,
                             windowNumber: 0, context: nil, characters: modifiers.contains(.control) ? "\u{3}" : "c",
                             charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        }
        surface.keyUp(with: event(.keyUp, .command))
        precondition(output.isEmpty, "A menu-consumed Command-C must not emit an unmatched Kitty release")
        surface.keyDown(with: event(.keyDown, .control))
        guard output == Data("\u{1b}[99;5u".utf8) else {
            fputs("Unexpected Kitty Control-C: \(output as NSData)\n", stderr); exit(1)
        }
        output.removeAll()
        surface.keyUp(with: event(.keyUp, .control))
        precondition(output == Data("\u{1b}[99;5:3u".utf8), "A forwarded key press has a matching release")
        output.removeAll()
        surface.keyUp(with: event(.keyUp, .control))
        precondition(output.isEmpty, "Each key release is forwarded only once")

        surface.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(surface.hasMarkedText() && surface.selectedRange().location == 1)
        surface.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(output == Data("日本語".utf8) && !surface.hasMarkedText(), "IME commits its Unicode text without key encoding")
        output.removeAll()
        surface.keyUp(with: event(.keyUp, []))
        precondition(output.isEmpty, "IME composition does not emit unmatched physical releases")
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:600,height:400), styleMask:.borderless, backing:.buffered, defer:false)
        let container = NSView(frame: NSRect(x:0,y:0,width:600,height:400))
        window.contentView = container
        // SwiftUI may request focus before AppKit attaches its native subtree.
        surface.wantsKeyboardFocus = true
        DispatchQueue.main.async { surface.window?.makeFirstResponder(surface) }
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        container.addSubview(surface)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        precondition(window.firstResponder === surface, "Terminal focus requested before attachment must be restored when mounted")
        func tabEvent(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 2,
                             windowNumber: window.windowNumber, context: nil, characters: "\t",
                             charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        }
        for modifiers: NSEvent.ModifierFlags in [.control, [.control, .shift], [.control, .capsLock]] {
            precondition(!surface.performKeyEquivalent(with: tabEvent(.keyDown, modifiers)),
                         "Control-Tab navigation must reach the application's menus")
            surface.keyUp(with: tabEvent(.keyUp, modifiers))
            precondition(output.isEmpty, "Menu-owned Control-Tab must not emit terminal input or an unmatched Kitty release")
        }
        precondition(surface.performKeyEquivalent(with: tabEvent(.keyDown, [.control, .option])),
                     "Control-Option-Tab must retain its terminal meaning")
        precondition(output == Data("\u{1b}[9;7u".utf8))
        output.removeAll()
        surface.keyUp(with: tabEvent(.keyUp, [.control, .option]))
        precondition(output == Data("\u{1b}[9;7:3u".utf8), "Forwarded Control-Option-Tab retains its matching Kitty release")
        output.removeAll()
        window.sendEvent(event(.keyDown, .control))
        precondition(output == Data("\u{1b}[99;5u".utf8), "The first Control-C must reach the mounted terminal without a click")
        output.removeAll()
        surface.removeFromSuperview();window.makeFirstResponder(nil)
        surface.wantsKeyboardFocus = false
        container.addSubview(surface)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        precondition(window.firstResponder !== surface, "An inactive terminal must not take attachment focus")
        precondition(!surface.performKeyEquivalent(with: event(.keyDown, .control)) && output.isEmpty,
                     "A terminal that is not first responder cannot intercept Control keys")
        surface.wantsKeyboardFocus = true
        surface.wantsKeyboardFocus = false
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        precondition(window.firstResponder !== surface, "Opening a palette must cancel queued terminal focus")
        let search = NSTextField(frame:NSRect(x:0,y:0,width:200,height:24))
        container.addSubview(search);window.makeFirstResponder(search)
        let editor = window.firstResponder
        surface.wantsKeyboardFocus = true
        surface.removeFromSuperview();container.addSubview(surface)
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        precondition(window.firstResponder === editor, "Attachment focus must preserve active text editing")
        precondition(!surface.performKeyEquivalent(with: tabEvent(.keyDown, [.control, .option])) && output.isEmpty,
                     "Active text editors retain Control-Option-Tab ownership")
        surface.wantsKeyboardFocus = false
        surface.removeFromSuperview();search.removeFromSuperview();window.makeFirstResponder(nil)
        let metal = TerminalMetalView(frame:container.bounds,device:nil)
        var attachedWakeups = 0
        metal.onDisplayEnvironmentChange = { [weak metal, weak window] in
            if let window, metal?.window === window { attachedWakeups += 1 }
        }
        container.addSubview(metal)
        precondition(attachedWakeups > 0, "Mounting a Metal child into an existing window must wake presentation after its own window is attached")
        let immediate = attachedWakeups
        RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
        precondition(attachedWakeups > immediate, "A deferred wake must run after subtree mounting and layout settle")
        let beforeVisibility = attachedWakeups
        metal.isHidden = true;metal.isHidden = false
        precondition(attachedWakeups > beforeVisibility, "A hidden Metal child must wake when revealed")
        metal.removeFromSuperview()
        let beforeReattach = attachedWakeups
        container.addSubview(metal)
        precondition(attachedWakeups > beforeReattach, "Reattaching a cached Metal view must wake without new terminal input")
        metal.onDisplayEnvironmentChange = nil
        window.contentView = nil
        print("Native input surface: menu key releases, matching Kitty releases, and IME Unicode commit passed.")
        print("Tab navigation input: Control-Tab yields to menus; Control-Option-Tab and Control-C still reach the focused terminal.")
        print("Terminal focus: delayed mount, first Control-C, inactive panes, palette cancellation, and active editor preservation passed.")
        print("Metal surface lifecycle: child attachment, deferred first-frame wake, hide/reveal, and reattachment passed.")
    }
}
