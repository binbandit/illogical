import AppKit

@MainActor
private final class ResourceTestWindow: NSWindow {
    var testKey = true
    var testVisible = true
    override var isKeyWindow: Bool { testKey }
    override var backingScaleFactor: CGFloat { 2 }
    override var occlusionState: NSWindow.OcclusionState { testVisible ? [.visible] : [] }
}

@main
struct TerminalSurfaceResourceTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let engine = TerminalEngine(blockID: "cursor-resource-test", theme: .merinoDark)
        let previews = (0..<32).map { _ in NativeTerminalView(engine: engine) }
        for preview in previews {
            preview.interactive = false
            preview.isHidden = true
            precondition(preview.cursorBlinkTimer == nil, "Hidden previews must not install idle timers")
        }
        let surface = NativeTerminalView(engine: engine)
        guard let renderer = surface.renderer else { fatalError("Resource tests require the actual Metal renderer and bundled shaders") }
        // Exercise real focus, notifications, terminal modes and timers without
        // ordering a test window onscreen or submitting unrelated GPU work.
        renderer.view = nil
        precondition(surface.cursorBlinkTimer == nil, "An unmounted terminal must have no blink timer")
        let window = ResourceTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        surface.wantsKeyboardFocus = true
        container.addSubview(surface)
        precondition(window.makeFirstResponder(surface))

        func mode(_ sequence: String) {
            let data = Data(sequence.utf8)
            data.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
            renderer.onFrame?(engine.frame()!)
        }
        func notify(_ name: Notification.Name) {
            NotificationCenter.default.post(name: name, object: window)
        }
        var input = Data()
        engine.onInput = { input.append($0) }
        mode("\u{1b}[?1004h")
        input.removeAll()
        window.testKey = false;notify(NSWindow.didResignKeyNotification)
        precondition(input == Data("\u{1b}[O".utf8), "Losing native key focus must report focus-out")
        input.removeAll()
        window.testKey = true;notify(NSWindow.didBecomeKeyNotification)
        precondition(input == Data("\u{1b}[I".utf8), "Regaining native key focus must report focus-in")
        input.removeAll()
        let extraPreview = NativeTerminalView(engine: engine)
        extraPreview.interactive = false;extraPreview.detach()
        precondition(input.isEmpty, "Mounting and destroying a preview must never report focus-out for its active terminal")
        mode("\u{1b}[?1004l")

        surface.frame = container.bounds;surface.layout()
        let cell = renderer.cell
        func mouse(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            // A point in the second column and row, with fractional point cell
            // metrics: the protocol must receive physical pixels on Retina.
            let local = NSPoint(x: 8 + cell.width * (type == .mouseMoved ? 2.2 : 1.2), y: 8 + cell.height * 1.2)
            return NSEvent.mouseEvent(with: type, location: surface.convert(local, to: nil), modifierFlags: modifiers,
                                      timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        mode("\u{1b}[?1003h\u{1b}[?1006h")
        surface.rightMouseDown(with: mouse(.rightMouseDown))
        precondition(input == Data("\u{1b}[<2;2;2M".utf8), "Right mouse must use terminal button 2 and the correct cell")
        input.removeAll();surface.rightMouseUp(with: mouse(.rightMouseUp))
        precondition(input == Data("\u{1b}[<2;2;2m".utf8))
        input.removeAll();surface.mouseMoved(with: mouse(.mouseMoved))
        precondition(input == Data("\u{1b}[<35;3;2M".utf8), "All-motion mode must receive native hover")
        input.removeAll();surface.mouseMoved(with: mouse(.mouseMoved))
        precondition(input.isEmpty, "Repeated motion in the same cell must not emit input")
        surface.mouseMoved(with: mouse(.mouseMoved, modifiers: .shift))
        precondition(input.isEmpty, "Shift must bypass application mouse reporting")
        mode("\u{1b}[?1003l\u{1b}[?1006l\u{1b}[Hcopied text")
        let privatePasteboard = NSPasteboard(name: NSPasteboard.Name("illogical-resource-tests-" + UUID().uuidString))
        defer { privatePasteboard.releaseGlobally() }
        surface.pasteboard = privatePasteboard
        var copied = [String]()
        surface.onCopy = { copied.append($0) }
        engine.selectAll();surface.copy(nil)
        precondition(copied.last?.contains("copied text") == true && privatePasteboard.string(forType: .string) == copied.last,
                     "Native Copy must write text and emit one selection event")
        let copies = copied.count
        surface.interactive = false;surface.copy(nil);surface.interactive = true
        precondition(copied.count == copies, "Preview copy must not overwrite the clipboard")
        surface.copyOnSelection = false;engine.selectAll();surface.mouseUp(with: mouse(.leftMouseUp))
        precondition(copied.count == copies, "Selection release must respect the disabled preference")
        surface.copyOnSelection = true;engine.selectAll();surface.mouseUp(with: mouse(.leftMouseUp))
        precondition(copied.count == copies + 1, "Selection release must copy when enabled")
        surface.copyOnSelection = false
        mode("\u{1b}[H\u{1b}[2J\u{1b}[2;1H\u{1b}]8;;https://example.com/illogical-test\u{1b}\\link\u{1b}]8;;\u{1b}\\")
        var clickedLinks: [URL] = [], openedLinks: [URL] = []
        surface.onLink = { clickedLinks.append($0) };surface.openURL = { openedLinks.append($0) }
        surface.mouseDown(with: mouse(.leftMouseDown, modifiers: .command))
        surface.mouseUp(with: mouse(.leftMouseUp, modifiers: .command))
        precondition(clickedLinks.map(\.absoluteString) == ["https://example.com/illogical-test"] && openedLinks == clickedLinks,
                     "Command-click must emit one link event and open the actual OSC 8 target")
        mode("\u{1b}[1 q\u{1b}[?25h")
        guard let initial = surface.cursorBlinkTimer else { fatalError("A visible focused blinking cursor must animate") }
        precondition(initial.tolerance > 0, "Cosmetic cursor wakes should allow timer coalescing")
        initial.fire()
        precondition(!renderer.cursorOn, "Blink timer must still update the visible cursor")

        window.testVisible = false
        notify(NSWindow.didChangeOcclusionStateNotification)
        precondition(!initial.isValid && surface.cursorBlinkTimer == nil && renderer.cursorOn,
                     "Occlusion must stop blinking immediately and restore the cursor phase")
        window.testVisible = true
        notify(NSWindow.didChangeOcclusionStateNotification)
        precondition(surface.cursorBlinkTimer != nil, "Revealing an idle terminal must resume its cursor without output")
        window.testKey = false
        notify(NSWindow.didResignKeyNotification)
        precondition(surface.cursorBlinkTimer == nil, "Background windows must not blink")
        window.testKey = true
        notify(NSWindow.didBecomeKeyNotification)
        precondition(surface.cursorBlinkTimer != nil)

        container.isHidden = true
        precondition(surface.cursorBlinkTimer == nil, "Hidden ancestors must stop blinking")
        container.isHidden = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        precondition(surface.cursorBlinkTimer != nil, "Unhiding must resume a visible cursor")
        surface.metal.isHidden = true
        precondition(surface.cursorBlinkTimer == nil, "A hidden Metal child must stop blinking")
        surface.metal.isHidden = false
        precondition(surface.cursorBlinkTimer != nil)
        surface.interactive = false
        precondition(surface.cursorBlinkTimer == nil, "A live preview never needs its own blink timer")
        surface.interactive = true
        precondition(surface.cursorBlinkTimer != nil)

        mode("\u{1b}[2 q")
        precondition(surface.cursorBlinkTimer == nil, "A steady cursor must not wake periodically")
        mode("\u{1b}[1 q\u{1b}[?25l")
        precondition(surface.cursorBlinkTimer == nil, "A terminal-hidden cursor must not blink")
        mode("\u{1b}[?25h")
        let control = NSTextField(frame: .zero)
        container.addSubview(control)
        window.makeFirstResponder(control)
        precondition(surface.cursorBlinkTimer == nil, "Palette or search focus must stop the terminal cursor timer")
        window.makeFirstResponder(surface)
        surface.updateCursorBlink()
        precondition(surface.cursorBlinkTimer != nil)
        surface.removeFromSuperview()
        precondition(surface.cursorBlinkTimer == nil, "Removing a terminal must cancel its timer")
        container.addSubview(surface)
        window.makeFirstResponder(surface)
        surface.updateCursorBlink()
        surface.detach()
        notify(NSWindow.didBecomeKeyNotification)
        precondition(surface.cursorBlinkTimer == nil, "Dismantled views must never restart their timer")
        for preview in previews { preview.detach() }
        window.contentView = nil
        print("Native protocols: focus ownership, right-click, hover deduplication, Shift override, copy preference/event and OSC 8 link event passed.")
        print("Cursor resource checks passed: 32 hidden previews install zero timers; focus, visibility, terminal modes, resume and teardown verified.")
    }
}
