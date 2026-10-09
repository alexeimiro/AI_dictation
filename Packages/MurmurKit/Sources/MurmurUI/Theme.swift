import SwiftUI

extension Color {
    /// `Color(hex: 0x312D38)`
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// Color tokens sampled from the reference screenshots.
public enum Palette {
    public static let ink = Color(hex: 0x312D38)
    public static let text = Color(hex: 0x28272C)
    public static let textSecondary = Color(hex: 0x5A595C)
    public static let splash = Color(hex: 0x2E2A34)
    public static let cream = Color(hex: 0xFFFFF0)
    public static let selectedFill = Color(hex: 0xFEFFEB)
    public static let cardBorder = Color(hex: 0xD0CED2)
    public static let disabled = Color(hex: 0xACACB0)
    public static let progressOff = Color(hex: 0xC1BDC4)
    public static let accent = Color(hex: 0xFFA83E)
    public static let lavender = Color(hex: 0xF0D7FF)
    public static let offerPill = Color(hex: 0xDDD4F0)
    public static let proBadge = Color(hex: 0xA08AFF)
    public static let toggleGreen = Color(hex: 0x4FBF77)
    public static let toggleGreenSoft = Color(hex: 0xC4EAD2)
    public static let teal = Color(hex: 0x004F47)
    public static let bubble = Color(hex: 0x1C1A1D)
    public static let canvas = Color(hex: 0xF3F3F5)
    public static let tabSelected = Color(hex: 0xECE9EC)
    public static let tabSelectedLabel = Color(hex: 0x6A4B97)
    public static let lockGray = Color(hex: 0xA8A5A9)
    public static let paper = Color.white
    public static let danger = Color(hex: 0xE5484D)
}

/// Layout constants measured from the 393 pt-wide references.
public enum Metrics {
    public static let screenMargin: CGFloat = 30
    public static let authMargin: CGFloat = 20
    public static let buttonHeight: CGFloat = 53
    public static let buttonRadius: CGFloat = 12
    public static let cardHeight: CGFloat = 64
    public static let cardRadius: CGFloat = 13
    public static let cardSpacing: CGFloat = 13
    public static let borderWidth: CGFloat = 1.6
}
