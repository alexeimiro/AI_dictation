import Foundation

/// The languages Translate works with: the one the user speaks (the Speak language, Auto-detect
/// until one is picked) and the one the text goes in as.
public struct TranslationPair: Equatable, Sendable {
    public let source: DictationLanguage
    public let target: DictationLanguage

    public init(source: DictationLanguage, target: DictationLanguage) {
        self.source = source
        self.target = target
    }

    /// "Auto → RU", "RU → EN": the keyboard bar's Translate button.
    public var shortTitle: String {
        "\(source.isAutomatic ? "Auto" : source.shortCode) → \(target.shortCode)"
    }

    /// "Auto-detect to Russian", "Russian to English": what VoiceOver says for it.
    public var spokenTitle: String {
        "\(source.localizedName) to \(target.localizedName)"
    }
}

/// Translate's switch and its pair, as the keyboard, the app (the Action Button) and the Mac read
/// them. The pair is kept whether the switch is on or off: one tap turns translation on with the
/// languages last used, the next turns it off without forgetting them, and a restart changes
/// neither. A dictation reads `translationTarget` once, as it begins, and keeps that for its whole
/// length, so turning the switch while one runs changes the next one, never that one.
extension SharedSettings {
    /// The pair the switch translates with: the Speak language and the saved "To" language. Before
    /// a "To" is saved, and when the saved one is the source itself or a language Murmur can't
    /// translate into (not one of `available`), the iPhone's language stands in
    /// (`KeyboardLanguageDefaults.target`), so there is always a usable pair, also the first time.
    public func translationPair(
        preferred: [String] = Locale.preferredLanguages,
        available: [DictationLanguage] = DictationLanguage.translationLanguages
    ) -> TranslationPair {
        let source = KeyboardLanguageDefaults.source(
            saved: translationSourceLanguage, autoDetectApplied: autoDetectDefaultApplied)
        let target = KeyboardLanguageDefaults.target(
            saved: translationTargetLanguage.map(DictationLanguage.init(tag:)), source: source,
            preferred: preferred, available: available,
            recent: recentTranslationLanguages.map(DictationLanguage.init(tag:)))
        return TranslationPair(source: source, target: target)
    }

    /// The language a dictation that begins now is translated into: nil while the switch is off,
    /// whatever pair is saved.
    public func translationTarget(
        preferred: [String] = Locale.preferredLanguages,
        available: [DictationLanguage] = DictationLanguage.translationLanguages
    ) -> DictationLanguage? {
        translationEnabled ? translationPair(preferred: preferred, available: available).target : nil
    }

    /// Turns translation on or off and returns the pair it translates with. Turning it on saves
    /// that pair's "To", so the languages shown on the switch are the ones a restart, the app and
    /// the Mac use as well, even if the iPhone's language changes later. Turning it off saves
    /// nothing but the switch.
    @discardableResult
    public func setTranslationEnabled(
        _ enabled: Bool,
        preferred: [String] = Locale.preferredLanguages,
        available: [DictationLanguage] = DictationLanguage.translationLanguages
    ) -> TranslationPair {
        let pair = translationPair(preferred: preferred, available: available)
        if enabled, translationTargetLanguage != pair.target.tag {
            translationTargetLanguage = pair.target.tag
        }
        translationEnabled = enabled
        return pair
    }
}
