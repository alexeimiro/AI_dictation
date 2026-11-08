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

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?,
        style: StylePreset, dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        receivedStyle = style
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
    func cancelUtterance() async {}
    func abandonUtterance() {}
    func shutdown() async {}
}

@MainActor
struct DictationPipelineStyleTests {
    /// The reported bug: a punctuated transcript skips the model, so these styles inserted the same text.
    @Test func stylesShowWhenTheGateSkipsTheModel() async {
        for (style, expected) in [
            (StylePreset.formal, "Sounds good, see you soon."),
            (.casual, "Sounds good, see you soon"),
            (.verbatim, "Sounds good, see you soon."),
        ] {
            let cleanup = StyleCleanup()
            let (result, transcript) = await dictate("Sounds good, see you soon.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == nil, "\(style)")
            #expect(result.text == expected, "\(style)")
            #expect(transcript.style == style)
        }
    }

    /// Three words or fewer never reach the model, whatever the style.
    @Test func shortRepliesGetTheStyleToo() async {
        for (style, expected) in [
            (StylePreset.veryCasual, "sounds good"),
            (.excited, "Sounds good!"),
        ] {
            let cleanup = StyleCleanup()
            let (result, _) = await dictate("Sounds good.", style: style, cleanup: cleanup)
            #expect(cleanup.receivedStyle == nil, "\(style)")
            #expect(result.text == expected, "\(style)")
        }
    }

    @Test func casualDropsTheModelsFinalPeriod() async throws {
        let cleanup = StyleCleanup()
        let pipeline = DictationPipeline(cleanup: cleanup)
        let stored = Transcript(language: "en-US", style: .casual, rawText: "sounds good", status: .raw)

        let updated = try await pipeline.recleanup(stored)

        #expect(cleanup.receivedStyle == .casual)
        #expect(updated.cleanedText == "Sounds good")
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
