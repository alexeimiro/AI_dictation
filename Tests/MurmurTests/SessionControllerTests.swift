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

/// Counts what the session asks of it. With `holds`, a finished dictation waits for `release()`,
/// like an upload still out, and notes whether its task was cancelled by then.
private final class GatedTranscriber: Transcriber, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?
    var holds = false
    private(set) var finishes = 0
    private(set) var abandoned = 0
    private(set) var cancelledWhileOut = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { "meet me at the station" }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        finishes += 1
        if holds, !released {
            await withCheckedContinuation { waiting = $0 }
        }
        cancelledWhileOut = Task.isCancelled
        return UtteranceOutput(transcript: try await finishUtterance())
    }
    func cancelUtterance() async {}
    func abandonUtterance() { abandoned += 1 }
    func shutdown() async {}

    @MainActor
    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

/// A transcriber with an on-device model's words for the keyboard, which the test speaks (`say`).
/// It keeps every dictation's handler after the dictation ended, as a recognizer still at work
/// could, so a test can report words late. With `holds`, a finished dictation waits for
/// `release()`, like an upload still out.
private final class PreviewingTranscriber: Transcriber, LiveWordsProviding, @unchecked Sendable {
    static let transcript = "meet me at the station"

    let displayName = "Test"
    private let lock = NSLock()
    private var language: ResolvedLanguage?
    private var _previews = true
    private var _holds = false
    private var _plainBegins = 0
    private var _liveBegins = 0
    private var _finishes = 0
    private var _abandoned = 0
    /// One for each dictation begun with live words, in order.
    private var handlers: [LiveWordsHandler] = []
    private var _atFinish: (@Sendable () -> Bool)?
    private var _finishChecks: [Bool] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    /// Whether an on-device model listens to the next dictation, and so has words for it.
    var previews: Bool {
        get { lock.withLock { _previews } }
        set { lock.withLock { _previews = newValue } }
    }
    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }
    /// Run as each dictation is finished, which is when its audio would be sent.
    var atFinish: (@Sendable () -> Bool)? {
        get { lock.withLock { _atFinish } }
        set { lock.withLock { _atFinish = newValue } }
    }
    /// The dictations begun without live words.
    var plainBegins: Int { lock.withLock { _plainBegins } }
    /// The dictations begun with live words, whether or not it had any for them.
    var liveBegins: Int { lock.withLock { _liveBegins } }
    var finishes: Int { lock.withLock { _finishes } }
    var abandoned: Int { lock.withLock { _abandoned } }
    var finishChecks: [Bool] { lock.withLock { _finishChecks } }

    var currentLanguage: ResolvedLanguage? { lock.withLock { language } }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        lock.withLock { self.language = language }
    }
    func setLanguage(_ language: ResolvedLanguage) { lock.withLock { self.language = language } }
    func beginUtterance() { lock.withLock { _plainBegins += 1 } }
    func beginUtterance(liveWords handler: @escaping LiveWordsHandler) -> Bool {
        lock.withLock {
            _liveBegins += 1
            handlers.append(handler)
            return _previews
        }
    }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { Self.transcript }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        let (check, hold) = lock.withLock { () -> ((@Sendable () -> Bool)?, Bool) in
            _finishes += 1
            return (_atFinish, _holds && !released)
        }
        if let check {
            let passed = check()
            lock.withLock { _finishChecks.append(passed) }
        }
        if hold {
            await withCheckedContinuation { continuation in
                let free = lock.withLock { () -> Bool in
                    if released { return true }
                    waiting.append(continuation)
                    return false
                }
                if free { continuation.resume() }
            }
        }
        return UtteranceOutput(transcript: try await finishUtterance())
    }
    func cancelUtterance() async {}
    func abandonUtterance() { lock.withLock { _abandoned += 1 } }
    func shutdown() async {}

    /// The words recognized so far, reported as the recognizer of the dictation begun `dictation`th
    /// with live words would (the last one by default), whether or not that dictation has ended.
    func say(_ settled: String, _ unsettled: String = "", dictation: Int? = nil) {
        let handler = lock.withLock { dictation.map { handlers[$0] } ?? handlers.last }
        handler?(settled, unsettled)
    }

    func release() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { waiting = [] }
            return waiting
        }
        held.forEach { $0.resume() }
    }
}

/// Forwards to an in-memory transport and notes what the hot state said each time the preview was
/// announced: what a keyboard that polls the state could have read by then.
private final class StateAtPreviewTransport: IPCTransport, @unchecked Sendable {
    let inner = InMemoryIPCTransport()
    private let lock = NSLock()
    private var statuses: [SessionStatus] = []

    var statusAtEachPreview: [SessionStatus] { lock.withLock { statuses } }
    var payloads: IPCPayloadStore { inner.payloads }
    func publish(_ state: HotState) { inner.publish(state) }
    func currentState() -> HotState { inner.currentState() }
    func post(_ event: IPCEvent) {
        if event == .livePreview {
            let status = inner.currentState().status
            lock.withLock { statuses.append(status) }
        }
        inner.post(event)
    }
    func observe(_ event: IPCEvent, handler: @escaping @Sendable () -> Void) -> IPCObservation {
        inner.observe(event, handler: handler)
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

/// Whether the iPhone is locked, as the session asks it.
@MainActor
private final class LockSpy {
    var locked = false
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
    /// `signedIn` and `locked` come after `configure`, so a trailing closure still means `configure`.
    private func makeHarness(transcriber: Transcriber = SpokenTranscriber(), recordings: RecordingStore? = nil,
                             configure: (SharedSettings) -> Void = { _ in },
                             signedIn: @escaping @MainActor () -> Bool = { true },
                             locked: @escaping @MainActor () -> Bool = { false },
                             lockTimeout: TimeInterval = IdleStop.lockTimeout) -> Harness {
        let transport = InMemoryIPCTransport()
        let log = TimingsLog(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("session-timings-\(UUID().uuidString)", isDirectory: true))
        let history = HistorySpy()
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.session.\(UUID().uuidString)"))
        settings.interactionSounds = false
        configure(settings)
        let session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoCleanup()), assets: SpeechAssetManager(),
            history: history, recordings: recordings, timingsLog: log, settings: settings, signedIn: signedIn,
            protectedDataAvailable: { !locked() }, lockTimeout: lockTimeout)
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

    /// The week's free words are used up: the Action Button records nothing, and the keyboard
    /// hears why (its card leads to Pro). Nothing goes into the history.
    @Test func withTheWordsUsedUpAShortcutRecordsNothing() async throws {
        let harness = makeHarness { settings in settings.noteWordsUsedUp() }
        #expect(harness.session.beginDictationForKeyboard())
        let pending = try #require(harness.transport.payloads.readPendingStart())
        #expect(await waitUntil { harness.transport.payloads.readResult(pending.requestId) != nil })
        let result = try #require(harness.transport.payloads.readResult(pending.requestId))
        #expect(result.status == .limitReached && result.text.isEmpty)
        #expect(result.message == Brand.limitReachedMessage)
        #expect(await waitUntil { harness.session.phase == .ready })
        #expect(harness.history.checks.isEmpty)
    }

    /// With "Turn off after: Immediately", a start that waited for the dictation which used the
    /// last words is still told why it was turned down, before the session turns off.
    @Test func aQueuedStartTurnedDownAtTheLimitIsToldWhy() async throws {
        let transcriber = GatedTranscriber()
        transcriber.holds = true
        var settings: SharedSettings?
        let harness = makeHarness(transcriber: transcriber) { shared in
            shared.disableAfter = .immediately
            settings = shared
        }
        let first = UUID(), queued = UUID()
        try harness.send(.start, first)
        #expect(await waitUntil { harness.session.phase == .recording(first) })
        try harness.send(.stop, first)
        #expect(await waitUntil { transcriber.finishes == 1 })
        try harness.send(.start, queued)
        #expect(await waitUntil { harness.transport.currentState().requestTag == queued.tag16 })
        settings?.noteWordsUsedUp()
        transcriber.release()

        #expect(await waitUntil { harness.transport.payloads.readResult(queued) != nil })
        let result = try #require(harness.transport.payloads.readResult(queued))
        #expect(result.status == .limitReached && result.message == Brand.limitReachedMessage)
    }

    /// A note's mic doesn't start a dictation either.
    @Test func withTheWordsUsedUpANoteRecordsNothing() {
        let harness = makeHarness { settings in settings.noteWordsUsedUp() }
        #expect(harness.session.wordsUsedUp)
        #expect(harness.session.beginInAppDictation() == nil)
        #expect(harness.session.phase == .ready)
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

    // MARK: Discarding: the OK to the AI services taken back, or the account ended

    /// A dictation being recorded is dropped, not finished: nothing is transcribed or sent, nothing
    /// reaches history, and the keyboard waiting for it is told it was cancelled.
    @Test func aDiscardedRecordingIsNeitherSentNorSaved() async throws {
        let transcriber = GatedTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let request = UUID()
        try harness.send(.start, request)
        #expect(await waitUntil { harness.session.phase == .recording(request) })

        harness.session.discardDictations()
        try await Task.sleep(for: .milliseconds(200))

        #expect(transcriber.finishes == 0, "nothing transcribed, so nothing uploaded")
        #expect(transcriber.abandoned == 1)
        #expect(harness.history.checks.isEmpty, "nothing in history")
        #expect(harness.transport.payloads.readResult(request)?.status == .cancelled)
        #expect(harness.transport.payloads.latestResult()?.requestId != request, "not offered to insert later")
        #expect(harness.log.all().isEmpty)
    }

    /// One already being written (its upload out) when the account ends: its requests are
    /// cancelled, and its text is neither typed nor saved into the history being wiped.
    @Test func aDiscardedDictationBeingWrittenIsNeitherTypedNorSaved() async throws {
        let transcriber = GatedTranscriber()
        transcriber.holds = true
        let harness = makeHarness(transcriber: transcriber)
        let request = UUID()
        try harness.send(.start, request)
        #expect(await waitUntil { harness.session.phase == .recording(request) })
        try harness.send(.stop, request)
        #expect(await waitUntil { transcriber.finishes == 1 })
        #expect(harness.session.phase == .processing(request))

        harness.session.discardDictations()
        transcriber.release()
        try await Task.sleep(for: .milliseconds(300))

        #expect(transcriber.cancelledWhileOut, "its task was cancelled, and its requests with it")
        #expect(harness.history.checks.isEmpty, "nothing in history")
        #expect(harness.transport.payloads.readResult(request)?.status == .cancelled, "nothing typed")
        #expect(harness.log.all().isEmpty)
    }

    /// Without discarding, a dictation that is being written still finishes as before.
    @Test func aDictationBeingWrittenFinishesWhenNothingDiscardsIt() async throws {
        let transcriber = GatedTranscriber()
        transcriber.holds = true
        let harness = makeHarness(transcriber: transcriber)
        let request = UUID()
        try harness.send(.start, request)
        #expect(await waitUntil { harness.session.phase == .recording(request) })
        try harness.send(.stop, request)
        #expect(await waitUntil { transcriber.finishes == 1 })
        transcriber.release()

        #expect(await waitUntil { harness.history.checks.count == 1 })
        #expect(!transcriber.cancelledWhileOut)
        #expect(harness.transport.payloads.readResult(request)?.text.isEmpty == false)
    }

    // MARK: Live words: the keyboard's preview of the dictation being recorded

    /// How often the session wrote or removed the preview.
    private func previewPosts(_ harness: Harness) -> Int {
        harness.transport.postedEvents.filter { $0 == .livePreview }.count
    }

    /// Long enough for words reported late to have reached the main queue and, had they been
    /// taken, the file: more than the publisher's quarter of a second between writes.
    private func waitForLateWords() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    /// A dictation the keyboard asked for, recording, with `words` on the keyboard.
    private func record(_ requestId: UUID, saying words: String, with transcriber: PreviewingTranscriber,
                        on harness: Harness) async throws {
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })
        transcriber.say(words)
        #expect(await waitUntil { harness.transport.payloads.readLivePreview()?.settled == words })
    }

    /// An on-device model hears the dictation: its preview is there, empty, before the keyboard
    /// can read that the app is recording, so the keyboard lays its listening screen out once.
    /// The keyboard reads that from the state it polls as well as from the event, so both come
    /// after the preview.
    @Test func aKeyboardDictationPublishesItsPreviewBeforeItReportsRecording() async throws {
        let transcriber = PreviewingTranscriber()
        let transport = StateAtPreviewTransport()
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.session.\(UUID().uuidString)"))
        settings.interactionSounds = false
        let session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoCleanup()), assets: SpeechAssetManager(),
            history: HistorySpy(), settings: settings)
        session.startForTesting(with: transcriber, language: english)
        let requestId = UUID()
        try transport.payloads.write(command: KeyboardCommand(requestId: requestId, kind: .start, createdAt: Date()))
        transport.post(.command)
        #expect(await waitUntil { session.phase == .recording(requestId) })

        #expect(transport.payloads.readLivePreview() == LivePreview(requestId: requestId))
        #expect(transcriber.liveBegins == 1 && transcriber.plainBegins == 0)
        // Announced once, while the state the keyboard polls did not say `recording` yet.
        #expect(transport.statusAtEachPreview.count == 1)
        #expect(transport.statusAtEachPreview.first != .recording)
        let events = transport.inner.postedEvents
        let preview = try #require(events.firstIndex(of: .livePreview))
        let recording = try #require(events.lastIndex(of: .stateChanged))
        #expect(preview < recording)
        #expect(transport.currentState().status == .recording)
        session.endDictation(commit: false)
        #expect(transport.payloads.readLivePreview() == nil)
    }

    /// What the recognizer has heard so far reaches the keyboard's file while the dictation is
    /// recorded, settled and unsettled words apart, and each change is announced.
    @Test func theWordsReachTheKeyboardWhileRecording() async throws {
        let transcriber = PreviewingTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let requestId = UUID()
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })

        transcriber.say("see you", " at five")
        let first = LivePreview(requestId: requestId, settled: "see you", unsettled: " at five")
        #expect(await waitUntil { harness.transport.payloads.readLivePreview() == first })
        #expect(previewPosts(harness) == 2)

        transcriber.say("see you at five", " at the station")
        let second = LivePreview(requestId: requestId, settled: "see you at five", unsettled: " at the station")
        #expect(await waitUntil { harness.transport.payloads.readLivePreview() == second })
        #expect(previewPosts(harness) == 3)
        #expect(harness.session.phase == .recording(requestId))
    }

    /// The check: the preview is removed before the keyboard is told the dictation is being
    /// written and before the transcriber is asked for it, which is when anything is sent. What is
    /// typed is the transcriber's text, whatever the preview said.
    @Test func thePreviewIsGoneOnTheCheckBeforeAnythingIsSent() async throws {
        let transcriber = PreviewingTranscriber()
        transcriber.holds = true
        let harness = makeHarness(transcriber: transcriber)
        transcriber.atFinish = { [payloads = harness.transport.payloads] in payloads.readLivePreview() == nil }
        let requestId = UUID()
        try await record(requestId, saying: "words only the preview had", with: transcriber, on: harness)

        try harness.send(.stop, requestId)
        #expect(await waitUntil { transcriber.finishes == 1 })

        #expect(harness.session.phase == .processing(requestId))
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(transcriber.finishChecks == [true], "gone before the dictation was asked for")
        let events = harness.transport.postedEvents
        #expect(try #require(events.lastIndex(of: .livePreview)) < #require(events.lastIndex(of: .stateChanged)),
                "gone before the keyboard hears of processing")
        // Words still on their way from the recognizer are not written under the upload.
        transcriber.say("words only the preview had", " and some more")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)

        transcriber.release()
        #expect(await waitUntil { harness.transport.payloads.readResult(requestId) != nil })
        let result = try #require(harness.transport.payloads.readResult(requestId))
        #expect(result.isInsertable)
        #expect(result.text.localizedCaseInsensitiveContains(PreviewingTranscriber.transcript))
        #expect(!result.text.localizedCaseInsensitiveContains("preview"))
        #expect(harness.transport.payloads.readLivePreview() == nil)
    }

    /// The keyboard's X: the preview goes with the dictation.
    @Test func thePreviewIsGoneOnCancel() async throws {
        let transcriber = PreviewingTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let requestId = UUID()
        try await record(requestId, saying: "never mind", with: transcriber, on: harness)

        try harness.send(.cancel, requestId)
        #expect(await waitUntil { harness.session.phase == .ready })

        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(transcriber.abandoned == 1 && transcriber.finishes == 0)
        let posts = previewPosts(harness)
        transcriber.say("never mind", " after all")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == posts)
    }

    /// The app ends the dictation itself (the five-minute cap, a lost heartbeat, the Lock Screen's
    /// Stop, and what a session that stops does to the one it is recording): it is finished and
    /// sent, and its preview is gone at once. `stop()` itself isn't called here: it takes the
    /// microphone down, which ends the test host on a simulator whose audio doesn't answer.
    @Test func thePreviewIsGoneWhenTheAppEndsTheDictation() async throws {
        let transcriber = PreviewingTranscriber()
        transcriber.holds = true
        let harness = makeHarness(transcriber: transcriber)
        let requestId = UUID()
        try await record(requestId, saying: "the app ends this one", with: transcriber, on: harness)

        harness.session.endDictation(commit: true)

        #expect(harness.session.phase == .processing(requestId))
        #expect(harness.transport.payloads.readLivePreview() == nil)
        let posts = previewPosts(harness)
        transcriber.say("the app ends this one", " now")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == posts)
        transcriber.release()
        #expect(await waitUntil { harness.transport.payloads.readResult(requestId) != nil })
        #expect(harness.transport.payloads.readLivePreview() == nil)
    }

    /// Sign-out, a deleted account, the OK to the AI services taken back: the dictation is dropped,
    /// and its preview with it. (What `stop(discardingDictation: true)` does first; the stop itself
    /// would take the microphone down, see above.)
    @Test func thePreviewIsGoneWhenDictationsAreDiscarded() async throws {
        let transcriber = PreviewingTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let requestId = UUID()
        try await record(requestId, saying: "this is dropped", with: transcriber, on: harness)

        harness.session.discardDictations()

        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(transcriber.finishes == 0 && transcriber.abandoned == 1)
        #expect(harness.transport.payloads.readResult(requestId)?.status == .cancelled)
        let posts = previewPosts(harness)
        transcriber.say("this is dropped", " for good")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == posts)
    }

    /// Murmur is swiped away while it records: iOS tells it first, and the preview goes with the
    /// app. (The method is called here; posting the notification would reach every session in the
    /// test process.)
    @Test func thePreviewIsGoneWhenTheAppIsAboutToEnd() async throws {
        let transcriber = PreviewingTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let requestId = UUID()
        try await record(requestId, saying: "the app is going", with: transcriber, on: harness)

        harness.session.appWillTerminate()

        #expect(harness.transport.payloads.readLivePreview() == nil)
        let posts = previewPosts(harness)
        transcriber.say("the app is going", " away")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == posts)
    }

    /// A reconnect while a dictation uploads lets the next one begin, and the upload's completion
    /// then reports the session ready under it. A preview is only published while the session
    /// says it is recording, so the second dictation's goes at that moment.
    @Test func aPreviewDoesNotOutliveItsRecording() async throws {
        let transcriber = PreviewingTranscriber()
        transcriber.holds = true
        let harness = makeHarness(transcriber: transcriber)
        let first = UUID(), second = UUID()
        try harness.send(.start, first)
        #expect(await waitUntil { harness.session.phase == .recording(first) })
        try harness.send(.stop, first)
        #expect(await waitUntil { transcriber.finishes == 1 })
        #expect(harness.session.phase == .processing(first))

        harness.session.reconnectedForTesting()
        #expect(harness.session.phase == .ready)
        try harness.send(.start, second)
        #expect(await waitUntil { harness.session.phase == .recording(second) })
        #expect(harness.transport.payloads.readLivePreview() == LivePreview(requestId: second))

        transcriber.release()
        #expect(await waitUntil { harness.session.phase == .ready })

        #expect(harness.transport.payloads.readResult(first) != nil)
        #expect(harness.transport.payloads.readLivePreview() == nil)
        let posts = previewPosts(harness)
        transcriber.say("still talking")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == posts)
    }

    /// A start that arrives while the dictation before it is still being written waits for it and
    /// begins in the very step that reports the session ready again, which is also where a preview
    /// is closed. The queued dictation's preview is opened after that, and stays.
    @Test func aQueuedDictationHasItsPreview() async throws {
        let transcriber = PreviewingTranscriber()
        transcriber.holds = true
        let harness = makeHarness(transcriber: transcriber)
        let first = UUID(), queued = UUID()
        try harness.send(.start, first)
        #expect(await waitUntil { harness.session.phase == .recording(first) })
        try harness.send(.stop, first)
        #expect(await waitUntil { transcriber.finishes == 1 })
        try harness.send(.start, queued)
        #expect(await waitUntil { harness.transport.currentState().status == .starting })
        #expect(harness.transport.payloads.readLivePreview() == nil)

        transcriber.release()
        #expect(await waitUntil { harness.session.phase == .recording(queued) })

        #expect(harness.transport.payloads.readLivePreview() == LivePreview(requestId: queued))
        transcriber.say("the queued one")
        #expect(await waitUntil { harness.transport.payloads.readLivePreview()?.settled == "the queued one" })
        harness.session.endDictation(commit: false)
        #expect(harness.transport.payloads.readLivePreview() == nil)
    }

    /// A recognizer can still report after its dictation ended. Those words are written neither
    /// after it, nor into the preview of the dictation that began since.
    @Test func wordsReportedAfterTheDictationEndedAreNotWritten() async throws {
        let transcriber = PreviewingTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let first = UUID(), second = UUID()
        try await record(first, saying: "the first dictation", with: transcriber, on: harness)
        try harness.send(.stop, first)
        #expect(await waitUntil { harness.transport.payloads.readResult(first) != nil })
        #expect(await waitUntil { harness.session.phase == .ready })

        let posts = previewPosts(harness)
        transcriber.say("the first dictation", " goes on")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == posts)

        try harness.send(.start, second)
        #expect(await waitUntil { harness.session.phase == .recording(second) })
        transcriber.say("the first dictation", " goes on", dictation: 0)
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == LivePreview(requestId: second))

        transcriber.say("the second one")
        let words = LivePreview(requestId: second, settled: "the second one")
        #expect(await waitUntil { harness.transport.payloads.readLivePreview() == words })
        // Not afterwards either, between two of the second one's reports.
        transcriber.say("the first dictation", " once more", dictation: 0)
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == words)
    }

    /// A start from a keyboard that doesn't know the dictation under way replaces it. The file is
    /// the new dictation's from its first moment, empty: the keyboard never reads the words of the
    /// one before under the new one.
    @Test func aDictationThatReplacesAnotherStartsWithAnEmptyPreview() async throws {
        let transcriber = PreviewingTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let unclaimed = UUID(), next = UUID()
        try await record(unclaimed, saying: "words of the one nobody claimed", with: transcriber, on: harness)

        try harness.send(.start, next)
        #expect(await waitUntil { harness.session.phase == .recording(next) })

        #expect(harness.transport.payloads.readLivePreview() == LivePreview(requestId: next))
        #expect(harness.transport.payloads.readResult(unclaimed)?.status == .cancelled)
        transcriber.say("words of the one nobody claimed", " still", dictation: 0)
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == LivePreview(requestId: next))
        harness.session.endDictation(commit: false)
        #expect(harness.transport.payloads.readLivePreview() == nil)
    }

    /// No on-device model listens to the dictation (not installed, not prepared yet): nothing is
    /// written and nothing announced, so the keyboard shows the listening screen it always had.
    @Test func aDictationWithoutAnOnDeviceModelPublishesNothing() async throws {
        let transcriber = PreviewingTranscriber()
        transcriber.previews = false
        let harness = makeHarness(transcriber: transcriber)
        let requestId = UUID()
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })

        #expect(transcriber.liveBegins == 1 && transcriber.plainBegins == 0)
        // Not even if the transcriber reported words after saying it has none.
        transcriber.say("words nobody asked for")
        try await waitForLateWords()
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == 0)

        try harness.send(.stop, requestId)
        #expect(await waitUntil { harness.transport.payloads.readResult(requestId) != nil })
        #expect(previewPosts(harness) == 0)
    }

    /// The week's words were said to be used up and the server hasn't said they are back (here
    /// past the reset by the iPhone's clock, so the dictation is recorded for the server to judge):
    /// the dictation begins as it always did, with no words on screen to stand in for one the
    /// server refuses. While they are known to be used up, nothing begins at all.
    @Test func noPreviewWhileTheWeeksWordsWaitForTheServer() async throws {
        let transcriber = PreviewingTranscriber()
        var settings: SharedSettings?
        let harness = makeHarness(transcriber: transcriber) { shared in
            shared.wordsUsedUpUntil = Date().addingTimeInterval(-60)
            settings = shared
        }
        let requestId = UUID()
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })

        #expect(transcriber.liveBegins == 0 && transcriber.plainBegins == 1)
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == 0)
        try harness.send(.cancel, requestId)
        #expect(await waitUntil { harness.session.phase == .ready })

        // Set directly: for ten minutes after the weekly reset `noteWordsUsedUp()` marks nothing as used up.
        settings?.wordsUsedUpUntil = Date().addingTimeInterval(3_600)
        let refused = UUID()
        try harness.send(.start, refused)
        #expect(await waitUntil { harness.transport.payloads.readResult(refused) != nil })
        #expect(harness.transport.payloads.readResult(refused)?.status == .limitReached)
        #expect(transcriber.liveBegins == 0 && transcriber.plainBegins == 1)
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == 0)
    }

    /// The mic in a note isn't the keyboard's dictation: no keyboard listens to it, so it has no
    /// preview.
    @Test func aNotesOwnDictationHasNoPreview() async throws {
        let transcriber = PreviewingTranscriber()
        let harness = makeHarness(transcriber: transcriber)
        let requestId = try #require(harness.session.beginInAppDictation())

        #expect(harness.session.phase == .recording(requestId))
        #expect(transcriber.liveBegins == 0 && transcriber.plainBegins == 1)
        #expect(harness.transport.payloads.readLivePreview() == nil)
        #expect(previewPosts(harness) == 0)
        harness.session.endDictation(commit: false)
    }

    /// Murmur crashed, or iOS ended it for memory, in the middle of a dictation: nothing told it,
    /// so its preview is still in the shared container. The next start removes it.
    @Test func aPreviewLeftByAKilledAppIsRemovedAtStart() throws {
        let container = SharedContainer.temporary()
        let left = LivePreview(requestId: UUID(), settled: "words the app left", unsettled: " behind")
        try IPCPayloadStore(container: container).write(livePreview: left)
        let transport = InMemoryIPCTransport(container: container)
        #expect(transport.payloads.readLivePreview() == left)
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.session.\(UUID().uuidString)"))

        let session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoCleanup()), assets: SpeechAssetManager(),
            history: HistorySpy(), settings: settings)

        #expect(session.phase == .off)
        #expect(transport.payloads.readLivePreview() == nil)
        #expect(!FileManager.default.fileExists(atPath: container.directory("live").path))
    }

    // MARK: A locked iPhone

    /// `date` is `seconds` from now, give or take what the test itself took. The stop itself is
    /// the idle timer's, as for "Turn off after"; these tests read when it is due.
    private func isDue(_ date: Date?, in seconds: TimeInterval) -> Bool {
        guard let date else { return false }
        return abs(date.timeIntervalSinceNow - seconds) < 5
    }

    /// A locked iPhone can't show the keyboard, so the unused session ends a minute after the
    /// lock, long before "Turn off after" (5 minutes) would end it.
    @Test func aLockedPhoneEndsTheUnusedSessionAfterAMinute() {
        let lock = LockSpy()
        let harness = makeHarness(locked: { lock.locked })
        harness.session.appDidEnterBackground()
        #expect(isDue(harness.session.idleStopDateForTesting, in: 300))

        lock.locked = true
        harness.session.heartbeatForTesting()

        #expect(isDue(harness.session.idleStopDateForTesting, in: IdleStop.lockTimeout))
        #expect(harness.session.phase == .ready)
    }

    /// Never keeps the microphone on for as long as the iPhone is in use, and no longer.
    @Test func neverStillEndsOnALockedPhone() {
        let lock = LockSpy()
        let harness = makeHarness(configure: { $0.disableAfter = .never }, locked: { lock.locked })
        harness.session.appDidEnterBackground()
        #expect(harness.session.idleStopDateForTesting == nil)

        lock.locked = true
        harness.session.heartbeatForTesting()

        #expect(isDue(harness.session.idleStopDateForTesting, in: IdleStop.lockTimeout))
    }

    /// Unlocked within the minute, the session stays, and "Turn off after" decides again.
    @Test func unlockingPutsTurnOffAfterBackInCharge() {
        let lock = LockSpy()
        let harness = makeHarness(locked: { lock.locked })
        harness.session.appDidEnterBackground()
        lock.locked = true
        harness.session.heartbeatForTesting()
        #expect(isDue(harness.session.idleStopDateForTesting, in: IdleStop.lockTimeout))

        lock.locked = false
        harness.session.heartbeatForTesting()

        #expect(isDue(harness.session.idleStopDateForTesting, in: 300))
        #expect(harness.session.phase == .ready)
    }

    /// The screen locked while a dictation recorded: it records on, as before, and the minute
    /// starts when it has been written.
    @Test func aDictationUnderWayWhenThePhoneLocksIsNotCut() async throws {
        let lock = LockSpy()
        let harness = makeHarness(locked: { lock.locked })
        harness.session.appDidEnterBackground()
        let requestId = UUID()
        try harness.send(.start, requestId)
        #expect(await waitUntil { harness.session.phase == .recording(requestId) })

        lock.locked = true
        harness.session.heartbeatForTesting()

        #expect(harness.session.phase == .recording(requestId))
        #expect(harness.session.idleStopDateForTesting == nil)
        try harness.send(.stop, requestId)
        #expect(await waitUntil { harness.session.phase == .ready })
        #expect(harness.transport.payloads.readResult(requestId)?.isInsertable == true)
        #expect(isDue(harness.session.idleStopDateForTesting, in: IdleStop.lockTimeout))
    }

    /// In front of the user nothing counts down, and coming to the front ends what was believed
    /// about the lock.
    @Test func inFrontNothingCountsDownWhateverTheLockSays() {
        let lock = LockSpy()
        let harness = makeHarness(locked: { lock.locked })
        lock.locked = true
        harness.session.heartbeatForTesting()
        #expect(harness.session.idleStopDateForTesting == nil)

        harness.session.appDidEnterBackground()
        #expect(isDue(harness.session.idleStopDateForTesting, in: IdleStop.lockTimeout))

        lock.locked = false
        harness.session.appDidBecomeActive()
        harness.session.appDidEnterBackground()
        #expect(isDue(harness.session.idleStopDateForTesting, in: 300))
    }

    /// A Debug build's `-lock-timeout`, for measuring what the session costs in a locked iPhone.
    @Test func theLockTimeoutCanBeLonger() {
        let lock = LockSpy()
        let harness = makeHarness(configure: { $0.disableAfter = .never }, locked: { lock.locked }, lockTimeout: 600)
        harness.session.appDidEnterBackground()

        lock.locked = true
        harness.session.heartbeatForTesting()

        #expect(isDue(harness.session.idleStopDateForTesting, in: 600))
    }
}
