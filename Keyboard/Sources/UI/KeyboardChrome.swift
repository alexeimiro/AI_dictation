import SwiftUI
import UIKit

/// Adaptive visual tokens shared by the SwiftUI voice surface and the UIKit key grid. The palette
/// stays close to the system keyboard, with a restrained plum accent that belongs to Murmur.
enum KeyboardChrome {
    static let backdropUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.071, blue: 0.086, alpha: 1)
            : UIColor(red: 0.910, green: 0.914, blue: 0.941, alpha: 1)
    }
    static let panelUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.098, blue: 0.122, alpha: 0.98)
            : UIColor(red: 0.963, green: 0.965, blue: 0.982, alpha: 0.98)
    }
    static let surfaceUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.11)
            : UIColor(white: 1, alpha: 0.78)
    }
    static let keyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.255, green: 0.247, blue: 0.286, alpha: 1)
            : UIColor(white: 1, alpha: 0.96)
    }
    static let functionKeyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.165, green: 0.157, blue: 0.188, alpha: 1)
            : UIColor(red: 0.790, green: 0.800, blue: 0.842, alpha: 1)
    }
    static let pressedKeyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.350, green: 0.337, blue: 0.388, alpha: 1)
            : UIColor(red: 0.710, green: 0.720, blue: 0.765, alpha: 1)
    }
    static let accentUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.855, green: 0.804, blue: 0.949, alpha: 1)
            : UIColor(red: 0.192, green: 0.176, blue: 0.220, alpha: 1)
    }
    static let accentGlyphUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.098, blue: 0.129, alpha: 1)
            : .white
    }
    static let accentSoftUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.490, green: 0.410, blue: 0.620, alpha: 0.36)
            : UIColor(red: 0.655, green: 0.555, blue: 0.835, alpha: 0.18)
    }
    static let borderUIColor = UIColor { traits in
        if traits.accessibilityContrast == .high {
            return traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.28)
                : UIColor(red: 0.135, green: 0.118, blue: 0.160, alpha: 0.26)
        }
        return traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(red: 0.135, green: 0.118, blue: 0.160, alpha: 0.10)
    }

    static let backdrop = Color(uiColor: backdropUIColor)
    static let panel = Color(uiColor: panelUIColor)
    static let surface = Color(uiColor: surfaceUIColor)
    static let key = Color(uiColor: keyUIColor)
    static let pressedKey = Color(uiColor: pressedKeyUIColor)
    static let accent = Color(uiColor: accentUIColor)
    static let accentGlyph = Color(uiColor: accentGlyphUIColor)
    static let accentSoft = Color(uiColor: accentSoftUIColor)
    static let border = Color(uiColor: borderUIColor)
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

struct KeyboardSurface<S: Shape>: View {
    let shape: S
    var active = false

    var body: some View {
        shape
            .fill(active ? KeyboardChrome.accentSoft : KeyboardChrome.surface)
            .overlay {
                shape.stroke(active ? KeyboardChrome.accent.opacity(0.22) : KeyboardChrome.border, lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.07), radius: 3, y: 1.5)
    }
}
