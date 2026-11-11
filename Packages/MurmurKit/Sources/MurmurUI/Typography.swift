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

extension Font {
    /// User content (transcripts, language names): the system font, which covers every script the
    /// recognizer can produce.
    public static func transcript(_ style: Font.TextStyle = .body) -> Font {
        .system(style)
    }
}
