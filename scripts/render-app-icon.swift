#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Editable vector master. Run from the repository root with:
// swift scripts/render-app-icon.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let destination = root.appendingPathComponent("illogical/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func polygon(_ points: [(CGFloat, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
    path.closeSubpath()
    return path
}

func gradient(_ context: CGContext, path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawMark(_ context: CGContext) {
    // A flowing italic i: the detached dot distinguishes it from the reference's
    // continuous S, while the rising curve gives the mark the same sense of motion.
    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: 276, y: 732))
    stem.addLine(to: CGPoint(x: 298, y: 634))
    stem.addLine(to: CGPoint(x: 352, y: 634))
    stem.addCurve(to: CGPoint(x: 464, y: 550), control1: CGPoint(x: 410, y: 634), control2: CGPoint(x: 441, y: 607))
    stem.addLine(to: CGPoint(x: 522, y: 406))
    stem.addLine(to: CGPoint(x: 634, y: 406))
    stem.addLine(to: CGPoint(x: 566, y: 575))
    stem.addCurve(to: CGPoint(x: 352, y: 732), control1: CGPoint(x: 524, y: 679), control2: CGPoint(x: 455, y: 732))
    stem.closeSubpath()
    let dot = polygon([(576, 272), (688, 272), (650, 366), (538, 366)])
    context.setFillColor(color(0xffffff))
    context.addPath(stem)
    context.fillPath()
    context.addPath(dot)
    context.fillPath()
}

func render(size: Int) -> CGImage {
    let scale = size < 512 ? 4 : 2
    let pixels = size * scale
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    let tile = CGMutablePath()
    tile.move(to: CGPoint(x: 354, y: 100))
    tile.addLine(to: CGPoint(x: 670, y: 100))
    tile.addCurve(to: CGPoint(x: 924, y: 354), control1: CGPoint(x: 860, y: 100), control2: CGPoint(x: 924, y: 164))
    tile.addLine(to: CGPoint(x: 924, y: 670))
    tile.addCurve(to: CGPoint(x: 670, y: 924), control1: CGPoint(x: 924, y: 860), control2: CGPoint(x: 860, y: 924))
    tile.addLine(to: CGPoint(x: 354, y: 924))
    tile.addCurve(to: CGPoint(x: 100, y: 670), control1: CGPoint(x: 164, y: 924), control2: CGPoint(x: 100, y: 860))
    tile.addLine(to: CGPoint(x: 100, y: 354))
    tile.addCurve(to: CGPoint(x: 354, y: 100), control1: CGPoint(x: 100, y: 164), control2: CGPoint(x: 164, y: 100))
    tile.closeSubpath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x604d5d, alpha: 0.22))
    context.addPath(tile)
    context.setFillColor(color(0xffb997))
    context.fillPath()
    context.restoreGState()
    gradient(context, path: tile,
             colors: [color(0xbac6fb), color(0xd5b3f0), color(0xf3a6ba), color(0xffb287), color(0xf4d68e), color(0xc1ddb8)],
             from: CGPoint(x: 115, y: 110), to: CGPoint(x: 910, y: 920))

    // A broad light wash keeps the colours luminous without a hard gloss line.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [color(0xffffff, alpha: 0.2), color(0xffffff, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    context.drawRadialGradient(light, startCenter: CGPoint(x: 785, y: 150), startRadius: 0,
                               endCenter: CGPoint(x: 785, y: 150), endRadius: 740,
                               options: [])
    if size > 32 {
        context.addPath(tile)
        context.setStrokeColor(color(0xffffff, alpha: 0.25))
        context.setLineWidth(3)
        context.strokePath()
    }
    context.restoreGState()

    context.saveGState()
    context.translateBy(x: 23, y: 8)
    drawMark(context)
    context.restoreGState()

    let output = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                           bytesPerRow: 0, space: space,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    output.interpolationQuality = .high
    output.draw(context.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
    return output.makeImage()!
}

func save(_ image: CGImage, to url: URL) throws {
    guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
}

struct IconEntry: Encodable {
    let filename: String
    let idiom = "mac"
    let scale: String
    let size: String
}

struct IconCatalog: Encodable {
    struct Info: Encodable {
        let author = "xcode"
        let version = 1
    }
    let images: [IconEntry]
    let info = Info()
}

var entries: [IconEntry] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try save(render(size: points * scale), to: destination.appendingPathComponent(filename))
        entries.append(IconEntry(filename: filename, scale: "\(scale)x", size: "\(points)x\(points)"))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(IconCatalog(images: entries))
try (data + Data("\n".utf8)).write(to: destination.appendingPathComponent("Contents.json"))
print("Rendered all 10 macOS app icon assets.")
