import SwiftUI
import UIKit

/// Adaptive visual tokens shared by the SwiftUI surfaces and the UIKit key grid, after Wispr Flow's
/// keyboard (captured November 2026): monochrome, white controls and grey keys on the system's own
/// keyboard panel, which the keyboard leaves undrawn. The dark values are Wispr's; the light ones
/// mirror them. The keyboard links only MurmurCore, so the values live here rather than in MurmurUI.
enum KeyboardChrome {
    /// The system's keyboard panel, painted only when the keyboard's chosen appearance differs from
    /// the host's, whose style the panel keeps.
    static let panelUIColor = dynamic(light: 0xE2E4E8, dark: 0x161617)
    /// Keys, and the bar's grey controls: Delete, the translate chip, Undo.
    static let keyUIColor = dynamic(light: 0xFFFFFF, dark: 0x424242)
    static let pressedKeyUIColor = dynamic(light: 0xD1D1D6, dark: 0x5C5C5E)
    /// Rows and fields on the menu and style pages, and notices.
    static let cardUIColor = dynamic(light: 0xFFFFFF, dark: 0x2A2A2C)
    /// The white (light: ink) controls: the talk button, the style pill, Start, the menu's buttons.
    static let primaryUIColor = dynamic(light: 0x111111, dark: 0xFFFFFF)
    static let primaryGlyphUIColor = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// ✕ while a dictation runs.
    static let secondaryUIColor = dynamic(light: 0x8E8E93, dark: 0x707070)
    /// The style pill while a dictation runs.
    static let disabledUIColor = dynamic(light: 0xE5E5EA, dark: 0x454546)
    static let disabledGlyphUIColor = dynamic(light: 0xAEAEB2, dark: 0x6E6E70)
    static let mutedUIColor = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        if traits.accessibilityContrast == .high { return UIColor(hex: dark ? 0xC7C7CC : 0x3A3A3C) }
        return UIColor(hex: dark ? 0x9A9A9E : 0x6C6C70)
    }
    /// The app's switch green (`Palette.toggleGreen`).
    static let switchUIColor = UIColor(hex: 0x4FBF77)
    /// Dividers, and the hairline Increase Contrast adds to keys and controls.
    static let borderUIColor = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        let alpha: CGFloat = traits.accessibilityContrast == .high ? (dark ? 0.32 : 0.30) : (dark ? 0.10 : 0.08)
        return dark ? UIColor(white: 1, alpha: alpha) : UIColor(white: 0, alpha: alpha)
    }

    static let key = Color(uiColor: keyUIColor)
    static let pressedKey = Color(uiColor: pressedKeyUIColor)
    static let card = Color(uiColor: cardUIColor)
    static let primary = Color(uiColor: primaryUIColor)
    static let primaryGlyph = Color(uiColor: primaryGlyphUIColor)
    static let secondary = Color(uiColor: secondaryUIColor)
    static let disabled = Color(uiColor: disabledUIColor)
    static let disabledGlyph = Color(uiColor: disabledGlyphUIColor)
    static let muted = Color(uiColor: mutedUIColor)
    static let switchTint = Color(uiColor: switchUIColor)
    static let border = Color(uiColor: borderUIColor)

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
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

/// A flat fill, as Wispr draws its controls: no border or shadow, except a hairline under Increase
/// Contrast. `pressed` darkens it while a held key (Delete) is down.
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

/// Sizes of the row above the keys: Wispr's 46 pt controls 12 pt from the top, or smaller ones in
/// landscape.
struct BarMetrics {
    var control: CGFloat
    var top: CGFloat

    static let regular = BarMetrics(control: 46, top: 12)
    static let compact = BarMetrics(control: 40, top: 5)

    @MainActor
    static func of(_ model: KeyboardModel) -> BarMetrics {
        model.compactHeight ? .compact : .regular
    }
}
