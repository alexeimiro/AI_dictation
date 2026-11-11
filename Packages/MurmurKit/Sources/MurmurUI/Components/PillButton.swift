import SwiftUI

/// Murmur's buttons: capsules. `.murmur(.primary)` is ink with a white label, `.secondary` an ink
/// outline; `.compact` hugs its label at 44 pt instead of filling the width at 56 pt.
public struct MurmurButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        case primary, secondary
        /// "Continue with Apple": pure black with a white label, which Apple's guidelines ask for.
        case apple
    }

    public enum Size: Sendable {
        case large, compact
    }

    let kind: Kind
    let size: Size
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind, size: Size = .large) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.murmur(size == .large ? .headline : .subhead, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, size == .large ? 20 : 18)
            .frame(maxWidth: size == .large ? .infinity : nil, minHeight: size == .large ? 56 : 44)
            .background(background, in: .roundCapsule)
            .overlay {
                if kind == .secondary, isEnabled {
                    Capsule(style: .circular).strokeBorder(Theme.ink, lineWidth: 1.5)
                }
            }
            .contentShape(.roundCapsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var background: Color {
        guard isEnabled else { return Theme.fill }
        return switch kind {
        case .primary: Theme.ink
        case .secondary: Theme.canvas
        case .apple: .black
        }
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.third }
        return switch kind {
        case .primary: Theme.onInk
        case .secondary: Theme.ink
        case .apple: .white
        }
    }
}

extension ButtonStyle where Self == MurmurButtonStyle {
    public static func murmur(_ kind: MurmurButtonStyle.Kind, size: MurmurButtonStyle.Size = .large) -> MurmurButtonStyle {
        MurmurButtonStyle(kind, size: size)
    }
}

/// A button that is only its label: it fades a little while pressed and doesn't dim when it is
/// disabled, so a label can show its own busy state.
public struct BareButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BareButtonStyle {
    public static var bare: BareButtonStyle { BareButtonStyle() }
}

/// The old button names, drawn as the new capsules until onboarding and the remaining screens are
/// redesigned.
public struct PillButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        /// The primary button: ink with a white label.
        case ink
        /// The primary button on the welcome pages' dark artwork: white with an ink label.
        case cream
        /// Also the primary button.
        case lavender
        /// An ink outline ("Continue with Google").
        case outline
        /// A grey outline (secondary sign-in methods).
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
            .font(.murmur(.headline))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(background, in: .roundCapsule)
            .overlay {
                if let border {
                    Capsule(style: .circular).strokeBorder(border, lineWidth: Metrics.borderWidth)
                }
            }
            .contentShape(.roundCapsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var border: Color? {
        guard isEnabled else { return nil }
        return switch variant {
        case .ink, .cream, .lavender: nil
        case .outline: Theme.ink
        case .subtle: Theme.graphic
        }
    }

    private var background: Color {
        guard isEnabled else { return Theme.fill }
        return switch variant {
        case .ink, .lavender: Theme.ink
        case .cream, .outline, .subtle: Theme.canvas
        }
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.third }
        return switch variant {
        case .ink, .lavender: Theme.onInk
        case .cream, .outline: Theme.ink
        case .subtle: Theme.second
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    public static func pill(_ variant: PillButtonStyle.Variant, height: CGFloat = Metrics.buttonHeight) -> PillButtonStyle {
        PillButtonStyle(variant, height: height)
    }
}

/// A plain text button under the primary one ("Not now", "More options").
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
            .foregroundStyle(Theme.ink)
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
