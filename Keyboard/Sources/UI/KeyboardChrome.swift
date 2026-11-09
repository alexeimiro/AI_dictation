import SwiftUI
import UIKit

/// Adaptive visual tokens shared by the SwiftUI voice surface and the UIKit key grid: the light and
/// dark palettes of Anton's keyboard mock (November 2026) with an indigo accent and a recording
/// red. The keyboard links only MurmurCore, so the values live here rather than in MurmurUI.
enum KeyboardChrome {
    static let backdropUIColor = dynamic(light: 0xE7E9EF, dark: 0x16171C)
    /// Sheets and the style menu.
    static let panelUIColor = dynamic(light: 0xFFFFFF, dark: 0x1E2028)
    /// Chips, pills and the translate row.
    static let surfaceUIColor = dynamic(light: 0xFFFFFF, dark: 0x24262E)
    static let keyUIColor = dynamic(light: 0xFFFFFF, dark: 0x2E3039)
    static let functionKeyUIColor = dynamic(light: 0xD3D6DE, dark: 0x24262E)
    static let pressedKeyUIColor = dynamic(light: 0xBFC3CD, dark: 0x454852)
    static let returnKeyUIColor = dynamic(light: 0x14161C, dark: 0xF2F3F5)
    static let returnGlyphUIColor = dynamic(light: 0xFFFFFF, dark: 0x16171C)
    static let accentUIColor = UIColor(hex: 0x4F5BD5)
    static let accentGlyphUIColor = UIColor.white
    static let accentSoftUIColor = UIColor { traits in
        accentUIColor.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.22 : 0.14)
    }
    /// The style menu's current row.
    static let selectedRowUIColor = UIColor { traits in
        accentUIColor.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.22 : 0.10)
    }
    static let recordingUIColor = UIColor(hex: 0xE5484D)
    static let mutedUIColor = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        if traits.accessibilityContrast == .high { return UIColor(hex: dark ? 0xC9CDD6 : 0x3C4150) }
        return UIColor(hex: dark ? 0xA3A8B4 : 0x5B6170)
    }
    /// The icon tiles of rows that aren't selected.
    static let tileUIColor = dynamic(light: 0xF1F2F5, dark: 0x2B2D36)
    static let tileGlyphUIColor = dynamic(light: 0x3C4150, dark: 0xC9CDD6)
    static let scrimUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.35)
            : UIColor(red: 20 / 255, green: 22 / 255, blue: 28 / 255, alpha: 0.10)
    }
    /// Switched off: the translate tile and switch tracks.
    static let offTrackUIColor = dynamic(light: 0xC4C8D2, dark: 0x3A3D47)
    static let translateTileUIColor = UIColor(hex: 0x8EC0EC)
    static let borderUIColor = UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        let alpha: CGFloat = traits.accessibilityContrast == .high ? (dark ? 0.28 : 0.26) : (dark ? 0.10 : 0.08)
        return dark
            ? UIColor(white: 1, alpha: alpha)
            : UIColor(red: 20 / 255, green: 22 / 255, blue: 28 / 255, alpha: alpha)
    }
    static let keyShadowUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.5)
            : UIColor(red: 20 / 255, green: 22 / 255, blue: 28 / 255, alpha: 0.18)
    }

    static let backdrop = Color(uiColor: backdropUIColor)
    static let panel = Color(uiColor: panelUIColor)
    static let surface = Color(uiColor: surfaceUIColor)
    static let key = Color(uiColor: keyUIColor)
    static let pressedKey = Color(uiColor: pressedKeyUIColor)
    static let accent = Color(uiColor: accentUIColor)
    static let accentGlyph = Color(uiColor: accentGlyphUIColor)
    static let accentSoft = Color(uiColor: accentSoftUIColor)
    static let selectedRow = Color(uiColor: selectedRowUIColor)
    static let recording = Color(uiColor: recordingUIColor)
    static let recordingSoft = recording.opacity(0.18)
    static let muted = Color(uiColor: mutedUIColor)
    static let tile = Color(uiColor: tileUIColor)
    static let tileGlyph = Color(uiColor: tileGlyphUIColor)
    static let scrim = Color(uiColor: scrimUIColor)
    static let offTrack = Color(uiColor: offTrackUIColor)
    static let translateTile = Color(uiColor: translateTileUIColor)
    static let border = Color(uiColor: borderUIColor)
    /// The mock's shadows are a cool navy, rgb(15, 20, 40).
    static let shadow = Color(red: 15 / 255, green: 20 / 255, blue: 40 / 255)

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

/// A small, tactile press treatment used by the mic, toolbar controls, and sheet chips.
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

/// The mock's chip: a white (dark: graphite) fill, a hairline and a soft shadow. `active` tints it
/// with the accent; `pressed` darkens it while a held key (Delete) is down.
struct KeyboardSurface<S: Shape>: View {
    let shape: S
    var active = false
    var pressed = false

    var body: some View {
        shape
            .fill(pressed ? KeyboardChrome.pressedKey : active ? KeyboardChrome.accentSoft : KeyboardChrome.surface)
            .overlay {
                shape.stroke(active ? KeyboardChrome.accent.opacity(0.22) : KeyboardChrome.border, lineWidth: 1)
            }
            .shadow(color: KeyboardChrome.shadow.opacity(0.06), radius: 1, y: 1)
    }
}
