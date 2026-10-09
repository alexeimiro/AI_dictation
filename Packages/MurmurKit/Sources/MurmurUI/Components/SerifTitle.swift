import SwiftUI

/// Serif headline with an optional highlighted phrase, e.g. "Let's *set up* Murmur" where the
/// accent is orange, or "Murmur works in *any app*" where it is italic.
public struct SerifTitle: View {
    public enum AccentStyle: Sendable {
        case orange
        case italic
    }

    let text: String
    let accent: String?
    let accentStyle: AccentStyle
    let size: CGFloat
    let color: Color

    public init(_ text: String, accent: String? = nil, accentStyle: AccentStyle = .orange,
                size: CGFloat = 36, color: Color = Palette.text) {
        self.text = text
        self.accent = accent
        self.accentStyle = accentStyle
        self.size = size
        self.color = color
    }

    public var body: some View {
        Text(attributed)
            .font(.serif(size))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineSpacing(-size * 0.12)
            .tracking(-size * 0.02)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var string = AttributedString(text)
        if let accent, let range = string.range(of: accent) {
            switch accentStyle {
            case .orange:
                string[range].foregroundColor = Palette.accent
            case .italic:
                string[range].font = .serif(size, .italic)
            }
        }
        return string
    }
}
