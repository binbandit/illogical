import AppKit

@main
struct TerminalFocusMouseTests {
    @MainActor
    static func main() {
        let engine = TerminalEngine(blockID: "focus-mouse", theme: .merinoDark)
        var bytes = Data(), notifications = 0
        engine.onInput = { bytes.append($0) }
        engine.observers[UUID()] = { notifications += 1 }
        func feed(_ text: String) {
            Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        }
        for _ in 0..<80 { feed("retained history\r\n") }
        engine.scrollTo(0)
        var viewports: [UInt64] = []
        engine.onViewportChange = { viewports.append($0) }
        let offset = engine.frame()!.scrollOffset
        engine.focusChanged(true); engine.focusChanged(false)
        precondition(bytes.isEmpty)
        feed("\u{1b}[?1004h\u{1b}[?1003h\u{1b}[?1006h")
        notifications = 0
        engine.focusChanged(true); engine.focusChanged(true); engine.focusChanged(false); engine.focusChanged(false)
        precondition(bytes == Data("\u{1b}[I\u{1b}[O".utf8))
        bytes.removeAll()
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0,
                                      context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        precondition(engine.mouse(event, action: 2, button: 0, point: NSPoint(x: 12, y: 10), cell: NSSize(width: 10, height: 20)))
        precondition(bytes == Data("\u{1b}[<35;2;1M".utf8))
        bytes.removeAll()
        precondition(engine.mouse(event, action: 2, button: 0, point: NSPoint(x: 13, y: 11), cell: NSSize(width: 10, height: 20)))
        precondition(bytes.isEmpty, "A suppressed same-cell event remains consumed without sending bytes")
        precondition(notifications == 0 && engine.frame()!.scrollOffset == offset, "Focus and hover reports must not jump scrollback or redraw the terminal")
        precondition(viewports.isEmpty, "Protocol replies cannot broadcast a viewport jump")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: 0,
                                  context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        engine.key(key)
        precondition(viewports == [0] && il_terminal_scroll_distance(engine.handle) == 0)
        engine.key(key);engine.send(Data("second input".utf8))
        precondition(viewports == [0], "Typing at the live bottom must not resend zero distance")
        engine.scrollTo(0);viewports.removeAll()
        engine.paste("pasted text")
        precondition(viewports == [0] && il_terminal_scroll_distance(engine.handle) == 0, "Paste returns synchronized peers to the live bottom")
        print("Engine focus/mouse: disabled reporting, deduplicated focus transitions, hover forwarding, retained scrollback, and zero input-triggered redraw notifications passed.")
    }
}
