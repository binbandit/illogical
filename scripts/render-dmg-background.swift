#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Finder coordinates are in points. Keep this canvas and the installation lane
// aligned with scripts/dmg-settings.py. Render both scales for Retina displays.
let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/dmg-artwork")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let width = 760
let height = 500

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func text(_ string: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight,
          ink: UInt32, centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    (string as NSString).draw(in: rect, withAttributes: [
        .font: font, .foregroundColor: color(ink), .paragraphStyle: paragraph
    ])
}

func render(scale: Int) throws {
    let context = CGContext(data: nil, width: width * scale, height: height * scale,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // The same lavender, coral, apricot and mint as the application's icon.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0xbac6fb).cgColor, color(0xd5b3f0).cgColor,
                 color(0xf3a6ba).cgColor, color(0xffb287).cgColor,
                 color(0xf4d68e).cgColor, color(0xc1ddb8).cgColor] as CFArray,
        locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 760, y: 470),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0xffffff, alpha: 0.55).cgColor,
                 color(0xffffff, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(light, startCenter: CGPoint(x: 180, y: 20), startRadius: 0,
        endCenter: CGPoint(x: 180, y: 20), endRadius: 650, options: [])

    // The flowing i from render-app-icon.swift, enlarged behind the install lane.
    context.saveGState()
    context.translateBy(x: 285, y: -140)
    context.scaleBy(x: 0.60, y: 0.60)
    let mark = CGMutablePath()
    mark.move(to: CGPoint(x: 276, y: 732))
    mark.addLine(to: CGPoint(x: 298, y: 634))
    mark.addLine(to: CGPoint(x: 352, y: 634))
    mark.addCurve(to: CGPoint(x: 464, y: 550), control1: CGPoint(x: 410, y: 634), control2: CGPoint(x: 441, y: 607))
    mark.addLine(to: CGPoint(x: 522, y: 406))
    mark.addLine(to: CGPoint(x: 634, y: 406))
    mark.addLine(to: CGPoint(x: 566, y: 575))
    mark.addCurve(to: CGPoint(x: 352, y: 732), control1: CGPoint(x: 524, y: 679), control2: CGPoint(x: 455, y: 732))
    mark.closeSubpath()
    mark.move(to: CGPoint(x: 576, y: 272))
    mark.addLine(to: CGPoint(x: 688, y: 272))
    mark.addLine(to: CGPoint(x: 650, y: 366))
    mark.addLine(to: CGPoint(x: 538, y: 366))
    mark.closeSubpath()
    context.setFillColor(color(0xffffff, alpha: 0.62).cgColor)
    context.addPath(mark)
    context.fillPath()
    context.restoreGState()

    text("illogical", in: CGRect(x: 48, y: 40, width: 450, height: 65),
         size: 50, weight: .bold, ink: 0x322c46)
    text("A new home for your terminal.", in: CGRect(x: 50, y: 113, width: 460, height: 32),
         size: 20, weight: .regular, ink: 0x554b62)

    // A soft paper veil gives the installation area breathing room without
    // enclosing the native icons in a generic card.
    let veil = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0xffffff, alpha: 0).cgColor,
                 color(0xffffff, alpha: 0.82).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(veil, start: CGPoint(x: 0, y: 170),
                               end: CGPoint(x: 0, y: 490), options: [.drawsAfterEndLocation])
    text("Drag to install", in: CGRect(x: 292, y: 267, width: 176, height: 25),
         size: 15, weight: .medium, ink: 0x62546f, centered: true)

    // The real Finder icons sit on either side of this arrow; never paint fake icons.
    context.setStrokeColor(color(0x84738f, alpha: 0.8).cgColor)
    context.setLineWidth(2)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 330, y: 310))
    context.addLine(to: CGPoint(x: 426, y: 310))
    context.move(to: CGPoint(x: 413, y: 297))
    context.addLine(to: CGPoint(x: 426, y: 310))
    context.addLine(to: CGPoint(x: 413, y: 323))
    context.strokePath()

    text("Open illogical from Applications to get started.",
         in: CGRect(x: 32, y: 447, width: 696, height: 24),
         size: 14, weight: .regular, ink: 0x554b62, centered: true)

    let filename = scale == 1 ? "background.png" : "background@2x.png"
    let url = destination.appendingPathComponent(filename)
    guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
          let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
}

try render(scale: 1)
try render(scale: 2)
print("Rendered DMG artwork at 1x and 2x in \(destination.path)")
