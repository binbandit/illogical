import AppKit
import MetalKit

@MainActor
private final class DisplayTestWindow: NSWindow {
    var displayScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { displayScale }
}

@main
struct TerminalDisplayTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let engine = TerminalEngine(blockID: "display-lifecycle-test", theme: .merinoDark)
        var terminal: GhosttyTerminal?
        precondition(ghostty_terminal_new(nil, &terminal, 80, 24) == GHOSTTY_SUCCESS)
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        precondition(ghostty_snapshot_encode_alloc(terminal, nil, &bytes, &count) == GHOSTTY_SUCCESS)
        engine.receive(WireMessage(type: "snapshot", stream: "display-test", data: Data(bytes: bytes!, count: count)))
        ghostty_free(nil, bytes, count)
        ghostty_terminal_free(terminal)
        precondition(engine.stream == "display-test")

        let surface = NativeTerminalView(engine: engine)
        defer { surface.detach() }
        guard let renderer = surface.renderer else { fatalError("Display tests require the production Metal renderer and shaders") }
        renderer.fontSize = 12
        let window = DisplayTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                       styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        surface.frame = NSRect(x: 23.25, y: 41.35, width: 401.35, height: 300.65)
        var resizes: [(UInt16, UInt16, UInt32, UInt32)] = []
        var reportedCells: [CGSize] = []
        engine.onResize = { resizes.append(($0, $1, $2, $3)) }
        surface.onCellSize = { reportedCells.append($0) }
        container.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        // Actual AppKit backing conversion, including a fractional split origin.
        // The artificial scale below tests lifecycle dispatch; GPU 1x/2x glyph
        // sampling is covered separately by the offscreen renderer tests.
        let backing = surface.metal.convertToBacking(surface.metal.bounds)
        for edge in [backing.minX, backing.minY, backing.maxX, backing.maxY] {
            precondition(abs(edge - edge.rounded()) < 0.0001,
                         "The terminal drawable must align both its origin and extent to physical pixels")
        }
        precondition(abs(surface.metal.drawableSize.width - backing.width) < 0.0001 &&
                     abs(surface.metal.drawableSize.height - backing.height) < 0.0001,
                     "The Metal viewport must not stretch an integer drawable across fractional physical pixels")
        precondition(resizes.count == 1 && reportedCells.count == 1)
        let retinaCell = renderer.cell
        precondition(resizes.last?.2 == UInt32(retinaCell.width * 2) && resizes.last?.3 == UInt32(retinaCell.height * 2))

        surface.needsLayout = false
        window.displayScale = 1
        surface.metal.viewDidChangeBackingProperties()
        precondition(surface.needsLayout, "A backing change must relayout an idle terminal without waiting for output or a window resize")
        surface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        let monitorCell = renderer.cell
        precondition(resizes.count == 2 && resizes.last?.2 == UInt32(monitorCell.width) && resizes.last?.3 == UInt32(monitorCell.height),
                     "Moving to 1x must update PTY cell pixels even if the window size did not change")
        precondition(monitorCell != retinaCell && reportedCells.last == monitorCell,
                     "Cell observers must receive the display's newly rounded grid metrics")

        surface.needsLayout = false
        window.displayScale = 2
        NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: window)
        precondition(surface.needsLayout)
        surface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        precondition(renderer.cell == retinaCell && resizes.count == 3 && reportedCells.last == retinaCell)
        let resizeCount = resizes.count
        for _ in 0..<3 {
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
            surface.layoutSubtreeIfNeeded()
        }
        precondition(resizes.count == resizeCount, "Unchanged screen notifications must not send duplicate PTY resizes")

        // The aligned origin must also anchor input and the IME candidate rect.
        var input = Data()
        engine.onInput = { input.append($0) }
        let mouseMode = Data("\u{1b}[?1003h\u{1b}[?1006h".utf8)
        mouseMode.withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, mouseMode.count) }
        for (offset, coordinate) in [(-0.001, 1), (0.001, 2)] {
            input.removeAll()
            let point = NSPoint(x: surface.metal.frame.minX + 8 + retinaCell.width + offset,
                                y: surface.metal.frame.minY + 8 + retinaCell.height + offset)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 1,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            surface.mouseMoved(with: event)
            precondition(input == Data("\u{1b}[<35;\(coordinate);\(coordinate)M".utf8),
                         "Pixel alignment must preserve mouse hit-testing on both sides of a cell boundary")
        }
        let imeScreenRect = surface.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let imeRect = surface.convert(window.convertFromScreen(imeScreenRect), from: nil)
        precondition(abs(imeRect.minX - surface.metal.frame.minX - 8) < 0.0001 &&
                     abs(imeRect.minY - surface.metal.frame.minY - 8) < 0.0001,
                     "IME candidates must share the terminal's physical pixel origin")

        surface.interactive = false
        window.displayScale = 1
        surface.metal.viewDidChangeBackingProperties()
        surface.layoutSubtreeIfNeeded()
        precondition(resizes.count == resizeCount, "Preview scale changes must not resize a shared terminal session")
        surface.detach()
        surface.needsLayout = false
        NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: window)
        precondition(!surface.needsLayout, "Detached surfaces must remove backing notifications")
        window.contentView = nil
        print("Native display lifecycle: physical pixel alignment, Retina/1x/Retina metrics, idle resize propagation, mouse/IME alignment, preview isolation and teardown passed.")
    }
}
