import SwiftUI

/// Murmur's type: the system font in a few roles. Every role follows Dynamic Type, and the system
/// font covers every script a dictation can come back in.
public enum TypeRole: Sendable {
    /// A screen's one big statement ("You're set.").
    case display
    /// Screen titles.
    case title
    case title2
    /// Row titles, button labels.
    case headline
    case body
    case callout
    case subhead
    /// Metadata under a row.
    case footnote
    case caption
}

extension Font {
    /// `Font.murmur(.title)`; pass a weight to override the role's own.
    public static func murmur(_ role: TypeRole, weight: Font.Weight? = nil) -> Font {
        switch role {
        case .display: .system(.largeTitle, weight: weight ?? .bold)
        case .title: .system(.title, weight: weight ?? .bold)
        case .title2: .system(.title2, weight: weight ?? .bold)
        case .headline: .system(.body, weight: weight ?? .semibold)
        case .body: .system(.body, weight: weight ?? .regular)
        case .callout: .system(.callout, weight: weight ?? .regular)
        case .subhead: .system(.subheadline, weight: weight ?? .regular)
        case .footnote: .system(.footnote, weight: weight ?? .regular)
        case .caption: .system(.caption, weight: weight ?? .regular)
        }
    }
}

/// The bundled fonts' names. Only onboarding's practice text box still loads one; they go with it.
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
    /// The old display face, now the system font in bold at the text style nearest to `size`, so
    /// it still follows Dynamic Type. New code uses `Font.murmur(_:)`.
    public static func serif(_ size: CGFloat, _ weight: SerifWeight = .regular,
                             relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .system(.nearest(to: size), weight: .bold)
    }

    /// The old UI face, now the system font at the text style nearest to `size`. New code uses
    /// `Font.murmur(_:)`.
    public static func ui(_ size: CGFloat, _ weight: UIWeight = .regular,
                          relativeTo style: Font.TextStyle = .body) -> Font {
        let weight: Font.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        return .system(.nearest(to: size), weight: weight)
    }
}

extension Font.TextStyle {
    /// The text style whose size at the default Dynamic Type setting is closest to `size`.
    static func nearest(to size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: .caption2
        case ..<12.5: .caption
        case ..<14: .footnote
        case ..<15.5: .subheadline
        case ..<16.5: .callout
        case ..<18.5: .body
        case ..<21: .title3
        case ..<25: .title2
        case ..<31: .title
        default: .largeTitle
        }
    }
}

extension Font {
    /// User content (transcripts, language names): the system font, which covers every script the
    /// recognizer can produce.
    public static func transcript(_ style: Font.TextStyle = .body) -> Font {
        .system(style)
    }
}
