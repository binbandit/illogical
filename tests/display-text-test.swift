// Concatenated with MetalRenderer.swift to test the production atlas, encoder
// and presentation scheduling through real Metal readback.
import ImageIO
import UniformTypeIdentifiers

@MainActor
private final class DisplayTextWindow: NSWindow {
    var testScale: CGFloat = 1
    override var backingScaleFactor: CGFloat { testScale }
    // Offscreen test windows count as visible so presentation runs.
    override var occlusionState: NSWindow.OcclusionState { [.visible] }
}

/// Reports a failed check and exits. A trap would raise a crash-report
/// dialog on the developer's desktop.
private func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "") {
    guard !condition() else { return }
    FileHandle.standardError.write(Data("FAIL: \(message())\n".utf8))
    exit(1)
}

/// BGRA pixels read back from one offscreen frame.
private struct Readback {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let metrics: TerminalCellMetrics
    let scale: CGFloat

    func pixel(_ x: Int, _ y: Int) -> UInt32 {
        let offset = (y * width + x) * 4
        return UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset])
    }

    /// Top-left device pixel of a cell.
    func origin(column: Int, row: Int) -> (x: Int, y: Int) {
        (Int(MetalTerminalRenderer.padding * scale) + column * metrics.cellWidth, Int(MetalTerminalRenderer.padding * scale) + row * metrics.cellHeight)
    }

    func write(_ path: String) {
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        expect(CGImageDestinationFinalize(destination))
    }
}

/// The owner's Ghostty configuration.
private let ownerOptions = TerminalFontOptions.importGhostty(entries: [
    ("font-thicken", "true"), ("font-thicken-strength", "100"), ("font-variation", "wght=420"), ("font-feature", "+calt"),
    ("font-feature", "+zero"), ("adjust-cell-height", "10%"), ("cursor-style", "bar"), ("cursor-style-blink", "false"),
    ("adjust-cursor-thickness", "2"), ("window-colorspace", "display-p3")
])

extension MetalTerminalRenderer {
    /// Renders `text` through the production renderer into an offscreen texture.
    @MainActor
    fileprivate static func renderOffscreen(_ text: String, columns: UInt16, rows: UInt16, scale: CGFloat, bounds: CGRect,
                                            theme: TerminalTheme = .merinoDark, thenChange change: ((MetalTerminalRenderer) -> Void)? = nil,
                                            configure: (MetalTerminalRenderer) -> Void) -> Readback {
        let window = DisplayTextWindow(contentRect: bounds, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testScale = scale
        let view = MTKView(frame: bounds, device: device!)
        window.contentView = view
        // AppKit may round a content view during attachment. Exercise
        // fractional split-pane bounds explicitly after attachment.
        view.bounds = bounds
        let engine = TerminalEngine(blockID: "display-text", theme: theme)
        engine.resizeFromServer(columns: columns, rows: rows)
        Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        let renderer = MetalTerminalRenderer(engine: engine, view: view)!
        configure(renderer)
        let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let output = device!.makeTexture(descriptor: descriptor)!
        func frame() {
            renderer.presentation.invalidate()
            let slot = renderer.presentation.beginAcquisition()!
            renderer.presentation.acquired()
            renderer.render(in: view, texture: output, drawable: nil, slot: slot)
            let fence = renderer.queue.makeCommandBuffer()!
            fence.commit()
            fence.waitUntilCompleted()
            expect(fence.status == .completed)
            // Return the buffer slot the completed command held.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        frame()
        if let change {
            change(renderer)
            frame()
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let readback = Readback(bytes: bytes, width: width, height: height, metrics: renderer.metrics, scale: scale)
        renderer.detach()
        window.contentView = nil
        window.close()
        return readback
    }

    @MainActor
    static func verifyDisplayText() {
        var failures: [String] = []
        for scale: CGFloat in [1, 2] {
            for size: CGFloat in [12, 13, 14, 15] {
                for fractional in [false, true] {
                    let bounds = CGRect(x: 0, y: 0, width: fractional ? 420.35 : 420, height: fractional ? 120.35 : 120)
                    var theme = TerminalTheme.merinoDark
                    theme.background = 0
                    theme.foreground = 0xffffff
                    let text = "\u{1b}[?25l" + String(repeating: "H", count: 24) + "\r\nThe quick brown fox 0123456789"
                    let frame = renderOffscreen(text, columns: 32, rows: 3, scale: scale, bounds: bounds, theme: theme) {
                        $0.fontSize = size
                        $0.contrastCorrection = false
                    }
                    let cellWidth = frame.metrics.cellWidth, cellHeight = frame.metrics.cellHeight
                    func tile(_ column: Int) -> [UInt8] {
                        let (x, y) = frame.origin(column: column, row: 0)
                        return (0..<cellHeight).flatMap { row in Array(frame.bytes[((y + row) * frame.width + x) * 4..<((y + row) * frame.width + x + cellWidth) * 4]) }
                    }
                    let reference = tile(0)
                    let different = (1..<24).filter { tile($0) != reference }.count
                    let label = "scale=\(scale), font=\(size), fractional=\(fractional), cellPixels=\(cellWidth), differentColumns=\(different)"
                    print(label)
                    if different != 0 { failures.append(label) }
                    if size == 13 && !fractional { frame.write(".build/display-text/text-\(Int(scale))x.png") }
                }
            }
        }
        expect(failures.isEmpty, "Repeated glyphs must retain identical coverage at every device-pixel column: \(failures)")
        print("Display text: real Metal readback preserves repeated glyph pixels at 1x/2x, four font sizes, and fractional pane bounds.")
    }

    /// Cursor shapes and colors follow Ghostty's sprites with the owner's options.
    @MainActor
    static func verifyCursors() {
        let theme = TerminalTheme.merinoDark
        let background = theme.background, cursor = theme.accent
        for scale: CGFloat in [1, 2] {
            func render(_ sequence: String, focused: Bool = true) -> Readback {
                renderOffscreen("ab\u{1b}[H\u{1b}[C\(sequence)", columns: 6, rows: 1, scale: scale,
                                bounds: CGRect(x: 0, y: 0, width: 120, height: 50)) {
                    $0.fontName = "Menlo"; $0.fontSize = 14; $0.fontOptions = ownerOptions; $0.focused = focused
                }
            }
            let bar = render("\u{1b}[6 q")
            let metrics = bar.metrics, (x, y) = bar.origin(column: 1, row: 0)
            let middle = y + metrics.cellHeight / 2
            expect(metrics.cursorThickness == 3 && metrics.cursorHeight < metrics.cellHeight)
            let barColumns = (x - 4..<x + 4).filter { bar.pixel($0, middle) == cursor }
            expect(barColumns == Array(x - 2..<x + 1), "The bar must be three pixels straddling the cell edge: \(barColumns)")
            expect(bar.pixel(x - 1, y + metrics.cursorTop - 1) == background && bar.pixel(x - 1, y + metrics.cursorTop) == cursor,
                         "The bar keeps the font's height, centered in the taller cell")

            let block = render("\u{1b}[2 q")
            let blockTop = y + metrics.cursorTop
            expect(block.pixel(x + metrics.cellWidth - 1, blockTop) == cursor && block.pixel(x, blockTop + metrics.cursorHeight - 1) == cursor
                   && block.pixel(x, blockTop - 1) == background, "The block cursor fills the font's height in its cell")
            // Antialiased stems at 1x may not reach full coverage.
            func near(_ color: UInt32, _ target: UInt32) -> Bool {
                [16, 8, 0].allSatisfy { abs(Int((color >> $0) & 255) - Int((target >> $0) & 255)) < 48 }
            }
            let blockText = (0..<metrics.cellWidth).contains { near(block.pixel(x + $0, middle), background) }
            expect(blockText, "Text under the block cursor takes the background color")

            let underline = render("\u{1b}[4 q")
            let line = (y..<y + metrics.cellHeight).filter { underline.pixel(x + metrics.cellWidth / 2, $0) == cursor }
            expect(line.count == metrics.cursorThickness && line.first! - y == metrics.underlinePosition, "Underline cursor: \(line)")

            let hollow = render("\u{1b}[2 q", focused: false)
            let top = y + metrics.cursorTop
            expect(hollow.pixel(x + metrics.cellWidth / 2, top) == cursor && hollow.pixel(x, middle) == cursor
                         && hollow.pixel(x + metrics.cellWidth - 1, middle) == cursor, "Unfocused cursors are hollow")
            expect(hollow.pixel(x + metrics.cursorThickness + 1, top + metrics.cursorThickness + 1) != cursor)
            if scale == 2 {
                for (name, frame) in [("bar", bar), ("block", block), ("underline", underline), ("hollow", hollow)] {
                    frame.write(".build/display-text/cursor-\(name).png")
                }
            }
        }
        print("Cursors: bar thickness/offset/height, block fill and inverted text, underline position and unfocused hollow outline at 1x/2x.")
    }

    /// Adjacent block elements tile without gaps, and procedural underlines
    /// keep their per-cell shapes.
    @MainActor
    static func verifyGeometry() {
        let e = "\u{1b}["
        let text = "\(e)?25l\(e)31;44m" + String(repeating: "▀", count: 10) + "\(e)0m\r\n"
            + "\(e)4:3m" + String(repeating: " ", count: 10) + "\(e)0m\r\n"
            + "\(e)4:4m" + String(repeating: " ", count: 10) + "\(e)0m\r\n"
            + "\(e)4:5m" + String(repeating: " ", count: 10) + "\(e)0m"
        var theme = TerminalTheme.merinoDark
        theme.ansi[1] = 0xff0000
        theme.ansi[4] = 0x0000ff
        for scale: CGFloat in [1, 2] {
            let frame = renderOffscreen(text, columns: 12, rows: 4, scale: scale, bounds: CGRect(x: 0, y: 0, width: 160, height: 120), theme: theme) {
                $0.fontName = "Menlo"; $0.fontSize = 14; $0.fontOptions = ownerOptions; $0.contrastCorrection = false
            }
            let metrics = frame.metrics
            let (left, top) = frame.origin(column: 0, row: 0)
            let halfBlock = metrics.cellHeight / 2
            for x in left..<left + metrics.cellWidth * 10 {
                expect(frame.pixel(x, top) == 0xff0000 && frame.pixel(x, top + halfBlock - 1) == 0xff0000, "Gap in upper half blocks at x=\(x)")
                expect(frame.pixel(x, top + metrics.cellHeight - 1) == 0x0000ff, "Half block background must fill the cell")
            }
            func strokeRows(_ row: Int, column: Int) -> Set<Int> {
                let (x, y) = frame.origin(column: column, row: row)
                return Set((y..<y + metrics.cellHeight + metrics.cellHeight / 4).filter { frame.pixel(x, $0) != theme.background })
            }
            let curlRows = (0..<metrics.cellWidth).reduce(into: Set<Int>()) { rows, offset in
                let (x, y) = frame.origin(column: 2, row: 1)
                rows.formUnion((y..<y + metrics.cellHeight + metrics.cellHeight / 4).filter { frame.pixel(x + offset, $0) != theme.background })
            }
            expect(curlRows.count > metrics.underlineThickness * 2, "The undercurl must wave, not draw a straight line")
            let (dotX, dotY) = frame.origin(column: 0, row: 2)
            let dotRow = dotY + metrics.underlinePosition + metrics.underlineThickness / 2
            let dotCoverage = (dotX..<dotX + metrics.cellWidth * 4).map { frame.pixel($0, dotRow) != theme.background }
            expect(dotCoverage.contains(true) && dotCoverage.contains(false), "Dotted underlines need dots and gaps")
            let (dashX, dashY) = frame.origin(column: 0, row: 3)
            let dash = metrics.cellWidth / 3 + 1
            let dashRow = dashY + metrics.underlinePosition
            expect(frame.pixel(dashX, dashRow) != theme.background && frame.pixel(dashX + dash, dashRow) == theme.background,
                         "Dashes follow Ghostty's one-third-cell pattern")
            expect(strokeRows(3, column: 1) == strokeRows(3, column: 5), "Every cell repeats the same dash")
            if scale == 2 { frame.write(".build/display-text/geometry-2x.png") }
        }
        print("Geometry: seamless half blocks, waving undercurl, dotted gaps and per-cell dashes at 1x/2x.")
    }

    /// Changing typography on a live renderer must draw exactly what a fresh
    /// renderer with those settings draws: no stale atlas, metrics or layer state.
    @MainActor
    static func verifyLiveFontChanges() {
        let e = "\u{1b}["
        let text = "\(e)?25hHello \(e)1mbold\(e)0m \(e)3mitalic\(e)0m -> ═╗ ▀ \(e)4:3mcurl\(e)0m 中 \u{f115}"
        var heavy = TerminalFontOptions.defaults
        heavy.variations = ["wght": 560]
        heavy.thicken = true
        heavy.cellHeight = .percent(0.1)
        heavy.cursorThickness = .pixels(4)
        heavy.features = ["calt": 0]
        let changes: [(String, (MetalTerminalRenderer) -> Void)] = [
            ("family", { $0.fontName = "Menlo" }),
            ("size", { $0.fontSize = 16 }),
            ("options", { $0.fontOptions = heavy }),
            ("everything", { $0.fontName = "Menlo"; $0.fontSize = 11; $0.fontOptions = ownerOptions })
        ]
        for scale: CGFloat in [1, 2] {
            for (name, change) in changes {
                let bounds = CGRect(x: 0, y: 0, width: 420, height: 60)
                let fresh = renderOffscreen(text, columns: 40, rows: 2, scale: scale, bounds: bounds) { $0.focused = true; change($0) }
                let live = renderOffscreen(text, columns: 40, rows: 2, scale: scale, bounds: bounds, thenChange: change) { $0.focused = true }
                let unchanged = renderOffscreen(text, columns: 40, rows: 2, scale: scale, bounds: bounds) { $0.focused = true }
                expect(live.bytes != unchanged.bytes, "The \(name) change must be visible")
                expect(live.metrics == fresh.metrics && live.bytes == fresh.bytes, "Live \(name) change at \(scale)x differs from a fresh renderer")
            }
        }
        let system = CTFontCreateCopyWithAttributes(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), 26, nil, nil)
        let axes = (CTFontCopyVariationAxes(system) as? [[String: Any]]) ?? []
        expect(axes.contains { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == 0x77676874 },
               "The default system monospace face must expose a weight axis for `variations[\"wght\"]`")
        print("Live typography: family, size, features, weight, thickening and line height changes match fresh renders at 1x/2x.")
    }

    /// Renders a feature gallery with the owner's configuration for visual
    /// inspection. ILLOGICAL_GALLERY_FONT selects a locally installed font.
    @MainActor
    static func renderGallery() {
        let fontName = ProcessInfo.processInfo.environment["ILLOGICAL_GALLERY_FONT"] ?? TerminalFontOptions.defaultFontName
        let e = "\u{1b}["
        var colors = "", gradient = ""
        for index in 0..<16 { colors += "\(e)48;5;\(index)m \(String(format: "%X", index)) " }
        for index in 0..<64 { gradient += "\(e)48;2;\(index * 4);64;\(255 - index * 4)m " }
        let lines = [
            "ASCII  Il1| O0o {}[]() @#$%&* gjpqy_ WAVE ~`'\"",
            "Ligs   -> => == != <= >= === // /* */ :: ... <!-- --> || &&",
            "Hex    0x1F 0xFF www #{} |> <| ++ --",
            "Style  \(e)1mBold\(e)0m \(e)3mItalic\(e)0m \(e)1;3mBoldItalic\(e)0m \(e)2mFaint\(e)0m \(e)7mInverse\(e)0m \(e)9mStrike\(e)0m \(e)53mOver\(e)0m",
            "Lines  \(e)4mSingle\(e)0m \(e)4:2mDouble\(e)0m \(e)4:3mCurly\(e)0m \(e)4:4mDotted\(e)0m \(e)4:5mDashed\(e)0m \(e)58;2;255;80;80;4:3mTinted\(e)0m",
            colors + "\(e)0m",
            gradient + "\(e)0m",
            "Box    ┌──┬──┐ ╭──╮ ┏━━┓ ╔══╗ ░▒▓█ ▀▄▌▐ ▖▗▘▝",
            "       │  │  │ │  │ ┃  ┃ ║  ║ ░▒▓█ ▀▄▌▐ ▙▛▜▟",
            "       └──┴──┘ ╰──╯ ┗━━┛ ╚══╝ ░▒▓█ ▀▄▌▐ ⣿⠿⠛⠉",
            "PL     \(e)30;44m ~/src \(e)34;42m\u{e0b0}\(e)30m \u{e0a0} main \(e)32;49m\u{e0b0}\(e)0m \u{e0b2}\u{e0b0} \u{e0b6}\u{e0b4} \u{e0b3}\u{e0b1}",
            "Nerd   \u{f115} \u{f120} \u{e725} \u{f07b} \u{f013} \u{f0001} \u{e7a8}  ok",
            "Wide   中文 日本語 한국어 😀 👩🏽‍💻 🇦🇺 e\u{301}a\u{308}",
            "\(e)32m❯\(e)0m vim \(e)6 q"
        ]
        for scale: CGFloat in [1, 2] {
            // Ghostty enables grapheme clustering (mode 2027) by default.
            let frame = renderOffscreen("\(e)?25h\(e)?2027h" + lines.joined(separator: "\r\n"), columns: 72, rows: UInt16(lines.count), scale: scale,
                                        bounds: CGRect(x: 0, y: 0, width: 640, height: 340)) {
                $0.fontName = fontName; $0.fontSize = 14; $0.focused = true; $0.fontOptions = ownerOptions
            }
            let path = ".build/display-text/gallery-\(Int(scale))x.png"
            frame.write(path)
            print("Gallery (\(fontName)): \(path)")
        }
    }

    /// A surface that stops changing must stop presenting: one frame for a
    /// burst of output, no frames while idle, and a paused display link.
    @MainActor
    static func verifyIdlePresentation() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let window = DisplayTextWindow(contentRect: bounds, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.testScale = 2
        let engine = TerminalEngine(blockID: "idle", theme: .merinoDark)
        engine.resizeFromServer(columns: 40, rows: 8)
        let surface = NativeTerminalView(engine: engine)
        let renderer = surface.renderer!
        window.contentView = surface
        surface.frame = bounds
        surface.layoutSubtreeIfNeeded()
        func tick() {
            surface.layoutSubtreeIfNeeded()
            renderer.draw(in: surface.metal)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        func submitted(over ticks: Int) -> Int {
            let start = renderer.presentation.submittedRevision
            var frames = 0, last = start
            for _ in 0..<ticks {
                tick()
                if renderer.presentation.submittedRevision != last { frames += 1; last = renderer.presentation.submittedRevision }
            }
            return frames
        }
        expect(submitted(over: 10) >= 1, "The first frame must present")
        expect(submitted(over: 60) == 0 && surface.metal.isPaused, "An idle surface must stop presenting and pause its display link")
        for _ in 0..<500 { engine.receive(WireMessage(type: "output", data: Data("burst output line\r\n".utf8))) }
        expect(!surface.metal.isPaused)
        let burst = submitted(over: 40)
        expect(burst == 1, "A burst between display ticks must coalesce into one frame, got \(burst)")
        expect(surface.metal.isPaused, "The display link pauses again after the burst")
        surface.detach()
        window.contentView = nil
        window.close()
        print("Idle presentation: one frame per output burst, no idle frames, paused display link.")
    }
}

@main
struct DisplayTextTest {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        MetalTerminalRenderer.verifyDisplayText()
        MetalTerminalRenderer.verifyCursors()
        MetalTerminalRenderer.verifyGeometry()
        MetalTerminalRenderer.verifyIdlePresentation()
        MetalTerminalRenderer.verifyLiveFontChanges()
        MetalTerminalRenderer.renderGallery()
    }
}
