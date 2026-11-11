import SwiftUI

/// The old headline, now plain: the system font in bold, with no accent word. It keeps its name
/// and parameters until onboarding and the remaining screens are redesigned; new screens set
/// `Font.murmur(.title)` on a `Text`.
public struct SerifTitle: View {
    public enum AccentStyle: Sendable {
        case orange
        case italic
        case purple
    }

    let text: String
    let size: CGFloat
    let color: Color
    let trailing: Image?
    let alignment: TextAlignment

    /// - Parameters:
    ///   - accent, accentStyle, tracking, lineHeight: no longer drawn; headlines are one weight
    ///     and one colour.
    ///   - trailing: an inline image after the text (a ✓ badge).
    public init(_ text: String, accent: String? = nil, accentStyle: AccentStyle = .orange,
                size: CGFloat = 36, color: Color = Palette.text, tracking: CGFloat? = nil,
                lineHeight: CGFloat? = nil, trailing: Image? = nil, alignment: TextAlignment = .center) {
        self.text = text
        self.size = size
        self.color = color
        self.trailing = trailing
        self.alignment = alignment
    }

    public var body: some View {
        content
            .font(.serif(size))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var content: Text {
        if let trailing {
            return Text("\(Text(text))\u{00A0}\(trailing)")
        }
        return Text(text)
    }
}

/// Three four-point stars, drawn in code so they can sit inline in a title
/// (`SerifTitle(trailing:)`). Onboarding's practice screens still use them.
public enum Sparkles {
    public static func image(size: CGFloat) -> Image {
        Image(size: CGSize(width: size, height: size), label: Text("sparkles")) { context in
            let stars: [(CGPoint, CGFloat)] = [
                (CGPoint(x: 0.64, y: 0.52), 0.46),
                (CGPoint(x: 0.22, y: 0.24), 0.21),
                (CGPoint(x: 0.24, y: 0.78), 0.19),
            ]
            for (center, radius) in stars {
                let path = star(center: CGPoint(x: center.x * size, y: center.y * size), radius: radius * size)
                context.fill(path, with: .color(Theme.ink))
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
