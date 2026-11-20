import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Which on-device models a cloud session counts on before it has looked at them: whether a
/// dictation can be promised its words, and which language's model is looked at first.
struct FallbackLanguagesTests {
    private let automatic = DictationLanguage.automatic

    /// A dictation in a language is promised its words when the iPhone holds a verified model for
    /// that language, whatever its region.
    @Test func aPinnedLanguageCountsOnItsOwnModel() {
        #expect(SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "ru-RU"), verified: ["ru-RU"], guesses: []))
        #expect(SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "en-US"), verified: ["en-GB", "ru-RU"], guesses: []))
        #expect(!SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "de-DE"), verified: ["en-GB", "ru-RU"], guesses: ["de-DE"]))
        #expect(!SessionController.expectsOnDeviceModel(
            for: DictationLanguage(tag: "ru-RU"), verified: [], guesses: ["ru-RU"]))
    }

    /// Under Auto-detect the phone listens in a guess: any guess with a verified model will do.
    @Test func autoDetectCountsOnAModelForAnyGuess() {
        #expect(SessionController.expectsOnDeviceModel(for: automatic, verified: ["ru-RU"], guesses: ["en", "ru"]))
        #expect(SessionController.expectsOnDeviceModel(for: automatic, verified: ["en-US"], guesses: ["en-GB"]))
        #expect(!SessionController.expectsOnDeviceModel(for: automatic, verified: ["ru-RU"], guesses: ["en-US", "de"]))
        #expect(!SessionController.expectsOnDeviceModel(for: automatic, verified: ["ru-RU"], guesses: []))
        #expect(!SessionController.expectsOnDeviceModel(for: automatic, verified: [], guesses: ["ru-RU"]))
    }

    /// The model of the language the next dictation is most likely in is looked at first, so the
    /// fallback is prepared for it before the other language is even checked.
    @Test func theLikelyLanguageIsLookedAtFirst() {
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "ru-RU", likely: "ru")
            == ["ru-RU", "en-US"])
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "ru-RU", likely: "en")
            == ["en-US", "ru-RU"])
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "ru-RU", likely: nil)
            == ["en-US", "ru-RU"])
        // A language neither of them is in changes nothing.
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "ru-RU", likely: "de")
            == ["en-US", "ru-RU"])
    }

    @Test func thereIsOneCandidateWithoutASecondLanguage() {
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: nil, likely: "ru") == ["en-US"])
        #expect(SessionController.fallbackCandidates(primary: "en-US", secondary: "en-US", likely: nil) == ["en-US"])
        #expect(SessionController.fallbackCandidates(primary: "und", secondary: "ru-RU", likely: nil) == ["ru-RU"])
    }
}
