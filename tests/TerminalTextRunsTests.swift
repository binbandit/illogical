import AppKit
import CoreText

private func cell(_ text: String, column: Int, width: UInt8 = 1, flags: UInt8 = 0, row: UInt16 = 0) -> ILCell {
    var value = ILCell()
    value.column = UInt16(column); value.row = row; value.width = width; value.flags = flags
    value.foreground = 0xffffff
    let bytes = Array(text.utf8)
    precondition(bytes.count < 128)
    withUnsafeMutableBytes(of: &value.text) { output in
        for (index, byte) in bytes.enumerated() { output[index] = byte }
    }
    return value
}

private func signatures(_ text: String, font: CTFont) -> [String] {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String):font]))
    return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [String] in
        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        return glyphs.map { "\(CTFontCopyPostScriptName(font)):\($0)" }
    }
}

private func composite(_ source: TerminalFontRasterizer.Bitmap, into bytes: inout [UInt8], width: Int, x: Int) {
    for row in 0..<source.height {
        for column in 0..<source.width where column+x >= 0 && column+x < width {
            let src=(row*source.width+column)*4
            let dest=(row*width+column+x)*4
            let alpha=Int(source.bytes[src+3])
            for component in 0..<4 {
                bytes[dest+component]=UInt8(min(255,Int(source.bytes[src+component])+(Int(bytes[dest+component])*(255-alpha)+127)/255))
            }
        }
    }
}

private func writePNG(_ bitmap: TerminalFontRasterizer.Bitmap, path: String) throws {
    let representation=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.width,pixelsHigh:bitmap.height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:bitmap.width*4,bitsPerPixel:32)!
    bitmap.bytes.withUnsafeBytes { representation.bitmapData!.update(from:$0.bindMemory(to:UInt8.self).baseAddress!,count:bitmap.bytes.count) }
    try representation.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
}

@main struct TerminalTextRunsTests {
    @MainActor static func main() throws {
        let raster = TerminalFontRasterizer(font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), scale: 2, cell: NSSize(width: 12, height: 27))
        for (name, fragments) in [("Arabic",["س","ل","ا","م"]), ("Devanagari",["क्","षि"]), ("Bengali",["ক্","ষি"])] {
            let cells = fragments.enumerated().map { cell($0.element,column:$0.offset) }
            let run = cells.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:0) }!
            precondition(run.cellCount == fragments.count && run.columns == fragments.count)
            let font = raster.resolvedFont(for: run.text)
            let shaped = TerminalTextRuns.shape(text:run.text,clusters:run.clusters,font:font,cellWidth:24)
            let isolated = fragments.flatMap { signatures($0,font:font) }
            let joined = shaped.map { "\(CTFontCopyPostScriptName($0.font)):\($0.id)" }
            precondition(!shaped.isEmpty && shaped.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.id != 0 })
            precondition(joined != isolated, "\(name): fixture did not reproduce cross-cell shaping loss")
            let oldBitmaps = fragments.map { raster.rasterize(.init(text:$0,bold:false,italic:false,width:1))! }
            precondition(oldBitmaps.allSatisfy { $0.bytes.contains { $0 != 0 } })
            var key=TerminalFontRasterizer.Key(text:run.text,bold:false,italic:false,width:run.columns)
            key.clusters=run.clusters
            let bitmap=raster.rasterize(key)!
            var before=[UInt8](repeating:0,count:bitmap.bytes.count)
            for (index,old) in oldBitmaps.enumerated() { composite(old,into:&before,width:bitmap.width,x:index*24) }
            precondition(before != bitmap.bytes,"Actual contextual raster stayed unchanged for \(name)")
            try writePNG(.init(bytes:before,width:bitmap.width,height:bitmap.height,padding:bitmap.padding,colored:false),path:".build/contextual-shaping/\(name)-before.png")
            try writePNG(bitmap,path:".build/contextual-shaping/\(name)-after.png")
            print("\(name): isolated glyphs=\(isolated), contextual glyphs=\(joined), anchors=\(shaped.map(\.clusterColumn))")
        }
        let text = [cell("ب",column:0),cell("ب",column:1),cell("ب",column:2),cell("ب",column:3)]
        let beforeCursor = text.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:0,cursor:.init(row:0,column:2)) }!
        precondition(beforeCursor.cellCount==2)
        precondition(text.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:2,cursor:.init(row:0,column:2)) } == nil)
        for flag: UInt8 in [1,2,8,64,128] {
            var changed=text;changed[1].flags=flag
            precondition(changed.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:0) } == nil,"Style/selection/search boundary joined")
        }
        var wrapped=text;wrapped[1].row=1
        precondition(wrapped.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:0) } == nil)
        let wide = [cell("क्",column:0,width:2),cell("",column:1,width:0),cell("षि",column:2)]
        let wideRun=wide.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:0) }!
        precondition(wideRun.columns==3 && wideRun.cellCount==3 && wideRun.clusters.map(\.column)==[0,2])
        var mismatchedWide=wide;mismatchedWide[1].flags=8
        precondition(mismatchedWide.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:0) } == nil)
        let long=(0..<200).map { cell("ب",column:$0) }
        let bounded=long.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:0) }!
        precondition(bounded.columns==64 && bounded.cellCount==64 && bounded.clusters.count==200)
        let nextTile=long.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:64) }!
        precondition(nextTile.columns==64 && nextTile.clusters.first!.column == -64 && nextTile.clusters.count==200)
        let sharedFont=raster.resolvedFont(for:bounded.text)
        let wholeGlyphs=TerminalTextRuns.shape(text:bounded.text,clusters:bounded.clusters,font:sharedFont,cellWidth:24)
        let tileGlyphs=TerminalTextRuns.shape(text:nextTile.text,clusters:nextTile.clusters,font:sharedFont,cellWidth:24)
        precondition(wholeGlyphs.map(\.id)==tileGlyphs.map(\.id),"Contextual forms changed at tile boundary")
        for (whole,tile) in zip(wholeGlyphs,tileGlyphs) {
            precondition(abs(whole.position.x-tile.position.x-64*24)<0.01 && whole.position.y==tile.position.y,"Context offsets drifted at tile boundary")
        }
        var wholeKey=TerminalFontRasterizer.Key(text:bounded.text,bold:false,italic:false,width:200)
        wholeKey.clusters=bounded.clusters
        let wholeBitmap=raster.rasterize(wholeKey)!
        var tiles=[UInt8](repeating:0,count:wholeBitmap.bytes.count)
        var column=0
        while column<long.count {
            let run=long.withUnsafeBufferPointer { TerminalTextRuns.plan($0,at:column) }!
            var key=TerminalFontRasterizer.Key(text:run.text,bold:false,italic:false,width:run.columns)
            key.clusters=run.clusters
            composite(raster.rasterize(key)!,into:&tiles,width:wholeBitmap.width,x:column*24)
            column += run.cellCount
        }
        precondition(wholeBitmap.bytes==tiles,"Context tiling changes pixels or double-paints padding")
        let ascii=(0..<10000).map { cell("A",column:$0) }
        let blocks=(0..<10000).map { cell("▀",column:$0) }
        let start=CFAbsoluteTimeGetCurrent()
        for values in [ascii,blocks] {
            values.withUnsafeBufferPointer { buffer in
                for index in buffer.indices { precondition(TerminalTextRuns.plan(buffer,at:index)==nil) }
            }
        }
        print("ASCII/block fast-path 20,000 candidates: \((CFAbsoluteTimeGetCurrent()-start)*1000) ms; zero shaping runs")
        print("Contextual text-run planner passed styles, cursor, row, wide cells, fallback and bounded work")
    }
}
