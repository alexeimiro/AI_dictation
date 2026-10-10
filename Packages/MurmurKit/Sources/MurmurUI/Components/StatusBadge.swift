import SwiftUI

/// Small capsule label for a transcript's state ("Not cleaned", "Pending").
public struct StatusBadge: View {
    public enum Tone: Sendable {
        case neutral, accent, danger, success
    }

    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.ui(11, .semibold, relativeTo: .caption2))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background, in: .capsule)
            .lineLimit(1)
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Palette.textSecondary
        case .accent: Palette.ink
        case .danger: .white
        case .success: Palette.teal
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Palette.tabSelected
        case .accent: Palette.accent.opacity(0.35)
        case .danger: Palette.danger
        case .success: Palette.toggleGreenSoft
        }
    }
}
