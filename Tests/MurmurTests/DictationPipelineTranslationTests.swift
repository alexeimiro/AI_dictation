@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class TranslationCleanup: Cleaning {
    var isConfigured = true
    var failure: CleanupClient.Failure?
    var text = "Raporu cuma gününe kadar gönderebilir misin?"
    var status = "cleaned"
    var reason: String?
    /// The current cleanup function echoes the target language; one deployed before translation
    /// ignores it and doesn't.
    var echoesTarget = true
    private(set) var receivedTarget: String?

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?,
        style: StylePreset, dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        receivedTarget = targetLanguage
        if let failure { throw failure }
        return CleanupClient.Response(
            text: text, status: status, words: 7, model: "test", ttftMs: 10, totalMs: 20, remaining: nil,
            reason: reason, targetLanguage: echoesTarget ? targetLanguage : nil)
    }
}

private final class FinishedTranscriber: Transcriber, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { "можешь скинуть отчёт до пятницы" }
    func cancelUtterance() async {}
    func shutdown() async {}
}

@MainActor
struct DictationPipelineTranslationTests {
    @Test func translationUsesTargetForInsertionAndSourceForHistory() async {
        let cleanup = TranslationCleanup()
        let pipeline = DictationPipeline(cleanup: cleanup)
        let requestID = UUID()
        let dictation = ActiveDictation(
            requestId: requestID, documentIdentifier: nil, style: .formal, language: "ru-RU",
            translationTargetLanguage: "tr-TR", source: .keyboard, startedAt: Date())

        let outcome = await pipeline.complete(
            dictation, transcriber: FinishedTranscriber(), audioSeconds: 2,
            stoppedAt: ContinuousClock.now)

        #expect(cleanup.receivedTarget == "tr-TR")
        #expect(outcome.result.status == .cleaned)
        #expect(outcome.result.language == "tr-TR")
        #expect(outcome.result.text == "Raporu cuma gününe kadar gönderebilir misin?")
        #expect(outcome.transcript.language == "ru-RU")
        #expect(outcome.transcript.rawText == "можешь скинуть отчёт до пятницы")
    }

    @Test func translationNeverInsertsUntranslatedFallbackText() async {
        let cleanup = TranslationCleanup()
        cleanup.failure = .unavailable("offline")
        let pipeline = DictationPipeline(cleanup: cleanup)
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .casual, language: "ru-RU",
            translationTargetLanguage: "tr-TR", source: .keyboard, startedAt: Date())

        let outcome = await pipeline.complete(
            dictation, transcriber: FinishedTranscriber(), audioSeconds: 2,
            stoppedAt: ContinuousClock.now)

        #expect(outcome.result.status == .failed)
        #expect(outcome.result.text.isEmpty)
        #expect(outcome.result.message?.contains("Couldn't translate") == true)
    }

    /// The reported bug: translation on, yet the text came in the spoken language. A cleanup
    /// function deployed before translation ignores the target and answers "cleaned" in Russian.
    @Test func cleanupFromAServerThatIgnoresTheTargetIsNeverInserted() async {
        let cleanup = TranslationCleanup()
        cleanup.echoesTarget = false
        cleanup.text = "Можешь скинуть отчёт до пятницы?"

        let (result, transcript) = await translate(with: cleanup)

        #expect(result.status == .failed)
        #expect(result.text.isEmpty)
        #expect(result.message == "Translation isn't available right now. Please try again later.")
        #expect(transcript.errorReason?.contains("Deploy the latest cleanup function") == true)
        #expect(transcript.rawText == "можешь скинуть отчёт до пятницы")
    }

    @Test func untranslatedReplyIsNotInsertedAndNotBlamedOnTheConnection() async {
        let cleanup = TranslationCleanup()
        cleanup.status = "raw"
        cleanup.reason = "untranslated"
        cleanup.text = "можешь скинуть отчёт до пятницы"

        let (result, transcript) = await translate(with: cleanup)

        #expect(result.status == .failed)
        #expect(result.text.isEmpty)
        #expect(result.message == "Couldn't translate that. Please try again.")
        #expect(transcript.errorReason == "The translation came back in the spoken language.")
    }

    /// Only a translation needs the echo; an ordinary cleanup never had one.
    @Test func cleanupNeedsNoTranslationEcho() async throws {
        let cleanup = TranslationCleanup()
        cleanup.echoesTarget = false
        cleanup.text = "Можешь скинуть отчёт до пятницы?"
        let pipeline = DictationPipeline(cleanup: cleanup)
        let stored = Transcript(language: "ru-RU", rawText: "можешь скинуть отчёт до пятницы", status: .raw)

        let updated = try await pipeline.recleanup(stored)

        #expect(cleanup.receivedTarget == nil)
        #expect(updated.status == .cleaned)
        #expect(updated.cleanedText == "Можешь скинуть отчёт до пятницы?")
    }

    /// A Russian → Turkish keyboard dictation through `cleanup`. Returns the result's parts, since
    /// `DictationOutcome` names both the pipeline's outcome and MurmurCore's keyboard enum here.
    private func translate(with cleanup: TranslationCleanup) async -> (DictationResult, Transcript) {
        let pipeline = DictationPipeline(cleanup: cleanup)
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .casual, language: "ru-RU",
            translationTargetLanguage: "tr-TR", source: .keyboard, startedAt: Date())
        let outcome = await pipeline.complete(
            dictation, transcriber: FinishedTranscriber(), audioSeconds: 2,
            stoppedAt: ContinuousClock.now)
        return (outcome.result, outcome.transcript)
    }
}
