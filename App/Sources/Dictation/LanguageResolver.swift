import Foundation
import MurmurCore
import Speech

/// A language ready for recognition: the locale the engine accepts, and which engine to use.
struct ResolvedLanguage: Sendable, Equatable {
    /// BCP-47 tag as stored in settings ("ru-RU").
    let tag: String
    /// The locale as returned by `supportedLocale(equivalentTo:)`, which the modules require.
    let locale: Locale
    let engine: AppleSpeechTranscriber.Kind
    /// Personal dictionary terms; only DictationTranscriber honors them (≤100).
    var contextualStrings: [String] = []

    var language: DictationLanguage { DictationLanguage(tag: tag) }
}

enum LanguageResolver {
    /// The main dictation language: the explicit setting, else the first of the device's
    /// preferred languages that an on-device engine supports, else US English. The result is
    /// persisted so later sessions and the keyboard see a stable value.
    ///
    /// `Locale.current` is deliberately not used: for an app without a Russian localization it
    /// is `en_RU` on a Russian iPhone, which would silently dictate in English.
    static func primaryTag(settings: SharedSettings) async -> String {
        if let tag = settings.primaryLanguage { return tag }
        for preferred in Locale.preferredLanguages {
            if let tag = await supportedTag(equivalentTo: preferred) {
                settings.primaryLanguage = tag
                return tag
            }
        }
        settings.primaryLanguage = DictationLanguage.englishUS.tag
        return DictationLanguage.englishUS.tag
    }

    /// The BCP-47 tag of the locale either engine accepts for `identifier`, or nil.
    static func supportedTag(equivalentTo identifier: String) async -> String? {
        let locale = Locale(identifier: identifier)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return match.identifier(.bcp47)
        }
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return match.identifier(.bcp47)
        }
        return nil
    }

    /// Every language either engine supports, deduplicated by tag and sorted by name.
    static func availableLanguages() async -> [DictationLanguage] {
        var seen: Set<String> = []
        var languages: [DictationLanguage] = []
        let locales = await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales
        for locale in locales {
            let tag = locale.identifier(.bcp47)
            if seen.insert(tag).inserted {
                languages.append(DictationLanguage(tag: tag))
            }
        }
        return languages.sorted {
            $0.localizedFullName.localizedCaseInsensitiveCompare($1.localizedFullName) == .orderedAscending
        }
    }
}
