import MurmurBrand
import SwiftUI
import UIKit

/// The keyboard's colours, by the name each part uses. Every one is a `BrandToken` (MurmurBrand),
/// which the app and the Live Activity draw from too, and each follows light, dark and Increase
/// Contrast. The keyboard leaves the system's own panel undrawn; these sit on it.
enum KeyboardChrome {
    /// The keyboard's own panel, painted only when its chosen appearance differs from the host's,
    /// whose style the system's panel keeps.
    static let panelUIColor = UIColor.brand(.keyboardPanel)
    /// Character keys, and the bar's capsule for a waiting dictation.
    static let keyUIColor = UIColor.brand(.key)
    static let pressedKeyUIColor = UIColor.brand(.keyPressed)
    /// Shift, Delete, ABC, return: the keys that type no character.
    static let functionKeyUIColor = UIColor.brand(.functionKey)
    /// Rows and fields on the menu and style pages, and notices.
    static let cardUIColor = UIColor.brand(.keyboardCard)
    /// Text and glyphs, and the fill of the talk button, Start and the menu's Add.
    static let primaryUIColor = UIColor.brand(.ink)
    static let primaryGlyphUIColor = UIColor.brand(.onInk)
    /// Hints, captions and the second line of a card.
    static let mutedUIColor = UIColor.brand(.second)
    /// Dividers, and the hairline Increase Contrast adds to keys and cards.
    static let borderUIColor = UIColor.brand(.line)

    static let key = Color(uiColor: keyUIColor)
    static let pressedKey = Color(uiColor: pressedKeyUIColor)
    static let card = Color(uiColor: cardUIColor)
    static let primary = Color(uiColor: primaryUIColor)
    static let primaryGlyph = Color(uiColor: primaryGlyphUIColor)
    static let muted = Color(uiColor: mutedUIColor)
    static let border = Color(uiColor: borderUIColor)
    /// A switch that is off.
    static let track = Color(brand: .track)
    /// The microphone is open: the talk button while it listens, and its rings. Nothing else is red.
    static let live = Color(brand: .live)
    static let liveGlyph = Color(brand: .onLive)
}

/// A small, tactile press treatment used by the mic, toolbar controls, and page rows.
struct KeyboardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == KeyboardPressStyle {
    static var keyboardPress: KeyboardPressStyle { KeyboardPressStyle() }
}

/// A flat fill: no border or shadow, except a hairline under Increase Contrast. `pressed` darkens
/// it while a held control is down.
struct KeyboardSurface<S: Shape>: View {
    let shape: S
    var fill = KeyboardChrome.key
    var pressed = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        shape
            .fill(pressed ? KeyboardChrome.pressedKey : fill)
            .overlay {
                if contrast == .increased {
                    shape.stroke(KeyboardChrome.border, lineWidth: 1)
                }
            }
    }
}

/// An outlined capsule with a short label: the style pill, the translate chip, Undo, a recent
/// language. `filled` turns it solid, for the one that is chosen or open.
struct OutlineChip<Label: View>: View {
    var height: CGFloat = 32
    var filled = false
    @ViewBuilder let label: Label

    var body: some View {
        label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(filled ? KeyboardChrome.primaryGlyph : KeyboardChrome.primary)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(filled ? KeyboardChrome.primary : .clear, in: Capsule(style: .circular))
            .overlay {
                if !filled {
                    Capsule(style: .circular).strokeBorder(KeyboardChrome.primary, lineWidth: 1.5)
                }
            }
    }
}

/// The keyboard's switch: ink when on, with a knob in the colour that reads on ink. A tinted
/// system switch would be white on white on a dark keyboard. VoiceOver gets a real switch.
struct KeyboardSwitch: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule(style: .circular)
            .fill(isOn ? KeyboardChrome.primary : KeyboardChrome.track)
            .frame(width: 51, height: 31)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? KeyboardChrome.primaryGlyph : Color.white)
                    .frame(width: 27, height: 27)
                    .padding(2)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isOn)
            .frame(minHeight: 44)
            .contentShape(.rect)
            .onTapGesture { isOn.toggle() }
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityRepresentation {
                Toggle(label, isOn: $isOn)
            }
    }
}

/// Sizes of the row above the keys: 46 pt controls 12 pt from the top, or smaller ones in
/// landscape.
struct BarMetrics {
    var control: CGFloat
    var top: CGFloat
    /// The talk button and Start on the key layouts, and the menu's round buttons.
    var disc: CGFloat

    static let regular = BarMetrics(control: 46, top: 12, disc: 40)
    static let compact = BarMetrics(control: 40, top: 5, disc: 36)

    @MainActor
    static func of(_ model: KeyboardModel) -> BarMetrics {
        model.compactHeight ? .compact : .regular
    }
}
