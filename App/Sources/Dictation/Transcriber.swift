@preconcurrency import AVFoundation
import Foundation
import MurmurCore

/// Speech-to-text engine used by the session. Implementations must make `append` cheap and
/// thread-safe: it is called on the audio thread.
protocol Transcriber: AnyObject, Sendable {
    var displayName: String { get }

    /// Called once when the session starts, while the app is in the foreground.
    func prepare(micFormat: AVAudioFormat, locale: Locale) async throws

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
    /// Apple SpeechAnalyzer + SpeechTranscriber (iOS 26 model). Default.
    case speechTranscriber
    /// Apple SpeechAnalyzer + DictationTranscriber (supports contextual strings).
    case dictationTranscriber
    /// No recognition: returns a test sentence. For exercising the IPC path.
    case stub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speechTranscriber: "SpeechTranscriber"
        case .dictationTranscriber: "DictationTranscriber"
        case .stub: "Stub (no ASR)"
        }
    }

    static var current: TranscriberEngine {
        SharedSettings.shared.transcriberEngine.flatMap(TranscriberEngine.init(rawValue:))
            ?? .speechTranscriber
    }

    func make(contextualStrings: [String]) -> Transcriber {
        switch self {
        case .speechTranscriber: AppleSpeechTranscriber(kind: .speech, contextualStrings: [])
        case .dictationTranscriber: AppleSpeechTranscriber(kind: .dictation, contextualStrings: contextualStrings)
        case .stub: StubTranscriber()
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

    func prepare(micFormat: AVAudioFormat, locale: Locale) async throws {
        lock.withLock { sampleRate = micFormat.sampleRate }
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
        let (count, seconds) = lock.withLock { (utteranceCount, Double(frames) / sampleRate) }
        return String(format: "Test dictation number %d, %.1f seconds of audio.", count, seconds)
    }

    func cancelUtterance() async {}
    func shutdown() async {}
}
