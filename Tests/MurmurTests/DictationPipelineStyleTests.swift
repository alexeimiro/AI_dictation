@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class StyleCleanup: Cleaning {
    var isConfigured = true
    var text = "Sounds good."
    /// Runs while the request is in flight: a test changes the settings there.
    var whileWriting: () -> Void = {}
    /// Nil while the model was never asked.
    private(set) var receivedStyle: StylePreset?
    private(set) var receivedLanguage: String?
    private(set) var receivedSnippets: [SnippetDefinition]?

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?,
        style: StylePreset, dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        receivedStyle = style
        receivedLanguage = language
        receivedSnippets = snippets
        whileWriting()
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
            dictation(style: .rewrite, language: "und"), transcriber: transcriber, audioSeconds: 2,
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
            dictation(style: .rewrite), transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)

        #expect(cleanup.receivedStyle == nil, "no second request")
        #expect(outcome.result.text == "He and I were going to the store.")
        let request = try #require(transcriber.request)
        #expect(request.style == .rewrite)
        #expect(request.targetLanguage == nil)
    }

    /// `dictate` leaves three words or fewer as they were: the local text goes in, and nothing failed.
    @Test func aShortGrammarDictationKeepsItsLocalText() async {
        let transcriber = CloudLikeTranscriber(UtteranceOutput(
            transcript: "sounds good",
            modelReply: .success(CleanupClient.Response(
                text: "", status: "raw", words: 2, model: nil, ttftMs: nil, totalMs: 0, remaining: nil, reason: "short"))))

        let outcome = await DictationPipeline(cleanup: StyleCleanup()).complete(
            dictation(style: .rewrite), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

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

    /// Word-to-Word has no model request to carry the dictation's id, so the pipeline names it:
    /// the server counts the free plan's words under that id, whichever requests the dictation takes.
    @Test func everyDictationIsNamedToTheTranscriber() async {
        for style in [StylePreset.verbatim, .rewrite] {
            let transcriber = CloudLikeTranscriber(UtteranceOutput(transcript: "See you at five."))
            let spoken = dictation(style: style)
            _ = await DictationPipeline(cleanup: StyleCleanup()).complete(
                spoken, transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)
            #expect(transcriber.dictationId == spoken.requestId, "\(style)")
        }
    }

    /// Word-to-Word and the styles the model writes go through the same function, so the timings
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
    /// Word-to-Word keeps hedges and self-corrections, so a punctuated transcript goes in as the
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
        let (result, transcript) = await dictate("Me and him was going to the store.", style: .rewrite, cleanup: cleanup)
        #expect(cleanup.receivedStyle == .rewrite)
        #expect(result.text == "He and I were going to the store.")
        #expect(transcript.style == .rewrite)
    }

    /// Three words or fewer never reach the model, whatever the mode: no call is made for them.
    @Test func shortRepliesSkipTheModel() async {
        for style in StylePreset.allCases {
            let cleanup = StyleCleanup()
            let (result, _) = await dictate("Sounds good.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == nil, "\(style)")
            #expect(result.text == "Sounds good.", "\(style)")
        }
    }

    /// Rewrite, Email and Funny are written by the model in the request that transcribes: one
    /// request per dictation, never a second one for the text.
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
            // The model's text goes in exactly as it came.
            #expect(outcome.result.text == "I will need the report by Friday.", "\(style)")
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

    /// A mode whose model step failed (offline, a timeout) still types what was said, tidied on
    /// the iPhone, and keeps the transcript for Retry.
    @Test func aModeWhoseModelStepFailedTypesTheSpeakersWords() async {
        for style in StylePreset.allCases where style.usesModel {
            let transcriber = CloudLikeTranscriber(UtteranceOutput(
                transcript: "Um, sounds good. See you at the office tomorrow.",
                modelReply: .failure(.unavailable("dictate couldn't write the text (deadline)"))))
            let dictation = ActiveDictation(
                requestId: UUID(), documentIdentifier: nil, style: style, language: "en-US",
                translationTargetLanguage: nil, source: .keyboard, startedAt: Date())
            let outcome = await DictationPipeline(cleanup: StyleCleanup()).complete(
                dictation, transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)
            #expect(outcome.result.text == "Sounds good. See you at the office tomorrow.", "\(style)")
            #expect(outcome.result.status == .raw, "\(style)")
            #expect(outcome.transcript.rawText == "Um, sounds good. See you at the office tomorrow.", "\(style)")
            #expect(outcome.transcript.style == style && outcome.transcript.canRegenerate, "\(style)")
        }
    }

    /// What the speaker said is kept beside what the mode wrote, for the transcript's page and
    /// for Regenerate.
    @Test func theTranscriptKeepsWhatWasSaidBesideWhatWasWritten() async {
        let cleanup = StyleCleanup()
        cleanup.text = "Hi Anna,\n\nI'll be ten minutes late.\n\nBest regards,"
        let (result, transcript) = await dictate(
            "tell anna I'll be like ten minutes late", style: .email, cleanup: cleanup)
        #expect(result.text == "Hi Anna,\n\nI'll be ten minutes late.\n\nBest regards,")
        #expect(transcript.rawText == "tell anna I'll be like ten minutes late")
        #expect(transcript.cleanedText == result.text)
    }

    /// Funny's emoji and Email's blank lines go in as the model wrote them.
    @Test func emojiAndBlankLinesGoInAsWritten() async {
        for (style, written) in [(StylePreset.funny, "Pizza night is ON 🍕 — see you at 8!"),
                                 (.email, "Hello,\n\nCould we move the call to Thursday?\n\nThanks,")] {
            let cleanup = StyleCleanup()
            cleanup.text = written
            let (result, _) = await dictate("so we are doing pizza tonight at eight", style: style, cleanup: cleanup)
            #expect(result.text == written, "\(style)")
        }
    }

    /// The pipeline writes in the dictation's own mode, read when it started: a mode picked while
    /// the model writes (the Style screen, the keyboard's pill) doesn't change this dictation.
    @Test func aModePickedWhileTheModelWritesDoesNotChangeTheDictation() async throws {
        let suite = "test.murmur.pipeline.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: defaults)
        settings.defaultStyle = .rewrite
        let cleanup = StyleCleanup()
        cleanup.text = "He and I were going to the store."
        cleanup.whileWriting = { settings.defaultStyle = .funny }
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .rewrite, language: "en-US",
            translationTargetLanguage: nil, source: .keyboard, startedAt: Date())
        let outcome = await DictationPipeline(cleanup: cleanup, settings: settings).complete(
            dictation, transcriber: SpokenTranscriber("Me and him was going to the store."), audioSeconds: 2,
            stoppedAt: ContinuousClock.now)
        #expect(cleanup.receivedStyle == .rewrite)
        #expect(outcome.transcript.style == .rewrite)
        #expect(outcome.timings?.style == "rewrite")
        #expect(settings.defaultStyle == .funny)
    }

    /// Each mode reaches the model under its own name, so the server writes it its own way.
    @Test func everyModeReachesTheModelUnderItsOwnName() async {
        var received: [StylePreset] = []
        for style in StylePreset.allCases where style.usesModel {
            let cleanup = StyleCleanup()
            _ = await dictate("Hey guys, so I'm gonna need the report by Friday.", style: style, cleanup: cleanup)
            if let sent = cleanup.receivedStyle { received.append(sent) }
        }
        #expect(received == [.rewrite, .email, .funny])
    }

    /// "um" is a word in German: Word-to-Word must not drop it as a hesitation.
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
        let stored = Transcript(language: "en-US", style: .rewrite, rawText: "sounds good", status: .raw)

        let updated = try await pipeline.recleanup(stored)

        #expect(cleanup.receivedStyle == .rewrite)
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

/// Snippets through the pipeline: a snippet's text goes in as the user typed it, whichever way
/// the dictation was written.
@MainActor
struct DictationPipelineSnippetTests {
    private let email = SnippetDefinition(trigger: "my email address", expansion: "anton@example.com")
    private let address = SnippetDefinition(trigger: "my home address", expansion: "12 Garden Road. London N1.")
    private let signature = SnippetDefinition(trigger: "my signature", expansion: "Best regards,\nAnton")

    /// Saying only the snippet's name types its text: no capital, no full stop and no model call,
    /// in every style. The recognizer writes the name as a sentence of its own.
    @Test func aSnippetSaidAloneIsItsTextInEveryStyle() async {
        for style in StylePreset.allCases {
            let cleanup = StyleCleanup()
            let result = await dictate("My email address.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == nil, "\(style)")
            #expect(result.text == "anton@example.com", "\(style)")
        }
    }

    /// Word-to-Word swaps the snippet in on the iPhone, in the middle of a sentence too.
    @Test func wordForWordExpandsASnippetWithoutTheModel() async {
        let cleanup = StyleCleanup()
        let result = await dictate("Send the invoice to my email address, please.", style: .verbatim, cleanup: cleanup)
        #expect(cleanup.receivedStyle == nil)
        #expect(result.text == "Send the invoice to anton@example.com, please.")
    }

    /// The model is told the snippets' names and returns placeholders; the text goes in here.
    @Test func theModelsPlaceholderBecomesTheSnippetsText() async {
        let cleanup = StyleCleanup()
        cleanup.text = "Could you send the invoice to \(SnippetPlaceholders.token(for: email)) by Friday?"
        let result = await dictate(
            "Hey, can you send the invoice to my email address by Friday?", style: .email, cleanup: cleanup)
        #expect(cleanup.receivedSnippets?.map(\.trigger).sorted() == ["my email address", "my home address", "my signature"])
        #expect(result.text == "Could you send the invoice to anton@example.com by Friday?")
        #expect(result.status == .cleaned)
    }

    /// The same when the request that transcribes writes the text (`dictate`): it carries the
    /// snippets, and its reply's placeholder is swapped here.
    @Test func aDictatedReplysPlaceholderBecomesTheSnippetsText() async throws {
        let transcriber = CloudLikeTranscriber(UtteranceOutput(
            transcript: "Hey, can you send the invoice to my email address by Friday?",
            modelReply: .success(CleanupClient.Response(
                text: "Hey, can you send the invoice to \(SnippetPlaceholders.token(for: email)) by Friday?",
                status: "cleaned", words: 9, model: "test", ttftMs: nil, totalMs: 400, remaining: nil))))
        let pipeline = DictationPipeline(cleanup: StyleCleanup())
        pipeline.snippets = [email]
        let outcome = await pipeline.complete(
            dictation(style: .rewrite), transcriber: transcriber, audioSeconds: 2, stoppedAt: ContinuousClock.now)
        #expect(outcome.result.text == "Hey, can you send the invoice to anton@example.com by Friday?")
        #expect(try #require(transcriber.request).snippets == [email])
    }

    /// The model doesn't mark every snippet (live check, November 2026): one it left as words, or
    /// replaced only in part ("My ⟦…⟧"), still goes in whole.
    @Test func aSnippetTheModelMissedIsStillExpanded() async {
        let cleanup = StyleCleanup()
        cleanup.text = "Please send the parcel to my home address by Friday."
        var result = await dictate("Send the parcel to my home address by Friday.", style: .rewrite, cleanup: cleanup)
        #expect(result.text == "Please send the parcel to 12 Garden Road. London N1. by Friday.")

        cleanup.text = "My \(SnippetPlaceholders.token(for: address)) is where the parcel should go."
        result = await dictate("My home address is where the parcel should go.", style: .email, cleanup: cleanup)
        #expect(result.text == "12 Garden Road. London N1. is where the parcel should go.")
    }

    /// Email and Funny reword the speaker's words and leave the snippet's text as typed, with the
    /// model and without it.
    @Test func emailAndFunnyLeaveTheSnippetsTextAsTyped() async {
        for style in [StylePreset.email, .funny] {
            // Three words or fewer never reach the model.
            var result = await dictate("Thanks. My signature.", style: style, cleanup: StyleCleanup())
            #expect(result.text == "Thanks. Best regards,\nAnton", "\(style)")

            let cleanup = StyleCleanup()
            cleanup.text = "Hi,\n\nPlease send it to \(SnippetPlaceholders.token(for: address))\n\nThanks,"
            result = await dictate("Thanks, send it to my home address.", style: style, cleanup: cleanup)
            #expect(result.text == "Hi,\n\nPlease send it to 12 Garden Road. London N1.\n\nThanks,", "\(style)")
        }
    }

    /// Regenerate swaps the snippets into the new text too.
    @Test func regenerateExpandsSnippets() async throws {
        let cleanup = StyleCleanup()
        cleanup.text = "Write to \(SnippetPlaceholders.token(for: email))."
        let pipeline = DictationPipeline(cleanup: cleanup)
        pipeline.snippets = [email]
        let stored = Transcript(language: "en-US", style: .rewrite, rawText: "write to my email address", status: .raw)
        let updated = try await pipeline.recleanup(stored)
        #expect(updated.cleanedText == "Write to anton@example.com.")
    }

    private func dictation(style: StylePreset) -> ActiveDictation {
        ActiveDictation(requestId: UUID(), documentIdentifier: nil, style: style, language: "en-US",
                        translationTargetLanguage: nil, source: .keyboard, startedAt: Date())
    }

    private func dictate(_ spoken: String, style: StylePreset, cleanup: StyleCleanup) async -> DictationResult {
        let pipeline = DictationPipeline(cleanup: cleanup)
        pipeline.snippets = [email, address, signature]
        let outcome = await pipeline.complete(
            dictation(style: style), transcriber: SpokenTranscriber(spoken), audioSeconds: 2, stoppedAt: ContinuousClock.now)
        return outcome.result
    }
}
