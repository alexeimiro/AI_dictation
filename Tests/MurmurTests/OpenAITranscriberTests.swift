@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class FakeCloud: CloudTranscribing {
    var isConfigured = true
    var result: Result<String, CloudTranscriptionError> = .success("Hello from OpenAI.")
    /// What the request reports with a transcript.
    var timing: RequestTiming?
    /// Requests wait for `releaseRequests()`, like a slow network.
    var holdsRequests = false
    private(set) var calls: [(audio: Data, format: EncodedAudio.Format, language: String?, keywords: [String])] = []
    /// When the last request answered.
    private(set) var answeredAt: ContinuousClock.Instant?
    private var held: [CheckedContinuation<Void, Never>] = []

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?,
                    keywords: [String]) async throws(CloudTranscriptionError) -> CloudTranscript {
        calls.append((audio, format, language, keywords))
        if holdsRequests { await withCheckedContinuation { held.append($0) } }
        answeredAt = .now
        return CloudTranscript(text: try result.get(), timing: timing)
    }

    func releaseRequests() {
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

/// Translates everything, reporting its request's timing like `CleanupClient`.
@MainActor
private final class TimedCleanup: Cleaning {
    var isConfigured = true

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?, style: StylePreset,
        dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        CleanupClient.Response(
            text: "Hi from the cloud.", status: "cleaned", words: 4, model: "gpt-test", ttftMs: nil, totalMs: 300,
            remaining: nil, targetLanguage: targetLanguage,
            request: RequestTiming(function: "cleanup", status: 200, tokenMs: 1, totalMs: 310))
    }
}

/// Stands in for the on-device transcriber.
private final class FakeOnDevice: Transcriber, @unchecked Sendable {
    let displayName = "On-device"
    /// How long ending a dictation takes; an analyzer can take a while to finish.
    private let teardownDelay: Duration
    private let lock = NSLock()
    private var _preparedTag: String?
    private var _begun = 0
    private var _appended = 0
    private var _finished = 0
    private var _cancelled = 0
    private var _abandoned = 0

    init(teardownDelay: Duration = .zero) {
        self.teardownDelay = teardownDelay
    }

    var currentLanguage: ResolvedLanguage? { nil }
    var preparedTag: String? { lock.withLock { _preparedTag } }
    var begun: Int { lock.withLock { _begun } }
    var appended: Int { lock.withLock { _appended } }
    var finished: Int { lock.withLock { _finished } }
    var cancelled: Int { lock.withLock { _cancelled } }
    var abandoned: Int { lock.withLock { _abandoned } }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        lock.withLock { _preparedTag = language.tag }
    }
    func setLanguage(_ language: ResolvedLanguage) {}
    func beginUtterance() { lock.withLock { _begun += 1 } }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { _appended += 1 } }
    func finishUtterance() async throws -> String {
        lock.withLock { _finished += 1 }
        return "Recognized on the iPhone."
    }
    func cancelUtterance() async {
        lock.withLock { _cancelled += 1 }
        try? await Task.sleep(for: teardownDelay)
    }
    func abandonUtterance() {
        lock.withLock { _abandoned += 1 }
        Task { [teardownDelay] in try? await Task.sleep(for: teardownDelay) }
    }
    func shutdown() async {}
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// How long an upload is, read back from its file.
private func seconds(of audio: Data, format: EncodedAudio.Format) throws -> Double {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).\(format.rawValue)")
    try audio.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.fileFormat.sampleRate
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

    @Test func automaticLanguageLetsTheCloudDetectIt() async throws {
        let cloud = FakeCloud()
        let automatic = ResolvedLanguage(tag: DictationLanguage.automatic.tag,
                                         locale: Locale(identifier: "en-US"), engine: .speech)
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()
        #expect(cloud.calls.first?.language == nil)
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
        await transcriber.prepareFallback()
        #expect(onDevice.preparedTag == "ru-RU")
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(onDevice.appended > 0)
        #expect(try await transcriber.finishUtterance() == "Recognized on the iPhone.")
    }

    @Test func theSessionDoesNotWaitForTheFallback() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        #expect(onDevice.preparedTag == nil)

        // A dictation before the fallback is ready has none.
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.self) { try await transcriber.finishUtterance() }

        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Recognized on the iPhone.")

        // A reconnect (new mic format) needs it prepared again.
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        #expect(transcriber.displayName == "OpenAI")
    }

    @Test func afterAConnectionFailureTheFallbackIsUsedDirectly() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("The request timed out."))
        let transcriber = OpenAITranscriber(client: cloud, fallback: FakeOnDevice(), fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
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
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")
        // Abandoned: the transcript doesn't wait for the analyzer to wind down.
        #expect(onDevice.abandoned == 1 && onDevice.cancelled == 0)
    }

    /// The keyboard's X, then a new start straight away: the new dictation is recorded from its
    /// first buffer, and nothing of the dropped one goes with it. (A cancel run in a task used
    /// to stop the new dictation capturing, so it sent nothing.)
    @Test func aDictationBegunRightAfterAnAbandonedOneSendsAllItsAudio() async throws {
        let cloud = FakeCloud()
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()

        transcriber.beginUtterance()
        feed(transcriber, seconds: 2)
        transcriber.abandonUtterance()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()

        #expect(cloud.calls.count == 2)
        let reference = try seconds(of: cloud.calls[0].audio, format: cloud.calls[0].format)
        let second = try seconds(of: cloud.calls[1].audio, format: cloud.calls[1].format)
        // About a second either way, give or take the encoder's padding.
        #expect((0.8...1.3).contains(reference))
        #expect(abs(second - reference) < 0.05)
    }

    /// A finish still under way when its dictation is abandoned (later, a hedge that lost) keeps
    /// no timings, and doesn't end the fallback's part in the dictation that began after.
    @Test func aFinishThatOutlivesItsAbandonedDictationTouchesNothing() async throws {
        let cloud = FakeCloud()
        cloud.holdsRequests = true
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()

        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let finishing = Task { try await transcriber.finishUtterance() }
        #expect(await waitUntil { cloud.calls.count == 1 })
        transcriber.abandonUtterance()
        cloud.releaseRequests()
        _ = try await finishing.value
        #expect(transcriber.takeTimings() == nil)
        #expect(onDevice.abandoned == 1)

        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let outlived = Task { try await transcriber.finishUtterance() }
        #expect(await waitUntil { cloud.calls.count == 2 })
        transcriber.abandonUtterance()
        transcriber.beginUtterance()
        cloud.releaseRequests()
        _ = try await outlived.value
        // Once, by the abandon; the late success left the new dictation's alone.
        #expect(onDevice.abandoned == 2)
        #expect(onDevice.finished == 0)
    }

    /// A reconnect can let a dictation begin while the last one is still uploading. The last one's
    /// fallback part is ended then, since its finish can no longer claim it, and only then.
    @Test func aDictationBegunWhileTheLastOneUploadsEndsItsFallbackPart() async throws {
        let cloud = FakeCloud()
        cloud.holdsRequests = true
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let uploading = Task { try await transcriber.finishUtterance() }
        #expect(await waitUntil { cloud.calls.count == 1 })

        // The reconnect prepares the cloud again; the fallback isn't ready for the next dictation.
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        #expect(onDevice.abandoned == 1)
        #expect(onDevice.begun == 1)
        cloud.releaseRequests()
        #expect(try await uploading.value == "Hello from OpenAI.")
        // Its late success ended nothing more.
        #expect(onDevice.abandoned == 1)
        cloud.holdsRequests = false
        #expect(try await transcriber.finishUtterance() == "")

        // With the fallback ready again, the next dictation's part is ended once, by its finish.
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()
        #expect(onDevice.begun == 2)
        #expect(onDevice.abandoned == 2)
    }

    /// Ending the on-device fallback can take its analyzer a second; the cloud transcript
    /// doesn't wait for that, and neither does a dictation too short to send.
    @Test func aSlowFallbackTeardownDoesNotDelayTheFinish() async throws {
        let cloud = FakeCloud()
        let onDevice = FakeOnDevice(teardownDelay: .seconds(1))
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()

        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        // Timed off the main actor, so other tests' work there doesn't count.
        let finishedAt = try await Task.detached { [transcriber] in
            _ = try await transcriber.finishUtterance()
            return ContinuousClock.now
        }.value
        let answeredAt = try #require(cloud.answeredAt)
        #expect(answeredAt.duration(to: finishedAt) < .milliseconds(100))

        transcriber.beginUtterance()
        feed(transcriber, seconds: 0.1)
        let elapsed = try await Task.detached { [transcriber] in
            let started = ContinuousClock.now
            _ = try await transcriber.finishUtterance()
            return started.duration(to: .now)
        }.value
        #expect(elapsed < .milliseconds(100))
        #expect(onDevice.abandoned == 2 && onDevice.cancelled == 0)
    }

    /// A cancelled request says nothing about the network: the next dictation still goes to the
    /// cloud, and the dropped one gets no on-device transcript.
    @Test func aCancelledRequestNeitherPausesTheCloudNorFallsBack() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.cancelled)
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.cancelled) { try await transcriber.finishUtterance() }
        #expect(onDevice.finished == 0)
        #expect(onDevice.abandoned == 1)

        cloud.result = .success("Hello from OpenAI.")
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")
        #expect(cloud.calls.count == 2)
        #expect(onDevice.finished == 0)
        #expect(DictationPipeline.transcriptionMessage(for: CloudTranscriptionError.cancelled)
            == "Couldn't transcribe that. Please try again.")
    }

    /// A signed-out account says nothing about the connection either: the dictation still gets its
    /// on-device transcript, and the next one goes to the cloud again.
    @Test func aSignOutFallsBackWithoutPausingTheCloud() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.signedOut)
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Recognized on the iPhone.")
        // The on-device transcript doesn't say why the cloud didn't answer; the timings do.
        #expect(transcriber.takeTimings()?.cloudFailure == .signedOut)

        cloud.result = .success("Hello from OpenAI.")
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")
        #expect(transcriber.takeTimings()?.cloudFailure == nil)
        #expect(cloud.calls.count == 2)
        #expect(DictationPipeline.transcriptionMessage(for: CloudTranscriptionError.signedOut)
            == "You're signed out. Open Murmur to sign in again.")
    }

    /// With AI cleanup off nothing else asks the cloud, so the refused transcription is the only
    /// word of the sign-out, and the keyboard still gets it with the on-device text.
    @Test func aSignOutReachesTheKeyboardWithoutACleanup() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.signedOut)
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let suite = "test.murmur.pipeline.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: UserDefaults(suiteName: suite))
        settings.aiCleanupEnabled = false
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .formal, language: "ru-RU",
            translationTargetLanguage: nil, source: .keyboard, startedAt: Date())

        let outcome = await DictationPipeline(cleanup: TimedCleanup(), settings: settings).complete(
            dictation, transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

        #expect(outcome.result.isInsertable)
        #expect(outcome.result.text.localizedCaseInsensitiveContains("recognized on the iphone"))
        #expect(outcome.result.message == "You're signed out. Open Murmur to sign in again.")
        #expect(outcome.timings?.cloudTranscript == false)
    }

    @Test func withoutAnInstalledModelAFailureIsReported() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.limitReached)
        let onDevice = FakeOnDevice()
        // Only English is installed on the device; this dictation is in Russian.
        let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["en-US": english])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        #expect(onDevice.preparedTag == nil)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }
        #expect(DictationPipeline.transcriptionMessage(for: CloudTranscriptionError.limitReached)
            == "Dictation limit reached. Get unlimited access in Murmur.")
    }

    @Test func measuresTheEncodingAndKeepsTheRequestsTiming() async throws {
        let cloud = FakeCloud()
        let request = RequestTiming(function: "transcribe", status: 200, tokenMs: 3, totalMs: 640, reused: true)
        cloud.timing = request
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 2)
        _ = try await transcriber.finishUtterance()

        let timings = try #require(transcriber.takeTimings())
        #expect((timings.encodeMs ?? -1) >= 0)
        #expect(timings.audioBytes == cloud.calls.first?.audio.count)
        #expect(timings.requests == [request])
        #expect(timings.cloudTranscript)
        // Taken once.
        #expect(transcriber.takeTimings() == nil)
    }

    @Test func aFailedRequestStillReportsTheEncoding() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.self) { try await transcriber.finishUtterance() }

        let timings = try #require(transcriber.takeTimings())
        #expect(timings.encodeMs != nil)
        #expect((timings.audioBytes ?? 0) > 0)
        #expect(timings.requests.isEmpty)
        #expect(!timings.cloudTranscript)
    }

    @Test func aNewDictationStartsWithoutTheLastOnesTimings() async throws {
        let transcriber = OpenAITranscriber(client: FakeCloud())
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()
        transcriber.beginUtterance()
        #expect(transcriber.takeTimings() == nil)
    }

    /// The pipeline puts the transcriber's and the cleanup's numbers together, and no text.
    @Test func theOutcomeCarriesTheTimingsButNoText() async throws {
        let cloud = FakeCloud()
        cloud.timing = RequestTiming(function: "transcribe", status: 200, tokenMs: 3, totalMs: 640)
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        var dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .formal, language: "ru-RU",
            translationTargetLanguage: "en-US", source: .keyboard, startedAt: Date())
        dictation.stopRequestedAt = Date().addingTimeInterval(-0.05)
        dictation.tapToStopMs = 50

        let outcome = await DictationPipeline(cleanup: TimedCleanup()).complete(
            dictation, transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

        #expect(outcome.result.text == "Hi from the cloud.")
        let timings = try #require(outcome.timings)
        #expect(timings.requestId == dictation.requestId)
        #expect(timings.kind == .translation)
        #expect(timings.createdAt == outcome.result.createdAt)
        #expect(timings.stopRequestedAt == dictation.stopRequestedAt)
        #expect(timings.tapToStopMs == 50)
        #expect(timings.requests.map(\.function) == ["transcribe", "cleanup"])
        #expect(timings.tokenMs == 4)
        #expect(timings.audioBytes == cloud.calls.first?.audio.count)
        #expect(timings.stopToResultMs == outcome.result.metrics?.stopToResultMs)
        #expect(timings.status == "cleaned")
        #expect(timings.insertable == true)
        #expect(timings.cloudTranscript == true)
        #expect(timings.cleanupModel == "gpt-test")
        let line = String(decoding: try JSONEncoder().encode(timings), as: UTF8.self)
        #expect(!line.contains("Hello") && !line.contains("cloud."))
    }

    /// A failed transcription still logs how long the user waited for the notice, and is kept
    /// out of the cloud rows.
    @Test func aFailedTranscriptionLogsItsWait() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .formal, language: "ru-RU",
            translationTargetLanguage: nil, source: .keyboard, startedAt: Date())

        let outcome = await DictationPipeline(cleanup: TimedCleanup()).complete(
            dictation, transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

        let timings = try #require(outcome.timings)
        #expect(timings.status == "failed")
        #expect(timings.cloudTranscript == false)
        #expect(timings.stopToResultMs != nil)
        #expect(timings.encodeMs != nil)
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
