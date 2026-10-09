import SwiftUI

/// Murmur's mark: three rounded bars rising like a voice, followed by a dot.
/// Original placeholder artwork — swap for the final brand mark later.
public struct LogoMarkShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let barHeights: [CGFloat] = [0.48, 1.0, 0.7]
        let unit = rect.width / 8.2
        let barWidth = unit * 1.3
        let gap = unit * 0.9
        var path = Path()
        for (index, height) in barHeights.enumerated() {
            let barRect = CGRect(
                x: rect.minX + CGFloat(index) * (barWidth + gap),
                y: rect.midY - rect.height * height / 2,
                width: barWidth,
                height: rect.height * height)
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        let dotSize = barWidth * 1.15
        let dotX = rect.minX + 3 * (barWidth + gap) + unit * 0.1
        path.addEllipse(in: CGRect(x: dotX, y: rect.midY - dotSize / 2, width: dotSize, height: dotSize))
        return path
    }
}

/// Mark + wordmark, as in the onboarding headers.
public struct Wordmark: View {
    let height: CGFloat
    let color: Color

    public init(height: CGFloat = 34, color: Color = Palette.ink) {
        self.height = height
        self.color = color
    }

    public var body: some View {
        HStack(spacing: height * 0.3) {
            LogoMarkShape()
                .fill(color)
                .frame(width: height * 1.05, height: height)
            Text(Brandname.display)
                .font(.ui(height * 1.15, .semibold, relativeTo: .largeTitle))
                .foregroundStyle(color)
        }
        .accessibilityElement()
        .accessibilityLabel(Brandname.display)
    }
}

enum Brandname {
    static let display = "Murmur"
}
