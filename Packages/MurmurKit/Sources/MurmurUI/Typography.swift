import SwiftUI

/// Bundled fonts (OFL): EB Garamond for display, Figtree for UI. Registered by the app through
/// `UIAppFonts`; when unavailable (widgets, previews) SwiftUI falls back to the system font.
public enum FontName {
    public static let serifRegular = "EBGaramond-Regular"
    public static let serifMedium = "EBGaramond-Medium"
    public static let serifItalic = "EBGaramond-Italic"
    public static let uiRegular = "Figtree-Regular"
    public static let uiMedium = "Figtree-Medium"
    public static let uiSemiBold = "Figtree-SemiBold"
}

public enum SerifWeight: Sendable {
    case regular, medium, italic
}

public enum UIWeight: Sendable {
    case regular, medium, semibold
}

extension Font {
    /// Display serif (titles), scaled with Dynamic Type relative to `.largeTitle`.
    public static func serif(_ size: CGFloat, _ weight: SerifWeight = .regular,
                             relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        let name = switch weight {
        case .regular: FontName.serifRegular
        case .medium: FontName.serifMedium
        case .italic: FontName.serifItalic
        }
        return .custom(name, size: size, relativeTo: style)
    }

    /// UI sans-serif (body, buttons).
    public static func ui(_ size: CGFloat, _ weight: UIWeight = .regular,
                          relativeTo style: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .regular: FontName.uiRegular
        case .medium: FontName.uiMedium
        case .semibold: FontName.uiSemiBold
        }
        return .custom(name, size: size, relativeTo: style)
    }
}

extension Font {
    /// User content (transcripts, language names): the system font, which covers every script the
    /// recognizer can produce. Figtree has no Cyrillic glyphs.
    public static func transcript(_ style: Font.TextStyle = .body) -> Font {
        .system(style)
    }
}
