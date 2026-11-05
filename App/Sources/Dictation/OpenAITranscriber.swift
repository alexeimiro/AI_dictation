@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import os

/// Cloud recognition with OpenAI, through the `transcribe` function.
///
/// The dictation's audio is kept as 16 kHz mono samples and sent in one request when it ends,
/// compressed to AAC. If the language's on-device model is already on the iPhone, an on-device
/// transcriber listens alongside and is used when the request fails (offline, a server error,
/// the free plan's weekly limit), so a dictation isn't lost.
final class OpenAITranscriber: Transcriber, @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Shorter recordings are treated as silence instead of being sent.
    static let minimumSeconds: Double = 0.3
    /// After a connection failure, dictations go straight to the on-device fallback for this long
    /// instead of waiting on the network each time (an unreachable server can take the whole
    /// request timeout to fail).
    static let cloudPause: TimeInterval = 120

    private let client: any CloudTranscribing
    private let fallback: (any Transcriber)?
    private let lock = NSLock()
    private let logger = Logger(subsystem: "Murmur", category: "CloudASR")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: OpenAITranscriber.sampleRate, channels: 1, interleaved: false)!
    private var language: ResolvedLanguage?
    private var converter: AVAudioConverter?
    private var micFormat: AVAudioFormat?
    /// Bumped by every `prepare`, so a fallback preparation for an older mic format that finishes
    /// late doesn't mark the fallback ready.
    private var generation = 0
    private var samples: [Float] = []
    private var capturing = false
    /// On-device languages the fallback can recognize, by tag.
    private var fallbackLanguages: [String: ResolvedLanguage]
    private var fallbackPrepared = false
    /// The fallback is listening to the current dictation.
    private var fallbackListening = false
    private var cloudPausedUntil: Date?

    /// `fallbackLanguages`: languages whose on-device model is installed and verified.
    init(client: any CloudTranscribing, fallback: (any Transcriber)? = nil,
         fallbackLanguages: [String: ResolvedLanguage] = [:]) {
        self.client = client
        self.fallback = fallback
        self.fallbackLanguages = fallbackLanguages
    }

    var displayName: String {
        lock.withLock { fallbackPrepared ? "OpenAI (on-device fallback)" : "OpenAI" }
    }

    var currentLanguage: ResolvedLanguage? {
        lock.withLock { language }
    }

    /// A language whose on-device model became ready after the session started.
    func addFallbackLanguage(_ language: ResolvedLanguage) {
        lock.withLock { fallbackLanguages[language.tag] = language }
    }

    // MARK: Transcriber

    /// Only what the cloud needs, so the session is ready quickly; the on-device fallback is
    /// prepared separately (`prepareFallback`).
    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        guard let converter = AVAudioConverter(from: micFormat, to: targetFormat) else {
            throw CloudTranscriptionError.unavailable("Unsupported microphone format")
        }
        lock.withLock {
            self.converter = converter
            self.language = language
            self.micFormat = micFormat
            generation += 1
            fallbackPrepared = false
        }
    }

    /// Prepares the installed on-device model for the current language. It takes a while, so the
    /// session calls it once it's ready; dictations before that go without a fallback.
    func prepareFallback() async {
        let (micFormat, onDevice, generation, prepared) = lock.withLock {
            (self.micFormat, language.flatMap { fallbackLanguages[$0.tag] }, self.generation, fallbackPrepared)
        }
        guard !prepared, let fallback, let micFormat, let onDevice else { return }
        do {
            try await fallback.prepare(micFormat: micFormat, language: onDevice)
            lock.withLock { if self.generation == generation { fallbackPrepared = true } }
        } catch {
            logger.notice("On-device fallback unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setLanguage(_ language: ResolvedLanguage) {
        let onDevice = lock.withLock { () -> ResolvedLanguage? in
            self.language = language
            return fallbackPrepared ? fallbackLanguages[language.tag] : nil
        }
        if let onDevice { fallback?.setLanguage(onDevice) }
    }

    func beginUtterance() {
        let listen = lock.withLock { () -> Bool in
            samples.removeAll(keepingCapacity: true)
            capturing = true
            // The fallback only helps when it recognizes the dictation's language.
            fallbackListening = fallbackPrepared && language.map { fallbackLanguages[$0.tag] != nil } == true
            return fallbackListening
        }
        if listen { fallback?.beginUtterance() }
    }

    /// Audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let (converter, capturing, listening) = lock.withLock { (self.converter, self.capturing, fallbackListening) }
        guard capturing, let converter else { return }
        if listening { fallback?.append(buffer) }
        guard let converted = convert(buffer, with: converter) else { return }
        let channel = UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))
        lock.withLock { samples.append(contentsOf: channel) }
    }

    func finishUtterance() async throws -> String {
        let (pcm, language, listening, paused) = lock.withLock { () -> ([Float], ResolvedLanguage?, Bool, Bool) in
            capturing = false
            let taken = samples
            samples.removeAll(keepingCapacity: true)
            return (taken, self.language, fallbackListening, cloudPausedUntil.map { $0 > Date() } ?? false)
        }
        guard Double(pcm.count) >= Self.sampleRate * Self.minimumSeconds else {
            if listening { await fallback?.cancelUtterance() }
            return ""
        }
        if paused, listening, let fallback {
            return try await fallback.finishUtterance()
        }
        do {
            let audio = try EncodedAudio(samples: pcm, sampleRate: Self.sampleRate)
            let text = try await client.transcribe(
                audio: audio.data, format: audio.format,
                language: language?.language.isAutomatic == true ? nil : language?.tag,
                keywords: language?.contextualStrings ?? [])
            lock.withLock { cloudPausedUntil = nil }
            if listening { await fallback?.cancelUtterance() }
            return text
        } catch {
            if case .unavailable = error as? CloudTranscriptionError {
                lock.withLock { cloudPausedUntil = Date().addingTimeInterval(Self.cloudPause) }
            }
            guard listening, let fallback else { throw error }
            logger.notice("Cloud transcription failed, using on-device: \(error.localizedDescription, privacy: .public)")
            return try await fallback.finishUtterance()
        }
    }

    func cancelUtterance() async {
        let listening = lock.withLock { () -> Bool in
            capturing = false
            samples.removeAll(keepingCapacity: true)
            return fallbackListening
        }
        if listening { await fallback?.cancelUtterance() }
    }

    func shutdown() async {
        await fallback?.shutdown()
    }

    // MARK: Audio

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return output
    }
}

/// A dictation's audio, ready to upload: AAC in an M4A container, or WAV if AAC encoding fails.
struct EncodedAudio: Sendable {
    enum Format: String, Sendable {
        case m4a, wav
    }

    let data: Data
    let format: Format

    init(samples: [Float], sampleRate: Double) throws {
        if let aac = try? Self.aac(samples, sampleRate: sampleRate) {
            data = aac
            format = .m4a
        } else {
            data = Self.wav(samples, sampleRate: sampleRate)
            format = .wav
        }
    }

    /// 32 kbps mono AAC: about 4 KB a second, so even a five-minute dictation uploads quickly.
    static func aac(_ samples: [Float], sampleRate: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw CloudTranscriptionError.unavailable("Couldn't allocate audio")
            }
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
            file.close()
        }
        return try Data(contentsOf: url)
    }

    /// 16-bit PCM WAV.
    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        let byteCount = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}
