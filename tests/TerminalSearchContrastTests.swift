import Foundation

@main
struct TerminalSearchContrastTests {
    @MainActor
    static func main() throws {
        let engine = TerminalEngine(blockID: "search-parity", theme: .merinoDark)
        let bytes = Array("audit-marker audit-marker".utf8)
        bytes.withUnsafeBufferPointer { il_terminal_feed(engine.handle, $0.baseAddress, bytes.count) }
        var counts: [(Int, Int, Int)] = []
        var geometries: [[TerminalSearchSpan]] = []
        engine.onSearch = { counts.append(($0, $1, $2)) }
        engine.onSearchGeometry = { geometries.append($0) }
        engine.search("audit-marker")
        precondition(engine.frame()?.searchCount == 2 && counts.last?.0 == 2)
        precondition(geometries.last?.count == 1 && geometries.last?.first?.endColumn == 24)
        let reported = geometries.count
        _ = engine.frame()
        precondition(geometries.count == reported, "Unchanged selected geometry should not publish new UI state")
        engine.search("")
        precondition(counts.last?.0 == 0 && counts.last?.1 == 0 && counts.last?.2 == -1 && geometries.last == [])
        precondition(engine.frame()?.searchCount == 0)

        engine.search("audit-marker"); _ = engine.frame()
        let ready = try Data(contentsOf: URL(fileURLWithPath: ".build/tests/search-contrast/snapshot-ready.bin"))
        engine.receive(WireMessage(type: "snapshot", stream: "new-reconnection", data: ready, cols: 120, rows: 12))
        precondition(engine.frame()?.searchCount == 1 && counts.last?.0 == 1, "Snapshot replacement must restore the active query")
        precondition(geometries.last?.count == 1)
        var firstListenerUpdate: [TerminalSearchSpan]?
        engine.onSearchGeometry = { firstListenerUpdate = $0 }
        _ = engine.frame()
        precondition(firstListenerUpdate?.count == 1, "A remounted pane needs the current selected geometry")
        engine.search("no-such-marker"); _ = engine.frame()
        precondition(counts.last?.0 == 0 && firstListenerUpdate == [], "No matches must clear selected geometry")

        let wrapped = TerminalEngine(blockID: "wrapped-geometry", theme: .merinoDark)
        wrapped.resizeFromServer(columns: 20, rows: 4)
        let text = "abcdefghijklmnopqrstuvw\r\nline2\r\nline3\r\nline4\r\nline5\r\n"
        Data(text.utf8).withUnsafeBytes { il_terminal_feed(wrapped.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        var spans: [TerminalSearchSpan] = []
        wrapped.onSearchGeometry = { spans = $0 }
        wrapped.search("abcdefghijklmnopqrstuvw"); wrapped.scrollTo(0); _ = wrapped.frame()
        precondition(spans == [TerminalSearchSpan(row: 0, startColumn: 0, endColumn: 19), TerminalSearchSpan(row: 1, startColumn: 0, endColumn: 2)])
        wrapped.scrollTo(1); _ = wrapped.frame()
        precondition(spans == [TerminalSearchSpan(row: 0, startColumn: 0, endColumn: 2)])
        wrapped.scrollBottom(); _ = wrapped.frame()
        precondition(spans.isEmpty)
        print("Search engine: immediate clear, reconnect query restoration, independent pane queries, remount publication, and clipped/wrapped selected geometry passed.")

        testServiceTheme(ready: ready)
        testContrast()
    }

    @MainActor
    static func testServiceTheme(ready: Data) {
        let engine = TerminalEngine(blockID: "theme-parity", theme: .merinoDark)
        var errors = 0
        engine.onError = { _ in errors += 1 }
        engine.applyServiceTheme(WireTheme(background: nil, foreground: 0x123456, cursor: nil, palette: nil))
        var frame = engine.frame()!
        precondition(frame.background == 0 && frame.foreground == 0x123456 && frame.cursorColor == 0x123456)
        precondition(engine.theme.background == 0 && engine.theme.foreground == 0x123456 && engine.theme.accent == 0x123456)
        let palette = (UInt32(0)...255).map { $0 * 0x010101 }
        engine.applyServiceTheme(WireTheme(background: 0x010203, foreground: 0xdddddd, cursor: 0xff0088, palette: palette))
        func feed(_ text: String) {
            Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        }
        feed("\u{1b}[H\u{1b}[38;5;200mX\u{1b}[48;5;201mY")
        frame = engine.frame()!
        precondition(frame.background == 0x010203 && frame.cursorColor == 0xff0088)
        precondition(frame.cells![0].foreground == 0xc8c8c8 && frame.cells![1].background == 0xc9c9c9)
        engine.applyServiceTheme(WireTheme())
        frame = engine.frame()!
        precondition(frame.background == 0 && frame.foreground == 0xffffff && frame.cursorColor == 0xffffff)
        precondition(frame.cells![0].foreground == 0xff00d7, "An omitted palette restores Ghostty's built-in extended colors")
        feed("\u{1b}]4;200;#123abc\u{7}\u{1b}]10;#abcdef\u{7}\u{1b}]11;#113355\u{7}\u{1b}]12;#2468ac\u{7}")
        engine.applyServiceTheme(WireTheme())
        frame = engine.frame()!
        precondition(frame.background == 0x113355 && frame.foreground == 0xabcdef && frame.cursorColor == 0x2468ac)
        precondition(frame.cells![0].foreground == 0x123abc, "Application OSC color overrides must survive default-theme changes")
        engine.receive(WireMessage(type: "snapshot", stream: "theme-reconnect", data: ready, cols: 120, rows: 12))
        frame = engine.frame()!
        precondition(frame.background == 0 && frame.foreground == 0xffffff, "A cleared service theme must survive reconnect")
        engine.applyServiceTheme(WireTheme(background: 0x1000000, palette: [1]))
        precondition(errors == 1 && engine.frame()!.background == 0, "Invalid color or palette data must not partially change the terminal")
        engine.applyTheme(.merinoLight)
        frame = engine.frame()!
        precondition(frame.background == TerminalTheme.merinoLight.background)
        engine.receive(WireMessage(type: "snapshot", stream: "local-theme-reconnect", data: ready, cols: 120, rows: 12))
        precondition(engine.frame()!.background == TerminalTheme.merinoLight.background, "An explicit local theme supersedes the service override")
        print("Service themes: partial/default colors, 256-color palette, reset, OSC override preservation, reconnect persistence, validation, and explicit local replacement passed.")
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ color: UInt32) -> Double {
            func linear(_ value: UInt32) -> Double {
                let n = Double(value) / 255
                return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color >> 16 & 255) + 0.7152 * linear(color >> 8 & 255) + 0.0722 * linear(color & 255)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func testContrast() {
        let regressions: [(UInt32, UInt32)] = [(0x888888, 0x808080), (0x444444, 0x999999), (0xeeeeee, 0xffffff), (0x222222, 0x111111)]
        for (fg, bg) in regressions {
            let corrected = ContrastCorrection.correct(fg, background: bg, target: 0xdddddd)
            precondition(ratio(corrected, bg) >= 4.5)
            print(String(format: "Contrast #%06x on #%06x -> #%06x %.6f:1", fg, bg, corrected, ratio(corrected, bg)))
        }
        for gray in UInt32(0)...255 {
            let color = gray * 0x010101
            for target: UInt32 in [0, 0xffffff, 0xff0088] {
                precondition(ratio(ContrastCorrection.correct(color, background: color, target: target), color) >= 4.5)
            }
        }
        var random: UInt64 = 0x676c797068
        func color() -> UInt32 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return UInt32((random >> 16) & 0xffffff)
        }
        for _ in 0..<20_000 {
            let fg = color(), bg = color(), target = color()
            let corrected = ContrastCorrection.correct(fg, background: bg, target: target)
            precondition(ratio(corrected, bg) >= 4.5, "Quantized RGB must meet the contrast target")
            if ratio(fg, bg) >= 4.5 { precondition(corrected == fg, "Already readable colors must remain unchanged") }
        }
        print("Contrast: 256 grays with three theme targets and 20,000 deterministic RGB pairs meet 4.5 after quantization; readable colors remain unchanged.")
    }
}
