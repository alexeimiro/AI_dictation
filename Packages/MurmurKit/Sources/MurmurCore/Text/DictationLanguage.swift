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
    public var shortCode: String { isAutomatic ? "AUTO" : languageCode.uppercased() }

    public var isRussian: Bool { languageCode == "ru" }
    public var isAutomatic: Bool { languageCode == "und" }

    /// Normally written in Latin letters: "de", "pt-BR", "sr-Latn"; not "ru", "ja" or "sr".
    public var usesLatinScript: Bool {
        let likely = Locale.Language(identifier: tag).maximalIdentifier
        return Locale.Language(identifier: likely).script == .latin
    }

    /// The language name in the UI language ("Russian").
    public var localizedName: String {
        if isAutomatic { return "Auto-detect" }
        return Locale.current.localizedString(forLanguageCode: languageCode) ?? tag
    }

    /// Language and region ("Russian (Russia)").
    public var localizedFullName: String {
        if isAutomatic { return "Auto-detect" }
        return Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    /// The language's name for itself ("Русский"), capitalized; nil when unknown.
    public var nativeName: String? {
        guard !isAutomatic,
              let name = Locale(identifier: tag).localizedString(forLanguageCode: languageCode) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "Russian (Русский)", or just "English" where both names are the same: the language lists.
    public var pickerName: String {
        guard let nativeName, nativeName.lowercased() != localizedName.lowercased() else { return localizedName }
        return "\(localizedName) (\(nativeName))"
    }

    public static let englishUS = DictationLanguage(tag: "en-US")
    /// Cloud recognition chooses the spoken language. The BCP-47 `und` tag means undetermined.
    public static let automatic = DictationLanguage(tag: "und")

    /// Every language OpenAI's speech-to-text and GPT translation support (the Whisper language
    /// list). Recognition reaches them through the cloud even when no on-device speech model is
    /// installed.
    public static let cloudLanguages: [DictationLanguage] = [
        "en-US", "af-ZA", "ar-SA", "hy-AM", "az-AZ", "be-BY", "bs-BA", "bg-BG", "ca-ES", "zh-CN",
        "hr-HR", "cs-CZ", "da-DK", "nl-NL", "et-EE", "fi-FI", "fr-FR", "gl-ES", "de-DE", "el-GR",
        "he-IL", "hi-IN", "hu-HU", "is-IS", "id-ID", "it-IT", "ja-JP", "kn-IN", "kk-KZ", "ko-KR",
        "lv-LV", "lt-LT", "mk-MK", "ms-MY", "mr-IN", "mi-NZ", "ne-NP", "nb-NO", "fa-IR", "pl-PL",
        "pt-BR", "ro-RO", "ru-RU", "sr-RS", "sk-SK", "sl-SI", "es-ES", "sw-KE", "sv-SE", "tl-PH",
        "ta-IN", "th-TH", "tr-TR", "uk-UA", "ur-PK", "vi-VN", "cy-GB",
    ].map(DictationLanguage.init(tag:))

    /// `cloudLanguages` in alphabetical order of their names in the UI language, for menus.
    public static let cloudLanguagesByName: [DictationLanguage] = cloudLanguages.sorted {
        $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
    }

    public var description: String { tag }
}
