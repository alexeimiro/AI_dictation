@preconcurrency import AVFoundation
import Foundation
import MurmurCore

/// Speech-to-text engine used by the session. Implementations must make `append` cheap and
/// thread-safe: it is called on the audio thread.
protocol Transcriber: AnyObject, Sendable {
    var displayName: String { get }

    /// The language the next dictation will be recognized in.
    var currentLanguage: ResolvedLanguage? { get }

    /// Called when the session starts, while the app is in the foreground, and again on
    /// reconnect (the mic format can change with the audio route).
    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws

    /// Switches the language for the next dictation. Only valid between dictations; the new
    /// model is prepared in the background and `finishUtterance` waits for it.
    func setLanguage(_ language: ResolvedLanguage)

    /// Starts a dictation. Synchronous so no audio is lost: buffers delivered through `append`
    /// right after this call belong to the new dictation.
    func beginUtterance()

    /// Audio thread.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Ends the dictation and returns the final transcript.
    func finishUtterance() async throws -> String

    /// Ends a dictation for the pipeline. With `request` (a translation, or Improve my grammar), a
    /// transcriber that can have the model write the text in the request that transcribes
    /// (`OpenAITranscriber` with `dictate`) returns that reply too; the others return the
    /// transcript alone, and the pipeline asks the cleanup. No default: a transcriber that wraps
    /// another must pass the request on.
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput

    /// The same, for the dictation `dictationId` (its `requestId`). A transcriber that sends the
    /// dictation to the server names it in every request (`OpenAITranscriber`), so the free plan
    /// counts its words once, whichever requests it takes. The others don't need it.
    func finishUtterance(model request: ModelRequest?, dictationId: UUID) async throws -> UtteranceOutput

    func cancelUtterance() async

    /// Drops the current dictation at once, from any context, and tears it down in the
    /// background: nothing it does afterwards reaches a dictation that begins right after (a
    /// `cancelUtterance` run in a task could stop that one recording). Each transcriber
    /// implements it itself; a default forwarding to `cancelUtterance` would bring the race back.
    func abandonUtterance()

    /// Called when the session ends.
    func shutdown() async
}

extension Transcriber {
    /// On the iPhone nothing is counted, so the dictation needs no name.
    func finishUtterance(model request: ModelRequest?, dictationId: UUID) async throws -> UtteranceOutput {
        try await finishUtterance(model: request)
    }
}

/// A finished dictation's transcript, and the model's text when the transcriber had it written in
/// the same request.
struct UtteranceOutput: Sendable {
    var transcript: String
    /// The translation or the improved grammar. Nil when only transcribed: the pipeline asks the
    /// cleanup itself.
    var modelReply: Result<CleanupClient.Response, CleanupClient.Failure>?
    /// Under Auto-detect, the language the transcript turned out to be in (BCP-47: "tr", "ru-RU"),
    /// as the cloud heard it or as the fallback recognized it. Nil for a dictation in a chosen
    /// language, or when the cloud couldn't tell.
    var detectedLanguage: String?

    init(transcript: String, modelReply: Result<CleanupClient.Response, CleanupClient.Failure>? = nil,
         detectedLanguage: String? = nil) {
        self.transcript = transcript
        self.modelReply = modelReply
        self.detectedLanguage = detectedLanguage
    }
}

/// What a cloud transcriber measured for one dictation, for `DictationTimings`.
struct UtteranceTimings: Sendable, Equatable {
    /// Compressing the audio after stop.
    var encodeMs: Int?
    var audioBytes: Int?
    /// The `transcribe` or `dictate` request; empty when the cloud was skipped or the request failed.
    var requests: [RequestTiming] = []
    /// The transcript is the cloud's; false when the fallback made it.
    var cloudTranscript = false
    /// Why the cloud didn't answer, when the fallback answered instead: its transcript alone
    /// doesn't say that the account is signed out.
    var cloudFailure: CloudTranscriptionError?
}

/// A transcriber that measures its cloud work (`OpenAITranscriber`).
/// A transcriber that encodes each dictation's audio (to upload it), kept for the transcript's
/// playback.
protocol RecordingProviding: AnyObject {
    /// The last finished dictation's audio, once: cleared by this call, when the next dictation
    /// begins, and when one is abandoned. Nil when none was encoded (on-device recognition).
    func takeRecording() -> EncodedAudio?
}

protocol UtteranceTimingProviding: AnyObject {
    /// The last finished dictation's measurements, once: they are cleared by this call, when the
    /// next dictation begins, and when one is abandoned.
    func takeTimings() -> UtteranceTimings?
}

enum TranscriberEngine: String, CaseIterable, Identifiable {
    /// OpenAI when the backend is configured, otherwise on-device. Default.
    case auto
    /// OpenAI through the `transcribe` function, with on-device models that are already
    /// installed as the fallback.
    case openAI
    /// On-device only. Per language: SpeechTranscriber when it supports the language and passes
    /// validation, otherwise DictationTranscriber.
    case onDevice
    /// Force Apple SpeechAnalyzer + SpeechTranscriber (iOS 26 model) for every language.
    case speechTranscriber
    /// Force Apple SpeechAnalyzer + DictationTranscriber (supports contextual strings).
    case dictationTranscriber
    /// No recognition: returns a test sentence. For exercising the IPC path.
    case stub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Automatic (recommended)"
        case .openAI: "OpenAI"
        case .onDevice: "On-device"
        case .speechTranscriber: "SpeechTranscriber"
        case .dictationTranscriber: "DictationTranscriber"
        case .stub: "Stub (no ASR)"
        }
    }

    static var current: TranscriberEngine {
        SharedSettings.shared.transcriberEngine.flatMap(TranscriberEngine.init(rawValue:)) ?? .auto
    }

    /// Debug: the on-device engine forced for every language, or nil for automatic selection.
    var kindOverride: AppleSpeechTranscriber.Kind? {
        switch self {
        case .speechTranscriber: .speech
        case .dictationTranscriber: .dictation
        case .auto, .openAI, .onDevice, .stub: nil
        }
    }

    /// Whether a session transcribes in the cloud. `cloudAvailable`: the backend is configured.
    func usesCloud(cloudAvailable: Bool) -> Bool {
        switch self {
        case .auto: cloudAvailable
        case .openAI: true
        case .onDevice, .speechTranscriber, .dictationTranscriber, .stub: false
        }
    }
}

/// Returns a fixed sentence describing the captured audio. Used to test the keyboard ↔ app path
/// without speech recognition.
final class StubTranscriber: Transcriber, @unchecked Sendable {
    let displayName = "Stub"
    private let lock = NSLock()
    private var frames: AVAudioFramePosition = 0
    private var sampleRate: Double = 48_000
    private var utteranceCount = 0
    private var language: ResolvedLanguage?

    var currentLanguage: ResolvedLanguage? {
        lock.withLock { language }
    }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        lock.withLock {
            sampleRate = micFormat.sampleRate
            self.language = language
        }
    }

    func setLanguage(_ language: ResolvedLanguage) {
        lock.withLock { self.language = language }
    }

    func beginUtterance() {
        lock.withLock {
            frames = 0
            utteranceCount += 1
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { frames += AVAudioFramePosition(buffer.frameLength) }
    }

    func finishUtterance() async throws -> String {
        let (count, seconds, tag) = lock.withLock { (utteranceCount, Double(frames) / sampleRate, language?.tag ?? "?") }
        return String(format: "Test dictation number %d in %@, %.1f seconds of audio.", count, tag, seconds)
    }

    /// The test sentence, for the pipeline to translate.
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        UtteranceOutput(transcript: try await finishUtterance())
    }

    func cancelUtterance() async {}
    /// Nothing to tear down: the next `beginUtterance` resets the frame count.
    func abandonUtterance() {}
    func shutdown() async {}
}
