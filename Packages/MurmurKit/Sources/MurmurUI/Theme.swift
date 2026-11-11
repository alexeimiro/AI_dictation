import SwiftUI
// The colours, the mark and the echo rings: everything that imports MurmurUI gets them too.
@_exported import MurmurBrand

extension Color {
    /// `Color(hex: 0x312D38)`. Only onboarding's artwork still uses it; everything else takes a
    /// `Theme` token.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// The old colour names, each now a `Theme` token (MurmurBrand), so every screen already wears
/// the new colours. A screen switches to `Theme` when it is redesigned; this goes when none is left.
public enum Palette {
    public static let ink = Theme.ink
    public static let text = Theme.ink
    public static let textSecondary = Theme.second
    public static let splash = Theme.ink
    public static let cream = Theme.fill
    public static let selectedFill = Theme.fill
    public static let cardBorder = Theme.line
    public static let disabled = Theme.disabled
    public static let muted = Theme.third
    public static let fineprint = Theme.third
    public static let purple = Theme.ink
    public static let sheetBackdrop = Theme.track
    public static let progressOff = Theme.track
    public static let accent = Theme.ink
    public static let lavender = Theme.fill
    public static let offerPill = Theme.fill
    public static let proBadge = Theme.ink
    public static let toggleGreen = Theme.ink
    public static let toggleGreenSoft = Theme.fill
    public static let teal = Theme.ink
    public static let bubble = Theme.ink
    public static let canvas = Theme.canvas
    public static let tabSelected = Theme.fill
    public static let tabSelectedLabel = Theme.ink
    public static let lockGray = Theme.graphic
    public static let paper = Theme.canvas
    /// Delete and errors are ink: red means an open microphone and nothing else.
    public static let danger = Theme.ink
}

/// The old layout constants, kept for the screens that haven't been redesigned yet.
public enum Metrics {
    public static let screenMargin: CGFloat = 30
    public static let authMargin: CGFloat = 20
    public static let buttonHeight: CGFloat = 54
    public static let buttonRadius: CGFloat = 13
    /// Distance from the bottom of the screen to the bottom of the primary button.
    public static let buttonBottom: CGFloat = 64
    public static let cardHeight: CGFloat = 66
    public static let cardRadius: CGFloat = 12
    public static let cardSpacing: CGFloat = 12
    public static let borderWidth: CGFloat = 1.5
}
