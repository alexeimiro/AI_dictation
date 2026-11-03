import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Serif headline with an optional highlighted phrase, e.g. "Let's *set up* Murmur" where the
/// accent is orange, or "Murmur works in *any app*" where it is italic.
public struct SerifTitle: View {
    public enum AccentStyle: Sendable {
        case orange
        case italic
        case purple
    }

    let text: String
    let accent: String?
    let accentStyle: AccentStyle
    let size: CGFloat
    let color: Color
    let tracking: CGFloat
    let lineHeight: CGFloat?
    let trailing: Image?
    let alignment: TextAlignment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - tracking: letter spacing in points; the references set most titles slightly tight.
    ///   - lineHeight: baseline-to-baseline distance in points; nil keeps the font's own.
    ///   - trailing: an inline image after the text (the sparkles, a ✓ badge).
    public init(_ text: String, accent: String? = nil, accentStyle: AccentStyle = .orange,
                size: CGFloat = 36, color: Color = Palette.text, tracking: CGFloat? = nil,
                lineHeight: CGFloat? = nil, trailing: Image? = nil, alignment: TextAlignment = .center) {
        self.text = text
        self.accent = accent
        self.accentStyle = accentStyle
        self.size = size
        self.color = color
        self.tracking = tracking ?? -size * 0.02
        self.lineHeight = lineHeight
        self.trailing = trailing
        self.alignment = alignment
    }

    public var body: some View {
        content
            .font(.serif(size))
            .foregroundStyle(color)
            .tracking(tracking)
            .multilineTextAlignment(alignment)
            .lineHeight(scaledLineHeight.map { .exact(points: $0) })
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The fixed line height grows with the text, like the font (`.serif` is relative to .largeTitle).
    private var scaledLineHeight: CGFloat? {
        guard let lineHeight else { return nil }
        #if canImport(UIKit)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .largeTitle).scaledValue(for: lineHeight, compatibleWith: traits)
        #else
        return lineHeight
        #endif
    }

    private var content: Text {
        if let trailing {
            return Text("\(Text(attributed))\u{00A0}\(trailing)")
        }
        return Text(attributed)
    }

    private var attributed: AttributedString {
        var string = AttributedString(text)
        if let accent, let range = string.range(of: accent) {
            switch accentStyle {
            case .orange:
                string[range].foregroundColor = Palette.accent
            case .purple:
                string[range].foregroundColor = Palette.purple
            case .italic:
                string[range].font = .serif(size, .italic)
            }
        }
        return string
    }
}

/// Murmur's sparkles: three four-point stars, orange with an ink outline. Drawn in code so it can
/// sit inline in a title (`SerifTitle(trailing:)`).
public enum Sparkles {
    public static func image(size: CGFloat) -> Image {
        Image(size: CGSize(width: size, height: size), label: Text("sparkles")) { context in
            let stroke = max(1, size * 0.045)
            let stars: [(CGPoint, CGFloat)] = [
                (CGPoint(x: 0.64, y: 0.52), 0.46),
                (CGPoint(x: 0.22, y: 0.24), 0.21),
                (CGPoint(x: 0.24, y: 0.78), 0.19),
            ]
            for (center, radius) in stars {
                let path = star(center: CGPoint(x: center.x * size, y: center.y * size), radius: radius * size)
                context.fill(path, with: .color(Palette.accent))
                context.stroke(path, with: .color(Palette.ink),
                               style: StrokeStyle(lineWidth: stroke, lineJoin: .round))
            }
        }
    }

    /// A four-point star with concave sides.
    static func star(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let waist = radius * 0.16
        let points = [
            CGPoint(x: center.x, y: center.y - radius),
            CGPoint(x: center.x + radius, y: center.y),
            CGPoint(x: center.x, y: center.y + radius),
            CGPoint(x: center.x - radius, y: center.y),
        ]
        path.move(to: points[0])
        for index in 0..<4 {
            let next = points[(index + 1) % 4]
            let control = CGPoint(
                x: center.x + (index == 0 || index == 1 ? waist : -waist),
                y: center.y + (index == 1 || index == 2 ? waist : -waist))
            path.addQuadCurve(to: next, control: control)
        }
        path.closeSubpath()
        return path
    }
}
