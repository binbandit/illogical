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
        focusClicks()
        pasteProtection()
        print("Native input surface: menu key releases, matching Kitty releases, and IME Unicode commit passed.")
        print("Tab navigation input: Control-Tab yields to menus; Control-Option-Tab and Control-C still reach the focused terminal.")
        print("Terminal focus: delayed mount, first Control-C, inactive panes, palette cancellation, and active editor preservation passed.")
        print("Metal surface lifecycle: child attachment, deferred first-frame wake, hide/reveal, and reattachment passed.")
    }

    @MainActor
    private final class KeyWindow: NSWindow {
        var key = true
        override var isKeyWindow: Bool { key }
    }

    /// Like Ghostty, a click that moves focus between panes (or activates the
    /// window) is not also a click in the program.
    @MainActor
    static func focusClicks() {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        let engine = TerminalEngine(blockID: "focus-click", theme: .merinoDark)
        var output = Data()
        engine.onInput = { output.append($0) }
        Data("\u{1b}[?1000h\u{1b}[?1006h".utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        let left = NativeTerminalView(engine: TerminalEngine(blockID: "focus-click-left", theme: .merinoDark))
        let right = NativeTerminalView(engine: engine)
        defer { left.detach(); right.detach(); window.contentView = nil }
        left.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        right.frame = NSRect(x: 300, y: 0, width: 300, height: 400)
        container.addSubview(left)
        container.addSubview(right)
        var focusRequests = 0
        right.onFocus = { focusRequests += 1 }
        func click() -> Data {
            output.removeAll()
            let location = right.convert(NSPoint(x: 30, y: 30), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { right.mouseDown(with: event) } else { right.mouseUp(with: event) }
            }
            return output
        }
        window.makeFirstResponder(left)
        precondition(click().isEmpty && window.firstResponder === right && focusRequests == 1,
                     "Clicking an unfocused pane focuses it without a mouse report")
        let report = click()
        precondition(report.starts(with: Data("\u{1b}[<0;".utf8)) && report.last == UInt8(ascii: "m"),
                     "The next click reaches the program: \(report as NSData)")
        _ = right.acceptsFirstMouse(for: nil)
        precondition(click().isEmpty, "The click that activates an inactive window only focuses")
        precondition(!click().isEmpty, "Later clicks in the activated window reach the program")

        precondition(right.renderer?.focused == true && left.renderer?.focused == false, "Only the focused pane draws a solid cursor")
        window.key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        precondition(right.renderer?.focused == false, "A background window shows a hollow cursor")
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        precondition(right.renderer?.focused == true, "The cursor turns solid again when the window is key")

        right.setPaneFocus(false, unfocusedOpacity: 0.85)
        precondition(right.isDimmed && right.renderer?.focused == false, "Unfocused panes dim when the workspace asks")
        right.setPaneFocus(true, unfocusedOpacity: 0.85)
        precondition(!right.isDimmed, "The focused pane is never dimmed")

        engine.optionAsAlt = .both
        output.removeAll()
        right.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 2, windowNumber: window.windowNumber,
                                             context: nil, characters: "∫", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!)
        precondition(output == Data("\u{1b}b".utf8), "Option as Alt reaches the program through the input system: \(output as NSData)")
        print("Focus clicks: pane and window activation clicks only focus; hollow background cursors, unfocused dimming and Option as Alt through the view passed.")
    }

    /// Ghostty's clipboard-paste-protection and file pasting.
    @MainActor
    static func pasteProtection() {
        let engine = TerminalEngine(blockID: "paste-protection", theme: .merinoDark)
        var output = Data()
        engine.onInput = { output.append($0) }
        let view = NativeTerminalView(engine: engine)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("illogical-paste-tests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally(); view.detach() }
        view.pasteboard = pasteboard
        var questions: [String] = []
        var approve = false
        view.confirmPaste = { text, answer in
            questions.append(text)
            answer(approve)
        }
        func paste(_ text: String) -> Data {
            output.removeAll()
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            view.paste(nil)
            return output
        }
        precondition(paste("echo safe") == Data("echo safe".utf8) && questions.isEmpty, "Single-line pastes need no confirmation")
        precondition(paste("ls\nrm -rf build\n").isEmpty && questions.count == 1, "A declined multi-line paste sends nothing")
        approve = true
        precondition(paste("ls\nrm -rf build\n") == Data("ls\rrm -rf build\r".utf8), "An approved paste sends newlines as returns")
        Data("\u{1b}[?2004h".utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        questions.removeAll()
        precondition(paste("a\nb") == Data("\u{1b}[200~a\nb\u{1b}[201~".utf8) && questions.isEmpty, "Bracketed pastes are trusted")
        output.removeAll()
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/two words.txt"), NSURL(fileURLWithPath: "/tmp/it's")])
        view.paste(nil)
        precondition(output == Data("\u{1b}[200~/tmp/two\\ words.txt /tmp/it\\'s\u{1b}[201~".utf8),
                     "Files paste as escaped paths: \(String(decoding: output, as: UTF8.self))")
        print("Paste protection: confirmation for unbracketed newlines, trusted bracketed paste, and escaped file paths passed.")
    }
}
