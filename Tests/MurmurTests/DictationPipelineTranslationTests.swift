@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class TranslationCleanup: Cleaning {
    var isConfigured = true
    var failure: CleanupClient.Failure?
    private(set) var receivedTarget: String?

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?,
        style: StylePreset, dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        receivedTarget = targetLanguage
        if let failure { throw failure }
        return CleanupClient.Response(
            text: "Raporu cuma gününe kadar gönderebilir misin?", status: "cleaned", words: 7,
            model: "test", ttftMs: 10, totalMs: 20, remaining: nil)
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
}
