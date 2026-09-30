// Concatenated with MetalRenderer.swift to test the production atlas and encoder.
import ImageIO
import UniformTypeIdentifiers

@MainActor
private final class DisplayTextWindow: NSWindow {
    var testScale: CGFloat = 1
    override var backingScaleFactor: CGFloat { testScale }
}

extension MetalTerminalRenderer {
    @MainActor
    static func verifyDisplayText() {
        _ = NSApplication.shared
        let device = device!
        var failures: [String] = []
        for scale: CGFloat in [1, 2] {
            for size: CGFloat in [12, 13, 14, 15] {
                for fractional in [false, true] {
                    let bounds = CGRect(x: 0, y: 0, width: fractional ? 420.35 : 420, height: fractional ? 120.35 : 120)
                    let window = DisplayTextWindow(contentRect: bounds, styleMask: [], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false;window.testScale = scale
                    let view = MTKView(frame: bounds, device: device)
                    window.contentView = view
                    // AppKit may round a content view during attachment. Exercise
                    // fractional split-pane bounds explicitly after attachment.
                    view.bounds = bounds
                    var theme = TerminalTheme.merinoDark;theme.background = 0;theme.foreground = 0xffffff
                    let engine = TerminalEngine(blockID: "display-text", theme: theme)
                    engine.resizeFromServer(columns: 32, rows: 3)
                    let text = "\u{1b}[?25l" + String(repeating: "H", count: 24) + "\r\nThe quick brown fox 0123456789"
                    Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                    let renderer = MetalTerminalRenderer(engine: engine, view: view)!
                    renderer.fontSize = size;renderer.contrastCorrection = false
                    let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                    descriptor.usage = [.renderTarget, .shaderRead];descriptor.storageMode = .shared
                    let output = device.makeTexture(descriptor: descriptor)!
                    renderer.presentation.invalidate()
                    let slot = renderer.presentation.beginAcquisition()!;renderer.presentation.acquired()
                    renderer.render(in: view, texture: output, drawable: nil, slot: slot)
                    let fence = renderer.queue.makeCommandBuffer()!;fence.commit();fence.waitUntilCompleted()
                    precondition(fence.status == .completed)
                    var bytes = [UInt8](repeating: 0, count: width * height * 4)
                    output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    let cell = renderer.cell
                    let pixelsWide = Int(round(cell.width * scale)), pixelsHigh = Int(round(cell.height * scale))
                    func tile(_ column: Int) -> [UInt8] {
                        let x = Int(round((8 + CGFloat(column) * cell.width) * scale)), y = Int(8 * scale)
                        return (0..<pixelsHigh).flatMap { row in Array(bytes[((y + row) * width + x) * 4..<((y + row) * width + x + pixelsWide) * 4]) }
                    }
                    let reference = tile(0)
                    let different = (1..<24).filter { tile($0) != reference }.count
                    let label = "scale=\(scale), font=\(size), fractional=\(fractional), cellPixels=\(cell.width * scale), differentColumns=\(different)"
                    print(label)
                    if different != 0 || cell.width * scale != round(cell.width * scale) { failures.append(label) }
                    if size == 13 && !fractional {
                        // Retain native-size pixels for visual inspection.
                        let data = Data(bytes) as CFData
                        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                        let url = URL(fileURLWithPath: ".build/display-text/text-\(Int(scale))x.png")
                        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                        CGImageDestinationAddImage(destination, image, nil);precondition(CGImageDestinationFinalize(destination))
                    }
                    renderer.detach();window.contentView = nil;window.close()
                }
            }
        }
        fflush(stdout)
        precondition(failures.isEmpty, "Repeated glyphs must retain identical coverage at every device-pixel column: \(failures)")
        print("Display text: real Metal readback preserves repeated glyph pixels at 1x/2x, four font sizes, and fractional pane bounds.")
    }
}

extension MetalTerminalRenderer {
    /// Renders a feature gallery through the production encoder for visual
    /// inspection. ILLOGICAL_GALLERY_FONT selects a locally installed font.
    @MainActor
    static func renderGallery() {
        let fontName = ProcessInfo.processInfo.environment["ILLOGICAL_GALLERY_FONT"] ?? "SF Mono"
        let e = "\u{1b}["
        var colors = "", gradient = ""
        for index in 0..<16 { colors += "\(e)48;5;\(index)m \(String(format: "%X", index)) " }
        for index in 0..<64 {
            let red = index * 4, blue = 255 - index * 4
            gradient += "\(e)48;2;\(red);64;\(blue)m "
        }
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
        let text = "\(e)?25h" + lines.joined(separator: "\r\n")
        for scale: CGFloat in [1, 2] {
            let bounds = CGRect(x: 0, y: 0, width: 640, height: 340)
            let window = DisplayTextWindow(contentRect: bounds, styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false;window.testScale = scale
            let view = MTKView(frame: bounds, device: device!)
            window.contentView = view
            let engine = TerminalEngine(blockID: "gallery", theme: .merinoDark)
            engine.resizeFromServer(columns: 72, rows: UInt16(lines.count))
            Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            let renderer = MetalTerminalRenderer(engine: engine, view: view)!
            renderer.fontName = fontName;renderer.fontSize = 14;renderer.focused = true
            // The owner's Ghostty configuration.
            renderer.fontOptions = .importGhostty(entries: [("font-thicken", "true"), ("font-thicken-strength", "100"),
                ("font-variation", "wght=420"), ("font-feature", "+calt"), ("font-feature", "+zero"), ("adjust-cell-height", "10%"),
                ("cursor-style", "bar"), ("cursor-style-blink", "false"), ("adjust-cursor-thickness", "2"), ("window-colorspace", "display-p3")])
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead];descriptor.storageMode = .shared
            let output = device!.makeTexture(descriptor: descriptor)!
            renderer.presentation.invalidate()
            let slot = renderer.presentation.beginAcquisition()!;renderer.presentation.acquired()
            renderer.render(in: view, texture: output, drawable: nil, slot: slot)
            let fence = renderer.queue.makeCommandBuffer()!;fence.commit();fence.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = URL(fileURLWithPath: ".build/display-text/gallery-\(Int(scale))x.png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil);precondition(CGImageDestinationFinalize(destination))
            print("Gallery (\(fontName)): \(url.path)")
            renderer.detach();window.contentView = nil;window.close()
        }
    }
}

@main
struct DisplayTextTest {
    @MainActor static func main() {
        MetalTerminalRenderer.verifyDisplayText()
        MetalTerminalRenderer.renderGallery()
    }
}
