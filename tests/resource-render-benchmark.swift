// The runner concatenates this harness with MetalRenderer.swift so it exercises
// the actual private atlas and quad types without exposing production test APIs.
// No window, terminal daemon, PTY, or display link is created.
extension GlyphAtlas {
    func legacyCapacityMiss(_ key: Key) -> Entry? {
        if let cached = entries[key] { return cached }
        guard let bitmap = rasterizer.rasterize(key) else { return nil }
        if x + bitmap.width >= dimension { x = 0; y += lineHeight + 1; lineHeight = 0 }
        guard y + bitmap.height < dimension else { full = true; return nil }
        preconditionFailure("The benchmark must begin with an exhausted atlas")
    }
}

extension MetalTerminalRenderer {
    @MainActor
    static func verifyFullRenderThemeTransitions() {
        let device = device!
        precondition(MemoryLayout<TerminalQuad>.size == MemoryLayout<TerminalQuad>.stride && MemoryLayout<TerminalQuad>.stride == 64,
            "Single-quad uploads must contain the complete Metal array stride")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 320, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead];descriptor.storageMode = .shared
        let output = device.makeTexture(descriptor: descriptor)!
        var panes: [(TerminalEngine, MTKView, MetalTerminalRenderer)] = []
        for pane in 0..<4 {
            let engine = TerminalEngine(blockID: "render-theme-\(pane)", theme: .merinoDark)
            engine.resizeFromServer(columns: 30, rows: 8)
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 160), device: device)
            let renderer = MetalTerminalRenderer(engine: engine, view: view)!
            let text = "\u{1b}[41mExplicit background\u{1b}[0m\r\nArabic العربية / glyphs == \u{1b}[4:3mdecorated\u{1b}[0m"
            Data(text.utf8).withUnsafeBytes { il_terminal_feed(engine.handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            if pane == 0 {
                // Runtime ID avoids the Swift compiler's static-array tail-
                // padding overread in optimized Address Sanitizer fixtures.
                let imageID = UInt32(ProcessInfo.processInfo.processIdentifier)
                let image = WireGraphicsImage(id: imageID, generation: 1, width: 1, height: 1, format: 1, data: Data([255, 0, 0, 128]))
                let placement = WireGraphicsPlacement(imageID: imageID, imageGeneration: 1, id: 1, column: 0, row: 2,
                    xOffset: 0, yOffset: 0, pixelWidth: 100, pixelHeight: 25, sourceX: 0, sourceY: 0, sourceWidth: 1, sourceHeight: 1, z: 0)
                engine.receive(WireMessage(type: "graphics", graphics: WireGraphicsState(generation: 1, reset: true, cellWidth: 8, cellHeight: 16, images: [image], placements: [placement])))
            }
            panes.append((engine, view, renderer))
        }
        for step in 0..<40 {
            for (engine, view, renderer) in panes {
                var theme = step % 2 == 0 ? TerminalTheme.merinoLight : .merinoDark
                theme.backgroundOpacity = step % 3 == 0 ? 1 : 0.55
                theme.backgroundOpacityCells = true
                engine.applyTheme(theme)
                renderer.presentation.invalidate()
                var slot = renderer.presentation.beginAcquisition()
                while slot == nil {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
                    slot = renderer.presentation.beginAcquisition()
                }
                renderer.presentation.acquired()
                renderer.render(in: view, texture: output, drawable: nil, slot: slot!)
            }
        }
        // Fence the renderer queues before releasing shared output/resources.
        for (_, _, renderer) in panes {
            let fence = renderer.queue.makeCommandBuffer()!;fence.commit();fence.waitUntilCompleted()
            precondition(fence.status == .completed)
            renderer.detach()
        }
        print("Actual full renderer: four panes, image placement, contextual text and 40 opaque/translucent light/dark transitions passed.")
    }

    @MainActor
    static func verifyStaticImages() throws {
        let device = device!
        let cache = TerminalImageTextureCache(byteLimit: 64 * 1_024)
        var image = WireGraphicsImage(id: 1, generation: 1, width: 1, height: 1, format: 0, data: Data([255, 0, 0]))
        func pixel(_ texture: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            return bytes
        }
        let first = cache.texture(device: device, namespace: "one", image: image)!
        precondition(pixel(first) == [255, 0, 0, 255])
        precondition(cache.texture(device: device, namespace: "one", image: image) === first)
        image.generation = 2;image.format = 1;image.data = Data([0, 255, 0, 128])
        let rgba = cache.texture(device: device, namespace: "one", image: image)!
        precondition(rgba !== first && pixel(rgba) == [0, 255, 0, 128] && cache.count == 1)
        image.generation = 3;image.format = 3;image.data = Data([70, 80])
        precondition(pixel(cache.texture(device: device, namespace: "one", image: image)!) == [70, 70, 70, 80])
        image.generation = 4;image.format = 4;image.data = Data([90])
        precondition(pixel(cache.texture(device: device, namespace: "one", image: image)!) == [90, 90, 90, 255])
        cache.prune(namespace: "one", images: [:]);precondition(cache.byteCount == 0 && cache.count == 0)
        for number in 1...20 {
            let large = WireGraphicsImage(id: UInt32(number), generation: UInt64(number), width: 64, height: 64, format: 1,
                data: Data(repeating: UInt8(number), count: 64 * 64 * 4))
            precondition(cache.texture(device: device, namespace: "bounded", image: large) != nil)
            precondition(cache.byteCount <= cache.byteLimit)
        }
        precondition(cache.count < 20)

        image = WireGraphicsImage(id: 1, generation: 5, width: 2, height: 2, format: 1, data: Data(repeating: 255, count: 16))
        var placement = WireGraphicsPlacement(imageID: 1, imageGeneration: 5, id: 1, column: 0, row: -1, xOffset: 0, yOffset: 0,
            pixelWidth: 4, pixelHeight: 4, sourceX: 0, sourceY: 0, sourceWidth: 2, sourceHeight: 2, z: 0)
        var scene = TerminalGraphicsState();scene.cellWidth = 2;scene.cellHeight = 2
        var frame = ILFrame();frame.columns = 20;frame.rows = 4;frame.scrollTotal = 104;frame.scrollOffset = 100
        let clipped = imageQuad(placement: placement, image: image, scene: scene, frame: frame, cell: CGSize(width: 10, height: 10),
            fit: 1, inset: 8, bounds: CGRect(x: 0, y: 0, width: 216, height: 56))!
        precondition(clipped.rect == SIMD4(8, 8, 20, 10) && clipped.uv == SIMD4(0, 0.5, 1, 0.5), "Top clipping must crop UVs with the image")
        frame.scrollOffset = 99
        let scrolled = imageQuad(placement: placement, image: image, scene: scene, frame: frame, cell: CGSize(width: 10, height: 10),
            fit: 1, inset: 8, bounds: CGRect(x: 0, y: 0, width: 216, height: 56))!
        precondition(scrolled.rect == SIMD4(8, 8, 20, 20) && scrolled.uv == SIMD4(0, 0, 1, 1))
        // Restoring additional history must not move a bottom-relative image.
        frame.scrollTotal += 1_000;frame.scrollOffset += 1_000
        let restored = imageQuad(placement: placement, image: image, scene: scene, frame: frame, cell: CGSize(width: 10, height: 10),
            fit: 1, inset: 8, bounds: CGRect(x: 0, y: 0, width: 216, height: 56))!
        precondition(restored.rect == scrolled.rect)
        placement.row = -1_000
        precondition(imageQuad(placement: placement, image: image, scene: scene, frame: frame, cell: CGSize(width: 10, height: 10),
            fit: 1, inset: 8, bounds: CGRect(x: 0, y: 0, width: 216, height: 56)) == nil)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead];descriptor.storageMode = .shared
        let output = device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor();pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let command = device.makeCommandQueue()!.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        var quad = TerminalQuad(rect: SIMD4(0, 0, 2, 2), uv: SIMD4(0, 0, 1, 1), color: SIMD4(repeating: 1), textured: 8)
        encoder.setVertexBytes(&quad, length: MemoryLayout<TerminalQuad>.stride, index: 0)
        var viewport = SIMD2<Float>(2, 2);encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setRenderPipelineState(makePipeline(device: device, blending: true)!)
        encoder.setFragmentTexture(rgba, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        precondition(command.status == .completed && pixel(output) == [0, 128, 0, 128], "Image shader must convert straight RGBA to premultiplied window pixels")
        print("Actual Metal images: RGB/RGBA/gray upload, generation replacement, cache reuse/delete/LRU bound, clipped UVs, independent scroll/history anchors, and premultiplied image pixels passed.")
    }

    @MainActor
    static func verifyTranslucentBackgrounds() throws {
        let device = device!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 4, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0, blue: 0, alpha: 0.5)
        let quads = [
            TerminalQuad(rect: SIMD4(4, 0, 4, 4), uv: .zero, color: rgba(0x00ff00, alpha: 0.5), textured: 0),
            TerminalQuad(rect: SIMD4(8, 0, 4, 4), uv: .zero, color: rgba(0x00ff00), textured: 0),
            TerminalQuad(rect: SIMD4(12, 0, 4, 4), uv: .zero, color: rgba(0x0000ff), textured: 0)
        ]
        let buffer = quads.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        let command = device.makeCommandQueue()!.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(16, 4)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setRenderPipelineState(makePipeline(device: device, blending: false)!)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 2)
        encoder.setRenderPipelineState(makePipeline(device: device, blending: true)!)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1, baseInstance: 2)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed)
        var bytes = [UInt8](repeating: 0, count: 16 * 4 * 4)
        texture.getBytes(&bytes, bytesPerRow: 16 * 4, from: MTLRegionMake2D(0, 0, 16, 4), mipmapLevel: 0)
        func pixel(_ x: Int) -> [UInt8] { Array(bytes[(16 + x) * 4..<(16 + x + 1) * 4]) }
        precondition(pixel(1) == [0, 0, 128, 128], "Default background must stay premultiplied translucent red")
        precondition(pixel(5) == [0, 128, 0, 128], "Explicit translucent background must replace, not compound, clear opacity")
        precondition(pixel(9) == [0, 255, 0, 255], "Selection/inverse backgrounds remain opaque")
        precondition(pixel(13) == [255, 0, 0, 255], "Foreground text must remain opaque over a translucent window")
        print("Actual Metal opacity: premultiplied clear, explicit background replacement, opaque selection/inverse and foreground passed.")
    }

    @MainActor
    static func verifyTextBlinkTimers() {
        let engine = TerminalEngine(blockID: "text-blink-resource", theme: .merinoDark)
        let view = MTKView(frame: .zero, device: device)
        guard let renderer = MetalTerminalRenderer(engine: engine, view: view) else { fatalError("Renderer/shader unavailable") }
        precondition(renderer.textBlinkTimer == nil)
        renderer.updateTextBlink(hasBlinkingText: false, canPresent: true)
        precondition(renderer.textBlinkTimer == nil, "An ordinary terminal must not create a text-blink timer")
        renderer.updateTextBlink(hasBlinkingText: true, canPresent: true)
        let timer = renderer.textBlinkTimer!
        precondition(timer.isValid)
        renderer.updateTextBlink(hasBlinkingText: true, canPresent: true)
        precondition(renderer.textBlinkTimer === timer, "Redraws must reuse the running blink timer")
        // This real view is unattached and cannot present. The actual timer
        // callback must detect that and stop, even without a lifecycle notice.
        timer.fire()
        precondition(!timer.isValid && renderer.textBlinkTimer == nil)
        renderer.updateTextBlink(hasBlinkingText: true, canPresent: true)
        let removed = renderer.textBlinkTimer!
        renderer.updateTextBlink(hasBlinkingText: false, canPresent: true)
        precondition(!removed.isValid && renderer.textBlinkTimer == nil)
        renderer.updateTextBlink(hasBlinkingText: true, canPresent: true)
        let detached = renderer.textBlinkTimer!
        renderer.detach()
        precondition(!detached.isValid && renderer.textBlinkTimer == nil)
        print("Actual renderer timers: absent without blinking text; reused across frames; stopped on hidden callback, content removal, and detach.")
    }
}

@main
struct ResourceRenderBenchmark {
    @MainActor
    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device unavailable") }
        MetalTerminalRenderer.verifyFullRenderThemeTransitions()
        if ProcessInfo.processInfo.environment["ILLOGICAL_RENDER_SANITIZE"] == "1" { return }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cell = NSSize(width: 8, height: 19)
        func create(_ size: CGFloat) -> GlyphAtlas {
            GlyphAtlas(device: device, font: NSFont(descriptor: font.fontDescriptor, size: size)!, scale: 2, cell: cell, options: .defaults)
        }
        let baselineBytes = autoreleasepool {
            let start = device.currentAllocatedSize
            var oldCache: [Int: GlyphAtlas] = [:]
            for size in 13..<22 {
                if oldCache.count > 8 { oldCache.removeAll() }
                oldCache[size] = create(CGFloat(size))
            }
            return withExtendedLifetime(oldCache) { device.currentAllocatedSize - start }
        }
        let pooledBytes = autoreleasepool {
            let start = device.currentAllocatedSize
            let pool = TerminalResourcePool<Int, GlyphAtlas>()
            for size in 13..<22 {
                _ = pool.resource(for: size, usable: { !$0.full }, create: { create(CGFloat(size)) })
            }
            return withExtendedLifetime(pool) { device.currentAllocatedSize - start }
        }
        precondition(pooledBytes * 8 < baselineBytes, "Obsolete atlas textures must be released")
        print("Nine sequential font sizes, actual Metal allocation: before=\(baselineBytes) after=\(pooledBytes) bytes")

        let atlas = create(13)
        // Fill the actual atlas with distinct keys, then benchmark an uncached
        // glyph at capacity. Previously every repeated miss was rasterized.
        for number in 0..<5_000 {
            _ = atlas.glyph(.init(text: "==\(number)", bold: false, italic: false, width: 24))
            if atlas.full { break }
        }
        precondition(atlas.full)
        let miss = GlyphAtlas.Key(text: "capacity-miss", bold: false, italic: false, width: 24)
        let missCount = 500
        let oldMiss = elapsed { for _ in 0..<missCount { precondition(atlas.legacyCapacityMiss(miss) == nil) } }
        let newMiss = elapsed { for _ in 0..<missCount { precondition(atlas.glyph(miss) == nil) } }
        print(String(format: "500 full-atlas misses: before=%.3f after=%.3f ms", oldMiss * 1_000, newMiss * 1_000))

        // Isolate CPU quad staging, including the production memcpy into a
        // shared Metal vertex buffer. This is not a whole-application FPS test.
        let cells = 134 * 35
        let count = cells * 2
        let buffer = device.makeBuffer(length: count * MemoryLayout<TerminalQuad>.stride, options: .storageModeShared)!
        let iterations = 2_000
        var checksum: Float = 0
        func element(_ index: Int, _ frame: Int) -> TerminalQuad {
            TerminalQuad(rect: SIMD4(Float(index), Float(frame), 8, 19), uv: .zero, color: SIMD4(1, 0, 0, 1), textured: 0)
        }
        func old() -> Double {
            elapsed {
                for frame in 0..<iterations {
                    var backgrounds: [TerminalQuad] = [], foregrounds: [TerminalQuad] = []
                    backgrounds.reserveCapacity(cells); foregrounds.reserveCapacity(cells)
                    for index in 0..<cells { backgrounds.append(element(index, frame)); foregrounds.append(element(index + cells, frame)) }
                    let quads = backgrounds + foregrounds
                    _ = quads.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
                    checksum += buffer.contents().assumingMemoryBound(to: TerminalQuad.self)[count - 1].rect.y
                }
            }
        }
        func new() -> Double {
            var backgrounds: [TerminalQuad] = [], foregrounds: [TerminalQuad] = []
            return elapsed {
                for frame in 0..<iterations {
                    backgrounds.removeAll(keepingCapacity: true); foregrounds.removeAll(keepingCapacity: true)
                    backgrounds.reserveCapacity(cells); foregrounds.reserveCapacity(cells)
                    for index in 0..<cells { backgrounds.append(element(index, frame)); foregrounds.append(element(index + cells, frame)) }
                    _ = backgrounds.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
                    _ = foregrounds.withUnsafeBytes { memcpy(buffer.contents().advanced(by: backgrounds.count * MemoryLayout<TerminalQuad>.stride), $0.baseAddress!, $0.count) }
                    checksum += buffer.contents().assumingMemoryBound(to: TerminalQuad.self)[count - 1].rect.y
                }
            }
        }
        var before: [Double] = [], after: [Double] = []
        for sample in 0..<5 {
            if sample.isMultiple(of: 2) { before.append(old()); after.append(new()) }
            else { after.append(new()); before.append(old()) }
            let quads = buffer.contents().assumingMemoryBound(to: TerminalQuad.self)
            for index in 0..<count {
                precondition(quads[index].rect == SIMD4(Float(index), Float(iterations - 1), 8, 19))
                precondition(quads[index].uv == .zero && quads[index].color == SIMD4(1, 0, 0, 1) && quads[index].textured == 0)
            }
        }
        precondition(checksum > 0)
        before.sort(); after.sort()
        print(String(format: "2,000 quad-staging frames, median of five: before=%.3f after=%.3f ms; checksum=%.0f", before[2] * 1_000, after[2] * 1_000, checksum))
        print("CPU staging allocations after warmup: 3 arrays/frame -> 0; quad bytes copied: \(count * MemoryLayout<TerminalQuad>.stride * 2) -> \(count * MemoryLayout<TerminalQuad>.stride)/frame")
        MetalTerminalRenderer.verifyTextBlinkTimers()
        try! MetalTerminalRenderer.verifyTranslucentBackgrounds()
        try! MetalTerminalRenderer.verifyStaticImages()
    }

    static func elapsed(_ operation: () -> Void) -> Double {
        let start = CACurrentMediaTime(); operation(); return CACurrentMediaTime() - start
    }
}
