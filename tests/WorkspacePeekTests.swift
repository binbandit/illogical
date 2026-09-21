import AppKit

private final class PeekTouch: NSTouch, @unchecked Sendable {
    let token: NSNumber
    let point: CGPoint
    init(_ identity: Int, _ point: CGPoint) { token = NSNumber(value: identity);self.point = point;super.init() }
    required init?(coder: NSCoder) { fatalError() }
    override var identity: any NSObjectProtocol & NSCopying { token }
    override var normalizedPosition: NSPoint { point }
    override var deviceSize: NSSize { NSSize(width: 320, height: 240) }
    override var phase: NSTouch.Phase { .touching }
    override var isResting: Bool { false }
}

private final class PeekEvent: NSEvent {
    let samples: Set<NSTouch>
    init(_ samples: [PeekTouch]) { self.samples = Set(samples);super.init() }
    required init?(coder: NSCoder) { fatalError() }
    override func touches(matching phase: NSTouch.Phase, in view: NSView?) -> Set<NSTouch> { samples }
}

@MainActor
private final class PeekWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

@main struct WorkspacePeekTests {
    @MainActor static func main() {
        let domain = "dev.illogical.peek-tests"
        precondition(Bundle.main.bundleIdentifier == domain)
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        _ = NSApplication.shared
        let engine = TerminalEngine(blockID: "peek-fixture", theme: .merinoDark)
        var terminal: GhosttyTerminal?
        precondition(ghostty_terminal_new(nil, &terminal, 80, 24) == GHOSTTY_SUCCESS)
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        precondition(ghostty_snapshot_encode_alloc(terminal, nil, &bytes, &count) == GHOSTTY_SUCCESS)
        engine.receive(WireMessage(type: "snapshot", stream: "peek-test", data: Data(bytes: bytes!, count: count)))
        ghostty_free(nil, bytes, count);ghostty_terminal_free(terminal)
        precondition(engine.stream == "peek-test")
        var resizes = 0
        engine.onResize = { _, _, _, _ in resizes += 1 }
        let view = NativeTerminalView(engine: engine)
        let cell = view.renderer!.cell
        let rect = NSRect(x: 0, y: 0, width: cell.width * 100 + 16, height: cell.height * 30 + 16)
        let window = PeekWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: rect)
        window.contentView = container;view.frame = rect;container.addSubview(view);view.layout()
        precondition(resizes > 0, "The attached terminal must emit a real initial PTY size request before testing gesture stability")
        engine.resizeFromServer(columns: 100, rows: 30);resizes = 0
        defer { view.detach();window.contentView = nil }
        let model = WorkspaceModel()
        var updates: [(CGFloat, Bool)] = []
        func synchronize() {
            view.peekProgress = model.peek;view.focusToken = model.focusToken
            view.renderer?.focused = model.peek == 0;view.wantsKeyboardFocus = model.peek == 0
        }
        view.onRequestEditorFocus = { model.consumeKeyboardFocusIntent($0) }
        view.onPeek = { progress, finished in
            updates.append((progress, finished));model.setPeek(progress, finished: finished);synchronize()
            view.layout()
        }
        func event(x: CGFloat = 0.5, y: CGFloat = 0.7, third: Int = 3) -> PeekEvent {
            PeekEvent([PeekTouch(1, CGPoint(x: x - 0.1, y: y)), PeekTouch(2, CGPoint(x: x, y: y)), PeekTouch(third, CGPoint(x: x + 0.1, y: y))])
        }
        func close() { model.dismissPeek();synchronize();updates.removeAll() }
        func finish() { view.touchesEnded(with: PeekEvent([])) }
        func reveal() { view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.54));finish() }

        view.touchesBegan(with: event());view.touchesMoved(with: event(x: 0.8, y: 0.66));finish()
        precondition(updates.isEmpty && model.peek == 0, "Horizontal drift must never reveal the workspace")
        view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.68));finish()
        precondition(updates.isEmpty, "Small resting jitter stays below the intent threshold")
        view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.9));finish()
        precondition(updates.isEmpty, "An upward swipe from the closed workspace must not start a reveal")
        view.interactive = false
        view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.4));finish()
        precondition(updates.isEmpty, "Preview terminals must never emit gesture callbacks")
        view.interactive = true;reveal()
        precondition(model.peek == 1 && !model.isPeekGestureActive)
        close();view.touchesCancelled(with: PeekEvent([]));reveal()
        precondition(model.peek == 1, "Lifecycle cancellation before a gesture must not swallow the next valid swipe")
        close();view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.45, third: 4));finish()
        precondition(updates.isEmpty && model.peek == 0, "Replacing a contact must not jump the centroid into a reveal")
        view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.5))
        precondition(model.peek > 0 && model.isPeekGestureActive)
        view.touchesMoved(with: event(y: 0.4, third: 4));finish()
        precondition(model.peek == 0 && !model.isPeekGestureActive, "Identity loss during tracking restores the starting state")
        close();view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.54))
        view.touchesEnded(with: PeekEvent([PeekTouch(1, CGPoint(x: 0.4, y: 0.54)), PeekTouch(2, CGPoint(x: 0.5, y: 0.54))]))
        let endedCount = updates.count
        view.touchesMoved(with: event(y: 0.3, third: 4))
        precondition(updates.count == endedCount, "Replacing the lifted finger cannot start a second gesture before all contacts lift")
        finish();precondition(model.peek == 1)
        view.touchesBegan(with: event());view.touchesMoved(with: event(y: 0.45));view.touchesCancelled(with: PeekEvent([]))
        precondition(model.peek == 1, "Cancellation from tab peek restores tab peek instead of closing it")
        view.touchesBegan(with: event(y: 0.35));view.touchesMoved(with: event(y: 0.75));finish()
        precondition(model.peek == 0, "An upward swipe on the visible terminal dismisses tab peek")
        view.touchesBegan(with: event(y: 0.95));view.touchesMoved(with: event(y: 0.2))
        precondition(model.peek == 2 && !model.peekExpanded, "The compact overview must not rearrange itself under a live gesture")
        finish();precondition(model.peek == 2 && model.peekExpanded)
        model.setPeek(0.9, finished: false)
        precondition(model.peekExpanded, "Closing a full overview keeps its layout stable while tracking")
        model.setPeek(0.9, finished: true)
        precondition(model.peek == 1 && !model.peekExpanded)
        close()
        for height: CGFloat in [360, 800, 1400] {
            var previous: CGFloat = 0
            for step in 0...2000 {
                model.peek = CGFloat(step) / 1000
                let offset = model.peekOffset(height: height)
                precondition(offset >= previous && offset - previous < 2, "Reveal offset must stay continuous and monotonic, including the former 1.35 discontinuity")
                previous = offset
            }
            precondition(abs(previous - height - 20) < 0.001)
        }
        close();precondition(resizes == 0, "Gesture and overview movement must never resize the PTY")
        print("Peek gestures: native three-finger callbacks reject jitter/horizontal motion/previews/contact replacement, preserve identity and direction, cancel cleanly, and keep reveal geometry continuous without PTY resizing.")

        var output = Data()
        engine.onInput = { output.append($0) }
        func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                            isARepeat: false, keyCode: code)!
        }
        model.togglePeek(1);synchronize();output.removeAll()
        view.pasteboard = NSPasteboard.withUniqueName();view.pasteboard.setString("must not reach terminal", forType: .string)
        defer { view.pasteboard.releaseGlobally() }
        view.keyDown(with: key(7, "x"));view.keyDown(with: key(8, "\u{3}", modifiers: .control))
        view.paste(nil);view.insertText("IME commit", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("中", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(output.isEmpty && !view.hasMarkedText(), "Overview must block ordinary keys, Control-C, menu paste and IME insertion")
        view.keyDown(with: key(53, "\u{1b}"))
        precondition(model.peek == 0 && output.isEmpty, "Escape dismisses the overview without reaching the terminal")
        reveal();precondition(model.peek == 1, "Dismissing with Escape must not suppress the next complete swipe")
        close()
        model.togglePeek(1);synchronize()
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(NSPoint(x: 15, y: 15), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        view.mouseDown(with: click)
        precondition(model.peek == 0 && output.isEmpty, "Clicking the visible terminal dismisses peek without selecting or sending mouse input")
        reveal();precondition(model.peek == 1, "Click dismissal must not suppress the next complete swipe")
        close()
        _ = model.consumeKeyboardFocusIntent(model.focusToken)
        for index in 0..<100 {
            let data = Data("line-\(index)\r\n".utf8)
            data.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        }
        engine.scrollTo(20)
        func mouse(_ type: NSEvent.EventType, row: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: 12, y: 8 + row * cell.height), to: nil), modifierFlags: [], timestamp: 1,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, row: 2));view.mouseDragged(with: mouse(.leftMouseDragged, row: 40))
        precondition(view.selectionAutoscrollTimer != nil)
        model.togglePeek(1);synchronize()
        precondition(view.selectionAutoscrollTimer == nil && view.cursorBlinkTimer == nil, "Overview must cancel selection dragging and cursor timers")
        close()
        print("Overview input: hidden-terminal typing, Control-C, paste and IME suppressed; Escape and visible-terminal click dismiss; selection autoscroll and cursor wakeups stop.")

        let filter = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        container.addSubview(filter);filter.selectText(nil)
        precondition(window.firstResponder is NSTextView)
        model.focus("peek-fixture", explicit: false);synchronize();view.requestKeyboardFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(window.firstResponder is NSTextView, "Background reconciliation and automatic attachment must preserve the sidebar editor")
        model.focus("peek-fixture");synchronize();view.requestKeyboardFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(window.firstResponder === view, "Explicit pane navigation must reclaim terminal keyboard focus from the sidebar editor")
        filter.selectText(nil);view.requestKeyboardFocus()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        precondition(window.firstResponder is NSTextView, "An already consumed focus request must not replay during reactivation")
        model.close()
        print("Keyboard focus: explicit navigation leaves the sidebar editor; background focus and later attachment/reactivation preserve editors and never replay consumed intent.")
    }
}
