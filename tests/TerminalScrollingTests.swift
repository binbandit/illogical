import AppKit
final class PositionedWheelEvent: NSEvent {
    let original: NSEvent
    let point: NSPoint
    init(_ original: NSEvent, point: NSPoint) {
        self.original = original; self.point = point
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { original.scrollingDeltaY }
    override var scrollingDeltaX: CGFloat { original.scrollingDeltaX }
    override var hasPreciseScrollingDeltas: Bool { original.hasPreciseScrollingDeltas }
    override var modifierFlags: NSEvent.ModifierFlags { original.modifierFlags }
    override var phase: NSEvent.Phase { original.phase }
}

@MainActor
private final class SelectionTestWindow: NSWindow {
    var exposed = true
    override var occlusionState: NSWindow.OcclusionState { exposed ? [.visible] : [] }
}

@main
struct TerminalScrollingTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func feed(_ engine: TerminalEngine, _ text: String) {
            Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        }
        func fixture(_ id: String) -> (TerminalEngine, NativeTerminalView, SelectionTestWindow) {
            let engine = TerminalEngine(blockID: id, theme: .merinoDark)
            let view = NativeTerminalView(engine: engine)
            let cell = view.renderer!.cell
            let size = NSRect(x: 0, y: 0, width: cell.width * 100 + 16, height: cell.height * 30 + 16)
            let window = SelectionTestWindow(contentRect: size, styleMask: .borderless, backing: .buffered, defer: false)
            let container = NSView(frame: size)
            window.contentView = container;view.frame = size;container.addSubview(view);view.layout()
            // The window stays off screen. Only its visibility predicate is
            // simulated; all events enter the production native callbacks.
            return (engine, view, window)
        }
        func wheel(_ view: NativeTerminalView, y: CGFloat = 0, x: CGFloat = 0, precise: Bool = false, shift: Bool = false) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
            cg.setDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis1, value: y)
            cg.setDoubleValueField(precise ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventFixedPtDeltaAxis2, value: x)
            if shift { cg.flags = .maskShift }
            return PositionedWheelEvent(NSEvent(cgEvent: cg)!, point: view.convert(NSPoint(x: 10, y: 10), to: nil))
        }
        let (alt, altView, altWindow) = fixture("alternate-scroll")
        defer { altView.detach();altWindow.contentView = nil }
        var output = Data()
        alt.onInput = { output.append($0) }
        func expect(_ expected: String, _ reason: String) {
            precondition(output == Data(expected.utf8), "\(reason): actual \(output as NSData)")
            output.removeAll()
        }
        feed(alt, "\u{1b}[?1049h\u{1b}[?1007h")
        altView.scrollWheel(with: wheel(altView, y: 1));expect("\u{1b}[A", "Alternate-screen up uses a normal cursor key")
        altView.scrollWheel(with: wheel(altView, y: -2));expect("\u{1b}[B\u{1b}[B", "Alternate-screen down preserves magnitude")
        feed(alt, "\u{1b}[?1h")
        altView.scrollWheel(with: wheel(altView, y: 1));expect("\u{1b}OA", "Application cursor up")
        altView.scrollWheel(with: wheel(altView, y: -1));expect("\u{1b}OB", "Application cursor down")
        feed(alt, "\u{1b}[?1007l")
        altView.scrollWheel(with: wheel(altView, y: 1));expect("", "Disabled alternate scroll does not send keys")
        feed(alt, "\u{1b}[?1007h\u{1b}[?1049l")
        altView.scrollWheel(with: wheel(altView, y: 1));expect("", "Primary screen does not send cursor keys")
        feed(alt, "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        altView.scrollWheel(with: wheel(altView, y: 1));expect("\u{1b}[<64;1;1M", "Mouse reporting takes precedence over alternate scroll")
        altView.scrollWheel(with: wheel(altView, x: 1));expect("\u{1b}[<66;1;1M", "Horizontal positive detent reaches the application")
        altView.scrollWheel(with: wheel(altView, x: -1));expect("\u{1b}[<67;1;1M", "Horizontal negative detent reaches the application")
        altView.scrollWheel(with: wheel(altView, y: 1, x: -1));expect("\u{1b}[<64;1;1M\u{1b}[<67;1;1M", "Both axes in one event are preserved")
        altView.scrollWheel(with: wheel(altView, y: 0.1));expect("\u{1b}[<64;1;1M", "A slow physical upward detent is immediate")
        altView.scrollWheel(with: wheel(altView, y: -0.1));expect("\u{1b}[<65;1;1M", "A slow physical downward detent is immediate")
        altView.scrollWheel(with: wheel(altView, y: 1, shift: true));expect("", "Shift bypasses application mouse reporting")
        let cell = altView.renderer!.cell
        let verticalPart = ceil(cell.height / 2)
        altView.scrollWheel(with: wheel(altView, y: verticalPart, precise: true));expect("", "Sub-cell precise vertical movement accumulates")
        altView.scrollWheel(with: wheel(altView, y: verticalPart, precise: true));expect("\u{1b}[<64;1;1M", "Precise vertical movement dispatches at a row")
        let horizontalPart = ceil(cell.width / 2)
        altView.scrollWheel(with: wheel(altView, x: horizontalPart, precise: true));expect("", "Sub-cell precise horizontal movement accumulates")
        altView.scrollWheel(with: wheel(altView, x: horizontalPart, precise: true));expect("\u{1b}[<66;1;1M", "Precise horizontal movement dispatches at a column")
        altView.scrollWheel(with: wheel(altView, x: horizontalPart, precise: true));expect("", "A partial trackpad gesture remains pending")
        altView.scrollWheel(with: wheel(altView, x: 1));expect("\u{1b}[<66;1;1M", "Physical wheel does not inherit a trackpad remainder")
        altView.scrollWheel(with: wheel(altView, x: horizontalPart, precise: true));expect("", "Returning to trackpad starts a new accumulation")
        print("Native wheel input: alternate cursor modes, reporting precedence, both axes, slow detents and precise accumulation passed.")

        let (drag, view, window) = fixture("selection-autoscroll")
        defer { view.detach();window.contentView = nil }
        for index in 0..<100 { feed(drag, "line-\(String(format: "%03d", index))\r\n") }
        drag.scrollTo(20)
        view.scrollWheel(with: wheel(view, y: 0.1))
        precondition(drag.frame()!.scrollOffset == 19, "Slow physical scrolling also moves ordinary local scrollback immediately")
        view.scrollWheel(with: wheel(view, x: 1))
        precondition(drag.frame()!.scrollOffset == 19, "Horizontal scrolling does not accidentally move vertical history")
        let dragCell = view.renderer!.cell
        var timestamp: Double = 10
        func mouse(_ type: NSEvent.EventType, row: CGFloat) -> NSEvent {
            timestamp += 1
            let point = view.convert(NSPoint(x: 8 + dragCell.width * 2, y: 8 + row * dragCell.height), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: Int(timestamp), clickCount: 1, pressure: 1)!
        }
        func beginDrag(_ row: CGFloat = 40) {
            drag.scrollTo(20)
            view.mouseDown(with: mouse(.leftMouseDown, row: 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, row: row))
        }
        func hold(_ duration: Double = 0.09) { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }
        func offset() -> UInt64 { drag.frame()!.scrollOffset }
        precondition(view.selectionAutoscrollTimer == nil)
        beginDrag()
        precondition(view.selectionAutoscrollTimer != nil, "Outside drag starts a demand-only timer")
        hold()
        precondition(offset() > 20, "Holding below the terminal scrolls without another pointer event")
        precondition((drag.copy() ?? "").contains("line-050"), "Selection follows newly exposed history")
        view.mouseDragged(with: mouse(.leftMouseDragged, row: 15))
        precondition(view.selectionAutoscrollTimer == nil, "Re-entry stops the timer immediately")
        let reentered = offset();hold();precondition(offset() == reentered)
        view.mouseUp(with: mouse(.leftMouseUp, row: 15))
        beginDrag(-3);hold()
        precondition(offset() < 20, "Holding above the terminal scrolls toward earlier history")
        view.mouseUp(with: mouse(.leftMouseUp, row: -3))
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Release stops the timer and completes the gesture")
        let released = offset();hold();precondition(offset() == released)
        beginDrag();view.isHidden = true
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Hiding the terminal cancels autoscroll")
        view.isHidden = false
        beginDrag();view.superview!.isHidden = true
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Hiding an ancestor cancels autoscroll")
        view.superview!.isHidden = false
        beginDrag();view.metal.isHidden = true
        precondition(view.selectionAutoscrollTimer == nil, "Hiding the drawable cancels autoscroll")
        view.metal.isHidden = false
        beginDrag();window.exposed = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Occlusion cancels autoscroll")
        window.exposed = true
        beginDrag();NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Leaving the window cancels autoscroll")
        beginDrag();hold(1.0)
        precondition(view.selectionAutoscrollTimer == nil, "Reaching the end of available history stops the timer")
        let bottom = offset();hold();precondition(offset() == bottom)
        view.mouseUp(with: mouse(.leftMouseUp, row: 40))
        beginDrag();view.interactive = false
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Previews cannot retain a selection timer")
        view.interactive = true
        beginDrag();let container = view.superview!;view.removeFromSuperview()
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Unmount cancels autoscroll")
        container.addSubview(view)
        beginDrag();view.detach()
        precondition(view.selectionAutoscrollTimer == nil && !drag.selectionNeedsAutoscroll, "Teardown cancels autoscroll")
        print("Native selection: held drags scroll and extend selection; release, re-entry, hide, occlusion, preview, unmount and teardown stop timers.")
    }
}
