import SwiftUI

/// The rounded full-width buttons used throughout onboarding and auth.
public struct PillButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        /// Dark fill, white label ("Next", "Continue with Apple").
        case ink
        /// Cream fill with ink border ("Get started" on the welcome carousel).
        case cream
        /// Lavender fill with ink border ("Set up", "Start Murmuring").
        case lavender
        /// White fill with ink border ("Continue with Google").
        case outline
    }

    let variant: Variant
    @Environment(\.isEnabled) private var isEnabled

    public init(_ variant: Variant) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(19, .medium, relativeTo: .headline))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
            .background(background, in: .rect(cornerRadius: Metrics.buttonRadius))
            .overlay {
                if hasBorder {
                    RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                        .strokeBorder(Palette.ink, lineWidth: 2)
                }
            }
            .contentShape(.rect(cornerRadius: Metrics.buttonRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var hasBorder: Bool {
        guard isEnabled else { return false }
        return variant != .ink
    }

    private var background: Color {
        guard isEnabled else { return Palette.disabled }
        return switch variant {
        case .ink: Palette.ink
        case .cream: Palette.cream
        case .lavender: Palette.lavender
        case .outline: Palette.paper
        }
    }

    private var foreground: Color {
        guard isEnabled else { return .white }
        return variant == .ink ? .white : Palette.ink
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    public static func pill(_ variant: PillButtonStyle.Variant) -> PillButtonStyle {
        PillButtonStyle(variant)
    }
}
