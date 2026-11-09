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
    private(set) var calls = 0

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?,
        style: StylePreset, dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        calls += 1
        receivedTarget = targetLanguage
        return try reply(to: targetLanguage).get()
    }

    /// What it answers for `target`, as a result: what `dictate` would have answered with the transcript.
    func reply(to target: String?) -> Result<CleanupClient.Response, CleanupClient.Failure> {
        if let failure { return .failure(failure) }
        return .success(CleanupClient.Response(
            text: text, status: status, words: 7, model: "test", ttftMs: 10, totalMs: 20, remaining: nil,
            reason: reason, targetLanguage: echoesTarget ? target : nil))
    }
}

private final class FinishedTranscriber: Transcriber, UtteranceTimingProviding, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?
    /// Set: translates in the request that transcribes, answering this.
    var translation: Result<CleanupClient.Response, CleanupClient.Failure>?
    var timings: UtteranceTimings?
    private(set) var translationRequest: ModelRequest?

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { "можешь скинуть отчёт до пятницы" }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        translationRequest = request
        return UtteranceOutput(transcript: try await finishUtterance(), modelReply: translation)
    }
    func cancelUtterance() async {}
    func abandonUtterance() {}
    func shutdown() async {}
    func takeTimings() -> UtteranceTimings? { timings }
}

/// The cleanup's answers a translation can get, to give through `cleanup` and through `dictate`.
enum TranslationAnswer: CaseIterable, Sendable {
    case translated, untranslated, unusable, ignoredTarget, unavailable, limitReached, signedOut

    @MainActor
    fileprivate func configure(_ cleanup: TranslationCleanup) {
        switch self {
        case .translated: break
        case .untranslated:
            cleanup.status = "raw"
            cleanup.reason = "untranslated"
        case .unusable:
            cleanup.status = "raw"
            cleanup.reason = "transcript_too_long"
        case .ignoredTarget:
            cleanup.echoesTarget = false
            cleanup.text = "Можешь скинуть отчёт до пятницы?"
        case .unavailable: cleanup.failure = .unavailable("dictate couldn't translate (deadline)")
        case .limitReached: cleanup.failure = .limitReached
        case .signedOut: cleanup.failure = .signedOut
        }
    }
}

@MainActor
struct DictationPipelineTranslationTests {
    @Test func translationUsesTargetForInsertionAndSourceForHistory() async {
        let cleanup = TranslationCleanup()
        let pipeline = DictationPipeline(cleanup: cleanup)
        let requestID = UUID()
        let dictation = ActiveDictation(
            requestId: requestID, documentIdentifier: nil, style: .grammar, language: "ru-RU",
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
            requestId: UUID(), documentIdentifier: nil, style: .verbatim, language: "ru-RU",
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

    /// Whatever `dictate` answers, the keyboard and the history get what two requests would give them.
    @Test(arguments: TranslationAnswer.allCases)
    func oneRequestComesToWhatTwoDo(_ answer: TranslationAnswer) async {
        let twoCalls = TranslationCleanup()
        answer.configure(twoCalls)
        let (expected, expectedTranscript) = await translate(with: twoCalls)

        // Only a translation `dictate` couldn't finish is tried again, through `cleanup`, which
        // answers as it did for two requests.
        let retry = TranslationCleanup()
        answer.configure(retry)
        let transcriber = FinishedTranscriber()
        transcriber.translation = twoCalls.reply(to: "tr-TR")
        let (result, transcript) = await translate(with: retry, transcriber: transcriber)

        #expect(retry.calls == (answer == .unavailable ? 1 : 0))
        #expect(result.status == expected.status)
        #expect(result.text == expected.text)
        #expect(result.message == expected.message)
        #expect(result.language == expected.language)
        #expect(transcript.rawText == expectedTranscript.rawText)
        #expect(transcript.errorReason == expectedTranscript.errorReason)
        #expect(transcript.cleanedText == expectedTranscript.cleanedText)
    }

    /// The request names the dictation, so `dictate` counts its usage once, and asks for its style.
    @Test func oneRequestCarriesTheDictationsTranslation() async {
        let transcriber = FinishedTranscriber()
        transcriber.translation = TranslationCleanup().reply(to: "tr-TR")
        let pipeline = DictationPipeline(cleanup: TranslationCleanup())
        let requestID = UUID()
        let dictation = ActiveDictation(
            requestId: requestID, documentIdentifier: nil, style: .grammar, language: "ru-RU",
            translationTargetLanguage: "tr-TR", source: .keyboard, startedAt: Date())

        _ = await pipeline.complete(dictation, transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)

        #expect(transcriber.translationRequest?.dictationId == requestID)
        #expect(transcriber.translationRequest?.targetLanguage == "tr-TR")
        #expect(transcriber.translationRequest?.style == .grammar)
    }

    /// Out of time or a model error in `dictate`: the transcript is translated through `cleanup`
    /// instead of the keyboard saying "Couldn't translate that".
    @Test func aTranslationDictateCouldntFinishIsRetriedThroughCleanup() async {
        let cleanup = TranslationCleanup()
        let transcriber = FinishedTranscriber()
        transcriber.translation = .failure(.unavailable("dictate couldn't write the text (deadline)"))

        let (result, _) = await translate(with: cleanup, transcriber: transcriber)

        #expect(cleanup.calls == 1)
        #expect(cleanup.receivedTarget == "tr-TR")
        #expect(result.status == .cleaned)
        #expect(result.text == "Raporu cuma gününe kadar gönderebilir misin?")
    }

    /// The fallback's transcript, or `transcribe`'s when `dictate` isn't there, still gets translated.
    @Test func aTranscriptWithoutItsTranslationIsTranslatedByCleanup() async {
        let cleanup = TranslationCleanup()

        let (result, _) = await translate(with: cleanup)

        #expect(cleanup.calls == 1)
        #expect(result.status == .cleaned)
    }

    /// The model's share of the one request is the cleanup's, and only the rest is recognition.
    @Test func oneRequestsTimingsSplitAtTheModel() async throws {
        let transcriber = FinishedTranscriber()
        transcriber.translation = TranslationCleanup().reply(to: "tr-TR")
        transcriber.timings = UtteranceTimings(
            encodeMs: 30, audioBytes: 20_000,
            requests: [RequestTiming(function: "dictate", status: 200, totalMs: 1_900,
                                     server: ServerTiming(transcribeMs: 800, modelMs: 700))],
            cloudTranscript: true)
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .verbatim, language: "ru-RU",
            translationTargetLanguage: "tr-TR", source: .keyboard, startedAt: Date())

        let outcome = await DictationPipeline(cleanup: TranslationCleanup()).complete(
            dictation, transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)

        #expect(outcome.transcript.metrics.cleanupMs == 700)
        #expect(outcome.transcript.metrics.ttftMs == 10)
        #expect(outcome.transcript.cleanupModel == "test")
        let timings = try #require(outcome.timings)
        #expect(timings.requests.map(\.function) == ["dictate"])
        #expect(timings.cloudTranscript == true)
    }

    /// A Russian → Turkish keyboard dictation through `cleanup`, or through `transcriber`'s own
    /// translation when it has one. Returns the result's parts, since `DictationOutcome` names
    /// both the pipeline's outcome and MurmurCore's keyboard enum here.
    private func translate(with cleanup: TranslationCleanup,
                           transcriber: FinishedTranscriber = FinishedTranscriber()) async -> (DictationResult, Transcript) {
        let pipeline = DictationPipeline(cleanup: cleanup)
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .verbatim, language: "ru-RU",
            translationTargetLanguage: "tr-TR", source: .keyboard, startedAt: Date())
        let outcome = await pipeline.complete(
            dictation, transcriber: transcriber, audioSeconds: 2,
            stoppedAt: ContinuousClock.now)
        return (outcome.result, outcome.transcript)
    }
}
