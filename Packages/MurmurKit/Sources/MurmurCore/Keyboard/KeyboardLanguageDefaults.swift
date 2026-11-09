import Foundation

/// The keyboard's languages until the user picks them, taken from the iPhone's own language: the
/// first of `Locale.preferredLanguages` (`Locale.current` is `en_RU` on a Russian iPhone with an
/// English region format). Pure, so the rules are tested here; the keyboard target has no tests.
public enum KeyboardLanguageDefaults {
    /// What the keyboard listens for. Auto-detect, like ChatGPT's dictation, until the user picks
    /// a language in the Speak menu. `autoDetectApplied` is false until the keyboard first ran
    /// with Auto as the default: a language saved before then was the old default, not a choice.
    public static func source(saved: String?, autoDetectApplied: Bool) -> DictationLanguage {
        guard autoDetectApplied, let saved else { return .automatic }
        return DictationLanguage(tag: saved)
    }

    /// The iPhone's language as one of `available` (matched by language code), or nil when it
    /// isn't one of them.
    public static func interfaceLanguage(preferred: [String], available: [DictationLanguage]) -> DictationLanguage? {
        preferred.first.flatMap { match($0, in: available) }
    }

    /// The letters layout's language: a chosen Speak language's, and under Auto the iPhone's, so
    /// a Russian iPhone keeps ЙЦУКЕН.
    public static func typingLanguage(source: DictationLanguage, interface: DictationLanguage?) -> String {
        source.isAutomatic ? interface?.languageCode ?? "en" : source.languageCode
    }

    /// "Type in" for translations, when the user hasn't picked it or picked the source itself:
    /// the iPhone's language ("Auto → Russian" on a Russian iPhone). When that is the source,
    /// English; when the source is English too, another of the iPhone's languages, a recent one,
    /// else Spanish.
    public static func target(
        saved: DictationLanguage?, source: DictationLanguage, preferred: [String],
        available: [DictationLanguage], recent: [DictationLanguage]
    ) -> DictationLanguage {
        let sourceCode = source.isAutomatic ? nil : source.languageCode
        func usable(_ language: DictationLanguage?) -> DictationLanguage? {
            guard let language, !language.isAutomatic, language.languageCode != sourceCode else { return nil }
            return language
        }
        if let saved = usable(saved) { return saved }
        let phone = preferred.compactMap { match($0, in: available) }
        if let interface = usable(phone.first) { return interface }
        if sourceCode != "en" { return match("en", in: available) ?? .englishUS }
        return phone.dropFirst().lazy.compactMap(usable).first
            ?? recent.lazy.compactMap(usable).first
            ?? match("es", in: available) ?? DictationLanguage(tag: "es-ES")
    }

    private static func match(_ identifier: String, in available: [DictationLanguage]) -> DictationLanguage? {
        let code = DictationLanguage(normalizing: identifier).languageCode
        return available.first { $0.languageCode == code }
    }
}
