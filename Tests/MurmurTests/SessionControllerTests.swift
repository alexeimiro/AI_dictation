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
                    keywords: [String], dictationId: UUID?) async throws(CloudTranscriptionError) -> CloudTranscript {
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

/// How often the session asked "Before Murmur listens".
@MainActor
private final class ConsentSpy {
    var count = 0
}

/// Whether someone is signed in, as the session asks it.
@MainActor
private final class SignedInSpy {
    var value = true
}

@MainActor
struct SessionControllerTests {
    private struct Harness {
        let session: SessionController
        let transport: InMemoryIPCTransport
        let log: TimingsLog
        let history: HistorySpy

        func send(_ kind: CommandKind, _ requestId: UUID, at createdAt: Date = Date(),
                  listeningSince: Date? = nil) throws {
            try transport.payloads.write(command: KeyboardCommand(
                requestId: requestId, kind: kind, createdAt: createdAt, listeningSince: listeningSince))
            transport.post(.command)
        }
    }

    private let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
    private let micFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// A ready session on the in-memory transport, with its own settings (no sounds) and log.
    /// `signedIn` comes last, so a trailing closure still means `configure`.
    private func makeHarness(transcriber: Transcriber = SpokenTranscriber(), recordings: RecordingStore? = nil,
                             configure: (SharedSettings) -> Void = { _ in },
                             signedIn: @escaping @MainActor () -> Bool = { true }) -> Harness {
        let transport = InMemoryIPCTransport()
        let log = TimingsLog(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("session-timings-\(UUID().uuidString)", isDirectory: true))
        let history = HistorySpy()
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.session.\(UUID().uuidString)"))
        settings.interactionSounds = false
        configure(settings)
        let session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoCleanup()), assets: SpeechAssetManager(),
            history: history, recordings: recordings, timingsLog: log, settings: settings, signedIn: signedIn)
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

    /// "Not now" to sending recordings to the AI services: the session doesn't start (so nothing
    /// is recorded), and the keyboard is told why, as for any failed start.
    @Test func withoutTheOKForTheAIServicesTheSessionDoesNotStart() async {
        let transport = InMemoryIPCTransport()
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.session.\(UUID().uuidString)"))
        let session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoCleanup()), assets: SpeechAssetManager(),
            history: HistorySpy(), settings: settings, consent: { false })

        await session.start()

        let message = SessionController.SessionError.aiNotAllowed.localizedDescription
        #expect(session.phase == .failed(message))
        #expect(!session.isLive)
        #expect(transport.payloads.readSessionFailure()?.message == message)
        #expect(transport.currentState().status == .error)
        #expect(session.beginInAppDictation() == nil)
    }

    /// Sign-in is required: while nobody is signed in no session starts, and the AI question
    /// doesn't even come up. The keyboard hears why, as it does for any start that fails.
    @Test func signedOutTheSessionDoesNotStart() async {
        let transport = InMemoryIPCTransport()
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.session.\(UUID().uuidString)"))
        let asked = ConsentSpy()
        let session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoCleanup()), assets: SpeechAssetManager(),
            history: HistorySpy(), settings: settings, consent: { asked.count += 1; return true }, signedIn: { false })

        await session.start()

        let message = SessionController.SessionError.signedOut.localizedDescription
        #expect(session.phase == .failed(message))
        #expect(!session.isLive)
        #expect(asked.count == 0)
        #expect(transport.payloads.readSessionFailure()?.message == message)
        #expect(transport.currentState().status == .error)
        #expect(session.beginInAppDictation() == nil)
    }

    /// The account went while a dictation was under way (its own request can be the one that
    /// finds out): its words still reach the keyboard, and then the session ends rather than wait
    /// for a dictation nobody may make.
    @Test func aDictationUnderWayWhenTheAccountGoesIsDeliveredThenTheSessionEnds() async throws {
        let account = SignedInSpy()
        let harness = makeHarness(signedIn: { account.value })
        let requestId = UUID()
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })

        account.value = false
        try harness.send(.stop, requestId)

        #expect(await waitUntil { harness.session.phase == .off })
        #expect(harness.transport.payloads.readResult(requestId)?.isInsertable == true)
        #expect(harness.transport.currentState().status == .off)
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

    /// A dictation the app ends itself (the time cap, a lost heartbeat) has no stop command. And
    /// nobody tapped the keyboard for a note's mic, so it has no start to time either.
    @Test func aDictationTheAppEndsHasNoStopTime() async throws {
        let harness = makeHarness()
        let requestId = try #require(harness.session.beginInAppDictation())
        harness.session.endDictation(commit: true)
        #expect(await waitUntil { !harness.log.all().isEmpty })

        let entry = try #require(harness.log.all().first)
        #expect(entry.requestId == requestId)
        #expect(entry.stopRequestedAt == nil && entry.tapToStopMs == nil)
        #expect(entry.startPath == nil && entry.startRequestedAt == nil && entry.tapToStartMs == nil)
        #expect(entry.tapToListeningMs == nil && entry.jump == nil)
    }

    /// The tap on the mic with the session on: when it was, how long the app took to be recording
    /// and how long the keyboard took to show it, which the keyboard reports with its stop.
    @Test func theStartOfAHotDictationReachesTheTimingsLog() async throws {
        let harness = makeHarness()
        let requestId = UUID()
        // Whole seconds survive the command file's millisecond encoding exactly.
        let tappedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 1)
        let sentAt = Date()
        try harness.send(.start, requestId, at: tappedAt)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })
        let recordingBy = Date()

        try harness.send(.stop, requestId, listeningSince: tappedAt.addingTimeInterval(0.25))
        #expect(await waitUntil { !harness.log.all().isEmpty })

        let entry = try #require(harness.log.all().first)
        #expect(entry.startPath == DictationTimings.StartPath.hot.rawValue)
        #expect(entry.startRequestedAt == tappedAt)
        let tapToStart = try #require(entry.tapToStartMs)
        #expect((sentAt.milliseconds(since: tappedAt)...recordingBy.milliseconds(since: tappedAt)).contains(tapToStart))
        #expect(entry.tapToListeningMs == 250)
        #expect(entry.jump == nil)
    }

    /// A keyboard whose clock reading makes no sense (listening before the tap) isn't believed.
    @Test func aListeningTimeBeforeTheTapIsLeftOut() async throws {
        let harness = makeHarness()
        let requestId = UUID()
        let tappedAt = Date()
        try harness.send(.start, requestId, at: tappedAt)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })
        try harness.send(.stop, requestId, listeningSince: tappedAt.addingTimeInterval(-3))
        #expect(await waitUntil { !harness.log.all().isEmpty })

        let entry = try #require(harness.log.all().first)
        #expect(entry.tapToStartMs != nil)
        #expect(entry.tapToListeningMs == nil)
    }

    /// The keyboard opened the app for a dictation: its timings count from the tap, which was
    /// before the request when the keyboard first waited for a session that didn't answer, and
    /// they keep the steps of the start. The session here is already on, so there is no
    /// microphone to turn on and those steps stay empty.
    @Test func theStartOfADictationTheAppWasOpenedForReachesTheTimingsLog() async throws {
        let harness = makeHarness()
        let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let tappedAt = createdAt.addingTimeInterval(-0.5)
        let request = PendingStart(requestId: UUID(), documentIdentifier: nil, createdAt: createdAt, autoStart: true,
                                   tappedAt: tappedAt)
        try harness.transport.payloads.write(pendingStart: request)

        await harness.session.start(beginning: request)

        #expect(harness.session.phase == .recording(request.requestId))
        harness.session.didReturnToHost(for: request.requestId)
        // The keyboard is back and joins the dictation, then stops it.
        let attachedAt = Date()
        try harness.send(.stop, request.requestId, listeningSince: attachedAt)
        #expect(await waitUntil { !harness.log.all().isEmpty })

        let entry = try #require(harness.log.all().first)
        #expect(entry.startPath == DictationTimings.StartPath.jump.rawValue)
        #expect(entry.startRequestedAt == tappedAt)
        let tapToStart = try #require(entry.tapToStartMs)
        #expect(tapToStart >= 500)
        let tapToListening = try #require(entry.tapToListeningMs)
        #expect(abs(tapToListening - attachedAt.milliseconds(since: tappedAt)) <= 1)
        let jump = try #require(entry.jump)
        #expect(jump.waitedMs == 500)
        let link = try #require(jump.linkMs)
        #expect(link >= 500 && link <= tapToStart)
        #expect(try #require(jump.appAgeMs) > 0)
        #expect(try #require(jump.returnMs) >= tapToStart)
        #expect(jump.audioSessionMs == nil && jump.engineMs == nil && jump.readyMs == nil && jump.liveActivityMs == nil)
    }

    /// A request the app was opened for and then dropped (the keyboard cancelled it, so its
    /// pending start is gone) takes its timings with it: the next dictation is timed as its own.
    @Test func aDroppedRequestTakesItsTimingsWithIt() async throws {
        let harness = makeHarness()
        let opened = PendingStart(requestId: UUID(), documentIdentifier: nil, createdAt: Date(), autoStart: true)
        await harness.session.start(beginning: opened)
        #expect(harness.session.phase == .ready)

        let next = UUID()
        try harness.send(.start, next)
        #expect(await waitUntil { harness.session.phase == .recording(next) })
        harness.session.endDictation(commit: true)
        #expect(await waitUntil { !harness.log.all().isEmpty })

        let entry = try #require(harness.log.all().first)
        #expect(entry.requestId == next)
        #expect(entry.startPath == DictationTimings.StartPath.hot.rawValue)
        #expect(entry.jump == nil)
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
        // Nobody tapped the keyboard for it: there is no start to time.
        #expect(await waitUntil { !harness.log.all().isEmpty })
        let entry = try #require(harness.log.all().first)
        #expect(entry.startPath == nil && entry.tapToStartMs == nil && entry.jump == nil)
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
