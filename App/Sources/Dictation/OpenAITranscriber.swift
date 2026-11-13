@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import os

/// Cloud recognition with OpenAI, through the `dictate` function: one request that transcribes a
/// dictation and, when it is translated or written in a style, writes it too. The older
/// `transcribe` function takes the audio whenever `dictate` can't.
///
/// The dictation's audio is kept as 16 kHz mono samples and sent in one request when it ends,
/// compressed to AAC. If the language's on-device model is already on the iPhone, an on-device
/// transcriber listens alongside and is used when the request fails (offline, a server error,
/// the free plan's weekly limit), so a dictation isn't lost.
final class OpenAITranscriber: Transcriber, UtteranceTimingProviding, RecordingProviding, @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Shorter recordings are treated as silence instead of being sent.
    static let minimumSeconds: Double = 0.3
    /// After a connection failure, dictations go straight to the on-device fallback for this long
    /// instead of waiting on the network each time (an unreachable server can take the whole
    /// request timeout to fail).
    static let cloudPause: TimeInterval = 120

    private let client: any CloudTranscribing
    private let dictation: (any Dictating)?
    private let fallback: (any Transcriber)?
    /// Low data mode: the audio uploads at `EncodedAudio.lowDataBitRate`.
    private let savesData: @Sendable () -> Bool
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
    /// What the fallback listens in under Auto-detect, when only the cloud knows the language
    /// (`setAutomaticFallback`).
    private var automaticFallback: ResolvedLanguage?
    private var fallbackPrepared = false
    /// The fallback is listening to the current dictation.
    private var fallbackListening = false
    private var cloudPausedUntil: Date?
    /// Bumped by every `beginUtterance` and `abandonUtterance`, so a finish or a buffer that
    /// outlives its dictation doesn't report into the next one.
    private var utteranceNumber = 0
    /// The last finished dictation's measurements, until `takeTimings`.
    private var timings: UtteranceTimings?
    /// The last finished dictation's audio as uploaded, until `takeRecording`.
    private var recording: EncodedAudio?

    /// `dictation`: transcribes, and translates or writes in a style, in one request; without it
    /// every dictation goes to `client` for its transcript. `fallbackLanguages`: languages whose
    /// on-device model is installed and verified.
    init(client: any CloudTranscribing, dictation: (any Dictating)? = nil, fallback: (any Transcriber)? = nil,
         fallbackLanguages: [String: ResolvedLanguage] = [:],
         savesData: @escaping @Sendable () -> Bool = { NetworkConditions.shared.savesData() }) {
        self.client = client
        self.dictation = dictation
        self.fallback = fallback
        self.fallbackLanguages = fallbackLanguages
        self.savesData = savesData
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

    /// Under Auto-detect a failed request can only be covered by a guess: the session names the
    /// installed language most likely spoken (nil: no fallback under Auto).
    func setAutomaticFallback(_ language: ResolvedLanguage?) {
        let switchTo = lock.withLock { () -> ResolvedLanguage? in
            let changed = automaticFallback != language
            automaticFallback = language
            // A prepared fallback already listening in the old guess switches before the next dictation.
            guard changed, fallbackPrepared, self.language?.language.isAutomatic == true else { return nil }
            return language
        }
        if let switchTo { fallback?.setLanguage(switchTo) }
    }

    /// The on-device language that covers a dictation in `language`. Call under the lock.
    private func onDeviceLanguage(for language: ResolvedLanguage) -> ResolvedLanguage? {
        language.language.isAutomatic ? automaticFallback : fallbackLanguages[language.tag]
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
            (self.micFormat, language.flatMap(onDeviceLanguage(for:)), self.generation, fallbackPrepared)
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
            return fallbackPrepared ? onDeviceLanguage(for: language) : nil
        }
        if let onDevice { fallback?.setLanguage(onDevice) }
    }

    func beginUtterance() {
        let (unended, listen) = lock.withLock { () -> (Bool, Bool) in
            // The last dictation's part, when a reconnect let this one begin while that one was
            // still uploading: its finish can no longer claim it, so it's ended here.
            let unended = fallbackListening
            samples.removeAll(keepingCapacity: true)
            capturing = true
            utteranceNumber += 1
            timings = nil
            recording = nil
            // The fallback only helps when it recognizes the dictation's language (or, under
            // Auto-detect, the language it is most likely in).
            fallbackListening = fallbackPrepared && language.flatMap(onDeviceLanguage(for:)) != nil
            return (unended, fallbackListening)
        }
        if unended { fallback?.abandonUtterance() }
        if listen { fallback?.beginUtterance() }
    }

    /// Audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let (converter, capturing, listening, utterance) = lock.withLock {
            (self.converter, self.capturing, fallbackListening, utteranceNumber)
        }
        guard capturing, let converter else { return }
        if listening { fallback?.append(buffer) }
        guard let converted = convert(buffer, with: converter) else { return }
        let channel = UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength))
        // Not into a dictation that was abandoned, or began, while this buffer was converted.
        lock.withLock { if utteranceNumber == utterance { samples.append(contentsOf: channel) } }
    }

    func finishUtterance() async throws -> String {
        try await finish(model: nil, dictationId: nil).transcript
    }

    /// With a request and `dictate` available, the transcript and the model's text from one
    /// request. Otherwise, and whenever the on-device fallback answers, the transcript alone.
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        try await finish(model: request, dictationId: request?.dictationId)
    }

    /// As above, naming the dictation whatever it asks for: Word for word has no model request to
    /// carry its id, and its words are counted under it by the function that transcribes it,
    /// `dictate` when that can, else `transcribe`.
    func finishUtterance(model request: ModelRequest?, dictationId: UUID) async throws -> UtteranceOutput {
        try await finish(model: request, dictationId: dictationId)
    }

    private func finish(model request: ModelRequest?, dictationId: UUID?) async throws -> UtteranceOutput {
        let (pcm, language, paused, utterance, onDevice) = lock.withLock {
            () -> ([Float], ResolvedLanguage?, Bool, Int, ResolvedLanguage?) in
            capturing = false
            let taken = samples
            samples.removeAll(keepingCapacity: true)
            return (taken, self.language, cloudPausedUntil.map { $0 > Date() } ?? false, utteranceNumber,
                    self.language.flatMap(onDeviceLanguage(for:)))
        }
        let automatic = language?.language.isAutomatic == true
        // Under Auto-detect the fallback's transcript is in the language it listened in.
        let fallbackDetected = automatic ? onDevice?.tag : nil
        guard Double(pcm.count) >= Self.sampleRate * Self.minimumSeconds else {
            if claimFallback(of: utterance) { fallback?.abandonUtterance() }
            return UtteranceOutput(transcript: "")
        }
        if paused, claimFallback(of: utterance), let fallback {
            return UtteranceOutput(transcript: try await fallback.finishUtterance(), detectedLanguage: fallbackDetected)
        }
        do {
            let encodeStarted = ContinuousClock.now
            let bitRate = savesData() ? EncodedAudio.lowDataBitRate : EncodedAudio.standardBitRate
            let audio = try EncodedAudio(samples: pcm, sampleRate: Self.sampleRate, bitRate: bitRate)
            var measured = UtteranceTimings(encodeMs: encodeStarted.elapsedMilliseconds, audioBytes: audio.data.count)
            record(measured, for: utterance)
            keep(audio, for: utterance)
            let spoken = automatic ? nil : language?.tag
            let hints = automatic ? language?.languageHints ?? [] : []
            let keywords = language?.contextualStrings ?? []
            // What OpenAI heard matters only when it chose the language.
            let detected = { (languages: [String]) in automatic ? languages.first.map(DictationLanguage.normalize) : nil }
            let output: UtteranceOutput
            let timing: RequestTiming?
            if let request,
               let reply = try await dictated(audio, language: spoken, hints: hints, keywords: keywords,
                                              request: request) {
                output = UtteranceOutput(transcript: reply.transcript, modelReply: reply.modelReply,
                                         detectedLanguage: detected(reply.languages))
                timing = reply.timing
            } else {
                // Word for word asks `dictate` for the transcript alone. A dictation the model was
                // to write, which `dictate` couldn't take, goes to `transcribe` as it always did.
                let transcript: CloudTranscript
                if request == nil, let dictationId,
                   let alone = try await transcribedAlone(audio, language: spoken, hints: hints, keywords: keywords,
                                                          dictationId: dictationId) {
                    transcript = alone
                } else {
                    transcript = try await client.transcribe(
                        audio: audio.data, format: audio.format, language: spoken, languageHints: hints,
                        keywords: keywords, dictationId: dictationId)
                }
                output = UtteranceOutput(transcript: transcript.text, detectedLanguage: detected(transcript.languages))
                timing = transcript.timing
            }
            measured.requests = timing.map { [$0] } ?? []
            measured.cloudTranscript = true
            record(measured, for: utterance)
            lock.withLock { cloudPausedUntil = nil }
            if claimFallback(of: utterance) { fallback?.abandonUtterance() }
            return output
        } catch CloudTranscriptionError.cancelled {
            // The dictation is being dropped, or another path already answered: the service isn't
            // at fault, and nobody is waiting for an on-device transcript.
            if claimFallback(of: utterance) { fallback?.abandonUtterance() }
            throw CloudTranscriptionError.cancelled
        } catch {
            if case .unavailable = error as? CloudTranscriptionError {
                lock.withLock { cloudPausedUntil = Date().addingTimeInterval(Self.cloudPause) }
            }
            recordFailure(error, for: utterance)
            guard claimFallback(of: utterance), let fallback else { throw error }
            logger.notice("Cloud transcription failed, using on-device: \(error.localizedDescription, privacy: .public)")
            return UtteranceOutput(transcript: try await fallback.finishUtterance(), detectedLanguage: fallbackDetected)
        }
    }

    /// `dictate`'s reply, or nil to send the same audio to `transcribe`: `dictate` is unavailable,
    /// or has just answered that it isn't deployed. Its other failures are the cloud's, as
    /// `transcribe`'s are.
    private func dictated(_ audio: EncodedAudio, language: String?, hints: [String], keywords: [String],
                          request: ModelRequest) async throws -> DictateReply? {
        guard let dictation, await dictation.isAvailable else { return nil }
        do {
            return try await dictation.dictate(
                audio: audio.data, format: audio.format, language: language, languageHints: hints,
                keywords: keywords, request: request)
        } catch {
            // Rethrown by hand: Swift 6.3.3's optimizer crashes (OSSACompleteLifetime) on the
            // implicit rethrow of the other typed errors after `catch .notDeployed`, in Release only.
            guard error == .notDeployed else { throw error }
            logger.notice("dictate isn't deployed; transcribing and writing in two requests")
            return nil
        }
    }

    /// A Word for word dictation's transcript from `dictate`, or nil to send the same audio to
    /// `transcribe`: `dictate` is unavailable, can't transcribe alone, or couldn't run its checks.
    private func transcribedAlone(_ audio: EncodedAudio, language: String?, hints: [String], keywords: [String],
                                  dictationId: UUID) async throws -> CloudTranscript? {
        guard let dictation, await dictation.transcribesAlone else { return nil }
        do {
            return try await dictation.transcribe(
                audio: audio.data, format: audio.format, language: language, languageHints: hints,
                keywords: keywords, dictationId: dictationId)
        } catch {
            // Rethrown by hand, as in `dictated`.
            guard error == .notDeployed else { throw error }
            logger.notice("dictate didn't transcribe alone; sending the audio to transcribe")
            return nil
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

    /// Under the lock, so audio and a finish still under way for this dictation find it gone: no
    /// samples or timings kept (`utteranceNumber` moves on), and the fallback's part ended once,
    /// here.
    func abandonUtterance() {
        let listening = lock.withLock { () -> Bool in
            capturing = false
            samples.removeAll(keepingCapacity: true)
            utteranceNumber += 1
            timings = nil
            recording = nil
            defer { fallbackListening = false }
            return fallbackListening
        }
        if listening { fallback?.abandonUtterance() }
    }

    func shutdown() async {
        await fallback?.shutdown()
    }

    /// Whether the fallback still listens to `utterance`, handing it to the caller to end if so.
    /// False once that dictation was abandoned (which ended it) or a newer one began, so a finish
    /// that outlives its dictation never ends or uses the next one's.
    private func claimFallback(of utterance: Int) -> Bool {
        lock.withLock {
            guard utteranceNumber == utterance, fallbackListening else { return false }
            fallbackListening = false
            return true
        }
    }

    // MARK: Timings

    func takeTimings() -> UtteranceTimings? {
        lock.withLock {
            defer { timings = nil }
            return timings
        }
    }

    func takeRecording() -> EncodedAudio? {
        lock.withLock {
            defer { recording = nil }
            return recording
        }
    }

    /// Keeps `audio` for `takeRecording`, unless a newer dictation has begun meanwhile.
    private func keep(_ audio: EncodedAudio, for utterance: Int) {
        lock.withLock {
            if utteranceNumber == utterance { recording = audio }
        }
    }

    /// Keeps `measured` for `takeTimings`, unless a newer dictation has begun meanwhile.
    private func record(_ measured: UtteranceTimings, for utterance: Int) {
        lock.withLock {
            if utteranceNumber == utterance { timings = measured }
        }
    }

    /// Adds why the request failed to `utterance`'s timings, for the pipeline to tell the user.
    private func recordFailure(_ error: any Error, for utterance: Int) {
        lock.withLock {
            if utteranceNumber == utterance { timings?.cloudFailure = error as? CloudTranscriptionError }
        }
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
    enum Format: String, Sendable, CaseIterable {
        case m4a, wav
    }

    let data: Data
    let format: Format

    /// 32 kbps mono AAC: about 4 KB a second, so even a five-minute dictation uploads quickly.
    static let standardBitRate = 32_000
    /// Low data mode: half that, still clear speech at 16 kHz.
    static let lowDataBitRate = 16_000

    private static let logger = Logger(subsystem: "Murmur", category: "CloudASR")

    init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }

    init(samples: [Float], sampleRate: Double, bitRate: Int = EncodedAudio.standardBitRate) throws {
        if let aac = try? Self.aac(samples, sampleRate: sampleRate, bitRate: bitRate) {
            data = aac
            format = .m4a
        } else {
            data = Self.wav(samples, sampleRate: sampleRate)
            format = .wav
        }
    }

    /// The M4A file to upload: as `AVAudioFile` writes it, without the empty space it leaves for
    /// the header (`M4AFreeSpace`), which is most of a short dictation's bytes.
    static func aac(_ samples: [Float], sampleRate: Double, bitRate: Int = standardBitRate) throws -> Data {
        let written = try writtenAAC(samples, sampleRate: sampleRate, bitRate: bitRate)
        guard let compact = M4AFreeSpace.removed(from: written) else {
            logger.notice("The recording's M4A isn't laid out as expected; sending it with its empty space")
            return written
        }
        return compact
    }

    /// The M4A file exactly as `AVAudioFile` writes it.
    static func writtenAAC(_ samples: [Float], sampleRate: Double, bitRate: Int = standardBitRate) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
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
