import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Which on-device models a cloud session counts on before it has looked at them: whether a
/// dictation can be promised its words, and which language's model is looked at first.
struct FallbackLanguagesTests {
    private let automatic = DictationLanguage.automatic

    /// A dictation in a language is promised its words when the iPhone holds a verified model for
    /// that language, whatever its region: the session looks at a pinned language's model.
    @Test func aPinnedLanguageCountsOnItsOwnModel() {
        #expect(SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "ru-RU"), verified: ["ru-RU"], looked: ["en-US"], guesses: []))
        #expect(SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "en-US"), verified: ["en-GB", "ru-RU"], looked: [], guesses: []))
        #expect(!SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "de-DE"), verified: ["en-GB", "ru-RU"], looked: ["de-DE"], guesses: ["de-DE"]))
        #expect(!SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "ru-RU"), verified: [], looked: ["ru-RU"], guesses: ["ru-RU"]))
    }

    /// Under Auto-detect the phone listens in a guess: any guess with a verified model the
    /// session looks at will do.
    @Test func autoDetectCountsOnAModelForAnyGuess() {
        #expect(SessionController.expectsOnDeviceModel(
            for: automatic, verified: ["ru-RU"], looked: ["en-US", "ru-RU"], guesses: ["en", "ru"]))
        #expect(SessionController.expectsOnDeviceModel(
            for: automatic, verified: ["en-US"], looked: ["en-GB"], guesses: ["en-GB"]))
        #expect(!SessionController.expectsOnDeviceModel(
            for: automatic, verified: ["ru-RU"], looked: ["en-US", "ru-RU"], guesses: ["en-US", "de"]))
        #expect(!SessionController.expectsOnDeviceModel(
            for: automatic, verified: ["ru-RU"], looked: ["ru-RU"], guesses: []))
        #expect(!SessionController.expectsOnDeviceModel(
            for: automatic, verified: [], looked: ["ru-RU"], guesses: ["ru-RU"]))
    }

    /// A verified model of a language that is no longer primary, secondary or picked is not
    /// looked at under Auto-detect, so nothing is promised on it.
    @Test func nothingIsPromisedOnAModelTheSessionWillNotLookAt() {
        #expect(!SessionController.expectsOnDeviceModel(
            for: automatic, verified: ["ru-RU"], looked: ["en-US"], guesses: ["ru-RU", "en-US"]))
        #expect(SessionController.expectsOnDeviceModel(
            for: automatic, verified: ["ru-RU", "en-US"], looked: ["en-US"], guesses: ["ru-RU", "en-US"]))
    }

    /// The model of the language the next dictation is most likely in is looked at first, so the
    /// fallback is prepared for it before the other language is even checked.
    @Test func theLikelyLanguageIsLookedAtFirst() {
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "ru-RU", likely: ["ru"])
            == ["ru-RU", "en-US"])
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "ru-RU", likely: ["en"])
            == ["en-US", "ru-RU"])
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "ru-RU", likely: [])
            == ["en-US", "ru-RU"])
    }

    /// Under Auto-detect the candidates come in the order the guess is made in: the last language
    /// detected, the ones picked, the iPhone's, the primary. The first one found is then the
    /// guess, and no later one changes it.
    @Test func theCandidatesComeInTheOrderOfTheGuess() {
        #expect(SessionController.fallbackCandidates(
            primary: "en-US", secondary: nil, picked: ["ru-RU", "en-GB"], likely: ["ru-RU", "en-GB", "en-US"])
            == ["ru-RU", "en-US"])
        #expect(SessionController.fallbackCandidates(
            primary: "en-US", secondary: "ru-RU", picked: ["de-DE", "fr-FR"], likely: ["de", "ru-RU", "en-US"])
            == ["de-DE", "ru-RU", "en-US"])
        // A guess the session holds no candidate for (the last language detected, never picked)
        // changes nothing.
        #expect(SessionController.fallbackCandidates(
            primary: "en-US", secondary: "ru-RU", likely: ["und", "es-ES", "ru"]) == ["ru-RU", "en-US"])
    }

    /// The language the keyboard is pinned to is looked at first, whatever the guesses say, and
    /// also when it is none of the session's own: its model may be on the iPhone from when it
    /// was one of them.
    @Test func aPinnedLanguageLeadsAndIsACandidateItself() {
        #expect(SessionController.fallbackCandidates(
            primary: "en-US", secondary: "ru-RU", pinned: "de-DE", likely: ["ru-RU"]) == ["de-DE", "en-US", "ru-RU"])
        #expect(SessionController.fallbackCandidates(
            primary: "en-US", secondary: "ru-RU", pinned: "ru-RU", likely: ["en-US"]) == ["ru-RU", "en-US"])
        // The British model serves a keyboard pinned to US English: no candidate of its own.
        #expect(SessionController.fallbackCandidates(
            primary: "en-GB", secondary: nil, pinned: "en-US", likely: []) == ["en-GB"])
        // Auto-detect is no language to pin.
        #expect(SessionController.fallbackCandidates(
            primary: "en-US", secondary: "ru-RU", pinned: "und", likely: ["ru"]) == ["ru-RU", "en-US"])
    }

    @Test func thereIsOneCandidateWithoutASecondLanguage() {
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: nil, likely: ["ru"]) == ["en-US"])
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "en-US", likely: []) == ["en-US"])
        #expect(SessionController.fallbackCandidates(primary: "und", secondary: "ru-RU", likely: []) == ["ru-RU"])
    }

    /// Onboarding confirms a language that was the default all along: it is still set, and its
    /// model brought, unless both are already so.
    @Test func aLanguageIsPreparedUnlessItIsChosenAndReady() async {
        #expect(await LanguageSettingsModel.needsPreparing(chosen: false, isReady: { true }))
        #expect(await LanguageSettingsModel.needsPreparing(chosen: false, isReady: { false }))
        #expect(await LanguageSettingsModel.needsPreparing(chosen: true, isReady: { false }))
        #expect(!(await LanguageSettingsModel.needsPreparing(chosen: true, isReady: { true })))
    }
}
