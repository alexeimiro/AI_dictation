import Foundation

/// One sRGB colour: `0xRRGGBB` and an opacity.
public struct BrandRGB: Sendable, Hashable {
    public let hex: UInt32
    public let opacity: Double

    public init(_ hex: UInt32, opacity: Double = 1) {
        self.hex = hex
        self.opacity = opacity
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    /// WCAG 2 relative luminance; opacity is ignored.
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// WCAG 2 contrast between two colours, from 1 to 21.
public enum BrandContrast {
    public static func ratio(_ a: BrandRGB, _ b: BrandRGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// Murmur's colours: black, white and a few greys, plus one red that marks an open microphone
/// and nothing else. Every token has a light and a dark value (the app is light only; the keyboard
/// follows its host app), and a few have Increase Contrast values. `MurmurBrandTests` holds every
/// text token to 4.5:1 on the backgrounds it is used on.
public enum BrandToken: String, CaseIterable, Sendable {
    /// Screen background.
    case canvas
    /// Cards, fields and chips.
    case fill
    case fillPressed
    /// Hairlines.
    case line
    /// Text, icons and primary buttons.
    case ink
    /// Labels on ink.
    case onInk
    /// Secondary text.
    case second
    /// Metadata and captions.
    case third
    /// Marks that aren't text: resting rings, selection rings, empty-state marks.
    case graphic
    /// The unfilled part of a meter or a switch.
    case track
    /// Disabled fills.
    case disabled
    /// The microphone is open. Used for nothing else: delete and errors are ink.
    case live
    /// Labels and glyphs on `live`.
    case onLive
    /// The keyboard's own panel, painted only when its appearance is forced against the host's.
    case keyboardPanel
    /// The keyboard's letter keys.
    case key
    case keyPressed
    /// The keyboard's ABC, shift, delete and return keys.
    case functionKey
    /// Cards on the keyboard: notices, menu rows.
    case keyboardCard
    /// The Live Activity's surface, the same in both appearances.
    case activity

    public var light: BrandRGB { values.light }
    public var dark: BrandRGB { values.dark }

    /// The value for an appearance, with Increase Contrast if asked.
    public func value(dark: Bool, highContrast: Bool = false) -> BrandRGB {
        if highContrast, let strong = highContrastValues {
            return dark ? strong.dark : strong.light
        }
        return dark ? values.dark : values.light
    }

    private var values: (light: BrandRGB, dark: BrandRGB) {
        switch self {
        case .canvas: (BrandRGB(0xFFFFFF), BrandRGB(0x121212))
        case .fill: (BrandRGB(0xF4F4F4), BrandRGB(0x2C2C2E))
        case .fillPressed: (BrandRGB(0xE8E8E8), BrandRGB(0x3A3A3C))
        case .line: (BrandRGB(0xE5E5E5), BrandRGB(0x3A3A3C))
        case .ink: (BrandRGB(0x0D0D0D), BrandRGB(0xFFFFFF))
        case .onInk: (BrandRGB(0xFFFFFF), BrandRGB(0x0D0D0D))
        case .second: (BrandRGB(0x5D5D5D), BrandRGB(0xC7C7CC))
        case .third: (BrandRGB(0x6B6B6B), BrandRGB(0xA0A0A6))
        case .graphic: (BrandRGB(0x8A8A8A), BrandRGB(0x8E8E93))
        case .track: (BrandRGB(0xDDDDDD), BrandRGB(0x48484A))
        case .disabled: (BrandRGB(0xC9C9C9), BrandRGB(0x48484A))
        case .live: (BrandRGB(0xD92D20), BrandRGB(0xFF5247))
        case .onLive: (BrandRGB(0xFFFFFF), BrandRGB(0x0D0D0D))
        case .keyboardPanel: (BrandRGB(0xE3E4E8), BrandRGB(0x1C1C1E))
        case .key: (BrandRGB(0xFFFFFF), BrandRGB(0x4A4A4D))
        case .keyPressed: (BrandRGB(0xD1D1D6), BrandRGB(0x5C5C5E))
        case .functionKey: (BrandRGB(0xC6C8CE), BrandRGB(0x333336))
        case .keyboardCard: (BrandRGB(0xFFFFFF), BrandRGB(0x2C2C2E))
        case .activity: (BrandRGB(0x0D0D0D), BrandRGB(0x0D0D0D))
        }
    }

    private var highContrastValues: (light: BrandRGB, dark: BrandRGB)? {
        switch self {
        case .third: (BrandRGB(0x5D5D5D), BrandRGB(0xC7C7CC))
        case .graphic: (BrandRGB(0x5D5D5D), BrandRGB(0xC7C7CC))
        case .line: (BrandRGB(0x9A9A9A), BrandRGB(0x6E6E73))
        default: nil
        }
    }
}
