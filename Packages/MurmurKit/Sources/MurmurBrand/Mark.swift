import SwiftUI

/// Redmic's mark, the red dot inside a ring (a voice and its echo), as numbers on a 24-unit grid. The
/// app, the keyboard, the widgets and the icon generator all draw it from here.
public enum MarkGeometry {
    public static let grid: CGFloat = 24
    public static let dotRadius: CGFloat = 4.2
    /// To the middle of the ring's stroke.
    public static let ringRadius: CGFloat = 9.2
    public static let ringWidth: CGFloat = 1.8

    /// The largest square centred in `rect`: the mark never stretches.
    static func square(in rect: CGRect) -> CGRect {
        let side = min(rect.width, rect.height)
        return CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
    }

    public static func dot(in rect: CGRect) -> CGRect {
        let square = square(in: rect)
        let radius = square.width * dotRadius / grid
        return CGRect(x: square.midX - radius, y: square.midY - radius, width: radius * 2, height: radius * 2)
    }

    /// The circle the ring's stroke is centred on, and the stroke's width.
    public static func ring(in rect: CGRect) -> (rect: CGRect, lineWidth: CGFloat) {
        let square = square(in: rect)
        let radius = square.width * ringRadius / grid
        return (CGRect(x: square.midX - radius, y: square.midY - radius, width: radius * 2, height: radius * 2),
                square.width * ringWidth / grid)
    }
}

/// The mark in one colour.
public struct LogoMarkShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let ring = MarkGeometry.ring(in: rect)
        var path = Path(ellipseIn: ring.rect).strokedPath(StrokeStyle(lineWidth: ring.lineWidth))
        path.addEllipse(in: MarkGeometry.dot(in: rect))
        return path
    }
}

/// Redmic's mark: the ring, and the red dot at its centre. `dot` gives the dot another colour, as
/// the choice markers do (they borrow the mark's shape, not the logo).
public struct BrandMark: View {
    let ring: Color
    let dot: Color

    public init(ring: Color = Theme.ink, dot: Color? = nil) {
        self.ring = ring
        self.dot = dot ?? Theme.live
    }

    public var body: some View {
        // Shapes, not a Canvas: where the appearance is overridden, as in the keyboard, a Canvas
        // draws a colour that follows the appearance in its light value.
        ZStack {
            MarkRingShape().fill(ring)
            MarkDotShape().fill(dot)
        }
        .accessibilityHidden(true)
    }
}

/// The mark's ring alone, as a filled outline.
struct MarkRingShape: Shape {
    func path(in rect: CGRect) -> Path {
        let ring = MarkGeometry.ring(in: rect)
        return Path(ellipseIn: ring.rect).strokedPath(StrokeStyle(lineWidth: ring.lineWidth))
    }
}

/// The mark's dot alone.
struct MarkDotShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: MarkGeometry.dot(in: rect))
    }
}

/// The name as the wordmark sets it: "redmic", lowercase, with its r and m in red (`accent`) and the
/// other letters in `color`, or in the surrounding foreground style when `color` is nil. One Text,
/// so the letters keep the font's spacing.
public func wordmarkName(_ color: Color? = nil, accent: Color = Theme.live) -> Text {
    func plain(_ letters: String) -> Text {
        color.map { Text(verbatim: letters).foregroundStyle($0) } ?? Text(verbatim: letters)
    }
    let r = Text(verbatim: "r").foregroundStyle(accent), m = Text(verbatim: "m").foregroundStyle(accent)
    return Text("\(r)\(plain("ed"))\(m)\(plain("ic"))")
}

/// The mark and the name. A logo, not text to read: it doesn't grow with Dynamic Type.
public struct Wordmark: View {
    let height: CGFloat
    let color: Color
    let accent: Color

    public init(height: CGFloat = 34, color: Color = Theme.ink, accent: Color = Theme.live) {
        self.height = height
        self.color = color
        self.accent = accent
    }

    public var body: some View {
        HStack(spacing: height * 0.32) {
            BrandMark(ring: color, dot: accent)
                .frame(width: height, height: height)
            wordmarkName(color, accent: accent)
                .font(.system(size: height * 0.92, weight: .semibold))
                .tracking(-height * 0.02)
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Redmic")
    }
}

/// The menu button's glyph: two lines, the lower one shorter. Stroke it.
public struct MenuGlyph: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        // On a 24-unit grid: the lines sit at y 9 and 15, from x 4 to 20 and from 4 to 14.
        let unit = min(rect.width, rect.height) / 24
        let left = rect.midX - 8 * unit
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.midY - 3 * unit))
        path.addLine(to: CGPoint(x: left + 16 * unit, y: rect.midY - 3 * unit))
        path.move(to: CGPoint(x: left, y: rect.midY + 3 * unit))
        path.addLine(to: CGPoint(x: left + 10 * unit, y: rect.midY + 3 * unit))
        return path
    }
}
