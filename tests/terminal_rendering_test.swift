import AppKit
import CoreText
import ImageIO
import Metal
import UniformTypeIdentifiers

private struct Quad {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
    var textured: UInt32
}

@main
struct TerminalRenderingTest {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        let cell = NSSize(width: 12, height: 25)
        let raster = TerminalFontRasterizer(font: font, scale: 2, cell: cell)
        let imported = TerminalFontOptions.importGhostty(entries:[("font-variation","wght=420"),("font-feature","+calt"),("font-feature","+zero"),("font-feature","-liga"),("font-thicken","true"),("font-thicken-strength","100")])
        precondition(imported.features == ["calt":1,"zero":1,"liga":0] && imported.variations == ["wght":420] && imported.thicken && imported.thickenStrength == 100)
        let thin = raster.rasterize(.init(text:"M",bold:false,italic:false,width:1))!
        let thickRaster = TerminalFontRasterizer(font:font,scale:2,cell:cell,options:.init(thicken:true))
        let thick = thickRaster.rasterize(.init(text:"M",bold:false,italic:false,width:1))!
        let coverage: (TerminalFontRasterizer.Bitmap) -> Int = { image in stride(from:3,to:image.bytes.count,by:4).reduce(0) { $0 + Int(image.bytes[$1]) } }
        precondition(coverage(thick) > coverage(thin),"CoreText font thickening did not increase glyph coverage")
        let lighterRaster = TerminalFontRasterizer(font:font,scale:2,cell:cell,options:.init(thicken:true,thickenStrength:100))
        let lighter = lighterRaster.rasterize(.init(text:"M",bold:false,italic:false,width:1))!
        precondition(coverage(lighter) < coverage(thick),"Font smoothing strength was ignored")
        let variableURL = root.appendingPathComponent(".build/dependencies/ghostty/src/font/res/Lilex-VF.ttf")
        do {
            guard let provider = CGDataProvider(url:variableURL as CFURL), let graphicsFont = CGFont(provider) else { fatalError("Run scripts/bootstrap.sh to obtain the pinned variable-font test fixture") }
            let variable = CTFontCreateWithGraphicsFont(graphicsFont,18,nil,nil) as NSFont
            let configured=TerminalFontRasterizer(font:variable,scale:2,cell:cell,options:imported)
            let variations=CTFontCopyVariation(configured.resolvedFont(for:"M"))! as NSDictionary
            precondition((variations[NSNumber(value:0x77676874)] as? NSNumber)?.intValue == 420,"Weight variation was dropped")
            let on=TerminalFontRasterizer(font:variable,scale:2,cell:cell,options:.init(features:["calt":1,"liga":1]))
            let off=TerminalFontRasterizer(font:variable,scale:2,cell:cell,options:.init(features:["calt":0,"liga":0]))
            let key=TerminalFontRasterizer.Key(text:"==>",bold:false,italic:false,width:3)
            precondition(on.rasterize(key)!.bytes != off.rasterize(key)!.bytes,"Code operator ligatures were not shaped")
        }
        for text in ["\u{f115}", "\u{f120}", "\u{f013}", "\u{f1e0}", "\u{f0001}"] {
            let chosen = raster.resolvedFont(for: text)
            let coverage = CTFontCopyCharacterSet(chosen)
            precondition(text.unicodeScalars.allSatisfy { CFCharacterSetIsLongCharacterMember(coverage, $0.value) }, "Missing Nerd Font glyph: \(text)")
        }
        let bundled = root.appendingPathComponent("illogical/Resources/Fonts/JetBrainsMonoNerdFont-Regular.ttf")
        let bundledFont = CTFontCreateWithGraphicsFont(CGFont(CGDataProvider(url:bundled as CFURL)!)!,36,nil,nil)
        precondition(CFCharacterSetIsLongCharacterMember(CTFontCopyCharacterSet(bundledFont), 0xf0001), "Bundled fallback missing supplementary PUA")
        for (text,width) in [("e\u{301}",1),("中",2),("👩🏽‍💻",2),("🇦🇺",2),("\u{f115}",1)] {
            let bitmap = raster.rasterize(.init(text:text,bold:false,italic:false,width:width))!
            precondition(stride(from:3,to:bitmap.bytes.count,by:4).contains { bitmap.bytes[$0] > 0 }, "Empty glyph: \(text)")
            if text == "👩🏽‍💻" { precondition(bitmap.colored, "Emoji lost its color font") }
        }
        let device = MTLCreateSystemDefaultDevice()!
        let library = try device.makeLibrary(URL:root.appendingPathComponent(".build/tests/Terminal.metallib"))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"terminal_vertex")
        descriptor.fragmentFunction = library.makeFunction(name:"terminal_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let blend = descriptor.colorAttachments[0]!
        blend.isBlendingEnabled = true;blend.sourceRGBBlendFactor = .one;blend.sourceAlphaBlendFactor = .one
        blend.destinationRGBBlendFactor = .oneMinusSourceAlpha;blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:2048,height:2048,mipmapped:false)
        atlasDescriptor.storageMode = .shared;atlasDescriptor.usage = .shaderRead
        let atlas = device.makeTexture(descriptor:atlasDescriptor)!
        var atlasX = 0, atlasY = 0
        var quads: [Quad] = []
        func solid(_ rect: CGRect, color: SIMD4<Float>) {
            quads.append(Quad(rect:SIMD4(Float(rect.minX),Float(rect.minY),Float(rect.width),Float(rect.height)),uv:.zero,color:color,textured:0))
        }
        func glyph(_ text: String, at point: CGPoint, width: Int = 1, bold: Bool = false, italic: Bool = false, color:SIMD4<Float> = SIMD4(0.9,0.92,0.95,1)) {
            let bitmap = raster.rasterize(.init(text:text,bold:bold,italic:italic,width:width))!
            if atlasX + bitmap.width >= 2048 { atlasX=0;atlasY+=52 }
            bitmap.bytes.withUnsafeBytes { atlas.replace(region:MTLRegionMake2D(atlasX,atlasY,bitmap.width,bitmap.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:bitmap.width*4) }
            quads.append(Quad(rect:SIMD4(Float(point.x)-Float(bitmap.padding)/2,Float(point.y),Float(bitmap.width)/2,Float(bitmap.height)/2),
                              uv:SIMD4(Float(atlasX)/2048,Float(atlasY)/2048,Float(bitmap.width)/2048,Float(bitmap.height)/2048),color:bitmap.colored ? SIMD4(repeating:1) : color,textured:1))
            atlasX += bitmap.width + 1
        }
        let lines = [
            "ASCII:  Il1 O0 @ # $ % & / \\ |  gjpqy",
            "Nerd:   \u{f115} \u{f120} \u{f013} \u{f1e0} \u{f0001} \u{e0a0} \u{f489}",
            "Marks:  e\u{301} a\u{308} n\u{303} o\u{302} A\u{30a}",
            "Box:    ┌─────┬─────┐ ╭────╮ ┏━━━━┓",
            "        │     │     │ │    │ ┃    ┃",
            "        ├─────┼─────┤ ╰────╯ ┗━━━━┛",
            "        └─────┴─────┘ ╔════╗ ║ ╚══╝",
            "Braille: ⠁⠃⠇⡇⣇⣧⣷⣿ ⠉⠛⠿⣿",
            "Powerline: \u{e0b2}\u{e0b0} \u{e0b3}\u{e0b1} \u{e0b6}\u{e0b4}"
        ]
        for (row,line) in lines.enumerated() {
            for (column,char) in line.enumerated() { glyph(String(char),at:CGPoint(x:20+column*12,y:20+row*25)) }
        }
        var x: CGFloat = 20
        for text in ["中","文","日","本","語","👩🏽‍💻","🇦🇺","😀","🏳️‍🌈"] { glyph(text,at:CGPoint(x:x,y:260),width:2);x+=36 }
        for (index,char) in "Bold italic f gjpqy".enumerated() { glyph(String(char),at:CGPoint(x:20+index*12,y:300),bold:true,italic:true) }
        // Adjacent half-blocks must tile without font baseline gaps or color alteration.
        for col in 0..<32 {
            let rect=CGRect(x:20+col*12,y:350,width:12,height:25)
            solid(rect,color:SIMD4(0.05,0.15,0.9,1))
            for part in TerminalCellGeometry.blocks[0] {
                solid(CGRect(x:rect.minX+part.minX*rect.width,y:rect.minY+part.minY*rect.height,width:part.width*rect.width,height:part.height*rect.height),color:SIMD4(1,0.3,0.02,1))
            }
        }
        // Exercise the same procedural decoration shader used by the renderer.
        // Split the dash into adjacent pieces to verify uninterrupted phase.
        for (kind,x,width,phase,height) in [(UInt32(5),CGFloat(20),CGFloat(100),CGFloat(0),CGFloat(3)),
                                           (UInt32(6),CGFloat(150),CGFloat(100),CGFloat(0),CGFloat(1.5)),
                                           (UInt32(7),CGFloat(280),CGFloat(40),CGFloat(0),CGFloat(1)),
                                           (UInt32(7),CGFloat(320),CGFloat(60),CGFloat(40),CGFloat(1))] {
            quads.append(Quad(rect:SIMD4(Float(x),385,Float(width),Float(height)),
                              uv:SIMD4(Float(phase),0,Float(width),Float(height)),color:SIMD4(0,1,0,1),textured:kind))
        }
        var blink = TerminalTextBlinkState()
        blink.update(hasBlinkingText: true, canPresent: true)
        for x in [CGFloat(450),CGFloat(474),CGFloat(498)] {
            solid(CGRect(x:x,y:340,width:12,height:25),color:SIMD4(0.1,0.2,0.7,1))
        }
        if blink.drawsText(attributes: 4) { glyph("B",at:CGPoint(x:450,y:340),color:SIMD4(0,1,0,1)) }
        precondition(blink.advance())
        if blink.drawsText(attributes: 4) { glyph("B",at:CGPoint(x:474,y:340),color:SIMD4(0,1,0,1)) }
        if blink.drawsText(attributes: 0) { glyph("B",at:CGPoint(x:498,y:340),color:SIMD4(1,0,0,1)) }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1120,height:800,mipmapped:false)
        outputDescriptor.storageMode = .shared;outputDescriptor.usage = [.renderTarget]
        let output = device.makeTexture(descriptor:outputDescriptor)!
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColor(red:0.035,green:0.045,blue:0.06,alpha:1)
        let queue=device.makeCommandQueue()!,command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor:pass)!
        let buffer=quads.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
        encoder.setRenderPipelineState(pipeline);encoder.setVertexBuffer(buffer,offset:0,index:0)
        var viewport=SIMD2<Float>(560,400);encoder.setVertexBytes(&viewport,length:MemoryLayout<SIMD2<Float>>.stride,index:1)
        encoder.setFragmentTexture(atlas,index:0);encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:quads.count)
        encoder.endEncoding();command.commit();command.waitUntilCompleted()
        precondition(command.status == .completed,"Metal render failed")
        var pixels=[UInt8](repeating:0,count:1120*800*4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:1120*4,from:MTLRegionMake2D(0,0,1120,800),mipmapLevel:0) }
        for px in 40..<808 { precondition(pixels[(710*1120+px)*4]>250,"Gap in adjoining upper-half block") }
        func green(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 1120 + x) * 4 + 1] }
        var waveRows: Set<Int> = []
        for x in 40..<240 {
            let rows = (770..<776).filter { green(x, $0) > 140 }
            precondition(!rows.isEmpty, "Curly underline lost a column")
            waveRows.formUnion(rows)
        }
        precondition(waveRows.count >= 4, "Curly underline was rendered as a straight line")
        precondition((300..<500).contains { green($0, 771) > 220 } && (300..<500).contains { green($0, 771) < 30 }, "Dotted underline must have dots and gaps")
        precondition(green(560,771) < 30 && green(566,771) > 220 && green(571,771) < 30, "Dashed underline has the wrong period")
        precondition(green(639,771) > 220 && green(640,771) > 220, "Dash phase must remain continuous across adjacent cells")
        precondition((680..<730).contains { y in (900..<924).contains { green($0,y)>220 } }, "Visible blink phase must draw glyph pixels")
        for y in 680..<730 { for x in 948..<972 {
            let p=(y*1120+x)*4
            precondition(pixels[p+1]==51 && pixels[p+2]>=177, "Hidden blink phase must preserve only its cell background")
        } }
        precondition((680..<730).contains { y in (996..<1020).contains { pixels[(y*1120+$0)*4]>220 } }, "Ordinary text must remain visible during the hidden blink phase")
        let image=CGImage(width:1120,height:800,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:1120*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(pixels) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let url=root.appendingPathComponent(".build/tests/terminal-rendering.png")
        let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,image,nil);precondition(CGImageDestinationFinalize(destination))
        print("PASS: Nerd Font BMP/supplementary fallback, bundled font coverage, variable weight, font smoothing, code ligatures, combining marks, CJK, color emoji, seam-free Metal half-blocks, and curly/dotted/dashed underline pixels")
        print(url.path)
    }
}
