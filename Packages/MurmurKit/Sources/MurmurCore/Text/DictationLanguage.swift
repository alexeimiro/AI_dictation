import Foundation

/// A dictation language, always as a BCP-47 tag such as "ru-RU". Foundation-only so the keyboard
/// extension can use it too.
public struct DictationLanguage: Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let tag: String

    public var id: String { tag }

    /// `tag` must already be a BCP-47 tag; use `init(normalizing:)` for arbitrary identifiers.
    public init(tag: String) {
        self.tag = tag
    }

    /// Accepts ICU ("ru_RU") or BCP-47 ("ru-RU") identifiers.
    public init(normalizing identifier: String) {
        self.tag = Self.normalize(identifier)
    }

    public static func normalize(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47)
    }

    /// Lowercased primary language subtag: "ru" for "ru-RU".
    public var languageCode: String {
        String(tag.split(separator: "-").first ?? Substring(tag)).lowercased()
    }

    /// "RU", "EN": the keyboard's language pill.
    public var shortCode: String { languageCode.uppercased() }

    public var isRussian: Bool { languageCode == "ru" }

    /// The language name in the UI language ("Russian").
    public var localizedName: String {
        Locale.current.localizedString(forLanguageCode: languageCode) ?? tag
    }

    /// Language and region ("Russian (Russia)").
    public var localizedFullName: String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    public static let englishUS = DictationLanguage(tag: "en-US")

    public var description: String { tag }
}
