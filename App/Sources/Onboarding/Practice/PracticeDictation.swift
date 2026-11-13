import Foundation
import MurmurCore
import Observation

/// What a practice screen shows about the dictation in progress.
enum PracticeDictationState: Equatable, Sendable {
    case idle
    case listening
    case processing
    /// The finished text. The real keyboard has already inserted it into the field.
    case completed(String)
    case failed(String)
    /// "Not now" to "Before Murmur listens": no session, so nothing to dictate with. The page
    /// offers the question again, or skipping the exercises.
    case notAllowed
}

/// The dictation behind the practice screens. Production (`SessionPracticeClient`) is the real
/// session driven by the Murmur keyboard; UI tests and screenshots use `ScriptedPracticeClient`.
@MainActor
protocol PracticeDictationClient: AnyObject {
    var state: PracticeDictationState { get }
    /// True when the keyboard inserts the result itself; a scripted client has the screen do it.
    var insertsText: Bool { get }
    /// The first exercise is where "Before Murmur listens" is asked, after the system's question
    /// about the microphone: true once it is allowed. After "Not now" it isn't asked again by the
    /// next exercise; `askAgain()` does that. Asked before the box takes the keyboard, which would
    /// cover the question's buttons.
    func allow() async -> Bool
    /// "Try again" after "Not now".
    func askAgain() async -> Bool
    /// Attributes the next dictations to `exercise` and, once allowed, turns the session on (so
    /// the keyboard's mic starts at once). `page` names the page on screen, for `end(page:)`.
    func begin(_ exercise: PracticeExercise, page: UUID) async
    /// Stops attributing dictations to an exercise, unless another page has begun since: a page
    /// that is sliding away disappears only after the next one has begun.
    func end(page: UUID)
    /// Scripted clients only: plays a listening → processing → completed run.
    func simulateDictation()
}

/// The real session. The keyboard records through the hot mic like in any other app, and the
/// finished transcript arrives through `PracticeTranscriptBuffer`.
@MainActor
@Observable
final class SessionPracticeClient: PracticeDictationClient {
    @ObservationIgnored private let session: SessionController
    @ObservationIgnored private let buffer: PracticeTranscriptBuffer
    @ObservationIgnored private let consent: AIConsent
    private var exercise: PracticeExercise?
    private var beganAt = Date.distantFuture
    /// The page that began last; only it can end the exercise.
    @ObservationIgnored private var page: UUID?
    /// "Not now" was the answer in this run.
    private var declined = false

    init(session: SessionController, buffer: PracticeTranscriptBuffer, consent: AIConsent) {
        self.session = session
        self.buffer = buffer
        self.consent = consent
    }

    var insertsText: Bool { true }

    var state: PracticeDictationState {
        if declined, !consent.isGranted { return .notAllowed }
        switch session.phase {
        case .recording: return .listening
        case .processing: return .processing
        case .failed(let message): return .failed(message)
        default:
            guard let exercise, let transcript = buffer.latest[exercise], transcript.createdAt >= beganAt else {
                return .idle
            }
            let text = transcript.displayText
            return text.isEmpty ? .failed(transcript.errorReason ?? "We didn't catch that. Try again.") : .completed(text)
        }
    }

    func allow() async -> Bool {
        if consent.isGranted { return true }
        guard !declined else { return false }
        declined = !(await consent.ensure())
        return !declined
    }

    func askAgain() async -> Bool {
        declined = false
        return await allow()
    }

    func begin(_ exercise: PracticeExercise, page: UUID) async {
        self.page = page
        self.exercise = exercise
        beganAt = Date()
        buffer.activeExercise = exercise
        // Without the OK there is no session: it would only ask again.
        guard consent.isGranted else { return }
        if !session.isLive { await session.start() }
    }

    func end(page: UUID) {
        guard page == self.page else { return }
        self.page = nil
        buffer.activeExercise = nil
        exercise = nil
    }

    func simulateDictation() {}
}

/// Deterministic dictation for UI tests and screenshot routes.
@MainActor
@Observable
final class ScriptedPracticeClient: PracticeDictationClient {
    private(set) var state: PracticeDictationState
    @ObservationIgnored private var exercise: PracticeExercise?
    @ObservationIgnored private var page: UUID?
    @ObservationIgnored private let delay: Duration
    /// The question as the app asks it; fixture runs allow without asking unless `-ai-consent`.
    @ObservationIgnored private let consent: AIConsent
    /// The state passed to `init` is for the first screen only (a screenshot route).
    @ObservationIgnored private var startedOnce = false
    @ObservationIgnored private var declined = false

    init(state: PracticeDictationState = .idle, delay: Duration = .milliseconds(400),
         consent: AIConsent = .allowedForFixtures()) {
        self.state = state
        self.delay = delay
        self.consent = consent
    }

    var insertsText: Bool { false }

    func allow() async -> Bool {
        if consent.isGranted { return true }
        if !declined { declined = !(await consent.ensure()) }
        if declined { state = .notAllowed }
        return !declined
    }

    func askAgain() async -> Bool {
        declined = false
        let allowed = await allow()
        if allowed, state == .notAllowed { state = .idle }
        return allowed
    }

    func begin(_ exercise: PracticeExercise, page: UUID) async {
        self.page = page
        self.exercise = exercise
        if startedOnce, state != .notAllowed { state = .idle }
        startedOnce = true
    }

    func end(page: UUID) {
        guard page == self.page else { return }
        self.page = nil
        exercise = nil
    }

    func simulateDictation() {
        guard state != .notAllowed else { return }
        Task {
            state = .listening
            try? await Task.sleep(for: delay)
            state = .processing
            try? await Task.sleep(for: delay)
            // Like the real session: the take counts for the exercise on screen when it finishes.
            guard let exercise else {
                state = .idle
                return
            }
            state = .completed(Self.sampleText(for: exercise))
        }
    }

    nonisolated static func sampleText(for exercise: PracticeExercise) -> String {
        switch exercise {
        case .basic: "Hello from Murmur."
        case .formatting: "Hey Tim, are you available on Friday at 4 pm?"
        case .whisper: "1. Call mom.\n2. Walk the dog."
        }
    }
}

/// Sits between the session and history while onboarding runs. Practice dictations are held per
/// exercise (a retry replaces the previous take) and copied into history once onboarding is
/// complete, so Home starts with one entry per exercise and no duplicates.
@MainActor
@Observable
final class PracticeTranscriptBuffer: TranscriptSink {
    private(set) var latest: [PracticeExercise: Transcript] = [:]
    /// The exercise on screen; dictations outside the practice screens go straight to history.
    @ObservationIgnored var activeExercise: PracticeExercise?
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let fileURL: URL?

    /// `fileURL`: where takes survive a termination (the app's private container, never the
    /// App Group, since they hold dictated text). Nil keeps them in memory.
    init(history: HistoryStore, fileURL: URL? = PracticeTranscriptBuffer.defaultFileURL) {
        self.history = history
        self.fileURL = fileURL
        if let fileURL, let stored = JSONFile.read([String: Transcript].self, from: fileURL) {
            for (key, transcript) in stored {
                if let exercise = PracticeExercise(rawValue: key) { latest[exercise] = transcript }
            }
        }
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("onboarding-practice.json")
    }

    func record(_ transcript: Transcript) {
        guard let exercise = activeExercise else {
            history.record(transcript)
            return
        }
        latest[exercise] = transcript
        persist()
    }

    /// Copies the latest take of each exercise into history, in exercise order. Upserts by id,
    /// so running it again after a termination doesn't duplicate anything.
    func flushToHistory() {
        for exercise in PracticeExercise.allCases {
            guard var transcript = latest[exercise], !transcript.displayText.isEmpty else { continue }
            // The keyboard put it in the practice box, so it was inserted.
            transcript.insertedAt = transcript.insertedAt ?? transcript.createdAt
            history.upsert(transcript)
        }
        latest = [:]
        if let fileURL { JSONFile.remove(fileURL) }
    }

    private func persist() {
        guard let fileURL else { return }
        let stored = Dictionary(uniqueKeysWithValues: latest.map { ($0.key.rawValue, $0.value) })
        try? JSONFile.write(stored, to: fileURL)
    }
}
