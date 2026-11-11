import SwiftUI

/// Murmur's mark, a dot inside a ring (a voice and its echo), as numbers on a 24-unit grid. The
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

/// The mark with its dot in a colour of its own: red while the microphone is open.
public struct BrandMark: View {
    let ring: Color
    let dot: Color

    public init(ring: Color = Theme.ink, dot: Color? = nil) {
        self.ring = ring
        self.dot = dot ?? ring
    }

    public var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let geometry = MarkGeometry.ring(in: rect)
            context.stroke(Path(ellipseIn: geometry.rect), with: .color(ring), lineWidth: geometry.lineWidth)
            context.fill(Path(ellipseIn: MarkGeometry.dot(in: rect)), with: .color(dot))
        }
        .accessibilityHidden(true)
    }
}

/// The mark and the name, lowercase. A logo, not text to read: it doesn't grow with Dynamic Type.
public struct Wordmark: View {
    let height: CGFloat
    let color: Color

    public init(height: CGFloat = 34, color: Color = Theme.ink) {
        self.height = height
        self.color = color
    }

    public var body: some View {
        HStack(spacing: height * 0.32) {
            LogoMarkShape()
                .fill(color)
                .frame(width: height, height: height)
            Text(verbatim: "murmur")
                .font(.system(size: height * 0.92, weight: .semibold))
                .tracking(-height * 0.02)
                .foregroundStyle(color)
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Murmur")
    }
}
