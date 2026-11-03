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
}

/// The dictation behind the practice screens. Production (`SessionPracticeClient`) is the real
/// session driven by the Murmur keyboard; UI tests and screenshots use `ScriptedPracticeClient`.
@MainActor
protocol PracticeDictationClient: AnyObject {
    var state: PracticeDictationState { get }
    /// True when the keyboard inserts the result itself; a scripted client has the screen do it.
    var insertsText: Bool { get }
    /// Turns the session on (so the keyboard's mic starts at once) and attributes the next
    /// dictations to `exercise`.
    func begin(_ exercise: PracticeExercise) async
    func end()
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
    private var exercise: PracticeExercise?
    private var beganAt = Date.distantFuture

    init(session: SessionController, buffer: PracticeTranscriptBuffer) {
        self.session = session
        self.buffer = buffer
    }

    var insertsText: Bool { true }

    var state: PracticeDictationState {
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

    func begin(_ exercise: PracticeExercise) async {
        self.exercise = exercise
        beganAt = Date()
        buffer.activeExercise = exercise
        if !session.isLive { await session.start() }
    }

    func end() {
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
    @ObservationIgnored private var exercise: PracticeExercise = .basic
    @ObservationIgnored private let delay: Duration
    /// The state passed to `init` is for the first screen only (a screenshot route).
    @ObservationIgnored private var startedOnce = false

    init(state: PracticeDictationState = .idle, delay: Duration = .milliseconds(400)) {
        self.state = state
        self.delay = delay
    }

    var insertsText: Bool { false }

    func begin(_ exercise: PracticeExercise) async {
        self.exercise = exercise
        if startedOnce { state = .idle }
        startedOnce = true
    }

    func end() {}

    func simulateDictation() {
        let text = Self.sampleText(for: exercise)
        Task {
            state = .listening
            try? await Task.sleep(for: delay)
            state = .processing
            try? await Task.sleep(for: delay)
            state = .completed(text)
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
