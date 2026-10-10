import Foundation
import MurmurCore
import SwiftData

/// Version 1 of the on-device history. Enums are stored as raw strings so `#Predicate` can
/// filter on them. Transcripts are never synced (PLAN.md: history stays on the device).
enum HistorySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TranscriptRecord.self]
    }

    @Model
    final class TranscriptRecord {
        @Attribute(.unique) var id: UUID
        var createdAt: Date
        var language: String?
        var style: String
        var rawText: String
        var cleanedText: String?
        var status: String
        var errorReason: String?
        var audioSeconds: Double
        var words: Int
        var asrMs: Int?
        var cleanupMs: Int?
        var ttftMs: Int?
        var totalMs: Int?
        var cleanupModel: String?
        var insertedAt: Date?
        var regeneratedAt: Date?
        var source: String

        init(_ transcript: Transcript) {
            id = transcript.id
            createdAt = transcript.createdAt
            language = transcript.language
            style = transcript.style.rawValue
            rawText = transcript.rawText
            cleanedText = transcript.cleanedText
            status = transcript.status.rawValue
            errorReason = transcript.errorReason
            audioSeconds = transcript.metrics.audioSeconds
            words = transcript.metrics.words
            asrMs = transcript.metrics.asrMs
            cleanupMs = transcript.metrics.cleanupMs
            ttftMs = transcript.metrics.ttftMs
            totalMs = transcript.metrics.totalMs
            cleanupModel = transcript.cleanupModel
            insertedAt = transcript.insertedAt
            regeneratedAt = transcript.regeneratedAt
            source = transcript.source.rawValue
        }

        /// Copies every field except `id`.
        func apply(_ transcript: Transcript) {
            createdAt = transcript.createdAt
            language = transcript.language
            style = transcript.style.rawValue
            rawText = transcript.rawText
            cleanedText = transcript.cleanedText
            status = transcript.status.rawValue
            errorReason = transcript.errorReason
            audioSeconds = transcript.metrics.audioSeconds
            words = transcript.metrics.words
            asrMs = transcript.metrics.asrMs
            cleanupMs = transcript.metrics.cleanupMs
            ttftMs = transcript.metrics.ttftMs
            totalMs = transcript.metrics.totalMs
            cleanupModel = transcript.cleanupModel
            insertedAt = transcript.insertedAt
            regeneratedAt = transcript.regeneratedAt
            source = transcript.source.rawValue
        }

        var snapshot: Transcript {
            Transcript(
                id: id,
                createdAt: createdAt,
                language: language,
                style: StylePreset(rawValue: style) ?? .casual,
                rawText: rawText,
                cleanedText: cleanedText,
                status: TranscriptStatus(rawValue: status) ?? .raw,
                errorReason: errorReason,
                metrics: TranscriptMetrics(
                    audioSeconds: audioSeconds, words: words, asrMs: asrMs, cleanupMs: cleanupMs,
                    ttftMs: ttftMs, totalMs: totalMs),
                cleanupModel: cleanupModel,
                insertedAt: insertedAt,
                regeneratedAt: regeneratedAt,
                source: TranscriptSource(rawValue: source) ?? .keyboard)
        }
    }
}

typealias TranscriptRecord = HistorySchemaV1.TranscriptRecord
