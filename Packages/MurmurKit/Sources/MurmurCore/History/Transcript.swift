import Foundation

/// Outcome of a stored dictation. Mirrors `ResultStatus` without `cancelled` (cancelled
/// dictations are never stored) and adds `processing` for the provisional row written before
/// cleanup finishes.
public enum TranscriptStatus: String, Codable, Sendable, CaseIterable {
    /// Cleaned by the AI cleanup service.
    case cleaned
    /// Local formatting only (offline, timeout, refusal, AI cleanup off).
    case raw
    case failed
    /// Nothing was recognized.
    case empty
    /// Locally formatted text delivered together with the usage-limit notice.
    case limitReached
    /// Recognized; cleanup still running (or interrupted, see `recoverInterrupted`).
    case processing

    public init(_ status: ResultStatus) {
        switch status {
        case .cleaned: self = .cleaned
        case .raw: self = .raw
        case .empty: self = .empty
        case .limitReached: self = .limitReached
        // Cancelled dictations are never stored; map defensively instead of trapping.
        case .failed, .cancelled: self = .failed
        }
    }
}

/// Per-dictation numbers shown in Details and summarized on the Debug screen.
public struct TranscriptMetrics: Codable, Sendable, Hashable {
    public var audioSeconds: Double
    public var words: Int
    /// Stop → final on-device transcript.
    public var asrMs: Int?
    /// Cleanup request round trip.
    public var cleanupMs: Int?
    /// Cleanup time to first token.
    public var ttftMs: Int?
    /// Stop → result delivered.
    public var totalMs: Int?

    public init(audioSeconds: Double, words: Int, asrMs: Int? = nil, cleanupMs: Int? = nil,
                ttftMs: Int? = nil, totalMs: Int? = nil) {
        self.audioSeconds = audioSeconds
        self.words = words
        self.asrMs = asrMs
        self.cleanupMs = cleanupMs
        self.ttftMs = ttftMs
        self.totalMs = totalMs
    }

    public init(_ metrics: DictationMetrics) {
        self.init(audioSeconds: metrics.audioSeconds, words: metrics.words,
                  asrMs: metrics.stopToTranscriptMs, cleanupMs: metrics.cleanupMs,
                  totalMs: metrics.stopToResultMs)
    }

    public var wpm: Int {
        WordCounter.wordsPerMinute(words: words, seconds: audioSeconds)
    }
}

public enum TranscriptSource: String, Codable, Sendable {
    case keyboard
    case inApp
}

/// Whether a transcript's text reached the field it was dictated into.
public enum InsertState: Sendable, Hashable {
    case inserted
    /// The keyboard may still pick it up ("Insert last dictation").
    case pending
    case notInserted
    /// Nothing to insert (failed, empty, still processing).
    case none
}

/// A stored dictation. Pure value type; the app persists it as a SwiftData record and the rules
/// below are what the list, details and Debug screens render.
public struct Transcript: Identifiable, Codable, Sendable, Hashable {
    /// Equals `DictationResult.requestId`, so insertion can be reconciled with the keyboard's claims.
    public var id: UUID
    public var createdAt: Date
    /// BCP-47 tag the dictation was recognized in.
    public var language: String?
    public var style: StylePreset
    /// Locally formatted on-device transcript. Stays in the app's private store.
    public var rawText: String
    public var cleanedText: String?
    public var status: TranscriptStatus
    /// User-facing reason for `failed`, `empty` and `limitReached`.
    public var errorReason: String?
    public var metrics: TranscriptMetrics
    /// Identifier of the cleanup model; nil for raw results.
    public var cleanupModel: String?
    /// When the text was inserted (set by the store once the keyboard claimed the result, or on
    /// in-app insertion).
    public var insertedAt: Date?
    /// Last successful Regenerate.
    public var regeneratedAt: Date?
    public var source: TranscriptSource

    /// How long the keyboard offers "Insert last dictation" for an unclaimed result
    /// (`KeyboardSessionClient.checkForResult`).
    public static let insertWindow: TimeInterval = 120

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), language: String? = nil,
        style: StylePreset = .casual, rawText: String, cleanedText: String? = nil,
        status: TranscriptStatus, errorReason: String? = nil,
        metrics: TranscriptMetrics = TranscriptMetrics(audioSeconds: 0, words: 0),
        cleanupModel: String? = nil, insertedAt: Date? = nil, regeneratedAt: Date? = nil,
        source: TranscriptSource = .keyboard
    ) {
        self.id = id
        self.createdAt = createdAt
        self.language = language
        self.style = style
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.status = status
        self.errorReason = errorReason
        self.metrics = metrics
        self.cleanupModel = cleanupModel
        self.insertedAt = insertedAt
        self.regeneratedAt = regeneratedAt
        self.source = source
    }

    /// What the list, Copy and Insert use.
    public var displayText: String {
        cleanedText ?? rawText
    }

    /// Statuses whose text is final: `processing` is still changing, `failed`/`empty` have none.
    private var hasFinalText: Bool {
        switch status {
        case .cleaned, .raw, .limitReached: true
        case .failed, .empty, .processing: false
        }
    }

    /// Cleanup can be run again (Regenerate) from the stored raw transcript.
    public var canRegenerate: Bool {
        hasFinalText && !rawText.isEmpty
    }

    /// Mirrors `DictationResult.isInsertable`.
    public var isInsertable: Bool {
        hasFinalText && !displayText.isEmpty
    }

    /// `claimed` is the keyboard's `IPCPayloadStore.isClaimed(id)`. Checked only for insertable
    /// transcripts: the keyboard also claims failed/empty results just to acknowledge the notice,
    /// so a claim on those must not read as "inserted".
    public func insertState(now: Date, claimed: Bool) -> InsertState {
        guard isInsertable else { return .none }
        if insertedAt != nil || claimed { return .inserted }
        return now.timeIntervalSince(createdAt) < Self.insertWindow ? .pending : .notInserted
    }
}
