@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class StyleCleanup: Cleaning {
    var isConfigured = true
    var text = "Sounds good."
    /// Nil while the model was never asked.
    private(set) var receivedStyle: StylePreset?
    private(set) var receivedLanguage: String?

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?,
        style: StylePreset, dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        receivedStyle = style
        receivedLanguage = language
        return CleanupClient.Response(
            text: text, status: "cleaned", words: 2, model: "test", ttftMs: 10, totalMs: 20, remaining: nil)
    }
}

private final class SpokenTranscriber: Transcriber, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?
    private let transcript: String

    init(_ transcript: String) {
        self.transcript = transcript
    }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { transcript }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        UtteranceOutput(transcript: try await finishUtterance())
    }
    func cancelUtterance() async {}
    func abandonUtterance() {}
    func shutdown() async {}
}

/// Answers as the cloud does: a transcript, under Auto-detect the language it was in, and the
/// model's text when it was written in the same request (`dictate`).
private final class CloudLikeTranscriber: Transcriber, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?
    private let output: UtteranceOutput
    private(set) var request: ModelRequest?

    init(_ output: UtteranceOutput) {
        self.output = output
    }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { output.transcript }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        self.request = request
        return output
    }
    func cancelUtterance() async {}
    func abandonUtterance() {}
    func shutdown() async {}
}

@MainActor
struct DictationPipelineLanguageTests {
    /// Auto-detect: the dictation is formatted, cleaned up, inserted and filed in the language
    /// OpenAI heard, and the fallback guesses it next time.
    @Test func theDetectedLanguageReachesTheCleanupTheResultAndHistory() async {
        let suite = "test.murmur.pipeline.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: UserDefaults(suiteName: suite))
        let cleanup = StyleCleanup()
        cleanup.text = "Yarın toplantıya gelemiyorum, çünkü hastayım."
        let transcriber = CloudLikeTranscriber(UtteranceOutput(
            transcript: "yarın toplantıya gelemiyorum çünkü hastayım", detectedLanguage: "tr"))

        let outcome = await DictationPipeline(cleanup: cleanup, settings: settings).complete(
            dictation(style: .grammar, language: "und"), transcriber: transcriber, audioSeconds: 2,
            stoppedAt: ContinuousClock.now)

        #expect(cleanup.receivedLanguage == "tr")
        #expect(outcome.result.language == "tr")
        #expect(outcome.transcript.language == "tr")
        #expect(settings.lastDetectedLanguage == "tr")
    }

    /// Improve my grammar asks `dictate` to write it in the request that transcribes.
    @Test func aGrammarDictationIsWrittenInTheTranscribingRequest() async throws {
        let cleanup = StyleCleanup()
        let transcriber = CloudLikeTranscriber(UtteranceOutput(
            transcript: "me and him was going to the store",
            modelReply: .success(CleanupClient.Response(
                text: "He and I were going to the store.", status: "cleaned", words: 8, model: "test", ttftMs: nil,
                totalMs: 400, remaining: nil))))

        let outcome = await DictationPipeline(cleanup: cleanup).complete(
            dictation(style: .grammar), transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)

        #expect(cleanup.receivedStyle == nil, "no second request")
        #expect(outcome.result.text == "He and I were going to the store.")
        let request = try #require(transcriber.request)
        #expect(request.style == .grammar)
        #expect(request.targetLanguage == nil)
    }

    /// `dictate` leaves three words or fewer as they were: the local text goes in, and nothing failed.
    @Test func aShortGrammarDictationKeepsItsLocalText() async {
        let transcriber = CloudLikeTranscriber(UtteranceOutput(
            transcript: "sounds good",
            modelReply: .success(CleanupClient.Response(
                text: "", status: "raw", words: 2, model: nil, ttftMs: nil, totalMs: 0, remaining: nil, reason: "short"))))

        let outcome = await DictationPipeline(cleanup: StyleCleanup()).complete(
            dictation(style: .grammar), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

        #expect(outcome.result.text == "Sounds good")
        #expect(outcome.result.status == .raw)
        #expect(outcome.transcript.errorReason == nil)
    }

    @Test func wordForWordAsksForTheTranscriptAlone() async {
        let transcriber = CloudLikeTranscriber(UtteranceOutput(transcript: "See you at five."))
        _ = await DictationPipeline(cleanup: StyleCleanup()).complete(
            dictation(style: .verbatim), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)
        #expect(transcriber.request == nil)
    }

    private func dictation(style: StylePreset, language: String = "en-US") -> ActiveDictation {
        ActiveDictation(requestId: UUID(), documentIdentifier: nil, style: style, language: language,
                        translationTargetLanguage: nil, source: .keyboard, startedAt: Date())
    }
}

@MainActor
struct DictationPipelineStyleTests {
    /// Word for word keeps hedges and self-corrections, so a punctuated transcript goes in as the
    /// recognizer wrote it, minus sound fillers, with no model call.
    @Test func wordForWordSkipsTheModelForAPunctuatedTranscript() async {
        let cleanup = StyleCleanup()
        let (result, transcript) = await dictate(
            "So, um, I think, actually, we should go tomorrow.", style: .verbatim, cleanup: cleanup)
        #expect(cleanup.receivedStyle == nil)
        #expect(result.text == "So, I think, actually, we should go tomorrow.")
        #expect(transcript.style == .verbatim)
    }

    @Test func wordForWordAsksTheModelForASpokenCommand() async {
        let cleanup = StyleCleanup()
        cleanup.text = "Send it today, please."
        let (result, _) = await dictate("Send it today comma please.", style: .verbatim, cleanup: cleanup)
        #expect(cleanup.receivedStyle == .verbatim)
        #expect(result.text == "Send it today, please.")
    }

    /// The model's text goes in exactly as it came back: neither mode restyles it.
    @Test func grammarAlwaysAsksTheModel() async {
        let cleanup = StyleCleanup()
        cleanup.text = "He and I were going to the store."
        let (result, transcript) = await dictate("Me and him was going to the store.", style: .grammar, cleanup: cleanup)
        #expect(cleanup.receivedStyle == .grammar)
        #expect(result.text == "He and I were going to the store.")
        #expect(transcript.style == .grammar)
    }

    /// Three words or fewer never reach the model, whatever the mode.
    @Test func shortRepliesSkipTheModel() async {
        for style in StylePreset.allCases {
            let cleanup = StyleCleanup()
            let (result, _) = await dictate("Sounds good.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == nil, "\(style)")
            #expect(result.text == "Sounds good.", "\(style)")
        }
    }

    @Test func regenerateUsesTheStoredMode() async throws {
        let cleanup = StyleCleanup()
        let pipeline = DictationPipeline(cleanup: cleanup)
        let stored = Transcript(language: "en-US", style: .grammar, rawText: "sounds good", status: .raw)

        let updated = try await pipeline.recleanup(stored)

        #expect(cleanup.receivedStyle == .grammar)
        #expect(updated.cleanedText == "Sounds good.")
    }

    /// Returns the result's parts, since `DictationOutcome` names both the pipeline's outcome and
    /// MurmurCore's keyboard enum here.
    private func dictate(_ spoken: String, style: StylePreset, cleanup: StyleCleanup)
        async -> (DictationResult, Transcript) {
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: style, language: "en-US",
            translationTargetLanguage: nil, source: .keyboard, startedAt: Date())
        let outcome = await DictationPipeline(cleanup: cleanup).complete(
            dictation, transcriber: SpokenTranscriber(spoken), audioSeconds: 2, stoppedAt: ContinuousClock.now)
        return (outcome.result, outcome.transcript)
    }
}
