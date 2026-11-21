import Foundation

/// A dictation language, always as a BCP-47 tag such as "ru-RU". Foundation-only so the keyboard
/// extension can use it too.
///
/// Murmur's languages live here and nowhere else (the app, the keyboard and the Mac read these
/// lists): `speechLanguages`, which can be spoken, and `translationLanguages`, which a dictation
/// can be typed in. Every language that can be spoken can be typed in; some can only be typed in.
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

    /// "RU", "EN": the keyboard's language pill. Filipino is "FIL", not Tagalog's "TL".
    public var shortCode: String {
        if isAutomatic { return "AUTO" }
        return Self.displayCodes[languageCode] ?? languageCode.uppercased()
    }

    public var isRussian: Bool { languageCode == "ru" }
    public var isAutomatic: Bool { languageCode == "und" }

    /// Normally written in Latin letters: "de", "pt-BR", "sr-Latn"; not "ru", "ja" or "sr".
    public var usesLatinScript: Bool {
        let likely = Locale.Language(identifier: tag).maximalIdentifier
        return Locale.Language(identifier: likely).script == .latin
    }

    /// Written right to left: Arabic, Hebrew, Persian, Urdu, Pashto.
    public var isRightToLeft: Bool {
        !isAutomatic && Locale.Language(identifier: tag).characterDirection == .rightToLeft
    }

    /// The language name in the UI language ("Russian").
    public var localizedName: String {
        if isAutomatic { return "Auto-detect" }
        let code = Self.nameCodes[languageCode] ?? languageCode
        return Locale.current.localizedString(forLanguageCode: code) ?? tag
    }

    /// Language and region ("Russian (Russia)").
    public var localizedFullName: String {
        if isAutomatic { return "Auto-detect" }
        return Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    /// The language's name for itself ("Русский"), capitalized; nil when unknown.
    public var nativeName: String? {
        guard !isAutomatic else { return nil }
        let code = Self.nameCodes[languageCode] ?? languageCode
        guard let name = Locale(identifier: code).localizedString(forLanguageCode: code) else { return nil }
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

    // MARK: What each language can do

    /// Can be spoken: recognized in the cloud, and offered as a Speak language. Matched by language,
    /// so "fil-PH" (Apple's Filipino) counts as "tl-PH" and "nb" as Norwegian. False for Auto-detect,
    /// which is a choice of the Speak menus but no language.
    public var supportsSpeech: Bool {
        !isAutomatic && Self.speechCodes.contains(capabilityCode)
    }

    /// Can be typed in: offered as a translation target ("Type in"). Every speech language, and
    /// the languages only the text model writes.
    public var supportsTranslation: Bool {
        !isAutomatic && Self.translationCodes.contains(capabilityCode)
    }

    /// The entry of `speechLanguages` for this language ("ru" → "ru-RU"), or nil.
    public var speechEntry: DictationLanguage? {
        Self.speechLanguages.first { $0.capabilityCode == capabilityCode }
    }

    /// The entry of `translationLanguages` for this language, or nil.
    public var translationEntry: DictationLanguage? {
        Self.translationLanguages.first { $0.capabilityCode == capabilityCode }
    }

    /// At most this many languages can be picked in Settings › Languages: the server sends at
    /// most 10 to the recognizer to detect the speech among (`TRANSCRIBE_LIMITS.maxLanguageHints`).
    public static let maxSpokenLanguages = 10

    /// The languages Murmur recognizes, through OpenAI's gpt-transcribe (the dictation) and, where
    /// it knows them, Soniox (the live words while speaking):
    /// - OpenAI's supported languages for its speech-to-text models (the Whisper list of 57);
    /// - Bengali, Albanian, Basque, Gujarati, Malayalam, Punjabi and Telugu: in Whisper's set and
    ///   on Soniox's published list (docs.soniox.com, 2026-11-21); OpenAI puts gpt-4o-transcribe's
    ///   error rate near 30% for the Indic and Dravidian languages, as for Tamil and Kannada above;
    /// - Cantonese: a code gpt-transcribe's guide names ("yue"), and an on-device Apple model.
    /// Each one must stay something the services process: `scripts/bench/language_probe.ts`
    /// checks that OpenAI accepts every code.
    public static let speechLanguages: [DictationLanguage] = [
        "en-US", "af-ZA", "ar-SA", "hy-AM", "az-AZ", "be-BY", "bs-BA", "bg-BG", "ca-ES", "zh-CN",
        "hr-HR", "cs-CZ", "da-DK", "nl-NL", "et-EE", "fi-FI", "fr-FR", "gl-ES", "de-DE", "el-GR",
        "he-IL", "hi-IN", "hu-HU", "is-IS", "id-ID", "it-IT", "ja-JP", "kn-IN", "kk-KZ", "ko-KR",
        "lv-LV", "lt-LT", "mk-MK", "ms-MY", "mr-IN", "mi-NZ", "ne-NP", "nb-NO", "fa-IR", "pl-PL",
        "pt-BR", "ro-RO", "ru-RU", "sr-RS", "sk-SK", "sl-SI", "es-ES", "sw-KE", "sv-SE", "tl-PH",
        "ta-IN", "th-TH", "tr-TR", "uk-UA", "ur-PK", "vi-VN", "cy-GB",
        "bn-BD", "sq-AL", "eu-ES", "gu-IN", "ml-IN", "pa-IN", "te-IN", "yue-CN",
    ].map(DictationLanguage.init(tag:))

    /// Languages a dictation can be typed in but not spoken in: the text model (Claude) writes
    /// them, but no speech service Murmur uses recognizes them reliably. Widely written languages
    /// with a standard script that iOS and macOS render; Anthropic's own scores for the
    /// lower-resource ones (Swahili, Yoruba) are 87–94% of English for Claude Haiku 5.5.
    public static let textOnlyLanguages: [DictationLanguage] = [
        "am-ET", "as-IN", "eo", "ga-IE", "ha-NG", "ht-HT", "ig-NG", "jv-ID", "ka-GE", "km-KH",
        "ky-KG", "la", "lb-LU", "lo-LA", "mn-MN", "mt-MT", "my-MM", "or-IN", "ps-AF", "si-LK",
        "so-SO", "tg-TJ", "uz-UZ", "xh-ZA", "yo-NG", "zu-ZA",
    ].map(DictationLanguage.init(tag:))

    /// Every language a dictation can be typed in: the speech languages, then the text-only ones.
    public static let translationLanguages: [DictationLanguage] = speechLanguages + textOnlyLanguages

    /// `speechLanguages` in alphabetical order of their names in the UI language, for menus.
    public static let speechLanguagesByName: [DictationLanguage] = sortedByName(speechLanguages)

    /// `translationLanguages` in alphabetical order of their names in the UI language, for menus.
    public static let translationLanguagesByName: [DictationLanguage] = sortedByName(translationLanguages)

    // MARK: Search

    /// The languages of `languages` that `query` finds, best first: an exact code ("pt", "fil"),
    /// then names that start with it, then names that contain it. A name is the one in the UI
    /// language, the English one, the language's own ("Deutsch", "日本語") or a common other one
    /// ("Farsi", "Mandarin", "Tagalog"); case and accents don't matter ("espanol"). An empty query
    /// returns `languages` as given.
    public static func search(_ query: String, in languages: [DictationLanguage]) -> [DictationLanguage] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return languages }
        let folded = fold(query)
        var ranked: [(rank: Int, index: Int, language: DictationLanguage)] = []
        for (index, language) in languages.enumerated() {
            let keys = searchKeys(for: language)
            let rank: Int
            if keys.codes.contains(folded) {
                rank = 0
            } else if keys.names.contains(where: { $0.hasPrefix(folded) || $0.contains(" " + folded) }) {
                rank = 1
            } else if keys.names.contains(where: { $0.contains(folded) }) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, index, language))
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.language)
    }

    public var description: String { tag }

    // MARK: Helpers

    /// The language code the capability lists know it by: Apple's and older codes for the same
    /// language map to the one in the lists.
    private var capabilityCode: String {
        Self.codeAliases[languageCode] ?? languageCode
    }

    private static let codeAliases: [String: String] = [
        "fil": "tl", "no": "nb", "iw": "he", "in": "id", "cmn": "zh",
    ]

    private static let speechCodes = Set(speechLanguages.map(\.languageCode))
    private static let translationCodes = Set(translationLanguages.map(\.languageCode))

    /// Codes the pill shows other than the language subtag.
    private static let displayCodes: [String: String] = ["tl": "FIL"]

    /// Codes whose names are taken from another code: Murmur's "tl" is called Filipino, the name
    /// the Philippines uses for the national standard of Tagalog.
    private static let nameCodes: [String: String] = ["tl": "fil"]

    /// Other names people search a language by, in English.
    private static let otherNames: [String: [String]] = [
        "bn": ["Bengali"],
        "zh": ["Mandarin", "Putonghua", "Simplified Chinese"],
        "yue": ["Guangdonghua"],
        "fa": ["Farsi"],
        "tl": ["Tagalog", "Pilipino"],
        "ms": ["Bahasa Melayu", "Malaysian"],
        "id": ["Bahasa Indonesia"],
        "nb": ["Bokmål"],
        "my": ["Myanmar"],
        "km": ["Cambodian"],
        "pa": ["Panjabi"],
        "sw": ["Kiswahili"],
        "ht": ["Creole", "Kreyòl"],
        "ky": ["Kirghiz"],
        "si": ["Sinhalese"],
        "or": ["Oriya"],
        "sr": ["Srpski"],
        "es": ["Castilian"],
        "el": ["Hellenic"],
        "he": ["Ivrit"],
        "ga": ["Gaelic", "Irish Gaelic"],
    ]

    private struct SearchKeys: Sendable {
        let codes: Set<String>
        let names: [String]
    }

    /// Built once for every language the lists hold, so a keystroke in a search field only
    /// compares strings.
    private static let searchIndex: [String: SearchKeys] = {
        var index: [String: SearchKeys] = [:]
        for language in translationLanguages {
            index[language.tag] = makeSearchKeys(for: language)
        }
        return index
    }()

    private static func searchKeys(for language: DictationLanguage) -> SearchKeys {
        searchIndex[language.tag] ?? makeSearchKeys(for: language)
    }

    private static func makeSearchKeys(for language: DictationLanguage) -> SearchKeys {
        let code = language.languageCode
        let nameCode = nameCodes[code] ?? code
        let english = Locale(identifier: "en").localizedString(forLanguageCode: nameCode)
        let names = [language.localizedName, english, language.nativeName] + (otherNames[code] ?? []).map(Optional.some)
        let codes = [code, language.capabilityCode, language.shortCode, nameCode, language.tag]
        return SearchKeys(codes: Set(codes.map(fold)), names: Array(Set(names.compactMap { $0 }.map(fold))))
    }

    /// Lowercased, without accents or width differences: "Español" and "espanol" match.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func sortedByName(_ languages: [DictationLanguage]) -> [DictationLanguage] {
        languages.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }
}

/// The direction a piece of dictated text runs in, from its first letter with a strong direction
/// (the Unicode bidirectional algorithm's rule for a paragraph): "مرحبا Murmur" is right to left,
/// "Murmur مرحبا" left to right. Digits, punctuation and emoji have none of their own.
public enum TextDirection: Sendable, Equatable {
    case leftToRight, rightToLeft

    public static func of(_ text: String) -> TextDirection {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return isRightToLeft(scalar) ? .rightToLeft : .leftToRight
        }
        return .leftToRight
    }

    /// The blocks of the scripts written right to left: Hebrew, Arabic, Syriac, Thaana, N'Ko,
    /// Samaritan, Mandaic, their supplements and presentation forms, and the historic ones.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: true
        default: false
        }
    }
}
