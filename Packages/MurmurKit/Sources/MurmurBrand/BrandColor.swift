import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension Color {
    /// A brand token that follows the appearance and Increase Contrast. The label matters: the
    /// asset catalog generates `Color(.accentColor)`-style symbols, which an unlabelled
    /// initialiser would make ambiguous.
    public init(brand token: BrandToken) {
        #if canImport(UIKit)
        self.init(uiColor: .brand(token))
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: token.value(dark: dark))
        })
        #endif
    }

    /// One fixed value, for surfaces that must not change with the appearance (the Live Activity,
    /// the app icon).
    public init(rgb: BrandRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: rgb.opacity)
    }
}

#if canImport(UIKit)
extension UIColor {
    /// A brand token for UIKit, resolved against the trait collection it is drawn in.
    public static func brand(_ token: BrandToken) -> UIColor {
        UIColor { traits in
            UIColor(rgb: token.value(dark: traits.userInterfaceStyle == .dark,
                                     highContrast: traits.accessibilityContrast == .high))
        }
    }

    public convenience init(rgb: BrandRGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: rgb.opacity)
    }
}
#elseif canImport(AppKit)
extension NSColor {
    public convenience init(rgb: BrandRGB) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: rgb.opacity)
    }
}
#endif

/// The brand tokens as SwiftUI colours: `Theme.ink`.
public enum Theme {
    public static let canvas = Color(brand: .canvas)
    public static let fill = Color(brand: .fill)
    public static let fillPressed = Color(brand: .fillPressed)
    public static let line = Color(brand: .line)
    public static let ink = Color(brand: .ink)
    public static let onInk = Color(brand: .onInk)
    public static let second = Color(brand: .second)
    public static let third = Color(brand: .third)
    public static let graphic = Color(brand: .graphic)
    public static let track = Color(brand: .track)
    public static let disabled = Color(brand: .disabled)
    /// The microphone is open. Nothing else is red.
    public static let live = Color(brand: .live)
    public static let onLive = Color(brand: .onLive)
}
