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
    /// The dictation the pipeline named, for the server to count its words under.
    private(set) var dictationId: UUID?

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
    func finishUtterance(model request: ModelRequest?, dictationId: UUID) async throws -> UtteranceOutput {
        self.dictationId = dictationId
        return try await finishUtterance(model: request)
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

    /// Word for word has no model request to carry the dictation's id, so the pipeline names it:
    /// the server counts the free plan's words under that id, whichever requests the dictation takes.
    @Test func everyDictationIsNamedToTheTranscriber() async {
        for style in [StylePreset.verbatim, .grammar] {
            let transcriber = CloudLikeTranscriber(UtteranceOutput(transcript: "See you at five."))
            let spoken = dictation(style: style)
            _ = await DictationPipeline(cleanup: StyleCleanup()).complete(
                spoken, transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)
            #expect(transcriber.dictationId == spoken.requestId, "\(style)")
        }
    }

    /// Word for word and the styles the model writes go through the same function, so the timings
    /// log is told the style: the requests alone no longer say which is which.
    @Test func theTimingsNameTheDictationsStyle() async {
        for style in StylePreset.allCases {
            let transcriber = CloudLikeTranscriber(UtteranceOutput(transcript: "See you at five."))
            let outcome = await DictationPipeline(cleanup: StyleCleanup()).complete(
                dictation(style: style), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)
            #expect(outcome.timings?.style == style.rawValue, "\(style)")
        }
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

    /// Three words or fewer never reach the model, whatever the mode. Casual still writes them
    /// its own way: lowercase, with no full stop.
    @Test func shortRepliesSkipTheModel() async {
        for style in StylePreset.allCases {
            let cleanup = StyleCleanup()
            let (result, _) = await dictate("Sounds good.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == nil, "\(style)")
            #expect(result.text == (style == .casual ? "sounds good" : "Sounds good."), "\(style)")
        }
    }

    /// Professional, Casual and Concise are written by the model in the request that transcribes,
    /// as Improve my grammar is.
    @Test func everyStyleTheModelWritesIsWrittenInTheTranscribingRequest() async throws {
        for style in StylePreset.allCases where style.usesModel {
            let cleanup = StyleCleanup()
            let transcriber = CloudLikeTranscriber(UtteranceOutput(
                transcript: "hey guys so I'm gonna need the report by Friday",
                modelReply: .success(CleanupClient.Response(
                    text: "I will need the report by Friday.", status: "cleaned", words: 7, model: "test", ttftMs: nil,
                    totalMs: 400, remaining: nil))))
            let dictation = ActiveDictation(
                requestId: UUID(), documentIdentifier: nil, style: style, language: "en-US",
                translationTargetLanguage: nil, source: .keyboard, startedAt: Date())

            let outcome = await DictationPipeline(cleanup: cleanup).complete(
                dictation, transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)

            #expect(cleanup.receivedStyle == nil, "\(style): no second request")
            let request = try #require(transcriber.request, "\(style)")
            #expect(request.style == style && request.targetLanguage == nil, "\(style)")
            #expect(outcome.result.status == .cleaned, "\(style)")
            #expect(outcome.transcript.style == style, "\(style)")
            // The model's text goes in as it came; Casual only loses a last full stop the model left.
            #expect(outcome.result.text == (style == .casual ? "I will need the report by Friday" : "I will need the report by Friday."),
                    "\(style)")
        }
    }

    /// Without `dictate` (on-device recognition, or the function switched off) the same styles go
    /// through `cleanup`, with their own name.
    @Test func everyStyleTheModelWritesAsksCleanupWhenTheTranscriptCameAlone() async {
        for style in StylePreset.allCases where style.usesModel {
            let cleanup = StyleCleanup()
            cleanup.text = "I will need the report by Friday."
            let (result, _) = await dictate("Hey guys, so I'm gonna need the report by Friday.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == style, "\(style)")
            #expect(result.status == .cleaned, "\(style)")
        }
    }

    /// A Casual dictation whose model step failed still goes in lowercase, with no full stop.
    @Test func casualFallsBackToItsLocalForm() async {
        let transcriber = CloudLikeTranscriber(UtteranceOutput(
            transcript: "Sounds good. See you at the office tomorrow.",
            modelReply: .failure(.unavailable("dictate couldn't write the text (deadline)"))))
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .casual, language: "en-US",
            translationTargetLanguage: nil, source: .keyboard, startedAt: Date())
        let outcome = await DictationPipeline(cleanup: StyleCleanup()).complete(
            dictation, transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)
        #expect(outcome.result.text == "sounds good. see you at the office tomorrow")
        #expect(outcome.result.status == .raw)
    }

    /// "um" is a word in German: Word for word must not drop it as a hesitation.
    @Test func wordForWordKeepsGermanUm() async {
        let cleanup = StyleCleanup()
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .verbatim, language: "de-DE",
            translationTargetLanguage: nil, source: .keyboard, startedAt: Date())
        let outcome = await DictationPipeline(cleanup: cleanup).complete(
            dictation, transcriber: SpokenTranscriber("Wir treffen uns um acht Uhr."), audioSeconds: 2,
            stoppedAt: ContinuousClock.now)
        #expect(cleanup.receivedStyle == nil)
        #expect(outcome.result.text == "Wir treffen uns um acht Uhr.")
    }

    /// Nothing but a hesitation: nothing is inserted, and the keyboard says so instead of typing ".".
    @Test func aDictationOfHesitationsAloneInsertsNothing() async {
        for style in StylePreset.allCases {
            let cleanup = StyleCleanup()
            let (result, transcript) = await dictate("Hmm.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == nil, "\(style)")
            #expect(result.text.isEmpty && result.status == .empty, "\(style)")
            #expect(result.message == "We didn't catch anything. Please try speaking again.", "\(style)")
            #expect(transcript.rawText == "Hmm.", "\(style)")
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
