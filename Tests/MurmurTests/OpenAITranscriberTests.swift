@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class FakeCloud: CloudTranscribing {
    var isConfigured = true
    var result: Result<String, CloudTranscriptionError> = .success("Hello from OpenAI.")
    /// The languages OpenAI reports hearing.
    var languages: [String] = []
    /// What the request reports with a transcript.
    var timing: RequestTiming?
    /// The free words the reply says are left.
    var remaining: Int?
    /// Requests wait for `releaseRequests()`, like a slow network.
    var holdsRequests = false
    private(set) var calls: [(audio: Data, format: EncodedAudio.Format, language: String?, keywords: [String])] = []
    /// Each call's `languageHints`.
    private(set) var hints: [[String]] = []
    /// The dictation each call named; nil for one that named none.
    private(set) var dictationIds: [UUID?] = []
    /// When the last request answered.
    private(set) var answeredAt: ContinuousClock.Instant?
    private var held: [CheckedContinuation<Void, Never>] = []

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                    keywords: [String], dictationId: UUID?) async throws(CloudTranscriptionError) -> CloudTranscript {
        calls.append((audio, format, language, keywords))
        hints.append(languageHints)
        dictationIds.append(dictationId)
        if holdsRequests { await withCheckedContinuation { held.append($0) } }
        answeredAt = .now
        return CloudTranscript(text: try result.get(), languages: languages, timing: timing, remaining: remaining)
    }

    func releaseRequests() {
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

/// `dictate`: transcribes and translates in one request, or fails as told.
@MainActor
private final class FakeDictate: Dictating {
    var isAvailable = true
    /// A deployment that takes Word for word; false for one from before it did.
    var takesPlain = true
    var transcribesAlone: Bool { isAvailable && takesPlain }
    var lastReplyAt: ContinuousClock.Instant?
    var failure: CloudTranscriptionError?
    /// What a Word for word request fails with.
    var plainFailure: CloudTranscriptionError?
    private(set) var calls: [(audio: Data, language: String?, request: ModelRequest)] = []
    /// The Word for word requests: the transcript alone.
    private(set) var plainCalls: [(audio: Data, language: String?, dictationId: UUID)] = []
    /// What the fake heard, as `dictate` reports it.
    var languages = ["ru"]
    /// Each call's `languageHints`.
    private(set) var hints: [[String]] = []

    func transcribe(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                    keywords: [String], dictationId: UUID) async throws(CloudTranscriptionError) -> CloudTranscript {
        plainCalls.append((audio, language, dictationId))
        hints.append(languageHints)
        if let plainFailure { throw plainFailure }
        return CloudTranscript(text: "Привет из облака.", languages: languages,
                               timing: RequestTiming(function: "dictate", status: 200, totalMs: 900))
    }

    func dictate(audio: Data, format: EncodedAudio.Format, language: String?, languageHints: [String],
                 keywords: [String], request: ModelRequest) async throws(CloudTranscriptionError) -> DictateReply {
        calls.append((audio, language, request))
        hints.append(languageHints)
        if let failure { throw failure }
        return DictateReply(
            transcript: "Привет из облака.", languages: languages,
            modelReply: .success(CleanupClient.Response(
                text: "Hi from the cloud.", status: "cleaned", words: 4, model: "gpt-test", ttftMs: nil,
                totalMs: 500, remaining: nil, targetLanguage: request.targetLanguage)),
            timing: RequestTiming(function: "dictate", status: 200, totalMs: 1_200))
    }

    func warm() async -> WarmupResult { .skipped }
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

/// The cleanup at the free plan's limit: refuses every request (`402 limit_reached`).
@MainActor
private final class RefusingCleanup: Cleaning {
    var isConfigured = true
    private(set) var calls = 0
    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?, style: StylePreset,
        dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        calls += 1
        throw .limitReached
    }
}

/// Stands in for the on-device transcriber. It has words for a dictation begun with live words,
/// which the test speaks (`say`), and takes up a dictation under way (`appendRecorded`).
private final class FakeOnDevice: Transcriber, LiveWordsProviding, ReplayableTranscriber, @unchecked Sendable {
    struct ModelDidNotLoad: Error {}

    let displayName = "On-device"
    /// How long ending a dictation takes; an analyzer can take a while to finish.
    private let teardownDelay: Duration
    private let lock = NSLock()
    private var _preparedTag: String?
    private var _language: ResolvedLanguage?
    private var _prepares = 0
    private var _preparing = false
    private var _holdsPrepare = false
    private var heldPrepares: [CheckedContinuation<Void, Never>] = []
    private var _prepareFails = false
    private var _refusesRecorded = false
    private var _holdsBegin = false
    private var _insideBegin = false
    private let beginGate = DispatchSemaphore(value: 0)
    private var _begun = 0
    private var _liveBegun = 0
    /// The handler the dictation was begun with, kept after it ended, as a recognizer still at
    /// work could; a dictation begun without live words has none.
    private var handler: LiveWordsHandler?
    private var _appended = 0
    private var _finished = 0
    private var _cancelled = 0
    private var _abandoned = 0
    private var _events: [String] = []
    private var _recorded: [Float] = []
    private var _direct: [Float] = []

    init(teardownDelay: Duration = .zero) {
        self.teardownDelay = teardownDelay
    }

    /// The language it was last prepared for or switched to.
    var currentLanguage: ResolvedLanguage? { lock.withLock { _language } }
    var preparedTag: String? { lock.withLock { _preparedTag } }
    /// How often it was asked to prepare.
    var prepares: Int { lock.withLock { _prepares } }
    /// A preparation is under way (held by `holdsPrepare`).
    var isPreparing: Bool { lock.withLock { _preparing } }
    /// `prepare` waits for `releasePrepare()`, like a model that takes its time to load.
    var holdsPrepare: Bool {
        get { lock.withLock { _holdsPrepare } }
        set { lock.withLock { _holdsPrepare = newValue } }
    }
    /// `prepare` throws: the model doesn't load.
    var prepareFails: Bool {
        get { lock.withLock { _prepareFails } }
        set { lock.withLock { _prepareFails = newValue } }
    }
    /// `appendRecorded` refuses, as an analyzer that isn't ready does.
    var refusesRecorded: Bool {
        get { lock.withLock { _refusesRecorded } }
        set { lock.withLock { _refusesRecorded = newValue } }
    }
    /// `beginUtterance(liveWords:)` waits for `releaseBegin()`, so a test can act while a
    /// dictation is being taken up.
    var holdsBegin: Bool {
        get { lock.withLock { _holdsBegin } }
        set { lock.withLock { _holdsBegin = newValue } }
    }
    var isInsideBegin: Bool { lock.withLock { _insideBegin } }
    /// The dictations begun without live words.
    var begun: Int { lock.withLock { _begun } }
    /// The dictations begun with live words.
    var liveBegun: Int { lock.withLock { _liveBegun } }
    var appended: Int { lock.withLock { _appended } }
    var finished: Int { lock.withLock { _finished } }
    var cancelled: Int { lock.withLock { _cancelled } }
    var abandoned: Int { lock.withLock { _abandoned } }
    /// Everything asked of it, in order: "prepare ru-RU", "language en-US", "begin", "live",
    /// "recorded", "append", "finish", "cancel", "abandon".
    var events: [String] { lock.withLock { _events } }
    /// The samples it was handed for a dictation it took up late.
    var recorded: [Float] { lock.withLock { _recorded } }
    /// The first sample of each buffer that came straight from the microphone.
    var direct: [Float] { lock.withLock { _direct } }

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        lock.withLock {
            _prepares += 1
            _preparing = true
        }
        await withCheckedContinuation { continuation in
            let held = lock.withLock { () -> Bool in
                if _holdsPrepare { heldPrepares.append(continuation) }
                return _holdsPrepare
            }
            if !held { continuation.resume() }
        }
        let fails = lock.withLock { () -> Bool in
            _preparing = false
            return _prepareFails
        }
        if fails { throw ModelDidNotLoad() }
        lock.withLock {
            _preparedTag = language.tag
            _language = language
            _events.append("prepare \(language.tag)")
        }
    }
    func releasePrepare() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdsPrepare = false
            defer { heldPrepares = [] }
            return heldPrepares
        }
        held.forEach { $0.resume() }
    }
    func setLanguage(_ language: ResolvedLanguage) {
        lock.withLock {
            _language = language
            _events.append("language \(language.tag)")
        }
    }
    func beginUtterance() {
        lock.withLock {
            _begun += 1
            handler = nil
            _events.append("begin")
        }
    }
    func beginUtterance(liveWords handler: @escaping LiveWordsHandler) -> Bool {
        let holds = lock.withLock { () -> Bool in
            _liveBegun += 1
            self.handler = handler
            _events.append("live")
            _insideBegin = _holdsBegin
            return _holdsBegin
        }
        if holds {
            beginGate.wait()
            lock.withLock { _insideBegin = false }
        }
        return true
    }
    func releaseBegin() {
        lock.withLock { _holdsBegin = false }
        beginGate.signal()
    }
    /// The words recognized so far, to whoever began the dictation with live words.
    func say(_ settled: String, _ unsettled: String = "") {
        lock.withLock { handler }?(settled, unsettled)
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            _appended += 1
            _direct.append(buffer.floatChannelData?[0][0] ?? 0)
            _events.append("append")
        }
    }
    func appendRecorded(_ samples: ArraySlice<Float>, sampleRate: Double) -> Bool {
        lock.withLock {
            guard !_refusesRecorded else { return false }
            _recorded.append(contentsOf: samples)
            _events.append("recorded")
            return true
        }
    }
    func finishUtterance() async throws -> String {
        lock.withLock {
            _finished += 1
            _events.append("finish")
        }
        return "Recognized on the iPhone."
    }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        UtteranceOutput(transcript: try await finishUtterance())
    }
    func cancelUtterance() async {
        lock.withLock {
            _cancelled += 1
            _events.append("cancel")
        }
        try? await Task.sleep(for: teardownDelay)
    }
    func abandonUtterance() {
        lock.withLock {
            _abandoned += 1
            _events.append("abandon")
        }
        Task { [teardownDelay] in try? await Task.sleep(for: teardownDelay) }
    }
    func shutdown() async {}
}

/// Microphone buffers made on the main actor and fed from another thread, as the audio thread feeds them.
private final class Buffers: @unchecked Sendable {
    let all: [AVAudioPCMBuffer]
    init(_ all: [AVAudioPCMBuffer]) { self.all = all }
}

/// A value a `@Sendable` closure reads while the test changes it.
private final class Shared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// The live words a transcriber reported, in order.
private final class HeardWords: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []

    /// Each report as it reads: `settled + unsettled`.
    var all: [String] { lock.withLock { _all } }
    var handler: LiveWordsHandler {
        { [self] settled, unsettled in lock.withLock { _all.append(settled + unsettled) } }
    }
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
    /// The keyboard's Auto-detect, as the session hands it over.
    private let automatic = ResolvedLanguage(tag: "und", locale: Locale(identifier: "und"), engine: .speech)

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

    private func translation() -> ModelRequest {
        ModelRequest(dictationId: UUID(), targetLanguage: "en-US", style: .verbatim, dictionary: [], snippets: [])
    }

    @Test func aTranslationIsTranscribedAndTranslatedInOneRequest() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let request = translation()

        let output = try await transcriber.finishUtterance(model: request)

        #expect(output.transcript == "Привет из облака.")
        #expect(try output.modelReply?.get().text == "Hi from the cloud.")
        #expect(cloud.calls.isEmpty)
        let call = try #require(dictate.calls.first)
        #expect(call.language == "ru-RU")
        #expect(call.request.dictationId == request.dictationId)
        let timings = try #require(transcriber.takeTimings())
        #expect(timings.requests.map(\.function) == ["dictate"])
        #expect(timings.cloudTranscript)
    }

    /// Improve my grammar goes out like a translation, with no target.
    @Test func aGrammarDictationIsTranscribedAndWrittenInOneRequest() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)

        let output = try await transcriber.finishUtterance(
            model: ModelRequest(dictationId: UUID(), targetLanguage: nil, style: .grammar, dictionary: [], snippets: []))

        #expect(try output.modelReply?.get().text == "Hi from the cloud.")
        #expect(cloud.calls.isEmpty)
        let call = try #require(dictate.calls.first)
        #expect(call.request.targetLanguage == nil)
        #expect(call.request.style == .grammar)
    }

    /// Word for word goes through `dictate` as well: one worker checks and transcribes it, and no
    /// model writes it.
    @Test func aWordForWordDictationIsTranscribedByDictate() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let id = UUID()

        let output = try await transcriber.finishUtterance(model: nil, dictationId: id)

        #expect(output.transcript == "Привет из облака.")
        #expect(output.modelReply == nil)
        #expect(output.detectedLanguage == nil)
        #expect(cloud.calls.isEmpty && dictate.calls.isEmpty)
        let call = try #require(dictate.plainCalls.first)
        #expect(call.dictationId == id)
        #expect(call.language == "ru-RU")
        #expect(try seconds(of: call.audio, format: .m4a) > 0.9)
        let timings = try #require(transcriber.takeTimings())
        #expect(timings.requests.map(\.function) == ["dictate"])
        #expect(timings.cloudTranscript)

        // Under Auto-detect the language it heard is the transcript's, as with `transcribe`.
        dictate.languages = ["tr"]
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance(model: nil, dictationId: UUID()).detectedLanguage == "tr")
        #expect(dictate.plainCalls.last?.language == nil)
    }

    /// `dictate` can't transcribe alone (a deployment from before it could, or one whose checks
    /// couldn't run): the very same audio goes to `transcribe`, under the same id.
    @Test func whenDictateCannotTranscribeAloneTheSameAudioGoesToTranscribe() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        dictate.plainFailure = .notDeployed
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let id = UUID()

        let output = try await transcriber.finishUtterance(model: nil, dictationId: id)

        #expect(output.transcript == "Hello from OpenAI.")
        #expect(try #require(cloud.calls.first).audio == #require(dictate.plainCalls.first).audio)
        #expect(cloud.dictationIds == [id])
        #expect(try #require(transcriber.takeTimings()).cloudTranscript)

        // Known not to take one: it isn't asked.
        dictate.takesPlain = false
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance(model: nil, dictationId: UUID())
        #expect(dictate.plainCalls.count == 1 && cloud.calls.count == 2)
    }

    /// Its failures are the cloud's, as `transcribe`'s are: the on-device transcript, and a pause.
    @Test func aFailedWordForWordRequestFallsBackOnDeviceAndPausesTheCloud() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        dictate.plainFailure = .unavailable("offline")
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate, fallback: onDevice,
                                            fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        for _ in 0..<2 {
            transcriber.beginUtterance()
            feed(transcriber, seconds: 1)
            let output = try await transcriber.finishUtterance(model: nil, dictationId: UUID())
            #expect(output.transcript == "Recognized on the iPhone.")
        }
        #expect(dictate.plainCalls.count == 1 && cloud.calls.isEmpty)
    }

    /// The weekly limit is the account's, whichever function says so: the audio isn't sent again.
    @Test func aWordForWordDictationOverTheLimitIsNotSentToTranscribe() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        dictate.plainFailure = .limitReached
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)

        await #expect(throws: CloudTranscriptionError.limitReached) {
            try await transcriber.finishUtterance(model: nil, dictationId: UUID())
        }
        #expect(cloud.calls.isEmpty)
    }

    /// Audio that belongs to no dictation has no id for `dictate` to count it under: `transcribe` alone.
    @Test func withoutARequestOnlyTheTranscriptIsAskedFor() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)

        let output = try await transcriber.finishUtterance(model: nil)

        #expect(output.transcript == "Hello from OpenAI.")
        #expect(output.modelReply == nil)
        #expect(dictate.calls.isEmpty && dictate.plainCalls.isEmpty)
        #expect(cloud.calls.count == 1)
    }

    /// The server counts a transcript's words under the dictation's own id, so `transcribe` is told
    /// it: by the pipeline for Word for word, by the model request when `dictate` can't take it.
    @Test func transcribeIsToldWhichDictationItIs() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        dictate.isAvailable = false
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)

        let wordForWord = UUID()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance(model: nil, dictationId: wordForWord)

        let request = translation()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance(model: request)

        // Audio that belongs to no dictation names none, and isn't counted.
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()

        #expect(cloud.dictationIds == [wordForWord, request.dictationId, nil])
        #expect(TranscriptionClient.headers(naming: wordForWord) == ["x-murmur-dictation": wordForWord.uuidString])
        #expect(TranscriptionClient.headers(naming: nil).isEmpty)
    }

    /// Under Auto-detect OpenAI picks the language and says which, so the pipeline can format,
    /// clean up and file the dictation in it. A chosen language needs no report.
    @Test func autoDetectReportsTheLanguageOpenAIHeard() async throws {
        let cloud = FakeCloud()
        cloud.languages = ["tr"]
        let dictate = FakeDictate()
        dictate.languages = ["tr"]
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance(model: nil).detectedLanguage == "tr")
        #expect(cloud.calls.first?.language == nil)

        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance(model: translation()).detectedLanguage == "tr")
        #expect(dictate.calls.first?.language == nil)

        let chosen = OpenAITranscriber(client: cloud)
        try await chosen.prepare(micFormat: micFormat, language: russian)
        chosen.beginUtterance()
        feed(chosen, seconds: 1)
        #expect(try await chosen.finishUtterance(model: nil).detectedLanguage == nil)
    }

    /// Under Auto-detect a failed request is covered by the installed language the session
    /// guesses, and the transcript is reported in it.
    @Test func autoDetectFallsBackToTheGuessedLanguage() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        transcriber.setAutomaticFallback(russian)
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        await transcriber.prepareFallback()
        #expect(onDevice.preparedTag == "ru-RU")
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)

        let output = try await transcriber.finishUtterance(model: nil)

        #expect(output.transcript == "Recognized on the iPhone.")
        #expect(output.detectedLanguage == "ru-RU")
    }

    @Test func autoDetectWithoutAGuessHasNoFallback() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.limitReached)
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        await transcriber.prepareFallback()
        #expect(onDevice.preparedTag == nil)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }
    }

    /// Switched off in Debug, or answered 404 earlier: `transcribe` alone, and the pipeline translates.
    @Test func withoutDictateATranslationIsOnlyTranscribed() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        dictate.isAvailable = false
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)

        let output = try await transcriber.finishUtterance(model: translation())

        #expect(output.transcript == "Hello from OpenAI.")
        #expect(output.modelReply == nil)
        #expect(dictate.calls.isEmpty && cloud.calls.count == 1)
    }

    /// A 404 sends the very same audio to `transcribe`: the user never sees it.
    @Test func anUndeployedDictateSendsTheSameAudioToTranscribe() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        dictate.failure = .notDeployed
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)

        let output = try await transcriber.finishUtterance(model: translation())

        #expect(output.transcript == "Hello from OpenAI.")
        #expect(output.modelReply == nil)
        #expect(try #require(cloud.calls.first).audio == #require(dictate.calls.first).audio)
    }

    /// Like a failed `transcribe`: the on-device transcript, for the pipeline to translate, and
    /// the cloud paused.
    @Test func aFailedOneRequestFallsBackOnDeviceAndPausesTheCloud() async throws {
        let cloud = FakeCloud()
        let dictate = FakeDictate()
        dictate.failure = .unavailable("offline")
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, dictation: dictate, fallback: onDevice,
                                            fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        for _ in 0..<2 {
            transcriber.beginUtterance()
            feed(transcriber, seconds: 1)
            let output = try await transcriber.finishUtterance(model: translation())
            #expect(output.transcript == "Recognized on the iPhone.")
            #expect(output.modelReply == nil)
        }
        #expect(dictate.calls.count == 1 && cloud.calls.isEmpty)
    }

    @Test func aDictationWithoutTranslationNeverUsesDictate() async throws {
        let dictate = FakeDictate()
        let transcriber = OpenAITranscriber(client: FakeCloud(), dictation: dictate)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)

        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")
        #expect(dictate.calls.isEmpty)
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
        #expect(cloud.hints.first == [])
    }

    /// Under Auto-detect the user's languages go along, so the cloud picks among them; a pinned
    /// language goes alone.
    @Test func automaticLanguageSendsTheUsersLanguagesAsHints() async throws {
        let cloud = FakeCloud()
        var automatic = ResolvedLanguage(tag: DictationLanguage.automatic.tag,
                                         locale: Locale(identifier: "en-US"), engine: .speech)
        automatic.languageHints = ["en-US", "ru-RU"]
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()
        #expect(cloud.calls.last?.language == nil)
        #expect(cloud.hints.last == ["en-US", "ru-RU"])

        var pinned = russian
        pinned.languageHints = ["en-US", "ru-RU"]
        transcriber.setLanguage(pinned)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = try await transcriber.finishUtterance()
        #expect(cloud.calls.last?.language == "ru-RU")
        #expect(cloud.hints.last == [])
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
        // Word for word: the punctuated on-device text has nothing for the model to change.
        let dictation = ActiveDictation(
            requestId: UUID(), documentIdentifier: nil, style: .verbatim, language: "ru-RU",
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
            requestId: UUID(), documentIdentifier: nil, style: .grammar, language: "ru-RU",
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
            requestId: UUID(), documentIdentifier: nil, style: .grammar, language: "ru-RU",
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

    // MARK: Live words

    /// The on-device model that listens beside the cloud is also what the keyboard's live words
    /// come from: begun with them, it reports to the handler the dictation was begun with.
    @Test func theFallbacksWordsAreHeardWhileItListens() async throws {
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice,
                                            fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        let heard = HeardWords()

        #expect(transcriber.beginUtterance(liveWords: heard.handler))

        #expect(onDevice.liveBegun == 1 && onDevice.begun == 0)
        onDevice.say("Привет,", " как")
        onDevice.say("Привет, как дела")
        #expect(heard.all == ["Привет, как", "Привет, как дела"])
        // It is still the fallback: fed the same audio.
        feed(transcriber, seconds: 1)
        #expect(onDevice.appended > 0)

        // A dictation begun without live words shows none.
        transcriber.abandonUtterance()
        transcriber.beginUtterance()
        #expect(onDevice.liveBegun == 1 && onDevice.begun == 1)
        onDevice.say("ещё слова")
        #expect(heard.all.count == 2)
    }

    /// No on-device model can listen to the dictation (there is none, or none that knows the
    /// language): there are no live words, the fallback isn't begun, and the dictation has begun
    /// all the same.
    @Test func withoutAnOnDeviceModelForItADictationHasNoLiveWords() async throws {
        let cloud = FakeCloud()
        let onDevice = FakeOnDevice()
        let heard = HeardWords()

        let alone = OpenAITranscriber(client: cloud)
        try await alone.prepare(micFormat: micFormat, language: russian)
        #expect(!alone.beginUtterance(liveWords: heard.handler))
        feed(alone, seconds: 1)
        #expect(try await alone.finishUtterance() == "Hello from OpenAI.")

        // Nothing is known of a Russian model, before the fallback is prepared or after.
        let unknown = OpenAITranscriber(client: cloud, fallback: onDevice)
        try await unknown.prepare(micFormat: micFormat, language: russian)
        #expect(!unknown.beginUtterance(liveWords: heard.handler))
        unknown.abandonUtterance()
        await unknown.prepareFallback()
        #expect(!unknown.beginUtterance(liveWords: heard.handler))
        unknown.abandonUtterance()

        // Only English is installed on the device; this dictation is in Russian.
        let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
        let other = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["en-US": english])
        try await other.prepare(micFormat: micFormat, language: russian)
        await other.prepareFallback()
        #expect(!other.beginUtterance(liveWords: heard.handler))
        #expect(onDevice.begun == 0 && onDevice.liveBegun == 0)
        #expect(heard.all.isEmpty)
    }

    // MARK: A dictation that begins before the fallback is ready

    private func marked(_ index: Int, frames: Int = 480) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames { buffer.floatChannelData![0][frame] = Float(index) / 1000 }
        return buffer
    }

    /// The buffers a level in the audio stands for: `marked(7)` reads 0.007.
    private func marks(_ samples: [Float]) -> [Int] {
        samples.map { Int(($0 * 1000).rounded()) }.filter { $0 > 0 }
    }

    /// A transcriber whose fallback is being prepared (and waits for `onDevice.releasePrepare()`).
    private func preparing(_ onDevice: FakeOnDevice, cloud: FakeCloud = FakeCloud(),
                           wordsUsedUpUntil: @escaping @Sendable () -> Date? = { nil },
                           lateJoinLimit: Duration = .seconds(60)) async throws -> (OpenAITranscriber, Task<Void, Never>) {
        onDevice.holdsPrepare = true
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian],
                                            wordsUsedUpUntil: wordsUsedUpUntil, lateJoinLimit: lateJoinLimit)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        let preparation = Task { await transcriber.prepareFallback() }
        #expect(await waitUntil { onDevice.isPreparing })
        return (transcriber, preparation)
    }

    /// The first dictation after the microphone turns on begins while the on-device model is
    /// still loading. It is promised its words, and when the model is ready the fallback takes it
    /// up: everything recorded so far first, then the microphone's buffers as they come.
    @Test func aDictationBegunBeforeTheFallbackIsReadyIsTakenUpWhenItIs() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        let heard = HeardWords()

        #expect(transcriber.beginUtterance(liveWords: heard.handler))
        #expect(onDevice.liveBegun == 0)
        feed(transcriber, seconds: 1)
        #expect(onDevice.appended == 0 && onDevice.recorded.isEmpty)

        onDevice.releasePrepare()
        await preparation.value

        #expect(onDevice.liveBegun == 1 && onDevice.begun == 0)
        // A second of the microphone's 48 kHz is a second at 16 kHz.
        #expect(abs(onDevice.recorded.count - 16_000) < 400)
        #expect(onDevice.appended == 0)
        onDevice.say("Привет,", " как")
        #expect(heard.all == ["Привет, как"])

        // From here it is fed like any other dictation's fallback.
        feed(transcriber, seconds: 0.5)
        #expect(onDevice.appended > 0)
        #expect(abs(onDevice.recorded.count - 16_000) < 400)
        let events = onDevice.events
        #expect(try #require(events.firstIndex(of: "live")) < #require(events.firstIndex(of: "recorded")))
        #expect(try #require(events.lastIndex(of: "recorded")) < #require(events.firstIndex(of: "append")))

        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")
        #expect(onDevice.abandoned == 1 && onDevice.finished == 0)
    }

    /// Buffers go on arriving while the fallback is handed the recording: each reaches it once,
    /// in the recording or straight from the microphone, and in the order it was spoken.
    @Test func whileADictationIsTakenUpNothingIsLostRepeatedOrOutOfOrder() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        let count = 400
        let fed = Shared(0)
        let buffers = Buffers((1...count).map { marked($0) })
        let feeder = Task.detached {
            for (index, buffer) in buffers.all.enumerated() {
                transcriber.append(buffer)
                fed.value = index + 1
                if index % 4 == 0 { try? await Task.sleep(for: .microseconds(300)) }
            }
        }
        #expect(await waitUntil { fed.value >= count / 4 })
        onDevice.releasePrepare()
        await feeder.value
        await preparation.value

        let recorded = marks(onDevice.recorded), direct = marks(onDevice.direct)
        #expect(!recorded.isEmpty && !direct.isEmpty)
        #expect(Set(recorded).union(direct) == Set(1...count))
        #expect(Set(recorded).isDisjoint(with: direct))
        #expect(direct == Array((direct.first ?? 0)...(direct.last ?? 0)))
        #expect((recorded.max() ?? 0) + 1 == direct.first)
        // What was handed over reads in the order it was spoken (a resampler rings a little at each step).
        let samples = onDevice.recorded
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1 >= $0 - 0.0005 })
        transcriber.abandonUtterance()
    }

    /// A dictation that ended before the model was ready is never taken up, and nothing of the
    /// fallback is begun or ended for it.
    @Test func aDictationThatEndsBeforeTheFallbackIsReadyIsNeverTakenUp() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")

        // And one that was dropped.
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        transcriber.abandonUtterance()

        onDevice.releasePrepare()
        await preparation.value
        #expect(onDevice.liveBegun == 0 && onDevice.begun == 0)
        #expect(onDevice.abandoned == 0 && onDevice.recorded.isEmpty)
        #expect(transcriber.displayName == "OpenAI (on-device fallback)")
    }

    /// The dictation ends at the moment the fallback takes it up: the end waits for the hand-over,
    /// and the fallback's part is ended once.
    @Test func aDictationEndingWhileItIsTakenUpEndsTheFallbacksPartOnce() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        onDevice.holdsBegin = true
        onDevice.releasePrepare()
        #expect(await waitUntil { onDevice.isInsideBegin })
        Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            onDevice.releaseBegin()
        }

        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")
        await preparation.value

        #expect(onDevice.liveBegun == 1 && onDevice.abandoned == 1 && onDevice.finished == 0)
        // It had the whole recording before the dictation's end took it away.
        #expect(abs(onDevice.recorded.count - 16_000) < 400)
        let events = onDevice.events
        #expect(try #require(events.lastIndex(of: "recorded")) < #require(events.firstIndex(of: "abandon")))
    }

    /// The dictation is dropped and the next begins while the first is being taken up: the first's
    /// part is ended, once, and the next one's is its own.
    @Test func aDictationDroppedWhileItIsTakenUpLeavesTheNextOneAlone() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        let first = HeardWords(), second = HeardWords()
        #expect(transcriber.beginUtterance(liveWords: first.handler))
        feed(transcriber, seconds: 1)
        onDevice.holdsBegin = true
        onDevice.releasePrepare()
        #expect(await waitUntil { onDevice.isInsideBegin })
        let next = Task.detached { () -> Bool in
            transcriber.abandonUtterance()
            return transcriber.beginUtterance(liveWords: second.handler)
        }
        try await Task.sleep(for: .milliseconds(100))
        onDevice.releaseBegin()

        #expect(await next.value)
        await preparation.value
        #expect(onDevice.liveBegun == 2 && onDevice.abandoned == 1)
        #expect(onDevice.events.filter { $0 == "live" || $0 == "abandon" } == ["live", "abandon", "live"])
        feed(transcriber, seconds: 0.5)
        #expect(onDevice.appended > 0)
        onDevice.say("вторая")
        #expect(second.all == ["вторая"] && first.all.isEmpty)
        transcriber.abandonUtterance()
        #expect(onDevice.abandoned == 2)
    }

    /// The request fails for a dictation the fallback took up late: its transcript is the whole
    /// dictation's, since it was handed the recording from the start.
    @Test func aFailedRequestAfterTheFallbackJoinedIsCoveredByIt() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice, cloud: cloud)
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        onDevice.releasePrepare()
        await preparation.value
        feed(transcriber, seconds: 1)

        #expect(try await transcriber.finishUtterance() == "Recognized on the iPhone.")
        #expect(onDevice.finished == 1 && onDevice.abandoned == 0)
        #expect(abs(onDevice.recorded.count - 16_000) < 400)
    }

    /// Before the fallback joined there is none, as ever: the request's failure is the dictation's.
    @Test func aFailedRequestBeforeTheFallbackJoinedIsNotCovered() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice, cloud: cloud)
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.self) { try await transcriber.finishUtterance() }
        onDevice.releasePrepare()
        await preparation.value
        #expect(onDevice.finished == 0 && onDevice.liveBegun == 0)
    }

    /// The server refuses the account for a dictation the fallback took up late: the iPhone's own
    /// recognition still doesn't stand in.
    @Test func aRefusedDictationIsNotRecognizedAfterTheFallbackJoinedEither() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.limitReached)
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice, cloud: cloud)
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        onDevice.releasePrepare()
        await preparation.value
        #expect(onDevice.liveBegun == 1)

        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }
        #expect(onDevice.finished == 0 && onDevice.abandoned == 1)
    }

    /// While the week's words wait for the server nothing is promised, and a dictation promised
    /// its words just before they ran out is not taken up.
    @Test func noDictationIsTakenUpWhileTheWeeksWordsWaitForTheServer() async throws {
        let until = Shared<Date?>(Date().addingTimeInterval(3_600))
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice, wordsUsedUpUntil: { until.value })
        #expect(!transcriber.beginUtterance(liveWords: HeardWords().handler))
        transcriber.abandonUtterance()

        until.value = nil
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        until.value = Date().addingTimeInterval(3_600)
        onDevice.releasePrepare()
        await preparation.value

        #expect(onDevice.liveBegun == 0 && onDevice.begun == 0 && onDevice.recorded.isEmpty)
        feed(transcriber, seconds: 0.5)
        #expect(onDevice.appended == 0)
    }

    /// A dictation begun without live words (a note's own mic) is left as it began.
    @Test func aDictationWithoutLiveWordsIsNotTakenUp() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        onDevice.releasePrepare()
        await preparation.value
        #expect(onDevice.liveBegun == 0 && onDevice.begun == 0 && onDevice.recorded.isEmpty)
        feed(transcriber, seconds: 0.5)
        #expect(onDevice.appended == 0)
    }

    /// A dictation that has run for longer than the limit is left alone: the recognizer would be
    /// busy with the past.
    @Test func aDictationThatHasRunTooLongIsNotTakenUp() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice, lateJoinLimit: .milliseconds(50))
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        try await Task.sleep(for: .milliseconds(120))
        onDevice.releasePrepare()
        await preparation.value
        #expect(onDevice.liveBegun == 0 && onDevice.recorded.isEmpty)
    }

    /// The fallback can't take the recording after all: its part is ended at once, so a request
    /// that fails later is not answered with a part of the dictation.
    @Test func aFallbackThatCannotTakeTheRecordingGivesItsPartBack() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        onDevice.refusesRecorded = true
        let (transcriber, preparation) = try await preparing(onDevice, cloud: cloud)
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        onDevice.releasePrepare()
        await preparation.value
        #expect(onDevice.liveBegun == 1 && onDevice.abandoned == 1)
        feed(transcriber, seconds: 0.5)
        #expect(onDevice.appended == 0)

        await #expect(throws: CloudTranscriptionError.self) { try await transcriber.finishUtterance() }
        #expect(onDevice.finished == 0 && onDevice.abandoned == 1)
    }

    /// The session knows of a verified model before the transcriber has heard of any language: the
    /// dictation is promised its words on that, and taken up once the language turns up.
    @Test func aDictationIsPromisedItsWordsOnAModelTheSessionKnowsOf() async throws {
        let onDevice = FakeOnDevice()
        let expected = OpenAITranscriber(client: FakeCloud(), fallback: onDevice, expectsOnDevice: { _ in true })
        try await expected.prepare(micFormat: micFormat, language: russian)
        let heard = HeardWords()
        #expect(expected.beginUtterance(liveWords: heard.handler))
        feed(expected, seconds: 1)

        expected.addFallbackLanguage(russian)
        await expected.prepareFallback()
        #expect(onDevice.liveBegun == 1 && abs(onDevice.recorded.count - 16_000) < 400)
        onDevice.say("слова")
        #expect(heard.all == ["слова"])
        expected.abandonUtterance()

        let unexpected = OpenAITranscriber(client: FakeCloud(), fallback: FakeOnDevice())
        try await unexpected.prepare(micFormat: micFormat, language: russian)
        #expect(!unexpected.beginUtterance(liveWords: heard.handler))
    }

    // MARK: Getting the fallback ready

    /// A language whose model turns up after the session asked for the fallback (its check was
    /// slower than the rest) is prepared at once, without the session asking again. Before the
    /// session has asked, nothing is prepared: the start of the microphone comes first.
    @Test func aLanguageThatTurnsUpLaterIsPreparedWithoutBeingAskedAgain() async throws {
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
        transcriber.addFallbackLanguage(english)
        try await Task.sleep(for: .milliseconds(50))
        #expect(onDevice.prepares == 0)

        await transcriber.prepareFallback()
        #expect(onDevice.prepares == 0 && transcriber.displayName == "OpenAI")

        transcriber.addFallbackLanguage(russian)
        #expect(await waitUntil { onDevice.preparedTag == "ru-RU" })
        #expect(await waitUntil { transcriber.displayName == "OpenAI (on-device fallback)" })
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        #expect(onDevice.liveBegun == 1)
    }

    /// The same under Auto-detect, where the model is the session's guess, and for a language the
    /// keyboard switches to.
    @Test func aGuessOrALanguageThatGetsAModelIsPreparedToo() async throws {
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice)
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        await transcriber.prepareFallback()
        #expect(onDevice.prepares == 0)
        transcriber.addFallbackLanguage(russian)
        transcriber.setAutomaticFallback(russian)
        #expect(await waitUntil { onDevice.preparedTag == "ru-RU" })

        let other = FakeOnDevice()
        let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
        let switched = OpenAITranscriber(client: FakeCloud(), fallback: other, fallbackLanguages: ["en-US": english])
        try await switched.prepare(micFormat: micFormat, language: russian)
        await switched.prepareFallback()
        #expect(other.prepares == 0)
        switched.setLanguage(english)
        #expect(await waitUntil { other.preparedTag == "en-US" })
    }

    /// Only one preparation runs at a time, however many ask.
    @Test func onlyOnePreparationRunsAtATime() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        let second = Task { await transcriber.prepareFallback() }
        transcriber.addFallbackLanguage(russian)
        try await Task.sleep(for: .milliseconds(50))
        #expect(onDevice.prepares == 1)
        onDevice.releasePrepare()
        await preparation.value
        await second.value
        #expect(onDevice.prepares == 1)
        #expect(transcriber.displayName == "OpenAI (on-device fallback)")
    }

    /// The model doesn't load: nothing is promised after that, and it is tried again as a
    /// dictation begins once the pause is over.
    @Test func afterAFailedPreparationNothingIsPromisedUntilItSucceeds() async throws {
        let onDevice = FakeOnDevice()
        onDevice.prepareFails = true
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice, fallbackLanguages: ["ru-RU": russian],
                                            fallbackRetryPause: 0.2)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        // Before any attempt the model can be expected.
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        transcriber.abandonUtterance()

        await transcriber.prepareFallback()
        #expect(onDevice.prepares == 1 && transcriber.displayName == "OpenAI")
        #expect(!transcriber.beginUtterance(liveWords: HeardWords().handler))
        transcriber.abandonUtterance()
        try await Task.sleep(for: .milliseconds(50))
        // Not at every dictation.
        #expect(onDevice.prepares == 1)

        onDevice.prepareFails = false
        try await Task.sleep(for: .milliseconds(250))
        #expect(!transcriber.beginUtterance(liveWords: HeardWords().handler))
        #expect(await waitUntil { transcriber.displayName == "OpenAI (on-device fallback)" })
        #expect(onDevice.prepares == 2)
        transcriber.abandonUtterance()
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        #expect(onDevice.liveBegun == 1)
    }

    /// A reconnect replaces the microphone format while the model loads for the old one: that
    /// preparation doesn't count, and the next one does.
    @Test func aReconnectDuringThePreparationLeavesTheFallbackUnprepared() async throws {
        let onDevice = FakeOnDevice()
        let (transcriber, preparation) = try await preparing(onDevice)
        try await transcriber.prepare(micFormat: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!,
                                      language: russian)
        onDevice.releasePrepare()
        await preparation.value
        #expect(transcriber.displayName == "OpenAI")
        await transcriber.prepareFallback()
        #expect(onDevice.prepares == 2 && transcriber.displayName == "OpenAI (on-device fallback)")
    }

    /// "en-US" is asked for and the iPhone holds the British model: it listens.
    @Test func aModelOfTheSameLanguageForAnotherRegionListens() async throws {
        let onDevice = FakeOnDevice()
        let british = ResolvedLanguage(tag: "en-GB", locale: Locale(identifier: "en-GB"), engine: .speech)
        let american = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice,
                                            fallbackLanguages: ["en-GB": british, "ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: american)
        await transcriber.prepareFallback()
        #expect(onDevice.preparedTag == "en-GB")
        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        #expect(onDevice.liveBegun == 1)
    }

    /// The guess changes while a dictation listens (the other language's model was found): the
    /// recognizer is left alone under it, the dictation's transcript stays in the language it
    /// listened in, and the next dictation begins in the new one.
    @Test func aGuessThatChangesDuringADictationIsTakenUpByTheNextOne() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice,
                                            fallbackLanguages: ["ru-RU": russian, "en-US": english])
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        transcriber.setAutomaticFallback(russian)
        await transcriber.prepareFallback()
        #expect(onDevice.preparedTag == "ru-RU")

        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        feed(transcriber, seconds: 1)
        transcriber.setAutomaticFallback(english)
        #expect(!onDevice.events.contains("language en-US"))
        let output = try await transcriber.finishUtterance(model: nil)
        #expect(output.detectedLanguage == "ru-RU")

        #expect(transcriber.beginUtterance(liveWords: HeardWords().handler))
        let events = onDevice.events
        #expect(try #require(events.firstIndex(of: "language en-US")) < #require(events.lastIndex(of: "live")))
        transcriber.abandonUtterance()
    }

    /// Under Auto-detect the words come in the installed language the session guesses; without a
    /// guess there are none.
    @Test func underAutoDetectTheLiveWordsAreInTheGuessedLanguage() async throws {
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice,
                                            fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: automatic)
        await transcriber.prepareFallback()
        let heard = HeardWords()
        #expect(!transcriber.beginUtterance(liveWords: heard.handler))
        #expect(onDevice.begun == 0 && onDevice.liveBegun == 0)
        transcriber.abandonUtterance()

        transcriber.setAutomaticFallback(russian)
        await transcriber.prepareFallback()
        #expect(onDevice.preparedTag == "ru-RU")
        #expect(transcriber.beginUtterance(liveWords: heard.handler))
        #expect(onDevice.liveBegun == 1)
        onDevice.say("Привет")
        #expect(heard.all == ["Привет"])
    }

    /// The words on the keyboard are only a preview: the cloud's transcript is the dictation's
    /// text, and the fallback that said them is dropped without being asked for its own.
    @Test func theCloudsTranscriptIsTheResultWhateverTheLiveWordsSaid() async throws {
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice,
                                            fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        let heard = HeardWords()
        #expect(transcriber.beginUtterance(liveWords: heard.handler))
        feed(transcriber, seconds: 1)
        onDevice.say("something else", " entirely")

        let output = try await transcriber.finishUtterance(model: nil)

        #expect(heard.all == ["something else entirely"])
        #expect(output.transcript == "Hello from OpenAI.")
        #expect(output.heardInCloud)
        #expect(onDevice.finished == 0 && onDevice.abandoned == 1)
    }

    // MARK: The free plan's weekly limit

    /// Its own settings, so a test's "words used up" stays its own.
    private func limitSettings() -> SharedSettings {
        SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.limit.\(UUID().uuidString)"))
    }

    private func dictation(style: StylePreset, target: String? = nil) -> ActiveDictation {
        ActiveDictation(requestId: UUID(), documentIdentifier: nil, style: style, language: "ru-RU",
                        translationTargetLanguage: target, source: .keyboard, startedAt: Date())
    }

    /// The server refused the dictation for the week's words: the iPhone's own recognition, ready
    /// and listening, doesn't stand in for it.
    @Test func aDictationOverTheLimitIsNeverRecognizedOnTheIPhone() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.limitReached)
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(onDevice.appended > 0)
        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }
        #expect(onDevice.finished == 0 && onDevice.abandoned == 1)
        // The refusal says nothing about the connection: the next dictation asks the cloud again.
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }
        #expect(cloud.calls.count == 2 && onDevice.finished == 0)
    }

    /// The same through `dictate`, for a style the model writes and for Word for word, and for too
    /// many dictations a minute.
    @Test(arguments: [CloudTranscriptionError.limitReached, .rateLimited])
    func aRefusedDictateIsNeverRecognizedOnTheIPhone(refusal: CloudTranscriptionError) async throws {
        for wordForWord in [false, true] {
            let cloud = FakeCloud()
            let dictate = FakeDictate()
            dictate.failure = refusal
            dictate.plainFailure = refusal
            let onDevice = FakeOnDevice()
            let transcriber = OpenAITranscriber(client: cloud, dictation: dictate, fallback: onDevice,
                                                fallbackLanguages: ["ru-RU": russian])
            try await transcriber.prepare(micFormat: micFormat, language: russian)
            await transcriber.prepareFallback()
            transcriber.beginUtterance()
            feed(transcriber, seconds: 1)
            let request = wordForWord ? nil : ModelRequest(dictationId: UUID(), targetLanguage: nil, style: .grammar,
                                                           dictionary: [], snippets: [])
            await #expect(throws: refusal) {
                try await transcriber.finishUtterance(model: request, dictationId: UUID())
            }
            #expect(onDevice.finished == 0 && cloud.calls.isEmpty)
        }
    }

    /// Offline, or with the cloud paused after a failure, while the week's words are known to be
    /// used up: the iPhone doesn't recognize the dictation, and the user hears why.
    @Test func offlineWithTheWordsUsedUpNothingIsRecognized() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let settings = limitSettings()
        settings.noteWordsUsedUp()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian],
                                            wordsUsedUpUntil: { settings.wordsUsedUpUntil })
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        for _ in 0..<2 {
            transcriber.beginUtterance()
            feed(transcriber, seconds: 1)
            await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }
        }
        // The second one met the pause, which skips the cloud: still nothing on the iPhone.
        #expect(cloud.calls.count == 1)
        #expect(onDevice.finished == 0 && onDevice.abandoned == 2)

        // Past the reset by the iPhone's clock (or a clock moved on), and the server hasn't said
        // the words are back: still nothing on the iPhone, and the cloud's own failure is the reason.
        settings.wordsUsedUpUntil = Date().addingTimeInterval(-60)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        await #expect(throws: CloudTranscriptionError.unavailable("The cloud is paused after a failure.")) {
            try await transcriber.finishUtterance()
        }
        #expect(onDevice.finished == 0)

        // The server said there are words (a new week, Pro): offline dictations are recognized
        // on the iPhone again.
        settings.wordsUsedUpUntil = nil
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        #expect(try await transcriber.finishUtterance() == "Recognized on the iPhone.")
    }

    /// While the week's words were said to be used up and the server hasn't said they are back
    /// (until the reset, and past it by the iPhone's clock), nothing the fallback hears is shown.
    /// It listens and is fed as before, begun without live words. Once the server says there are
    /// words, the next dictation shows them again.
    @Test(arguments: [3_600.0, -60.0])
    func noLiveWordsWhileTheWeeksWordsWaitForTheServer(resetIn: TimeInterval) async throws {
        let onDevice = FakeOnDevice()
        let settings = limitSettings()
        settings.wordsUsedUpUntil = Date().addingTimeInterval(resetIn)
        let transcriber = OpenAITranscriber(client: FakeCloud(), fallback: onDevice,
                                            fallbackLanguages: ["ru-RU": russian],
                                            wordsUsedUpUntil: { settings.wordsUsedUpUntil })
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        let heard = HeardWords()

        #expect(!transcriber.beginUtterance(liveWords: heard.handler))

        #expect(onDevice.liveBegun == 0 && onDevice.begun == 1)
        feed(transcriber, seconds: 1)
        #expect(onDevice.appended > 0)
        onDevice.say("Привет", " как дела")
        #expect(heard.all.isEmpty)
        #expect(try await transcriber.finishUtterance() == "Hello from OpenAI.")

        settings.wordsUsedUpUntil = nil
        #expect(transcriber.beginUtterance(liveWords: heard.handler))
        #expect(onDevice.liveBegun == 1 && onDevice.begun == 1)
        onDevice.say("Привет", " как дела")
        #expect(heard.all == ["Привет как дела"])
    }

    /// The server refused the dictation for the week's words, and its words were on the keyboard
    /// while it was spoken: the iPhone's own recognition still doesn't stand in for it, and nothing
    /// of what was shown reaches the keyboard's field or the history.
    @Test func aRefusedDictationIsStillNeverRecognizedWithLiveWordsOn() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.limitReached)
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        let heard = HeardWords()
        #expect(transcriber.beginUtterance(liveWords: heard.handler))
        feed(transcriber, seconds: 1)
        onDevice.say("увидимся на вокзале", " в пять")
        #expect(heard.all == ["увидимся на вокзале в пять"])
        #expect(onDevice.appended > 0)

        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcriber.finishUtterance() }

        #expect(onDevice.finished == 0 && onDevice.abandoned == 1)

        // The same through the pipeline: the keyboard and the history get no text.
        #expect(transcriber.beginUtterance(liveWords: heard.handler))
        feed(transcriber, seconds: 1)
        onDevice.say("увидимся на вокзале", " в пять")
        let settings = limitSettings()
        let outcome = await DictationPipeline(cleanup: TimedCleanup(), settings: settings).complete(
            dictation(style: .verbatim), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)
        #expect(outcome.result.status == .limitReached && outcome.result.text.isEmpty)
        #expect(!outcome.result.isInsertable)
        #expect(outcome.transcript.rawText.isEmpty && outcome.transcript.displayText.isEmpty)
        #expect(onDevice.finished == 0 && onDevice.abandoned == 2)
        // The mark, not the clock: for ten minutes after the weekly reset nothing counts as used up.
        #expect(settings.wordsAwaitServer)
    }

    /// The dictation that spends the last words answers 200 with none left: the next tap shows the
    /// way to Pro. A reply with words left (a new week) lifts that.
    @Test func theWordsLeftInAReplyAreKept() async throws {
        let cloud = FakeCloud()
        cloud.result = .success("see you at five")
        cloud.remaining = 0
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        let settings = limitSettings()
        let pipeline = DictationPipeline(cleanup: TimedCleanup(), settings: settings)

        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let spent = await pipeline.complete(dictation(style: .verbatim), transcriber: transcriber, audioSeconds: 1,
                                            stoppedAt: ContinuousClock.now)
        #expect(spent.result.isInsertable)
        #expect(settings.wordsUsedUp())

        cloud.remaining = 1_000
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = await pipeline.complete(dictation(style: .verbatim), transcriber: transcriber, audioSeconds: 1,
                                    stoppedAt: ContinuousClock.now)
        #expect(settings.wordsUsedUpUntil == nil)

        // Pro answers no count: nothing changes.
        settings.noteWordsUsedUp()
        cloud.remaining = nil
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        _ = await pipeline.complete(dictation(style: .verbatim), transcriber: transcriber, audioSeconds: 1,
                                    stoppedAt: ContinuousClock.now)
        #expect(settings.wordsUsedUp())
    }

    /// Word for word at the limit, with the iPhone's model ready: nothing for the keyboard or the
    /// history, the limit's notice, and no dictation until the week resets.
    @Test func pastTheLimitTheKeyboardAndTheHistoryGetNoText() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.limitReached)
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let settings = limitSettings()

        let outcome = await DictationPipeline(cleanup: TimedCleanup(), settings: settings).complete(
            dictation(style: .verbatim), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

        #expect(outcome.result.status == .limitReached && outcome.result.text.isEmpty)
        #expect(!outcome.result.isInsertable)
        #expect(outcome.result.message == Brand.limitReachedMessage)
        #expect(outcome.transcript.rawText.isEmpty && outcome.transcript.cleanedText == nil)
        #expect(outcome.transcript.displayText.isEmpty && !outcome.transcript.isInsertable)
        #expect(settings.wordsUsedUp())
        let reset = try #require(settings.wordsUsedUpUntil)
        #expect(reset == WeeklyWords.nextReset(after: Date()))
    }

    /// The cloud transcribed it (the server checked the words first), and the words ran out at the
    /// cleanup: it goes in as the iPhone formatted it, and the notice follows.
    @Test func theDictationThatUsedTheLastWordsGoesInWithTheNotice() async throws {
        let cloud = FakeCloud()
        cloud.result = .success("see you at the station at five")
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let settings = limitSettings()
        let cleanup = RefusingCleanup()

        let outcome = await DictationPipeline(cleanup: cleanup, settings: settings).complete(
            dictation(style: .grammar), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

        #expect(cleanup.calls == 1)
        #expect(outcome.result.status == .raw && outcome.result.isInsertable)
        #expect(outcome.result.text.localizedCaseInsensitiveContains("see you at the station"))
        #expect(outcome.result.message == Brand.limitReachedMessage)
        #expect(outcome.transcript.status == .raw && outcome.transcript.rawText == "see you at the station at five")
        #expect(outcome.transcript.errorReason == "Dictation limit reached.")
        #expect(settings.wordsUsedUp())
    }

    /// The iPhone recognized it while the cloud was out of reach, then the cleanup found the words
    /// gone: nothing the server never took goes in, or into the history.
    @Test func anIPhoneTranscriptRefusedAtTheCleanupDoesNotGoIn() async throws {
        let cloud = FakeCloud()
        cloud.result = .failure(.unavailable("offline"))
        let onDevice = FakeOnDevice()
        let transcriber = OpenAITranscriber(client: cloud, fallback: onDevice, fallbackLanguages: ["ru-RU": russian])
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        await transcriber.prepareFallback()
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let settings = limitSettings()
        let cleanup = RefusingCleanup()

        let outcome = await DictationPipeline(cleanup: cleanup, settings: settings).complete(
            dictation(style: .grammar), transcriber: transcriber, audioSeconds: 1, stoppedAt: ContinuousClock.now)

        #expect(onDevice.finished == 1 && cleanup.calls == 1)
        #expect(outcome.result.status == .limitReached && outcome.result.text.isEmpty)
        #expect(outcome.result.message == Brand.limitReachedMessage)
        #expect(outcome.transcript.rawText.isEmpty && outcome.transcript.displayText.isEmpty)
        #expect(outcome.transcript.metrics.words == 0)
        #expect(settings.wordsUsedUp())
    }

    /// A translation refused at the limit keeps nothing, not even the transcript it was heard as.
    @Test func aTranslationRefusedAtTheLimitKeepsNoTranscript() async throws {
        let cloud = FakeCloud()
        cloud.result = .success("see you at the station at five")
        let transcriber = OpenAITranscriber(client: cloud)
        try await transcriber.prepare(micFormat: micFormat, language: russian)
        transcriber.beginUtterance()
        feed(transcriber, seconds: 1)
        let settings = limitSettings()

        let outcome = await DictationPipeline(cleanup: RefusingCleanup(), settings: settings).complete(
            dictation(style: .verbatim, target: "en-US"), transcriber: transcriber, audioSeconds: 1,
            stoppedAt: ContinuousClock.now)

        #expect(outcome.result.status == .limitReached && outcome.result.text.isEmpty)
        #expect(outcome.transcript.rawText.isEmpty && outcome.transcript.displayText.isEmpty)
        #expect(settings.wordsUsedUp())
    }

    /// Retry and Regenerate at the limit change nothing: the stored text stays, and the user is
    /// told why.
    @Test func regenerateAtTheLimitLeavesTheTranscriptAsItWas() async throws {
        let settings = limitSettings()
        let stored = Transcript(rawText: "see you at the station at five", cleanedText: "See you at the station at five.",
                                status: .cleaned)
        do {
            _ = try await DictationPipeline(cleanup: RefusingCleanup(), settings: settings).recleanup(stored)
            Issue.record("Regenerate at the limit gave a transcript to store")
        } catch {
            guard case .limitReached = error else {
                Issue.record("expected limitReached, got \(error)")
                return
            }
        }
        #expect(settings.wordsUsedUp())
    }

    /// Release builds never take the Debug screen's recognizer, which would skip the server.
    @Test func theRecognizerSettingIsOnlyADebugChoice() {
        #expect(TranscriberEngine.resolve(stored: "onDevice", debug: false) == .auto)
        #expect(TranscriberEngine.resolve(stored: "stub", debug: false) == .auto)
        #expect(TranscriberEngine.resolve(stored: "onDevice", debug: true) == .onDevice)
        #expect(TranscriberEngine.resolve(stored: nil, debug: true) == .auto)
        #expect(TranscriberEngine.resolve(stored: "nonsense", debug: true) == .auto)
    }
}
