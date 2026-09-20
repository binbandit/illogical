import Foundation

@main
struct TerminalRenderHoldTests {
    @MainActor
    static func main() async {
        let engine = TerminalEngine(blockID: "render-hold-test", theme: .merinoDark)
        let key = UUID()
        var notifications = 0
        var visible = ""
        engine.observers[key] = {
            notifications += 1
            guard let frame = engine.frame(), let cells = frame.cells else { return }
            visible = (0..<8).map { index in
                var cell = cells[index]
                return withUnsafePointer(to: &cell.text) { $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) } }
            }.joined()
        }
        // Disable cursor blinking too: the independent deadline must wake the
        // view even when the process is quiet and its cursor cannot trigger a frame.
        engine.receive(WireMessage(type: "output", data: Data("\u{1b}[?12lcomplete\u{1b}[?2026h\rtimeout!".utf8)))
        precondition(visible == "complete")
        let before = notifications
        try? await Task.sleep(for: .milliseconds(1200))
        precondition(notifications > before && visible == "timeout!", "A quiet producer must redraw after the one-second deadline")
        precondition(il_terminal_render_hold_remaining(engine.handle) == 0)
        engine.observers.removeValue(forKey: key)
        print("Render deadline: a quiet producer with a non-blinking cursor wakes and displays its frame automatically.")
    }
}
