import SwiftUI

/// The process icon catalogue: each program is a rounded card colour, a
/// glyph colour and a glyph, like the design's icon studio.
extension ProcessBadge {
    enum Glyph {
        case prompt, neovim, sunburst, pulse
        case letters(String, italic: Bool, serif: Bool)
        case symbol(String)
    }

    var glyph: Glyph {
        switch self {
        case .shell: .prompt
        case .neovim: .neovim
        case .vim: .letters("V", italic: false, serif: false)
        case .claude: .sunburst
        case .codex: .symbol("hexagon")
        case .fx: .letters("fx", italic: true, serif: true)
        case .monitor: .pulse
        }
    }

    /// Measured card colours where the reference shows them.
    var card: UInt32 {
        switch self {
        case .shell: 0x1d1f21
        case .neovim: 0x0a9ec7
        case .vim: 0x1b8a3a
        case .claude: 0xe06a3a
        case .codex: 0xf8f8f8
        case .fx: 0x000000
        case .monitor: 0xa3262a
        }
    }

    var ink: UInt32 {
        switch self {
        case .shell: 0xa5e4b1
        case .codex: 0x000000
        default: 0xffffff
        }
    }
}

/// A tab's badge: the tab's primary process in front and up to two more
/// peeking out behind it to the right, each smaller and turned.
struct ProcessBadgeStack: View {
    let badges: [ProcessBadge]
    var size = Chrome.Badge.size
    let isLight: Bool

    private var behind: [ProcessBadge] { Array(badges.dropFirst().prefix(Chrome.Badge.stackLimit)) }

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(behind.enumerated()).reversed(), id: \.offset) { index, badge in
                let level = CGFloat(index + 1)
                let scale = pow(Chrome.Badge.stackScale, level)
                let width = size.width * scale
                ProcessBadgeCard(badge: badge, isLight: isLight, glyphOffset: width * Chrome.Badge.stackGlyphOffset)
                    .frame(width: width, height: size.height * scale)
                    .brightness(-0.08 * level)
                    .rotationEffect(Chrome.Badge.stackRotation * Double(level))
                    // Right edge `level` reveals past the front card's.
                    .offset(x: size.width + level * Chrome.Badge.stackReveal - width)
            }
            if let front = badges.first {
                ProcessBadgeCard(badge: front, isLight: isLight).frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width + CGFloat(behind.count) * Chrome.Badge.stackReveal, height: size.height, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// One card with the icon finish: a radial sheen from above, a light top
/// highlight and a ring that separates stacked cards.
struct ProcessBadgeCard: View {
    let badge: ProcessBadge
    let isLight: Bool
    var glyphOffset: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.Badge.cornerRadius, style: .continuous)
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                shape.fill(Color(hex: badge.card))
                shape.fill(RadialGradient(colors: [.white.opacity(0.24), .white.opacity(0)], center: UnitPoint(x: 0.5, y: -0.5),
                                          startRadius: 0, endRadius: height * 2.5))
                ProcessGlyph(badge: badge, size: CGSize(width: height * 0.6, height: height * 0.48))
                    .foregroundStyle(Color(hex: badge.ink))
                    .offset(x: glyphOffset)
            }
            .clipShape(shape)
            .overlay { shape.inset(by: 0.25).stroke(.white.opacity(0.25), lineWidth: 0.5).mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center)) }
            .overlay { shape.stroke(isLight ? .white : .black.opacity(0.6), lineWidth: Chrome.Badge.ringWidth) }
        }
    }
}

/// A badge's glyph alone, in the current foreground style, as pane title
/// rows show it.
struct ProcessGlyph: View {
    let badge: ProcessBadge
    var size = Chrome.Badge.plainGlyphSize

    var body: some View {
        Group {
            switch badge.glyph {
            case .prompt: PromptGlyph().stroke(style: StrokeStyle(lineWidth: size.height * 0.16, lineCap: .round, lineJoin: .round))
            case .neovim: NeovimGlyph()
            case .sunburst: SunburstGlyph().stroke(style: StrokeStyle(lineWidth: size.height * 0.14, lineCap: .round))
            case .pulse: PulseGlyph().stroke(style: StrokeStyle(lineWidth: size.height * 0.14, lineCap: .round, lineJoin: .round))
            case .letters(let text, let italic, let serif):
                Text(text)
                    .font(.system(size: size.height * 1.3, weight: serif ? .regular : .bold, design: serif ? .serif : .default))
                    .italic(italic)
                    .fixedSize()
            case .symbol(let name):
                Image(systemName: name).font(.system(size: size.height, weight: .semibold))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// `>_`: a prompt chevron and a cursor underscore.
private struct PromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: point(0.08, 0.1, rect))
            path.addLine(to: point(0.45, 0.47, rect))
            path.addLine(to: point(0.08, 0.84, rect))
            path.move(to: point(0.6, 0.9, rect))
            path.addLine(to: point(0.98, 0.9, rect))
        }
    }
}

/// A geometric N: two bevelled pillars joined by a diagonal.
private struct NeovimGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines([point(0.08, 0.14, rect), point(0.32, 0, rect), point(0.32, 1, rect), point(0.08, 0.86, rect)])
            path.closeSubpath()
            path.addLines([point(0.92, 0.14, rect), point(0.68, 0, rect), point(0.68, 1, rect), point(0.92, 0.86, rect)])
            path.closeSubpath()
            path.addLines([point(0.32, 0, rect), point(0.46, 0, rect), point(0.68, 1, rect), point(0.54, 1, rect)])
            path.closeSubpath()
        }
    }
}

/// A burst of rays, drawn in the spirit of the agent's mark.
private struct SunburstGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.6
        return Path { path in
            for ray in 0..<10 {
                let angle = Double(ray) / 10 * 2 * .pi + .pi / 20
                let reach = ray.isMultiple(of: 2) ? outer : outer * 0.8
                path.move(to: CGPoint(x: centre.x + cos(angle) * outer * 0.18, y: centre.y + sin(angle) * outer * 0.18))
                path.addLine(to: CGPoint(x: centre.x + cos(angle) * reach, y: centre.y + sin(angle) * reach))
            }
        }
    }
}

/// A monitor's heartbeat line.
private struct PulseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines([point(0, 0.55, rect), point(0.28, 0.55, rect), point(0.42, 0.1, rect),
                           point(0.58, 0.95, rect), point(0.72, 0.55, rect), point(1, 0.55, rect)])
        }
    }
}

private func point(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
}
