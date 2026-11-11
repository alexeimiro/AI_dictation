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

/// A button that is only its words, under a primary one: "Not now", "More options".
public struct TextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.murmur(.subhead, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.ink : Theme.third)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == TextButtonStyle {
    public static var textOnly: TextButtonStyle { TextButtonStyle() }
}
