@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Says the same words for every dictation; a test has no microphone.
private final class PracticeTranscriber: Transcriber, @unchecked Sendable {
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

/// No cleanup service: the transcript is formatted on the iPhone.
@MainActor
private final class NoPracticeCleanup: Cleaning {
    let isConfigured = false

    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?, style: StylePreset,
        dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        throw .notConfigured
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

/// The exercise pages over the real session. Pages slide, so the page being left disappears (and
/// ends its exercise) only after the next page has begun: that late end must not take the new
/// page's exercise away, or its dictation never counts and the page never offers Next.
@MainActor
struct PracticeDictationTests {
    private let transport = InMemoryIPCTransport()
    private let history: HistoryStore
    private let buffer: PracticeTranscriptBuffer
    private let session: SessionController
    private let practice: SessionPracticeClient

    init() throws {
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.practice.\(UUID().uuidString)")!)
        settings.interactionSounds = false
        history = try HistoryStore(inMemory: true, settings: settings)
        buffer = PracticeTranscriptBuffer(history: history, fileURL: nil)
        session = SessionController(
            transport: transport, pipeline: DictationPipeline(cleanup: NoPracticeCleanup()), assets: SpeechAssetManager(),
            history: buffer, settings: settings)
        session.startForTesting(
            with: PracticeTranscriber(),
            language: ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech))
        practice = SessionPracticeClient(session: session, buffer: buffer)
    }

    /// The keyboard's mic tapped, then tapped again, as in the practice box.
    private func dictate() async throws {
        let requestId = UUID()
        try transport.payloads.write(command: KeyboardCommand(requestId: requestId, kind: .start, createdAt: Date()))
        transport.post(.command)
        #expect(await waitUntil { session.phase == .recording(requestId) })
        try transport.payloads.write(command: KeyboardCommand(requestId: requestId, kind: .stop, createdAt: Date()))
        transport.post(.command)
        // The result is written, then the take recorded, then the session is ready, in one turn.
        #expect(await waitUntil { session.phase == .ready && transport.payloads.readResult(requestId) != nil })
    }

    /// The bug seen on the iPhone: from the first exercise to the email, the first page finished
    /// leaving after the email page had begun, and the email's dictation went nowhere.
    @Test func theEmailCountsWhenTheFirstPageFinishesLeavingLate() async throws {
        let first = UUID(), email = UUID()
        await practice.begin(.basic, page: first)
        await practice.begin(.formatting, page: email)
        practice.end(page: first)

        try await dictate()

        let take = try #require(buffer.latest[.formatting])
        #expect(!take.displayText.isEmpty)
        #expect(practice.state == .completed(take.displayText))
        #expect(buffer.latest[.basic] == nil)
        #expect(history.recent().isEmpty, "a practice take waits for the end of onboarding")
    }

    /// Back from the email to the first exercise: the email page finishes leaving last.
    @Test func goingBackKeepsTheFirstExercise() async throws {
        let email = UUID(), first = UUID()
        await practice.begin(.formatting, page: email)
        await practice.begin(.basic, page: first)
        practice.end(page: email)

        try await dictate()

        let take = try #require(buffer.latest[.basic])
        #expect(practice.state == .completed(take.displayText))
        #expect(buffer.latest[.formatting] == nil)
    }

    /// After the last exercise page has gone, a dictation is an ordinary one.
    @Test func onceTheLastPageHasGoneADictationGoesToHistory() async throws {
        let whisper = UUID()
        await practice.begin(.whisper, page: whisper)
        practice.end(page: whisper)

        try await dictate()

        #expect(buffer.latest.isEmpty)
        #expect(history.recent().count == 1)
        #expect(practice.state == .idle)
    }
}
