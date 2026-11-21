import Foundation
import Testing
@testable import MurmurCore

/// The keyboard bar's one-tap Translate: on and off with the pair last used, kept across restarts.
struct TranslationSwitchTests {
    private let available = ["en-US", "ru-RU", "uk-UA", "tr-TR", "es-ES", "de-DE"].map(DictationLanguage.init(tag:))

    /// A fresh App Group store, and a second `SharedSettings` on it stands for the next launch
    /// (or the other process: the keyboard writes, the app reads).
    private func store() throws -> (settings: SharedSettings, relaunch: () -> SharedSettings, cleanup: () -> Void) {
        let suite = "test.murmur.translation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SharedSettings(defaults: defaults), { SharedSettings(defaults: defaults) },
                { defaults.removePersistentDomain(forName: suite) })
    }

    /// The user picked Russian → English once.
    private func pickRussianToEnglish(_ settings: SharedSettings) {
        settings.autoDetectDefaultApplied = true
        settings.translationSourceLanguage = "ru-RU"
        settings.translationTargetLanguage = "en-US"
    }

    /// Nothing configured: off, yet a usable pair is ready for the first tap (Auto → the iPhone's
    /// language), and a dictation gets no target.
    @Test func aFirstTimeUserIsOffWithAUsablePair() throws {
        let (settings, _, cleanup) = try store()
        defer { cleanup() }
        #expect(!settings.translationEnabled)
        #expect(settings.translationTarget(preferred: ["ru-RU"], available: available) == nil)
        let pair = settings.translationPair(preferred: ["ru-RU"], available: available)
        #expect(pair.source.isAutomatic && pair.target.tag == "ru-RU")
        #expect(pair.shortTitle == "Auto → RU")
        // A phone language Murmur can't translate into: English stands in.
        #expect(settings.translationPair(preferred: ["xx-YY"], available: available).target.tag == "en-US")
    }

    /// The first tap turns it on with that pair and saves it, so a restart (or the app, reading
    /// what the keyboard wrote) translates the same way, even after the iPhone's language changes.
    @Test func turningItOnSavesThePairForTheNextLaunch() throws {
        let (settings, relaunch, cleanup) = try store()
        defer { cleanup() }
        let pair = settings.setTranslationEnabled(true, preferred: ["ru-RU"], available: available)
        #expect(pair.target.tag == "ru-RU")
        #expect(settings.translationTargetLanguage == "ru-RU")

        let next = relaunch()
        #expect(next.translationEnabled)
        #expect(next.translationTarget(preferred: ["de-DE"], available: available)?.tag == "ru-RU")
    }

    /// Off: no dictation is translated, whatever is saved, and the pair stays for the next tap.
    @Test func turningItOffKeepsThePairAndTranslatesNothing() throws {
        let (settings, relaunch, cleanup) = try store()
        defer { cleanup() }
        pickRussianToEnglish(settings)
        settings.setTranslationEnabled(true, available: available)
        #expect(settings.translationTarget(available: available)?.tag == "en-US")

        let pair = settings.setTranslationEnabled(false, available: available)
        #expect(pair == TranslationPair(source: DictationLanguage(tag: "ru-RU"), target: DictationLanguage(tag: "en-US")))
        #expect(settings.translationTarget(available: available) == nil)
        #expect(relaunch().translationTarget(available: available) == nil, "still off after a restart")
        #expect(relaunch().translationTargetLanguage == "en-US", "the pair is kept")

        settings.setTranslationEnabled(true, available: available)
        #expect(settings.translationTarget(available: available)?.tag == "en-US", "back on with the same pair")
    }

    /// A pair changed in the ☰ menu replaces the old one, and the switch goes on using it.
    @Test func aChangedPairIsTheOneTheSwitchUses() throws {
        let (settings, relaunch, cleanup) = try store()
        defer { cleanup() }
        pickRussianToEnglish(settings)
        settings.setTranslationEnabled(true, available: available)
        settings.translationTargetLanguage = "tr-TR"
        #expect(settings.translationTarget(available: available)?.tag == "tr-TR")
        settings.setTranslationEnabled(false, available: available)
        settings.translationSourceLanguage = "uk-UA"
        let pair = settings.setTranslationEnabled(true, available: available)
        #expect(pair.source.tag == "uk-UA" && pair.target.tag == "tr-TR")
        #expect(relaunch().translationPair(available: available).shortTitle == "UK → TR")
    }

    /// Never a pair that can't work: a saved "To" that is the source, or a language Murmur can't
    /// translate into (a tag from an older build), is replaced as the switch goes on.
    @Test func anUnusableSavedTargetIsReplacedWhenItGoesOn() throws {
        let (settings, _, cleanup) = try store()
        defer { cleanup() }
        settings.autoDetectDefaultApplied = true
        settings.translationSourceLanguage = "ru-RU"
        settings.translationTargetLanguage = "ru-RU"
        var pair = settings.setTranslationEnabled(true, preferred: ["ru-RU"], available: available)
        #expect(pair.target.tag == "en-US")
        #expect(settings.translationTargetLanguage == "en-US")

        settings.translationTargetLanguage = "xx-YY"
        #expect(settings.translationTarget(preferred: ["de-DE"], available: available)?.tag == "de-DE")
        pair = settings.setTranslationEnabled(true, preferred: ["de-DE"], available: available)
        #expect(pair.target.tag == "de-DE")
        #expect(settings.translationTargetLanguage == "de-DE")
    }

    /// Taps in quick succession: each one lands, the last one wins, and the pair never moves.
    @Test func rapidTapsEndOnTheLastOne() throws {
        let (settings, relaunch, cleanup) = try store()
        defer { cleanup() }
        pickRussianToEnglish(settings)
        var on = false
        for _ in 0..<101 {
            on.toggle()
            settings.setTranslationEnabled(on, available: available)
            #expect(settings.translationEnabled == on)
            #expect((settings.translationTarget(available: available) != nil) == on)
        }
        #expect(relaunch().translationEnabled)
        #expect(relaunch().translationPair(available: available).shortTitle == "RU → EN")
    }

    /// The menus never offer, and the defaults never pick, a language Murmur can't translate into.
    @Test func recentLanguagesMurmurCantTranslateIntoArePassedOver() {
        let target = KeyboardLanguageDefaults.target(
            saved: nil, source: DictationLanguage(tag: "en-US"), preferred: ["en-US"], available: available,
            recent: ["xx-YY", "tr-TR"].map(DictationLanguage.init(tag:)))
        #expect(target.tag == "tr-TR")
    }

    /// An alias of a listed language (Apple's "fil" for Murmur's "tl") is still a usable "To".
    @Test func anAliasOfAListedLanguageIsKept() {
        let target = KeyboardLanguageDefaults.target(
            saved: DictationLanguage(tag: "fil-PH"), source: .automatic, preferred: ["en-US"],
            available: DictationLanguage.translationLanguages, recent: [])
        #expect(target.tag == "fil-PH")
    }
}
