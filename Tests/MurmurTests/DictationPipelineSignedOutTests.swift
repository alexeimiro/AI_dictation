@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The cleanup while the account is signed out: `ensureSession` refuses before anything is sent.
@MainActor
private final class SignedOutCleanup: Cleaning {
    var isConfigured = true
    private(set) var calls = 0

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?,
        style: StylePreset, dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        calls += 1
        throw .signedOut
    }
}

/// The on-device fallback's transcript, or the cloud's refusal when nothing listened alongside.
/// Like `OpenAITranscriber`, it reports why the cloud didn't answer (`refusal`).
private final class SignedOutTranscriber: Transcriber, UtteranceTimingProviding, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?
    private let transcript: String?
    private let refusal: CloudTranscriptionError
    private let fallbackFailure: (any Error)?

    /// `fallbackFailure`: what the fallback threw when it couldn't transcribe either.
    init(fallbackTranscript transcript: String?, refusal: CloudTranscriptionError = .signedOut,
         fallbackFailure: (any Error)? = nil) {
        self.transcript = transcript
        self.refusal = refusal
        self.fallbackFailure = fallbackFailure
    }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String {
        guard let transcript else { throw fallbackFailure ?? refusal }
        return transcript
    }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        UtteranceOutput(transcript: try await finishUtterance())
    }
    func cancelUtterance() async {}
    func abandonUtterance() {}
    func shutdown() async {}

    func takeTimings() -> UtteranceTimings? {
        UtteranceTimings(cloudFailure: refusal)
    }
}

/// What the keyboard shows while the account is signed out: the same sentence wherever the cloud
/// was refused, and never "Check your connection".
@MainActor
struct DictationPipelineSignedOutTests {
    private let signedOut = "You're signed out. Open Murmur to sign in again."

    @Test func aRefusedTranscriptionSaysSo() async {
        let (result, transcript, _) = await dictate(heard: nil)
        #expect(result.status == .failed)
        #expect(result.text.isEmpty)
        #expect(result.message == signedOut)
        #expect(transcript.errorReason == "The account was signed out.")
    }

    @Test func aRefusedTranslationSaysSo() async {
        let (result, _, _) = await dictate(heard: "можешь скинуть отчёт до пятницы", translatingTo: "en-US")
        #expect(result.status == .failed)
        #expect(result.text.isEmpty)
        #expect(result.message == signedOut)
    }

    /// The on-device transcript is still inserted, with local formatting, and the keyboard shows
    /// the sentence after it, as it does after the free plan's limit.
    @Test func aDictationKeepsItsLocalTextAndSaysSo() async {
        let (result, transcript, _) = await dictate(heard: "can you send me the report by friday")
        #expect(result.status == .raw)
        #expect(result.isInsertable)
        #expect(result.text.localizedCaseInsensitiveContains("send me the report"))
        #expect(result.message == signedOut)
        #expect(transcript.errorReason == "The account was signed out.")
    }

    /// No cleanup runs to be refused for a short dictation or a Word for word one with nothing to
    /// write differently: the transcriber's word on the refusal is enough for the keyboard to say so.
    @Test func aDictationThatSkipsTheCleanupSaysSoToo() async {
        for (heard, style) in [("Thanks, Olga", StylePreset.grammar), ("Can you send me the report by Friday?", .verbatim)] {
            let (result, transcript, cleanup) = await dictate(heard: heard, style: style)
            #expect(cleanup.calls == 0)
            #expect(result.status == .raw)
            #expect(result.isInsertable)
            #expect(result.message == signedOut)
            #expect(transcript.errorReason == "The account was signed out.")
        }
    }

    /// When the fallback fails too, signing in is still what helps, not trying again.
    @Test func aFallbackThatFailsAfterTheRefusalSaysSo() async {
        let (result, _, _) = await dictate(heard: nil, fallbackFailure: CocoaError(.featureUnsupported))
        #expect(result.status == .failed)
        #expect(result.message == signedOut)
    }

    /// The fallback answering for any other reason (offline) is no sign-out.
    @Test func anOnDeviceDictationForAnotherReasonSaysNothing() async {
        let (result, transcript, _) = await dictate(heard: "Thanks, Olga", refusal: .unavailable("offline"))
        #expect(result.status == .raw)
        #expect(result.message == nil)
        #expect(transcript.errorReason == nil)
    }

    /// `heard`: the fallback's transcript, or nil when the cloud's refusal (or `fallbackFailure`)
    /// is all there is.
    private func dictate(
        heard: String?, translatingTo target: String? = nil, style: StylePreset = .grammar,
        refusal: CloudTranscriptionError = .signedOut, fallbackFailure: (any Error)? = nil
    ) async -> (DictationResult, Transcript, SignedOutCleanup) {
        let suite = "test.murmur.pipeline.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: UserDefaults(suiteName: suite))
        let cleanup = SignedOutCleanup()
        let pipeline = DictationPipeline(cleanup: cleanup, settings: settings)
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: style, language: target == nil ? "en-US" : "ru-RU",
            translationTargetLanguage: target, source: .keyboard, startedAt: Date())
        let transcriber = SignedOutTranscriber(fallbackTranscript: heard, refusal: refusal, fallbackFailure: fallbackFailure)
        let outcome = await pipeline.complete(dictation, transcriber: transcriber, audioSeconds: 2,
                                              stoppedAt: ContinuousClock.now)
        return (outcome.result, outcome.transcript, cleanup)
    }
}
