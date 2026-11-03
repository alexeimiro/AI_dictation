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
        /// White fill with a light border (secondary sign-in methods).
        case subtle
    }

    let variant: Variant
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    public init(_ variant: Variant, height: CGFloat = Metrics.buttonHeight) {
        self.variant = variant
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(19, .medium, relativeTo: .headline))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(background, in: .rect(cornerRadius: Metrics.buttonRadius))
            .overlay {
                // Centered on the edge, like the references: the border adds a point outside.
                if let border {
                    RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                        .stroke(border, lineWidth: Metrics.borderWidth)
                }
            }
            .contentShape(.rect(cornerRadius: Metrics.buttonRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var border: Color? {
        guard isEnabled else { return nil }
        return switch variant {
        case .ink: nil
        case .cream, .lavender, .outline: Palette.ink
        case .subtle: Palette.muted
        }
    }

    private var background: Color {
        guard isEnabled else { return Palette.disabled }
        return switch variant {
        case .ink: Palette.ink
        case .cream: Palette.cream
        case .lavender: Palette.lavender
        case .outline, .subtle: Palette.paper
        }
    }

    private var foreground: Color {
        guard isEnabled else { return .white }
        return switch variant {
        case .ink: .white
        case .subtle: Palette.textSecondary
        default: Palette.ink
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    public static func pill(_ variant: PillButtonStyle.Variant, height: CGFloat = Metrics.buttonHeight) -> PillButtonStyle {
        PillButtonStyle(variant, height: height)
    }
}

/// A plain text button under the primary one ("Maybe later", "Another time", "More options").
public struct QuietButtonStyle: ButtonStyle {
    let size: CGFloat
    let weight: UIWeight

    public init(size: CGFloat = 15, weight: UIWeight = .regular) {
        self.size = size
        self.weight = weight
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(size, weight))
            .foregroundStyle(Palette.ink)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    public static func quiet(size: CGFloat = 15, weight: UIWeight = .regular) -> QuietButtonStyle {
        QuietButtonStyle(size: size, weight: weight)
    }
}
