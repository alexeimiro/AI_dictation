@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

private final class SpokenTranscriber: Transcriber, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { "see you at five" }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        UtteranceOutput(transcript: try await finishUtterance())
    }
    func cancelUtterance() async {}
    func abandonUtterance() {}
    func shutdown() async {}
}

/// The cloud as `OpenAITranscriber` sees it, keeping each upload.
@MainActor
private final class RecordingCloud: CloudTranscribing {
    let isConfigured = true
    private(set) var uploads: [(audio: Data, format: EncodedAudio.Format)] = []

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                    keywords: [String]) async throws(CloudTranscriptionError) -> CloudTranscript {
        uploads.append((audio, format))
        return CloudTranscript(text: "see you at five", timing: nil)
    }
}

/// No cleanup service: the transcript is formatted on the iPhone.
@MainActor
private final class NoCleanup: Cleaning {
    let isConfigured = false

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?, style: StylePreset,
        dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        throw .notConfigured
    }
}

/// Runs `check` as each transcript reaches history, to see what had happened by then.
@MainActor
private final class HistorySpy: TranscriptSink {
    var check: () -> Bool = { true }
    private(set) var checks: [Bool] = []

    func record(_ transcript: Transcript) { checks.append(check()) }
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

@MainActor
struct SessionControllerTests {
    private struct Harness {
        let session: SessionController
        let transport: InMemoryIPCTransport
        let log: TimingsLog
        let history: HistorySpy

        func send(_ kind: CommandKind, _ requestId: UUID, at createdAt: Date = Date()) throws {
            try transport.payloads.write(command: KeyboardCommand(requestId: requestId, kind: kind, createdAt: createdAt))
            transport.post(.command)
        }
    }

    private let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
    private let micFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// A ready session on the in-memory transport, with its own settings (no sounds) and log.
    private func makeHarness(transcriber: Transcriber = SpokenTranscriber(), recordings: RecordingStore? = nil,
                             configure: (SharedSettings) -> Void = { _ in }) -> Harness {
        let transport = InMemoryIPCTransport()
        let log = TimingsLog(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("session-timings-\(UUID().uuidString)", isDirectory: true))
        let history = HistorySpy()
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.session.\(UUID().uuidString)"))
        settings.interactionSounds = false
        configure(settings)
        let session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoCleanup()), assets: SpeechAssetManager(),
            history: history, recordings: recordings, timingsLog: log, settings: settings)
        session.startForTesting(with: transcriber, language: english)
        return Harness(session: session, transport: transport, log: log, history: history)
    }

    /// A transcriber on `cloud`, ready for the session; there's no microphone, so the tests
    /// hand it the audio (`feed`).
    private func cloudTranscriber(_ cloud: RecordingCloud) async throws -> OpenAITranscriber {
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: english)
        return transcriber
    }

    /// `seconds` of a 440 Hz tone in 4096-frame buffers, as the mic tap delivers them.
    private func feed(_ transcriber: Transcriber, seconds: Double) {
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

    /// How long an upload is, read back from its file.
    private func seconds(of upload: (audio: Data, format: EncodedAudio.Format)) throws -> Double {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).\(upload.format.rawValue)")
        try upload.audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// The keyboard's stop command, when it was sent and how long it took to reach the app, ends
    /// up in the timings log, which is written once the keyboard has its result and history its
    /// transcript.
    @Test func theStopCommandReachesTheTimingsLog() async throws {
        let harness = makeHarness()
        let requestId = UUID()
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })

        // Whole seconds survive the command file's millisecond encoding exactly.
        let tappedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 1)
        harness.history.check = { [transport = harness.transport, log = harness.log] in
            transport.payloads.readResult(requestId) != nil && log.all().isEmpty
        }
        let sentAt = Date()
        try harness.send(.stop, requestId, at: tappedAt)
        #expect(await waitUntil { !harness.log.all().isEmpty })

        let entry = try #require(harness.log.all().first)
        #expect(entry.requestId == requestId)
        #expect(entry.stopRequestedAt == tappedAt)
        let tapToStop = try #require(entry.tapToStopMs)
        #expect((sentAt.milliseconds(since: tappedAt)...Date().milliseconds(since: tappedAt)).contains(tapToStop))
        #expect(harness.history.checks == [true])
    }

    /// A dictation the app ends itself (the time cap, a lost heartbeat) has no stop command.
    @Test func aDictationTheAppEndsHasNoStopTime() async throws {
        let harness = makeHarness()
        let requestId = try #require(harness.session.beginInAppDictation())
        harness.session.endDictation(commit: true)
        #expect(await waitUntil { !harness.log.all().isEmpty })

        let entry = try #require(harness.log.all().first)
        #expect(entry.requestId == requestId)
        #expect(entry.stopRequestedAt == nil && entry.tapToStopMs == nil)
    }

    /// The keyboard went off screen with the dictation running (the screen locked): its heartbeats
    /// stop, and the app records on instead of finishing it after 4 s, until the keyboard is back.
    @Test func anAwayDictationOutlivesItsHeartbeats() async throws {
        let harness = makeHarness()
        let requestId = UUID()
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })
        let startedAt = Date()
        try harness.transport.payloads.write(keyboardStatus: KeyboardStatus(
            fullAccessAt: startedAt, lastSeenAt: startedAt, listeningRequestId: requestId, listeningHeartbeatAt: startedAt))
        try await Task.sleep(for: .seconds(1.5))
        try harness.transport.payloads.write(keyboardStatus: KeyboardStatus(
            fullAccessAt: startedAt, lastSeenAt: startedAt, hiddenAt: Date(), awayRequestId: requestId,
            awayListeningSince: startedAt))

        try await Task.sleep(for: .seconds(5.5))

        #expect(harness.session.phase == .recording(requestId))
        try harness.send(.stop, requestId)
        #expect(await waitUntil { harness.transport.payloads.readResult(requestId) != nil })
    }

    /// X, then the mic again straight away: the second dictation records and is delivered. The
    /// in-memory transport hands over each command in a turn of its own, so the race itself shows
    /// in the next test.
    @Test func aStartRightAfterACancelRecords() async throws {
        let cloud = RecordingCloud()
        let transcriber = try await cloudTranscriber(cloud)
        let harness = makeHarness(transcriber: transcriber)
        let cancelled = UUID(), next = UUID()
        try harness.send(.start, cancelled)
        #expect(await waitUntil { harness.session.phase == .recording(cancelled) })
        feed(transcriber, seconds: 1)
        try harness.send(.cancel, cancelled)
        #expect(await waitUntil { harness.session.phase == .ready })
        try harness.send(.start, next)
        #expect(await waitUntil { harness.session.phase == .recording(next) })
        feed(transcriber, seconds: 1)
        try harness.send(.stop, next)
        #expect(await waitUntil { harness.transport.payloads.readResult(next) != nil })

        #expect(harness.transport.payloads.readResult(next)?.isInsertable == true)
        #expect(cloud.uploads.count == 1)
        let length = try seconds(of: #require(cloud.uploads.first))
        #expect(abs(length - 1) < 0.3)
    }

    /// A start from a keyboard that doesn't know the dictation under way, which nobody attached
    /// to: `handleStart` drops that one and begins the new one in the same turn. A teardown run in
    /// a task landed on the new one, which then sent nothing; now it records and is delivered.
    @Test func aStartThatReplacesAnUnclaimedDictationRecords() async throws {
        let cloud = RecordingCloud()
        let transcriber = try await cloudTranscriber(cloud)
        let harness = makeHarness(transcriber: transcriber)
        let unclaimed = UUID(), next = UUID()
        try harness.send(.start, unclaimed)
        #expect(await waitUntil { harness.session.phase == .recording(unclaimed) })
        feed(transcriber, seconds: 1)
        try harness.send(.start, next)
        #expect(await waitUntil { harness.session.phase == .recording(next) })
        #expect(harness.transport.payloads.readResult(unclaimed)?.status == .cancelled)
        feed(transcriber, seconds: 1)
        try harness.send(.stop, next)
        #expect(await waitUntil { harness.transport.payloads.readResult(next) != nil })

        #expect(harness.transport.payloads.readResult(next)?.isInsertable == true)
        #expect(cloud.uploads.count == 1)
        let length = try seconds(of: #require(cloud.uploads.first))
        #expect(abs(length - 1) < 0.3)
    }

    /// The Action Button with the Murmur keyboard on screen: the app records a dictation the
    /// keyboard can join (a pending start with the keyboard's options), as after a bounce.
    @Test func aShortcutStartsADictationTheKeyboardJoins() async throws {
        let harness = makeHarness { settings in
            settings.defaultStyle = .grammar
            settings.autoDetectDefaultApplied = true
            settings.translationSourceLanguage = "en-US"
            settings.translationEnabled = true
            settings.translationTargetLanguage = "de-DE"
        }
        #expect(harness.session.beginDictationForKeyboard())
        let pending = try #require(harness.transport.payloads.readPendingStart())
        #expect(pending.autoStart == true && pending.documentIdentifier == nil)
        #expect(pending.styleOverride == .grammar && pending.languageOverride == "en-US")
        #expect(pending.translationTargetLanguage == "de-DE")
        #expect(harness.session.phase == .recording(pending.requestId))
        harness.session.endDictation(commit: true)
        #expect(await waitUntil { harness.transport.payloads.readResult(pending.requestId) != nil })
    }

    /// The mic in a note: the result goes to the note, not to the keyboard's files.
    @Test func anInAppDictationGoesToItsHandler() async throws {
        let harness = makeHarness()
        var delivered: [DictationResult] = []
        harness.session.inAppResultHandler = { delivered.append($0) }
        let requestId = try #require(harness.session.beginInAppDictation())
        harness.session.endDictation(commit: true)
        #expect(await waitUntil { !delivered.isEmpty })
        #expect(delivered.first?.requestId == requestId)
        #expect(harness.transport.payloads.readResult(requestId) == nil)
    }

    /// The uploaded audio is kept for the transcript's playback, unless Keep recordings is off.
    @Test(arguments: [true, false])
    func theRecordingIsKeptWithTheTranscript(keep: Bool) async throws {
        let cloud = RecordingCloud()
        let transcriber = try await cloudTranscriber(cloud)
        let recordings = RecordingStore.temporary()
        defer { recordings.deleteAll() }
        let harness = makeHarness(transcriber: transcriber, recordings: recordings) { $0.keepRecordings = keep }
        let requestId = try #require(harness.session.beginInAppDictation())
        feed(transcriber, seconds: 1)
        harness.session.endDictation(commit: true)
        #expect(await waitUntil { harness.history.checks.count == 1 })
        #expect((recordings.url(for: requestId) != nil) == keep)
    }
}
