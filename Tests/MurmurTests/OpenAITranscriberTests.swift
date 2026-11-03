@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class FakeCloud: CloudTranscribing {
    var isConfigured = true
    var result: Result<String, CloudTranscriptionError> = .success("Hello from OpenAI.")
    private(set) var calls: [(audio: Data, format: EncodedAudio.Format, language: String?, keywords: [String])] = []

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?,
                    keywords: [String]) async throws(CloudTranscriptionError) -> String {
        calls.append((audio, format, language, keywords))
        return try result.get()
    }
}

/// Stands in for the on-device transcriber.
private final class FakeOnDevice: Transcriber, @unchecked Sendable {
    let displayName = "On-device"
    private let lock = NSLock()
    private var _preparedTag: String?
    private var _appended = 0
    private var _cancelled = 0

    var currentLanguage: ResolvedLanguage? { nil }
    var preparedTag: String? { lock.withLock { _preparedTag } }
    var appended: Int { lock.withLock { _appended } }
    var cancelled: Int { lock.withLock { _cancelled } }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        lock.withLock { _preparedTag = language.tag }
    }
    func setLanguage(_ language: ResolvedLanguage) {}
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { _appended += 1 } }
    func finishUtterance() async throws -> String { "Recognized on the iPhone." }
    func cancelUtterance() async { lock.withLock { _cancelled += 1 } }
    func shutdown() async {}
}

@MainActor
struct OpenAITranscriberTests {
    private let micFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let russian = ResolvedLanguage(tag: "ru-RU", locale: Locale(identifier: "ru-RU"), engine: .speech,
                                           contextualStrings: ["Окафор", "Valerio"])

    /// `seconds` of a 440 Hz tone in 4096-frame buffers, like the mic tap delivers.
    private func feed(_ transcriber: OpenAITranscriber, seconds: Double) {
        let total = Int(48_000 * seconds)
        var written = 0
        while written < total {
            let frames = min(4096, total - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for index in 0..<frames {
                buffer.floatChannelData![0][index] = 0.3 * sin(2 * .pi * 440 * Float(written + index) / 48_000)
            }
            transcriber.append(buffer)
            written += frames
        }
    }

    @Test func sendsTheDictationsAudioWithItsLanguageAndDictionary() async throws {
        let cloud = FakeCloud()
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 6)
        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")

        let call = try #require(cloud.calls.first)
        #expect(call.language == "ru-RU")
        #expect(call.keywords == ["Окафор", "Valerio"])
        #expect(call.audio.count > 1_000)
        // Compressed: an MPEG-4 container ("ftyp" at byte 4), a third of the size of 16-bit WAV
        // or less (AAC at 32 kbps plus ~25 KB of container).
        #expect(call.format == .m4a)
        #expect(String(decoding: call.audio[4..<8], as: UTF8.self) == "ftyp")
        let wavSize = 44 + 6 * 16_000 * 2
        #expect(call.audio.count < wavSize / 3)
    }

    @Test func silenceShorterThanAThirdOfASecondIsNotSent() async throws {
        let cloud = FakeCloud()
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 0.1)
        #expect(try await transcriber.finishUtterance() == "")
        #expect(cloud.calls.isEmpty)
    }

    @Test func audioBetweenDictationsIsIgnored() async throws {
        let cloud = FakeCloud()
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        feed(transcriber, seconds: 2)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 0.5)
        _ = try await transcriber.finishUtterance()
        // ~0.5 s of 16 kHz audio, not 2.5 s.
        let size = try #require(cloud.calls.first).audio.count
        #expect(size < EncodedAudio.wav(Array(repeating: 0, count: 16_000), sampleRate: 16_000).count)
    }

    @Test func fallsBackToTheInstalledOnDeviceModelWhenTheRequestFails() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        #expect(onDevice.preparedTag == "ru-RU")
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(onDevice.appended > 0)
        #expect(try await transcriber.finishUtterance() == "Recognized on the iPhone.")
    }

    @Test func afterAConnectionFailureTheFallbackIsUsedDirectly() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("The request timed out."))
        let transcriber = OpenAITranscriber(client: cloud, fallback: FakeOnDevice(), fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        for _ in 0..<2 {
            transcriber.beginUtterance()
            feed(transcriber, seconds: 1)
            #expect(try await transcriber.finishUtterance() == "Recognized on the iPhone.")
        }
        // The second dictation didn't wait on the network again.
        #expect(cloud.calls.count == 1)
    }

    @Test func aSuccessfulRequestCancelsTheFallback() async throws {
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")
        #expect(onDevice.cancelled == 1)
    }

    @Test func withoutAnInstalledModelAFailureIsReported() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.limitReached)
        let onDevice = FakeOnDevice()
        // Only English is installed on the device; this dictation is in Russian.
        let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["en-US": english])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        #expect(onDevice.preparedTag == nil)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }
        #expect(DictationPipeline.transcriptionMessage(for: CloudTranscriptionError.limitReached)
            == "Dictation limit reached. Get unlimited access in Murmur.")
    }

    @Test func wavIsValidSixteenBitMono() {
        let data = EncodedAudio.wav([0, 0.5, -0.5, 1], sampleRate: 16_000)
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
    }

    @Test func automaticEngineUsesTheCloudOnlyWithABackend() {
        #expect(TranscriberEngine.auto.usesCloud(cloudAvailable: true))
        #expect(!TranscriberEngine.auto.usesCloud(cloudAvailable: false))
        #expect(TranscriberEngine.openAI.usesCloud(cloudAvailable: false))
        #expect(!TranscriberEngine.onDevice.usesCloud(cloudAvailable: true))
        #expect(!TranscriberEngine.stub.usesCloud(cloudAvailable: true))
    }
}
