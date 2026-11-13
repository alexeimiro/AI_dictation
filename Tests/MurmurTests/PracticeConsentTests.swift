@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Stands in for "Before Murmur listens": answers as told, and counts how often it was shown.
@MainActor
private final class Question {
    var answer: Bool
    private(set) var asked = 0

    init(answer: Bool) {
        self.answer = answer
    }

    func ask() async -> Bool {
        asked += 1
        return answer
    }
}

/// A transcriber for a session that is on without a microphone.
private final class QuietTranscriber: Transcriber, @unchecked Sendable {
    let displayName = "Test"
    var currentLanguage: ResolvedLanguage?

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        currentLanguage = language
    }
    func setLanguage(_ language: ResolvedLanguage) { currentLanguage = language }
    func beginUtterance() {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finishUtterance() async throws -> String { "" }
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        UtteranceOutput(transcript: try await finishUtterance())
    }
    func cancelUtterance() async {}
    func abandonUtterance() {}
    func shutdown() async {}
}

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

/// "Before Murmur listens" on the first exercise, after the system's microphone question (App
/// Review 5.1.1: the microphone page itself offers no way out). "Not now" leaves the session off,
/// and the page offers the question again or skipping the exercises; the next exercises don't ask
/// again by themselves.
@MainActor
struct PracticeConsentTests {
    private let english = ResolvedLanguage(tag: "en-US", locale: Locale(identifier: "en-US"), engine: .speech)

    private func makeSession() throws -> (session: SessionController, buffer: PracticeTranscriptBuffer) {
        let settings = SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.practice-consent.\(UUID().uuidString)"))
        settings.interactionSounds = false
        let history = try HistoryStore(inMemory: true, settings: settings)
        let buffer = PracticeTranscriptBuffer(history: history, fileURL: nil)
        let session = SessionController(
            transport: InMemoryIPCTransport(), pipeline: DictationPipeline(cleanup: NoCleanup()),
            assets: SpeechAssetManager(), history: buffer, settings: settings)
        return (session, buffer)
    }

    @Test func notNowLeavesTheSessionOffAndTheNextExerciseDoesntAskAgain() async throws {
        let (session, buffer) = try makeSession()
        let question = Question(answer: false)
        let consent = AIConsent(settings: nil, ask: question.ask)
        let practice = SessionPracticeClient(session: session, buffer: buffer, consent: consent)

        #expect(await !practice.allow())
        #expect(question.asked == 1)
        #expect(practice.state == .notAllowed)
        await practice.begin(.basic, page: UUID())
        #expect(session.phase == .off, "no session without the OK: it would only ask again")
        #expect(buffer.activeExercise == .basic)

        // The email exercise, after Skip: not asked again unprompted.
        #expect(await !practice.allow())
        await practice.begin(.formatting, page: UUID())
        #expect(question.asked == 1)
        #expect(practice.state == .notAllowed)
        #expect(session.phase == .off)

        // "Try again" asks once more, every time.
        #expect(await !practice.askAgain())
        #expect(question.asked == 2)
        #expect(practice.state == .notAllowed)
        question.answer = true
        #expect(await practice.askAgain())
        #expect(question.asked == 3)
        #expect(consent.isGranted)
        #expect(practice.state == .idle)
        #expect(await practice.allow(), "allowed now, without asking")
        #expect(question.asked == 3)

        // Allowed, the exercise uses the session as before (here one already on).
        session.startForTesting(with: QuietTranscriber(), language: english)
        await practice.begin(.formatting, page: UUID())
        #expect(session.phase == .ready)
        #expect(buffer.activeExercise == .formatting)
    }

    @Test func anOKGivenBeforeIsntAskedAgain() async throws {
        let (session, buffer) = try makeSession()
        let question = Question(answer: false)
        let consent = AIConsent(settings: nil, ask: question.ask)
        consent.grant()
        let practice = SessionPracticeClient(session: session, buffer: buffer, consent: consent)

        #expect(await practice.allow())
        #expect(question.asked == 0)
        #expect(practice.state == .idle)
    }

    /// The UI tests' stand-in asks the same way (`-ai-consent`), so the journey's "Not now" can
    /// be driven end to end.
    @Test func theScriptedExercisesAskAsTheAppDoes() async throws {
        let question = Question(answer: false)
        let practice = ScriptedPracticeClient(delay: .milliseconds(5), consent: AIConsent(settings: nil, ask: question.ask))

        #expect(await !practice.allow())
        await practice.begin(.basic, page: UUID())
        #expect(practice.state == .notAllowed)
        practice.simulateDictation()
        try await Task.sleep(for: .milliseconds(50))
        #expect(practice.state == .notAllowed, "nothing to dictate with")

        #expect(await !practice.allow())
        await practice.begin(.formatting, page: UUID())
        #expect(question.asked == 1)
        #expect(practice.state == .notAllowed)

        question.answer = true
        #expect(await practice.askAgain())
        #expect(practice.state == .idle)
        practice.simulateDictation()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, practice.state != .completed(ScriptedPracticeClient.sampleText(for: .formatting)) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(practice.state == .completed(ScriptedPracticeClient.sampleText(for: .formatting)))
    }

    /// Fixture runs that don't ask (`AIConsent.allowedForFixtures`) never stop for the question.
    @Test func fixtureRunsDontAsk() async {
        let practice = ScriptedPracticeClient()
        #expect(await practice.allow())
        #expect(practice.state == .idle)
    }
}
