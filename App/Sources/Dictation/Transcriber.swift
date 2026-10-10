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

    func cancelUtterance() async

    /// Called when the session ends.
    func shutdown() async
}

enum TranscriberEngine: String, CaseIterable, Identifiable {
    /// Per language: SpeechTranscriber when it supports the language and passes validation,
    /// otherwise DictationTranscriber. Default.
    case auto
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
        case .speechTranscriber: "SpeechTranscriber"
        case .dictationTranscriber: "DictationTranscriber"
        case .stub: "Stub (no ASR)"
        }
    }

    static var current: TranscriberEngine {
        SharedSettings.shared.transcriberEngine.flatMap(TranscriberEngine.init(rawValue:)) ?? .auto
    }

    /// Debug: the engine forced for every language, or nil for automatic selection.
    var kindOverride: AppleSpeechTranscriber.Kind? {
        switch self {
        case .speechTranscriber: .speech
        case .dictationTranscriber: .dictation
        case .auto, .stub: nil
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

    func cancelUtterance() async {}
    func shutdown() async {}
}
