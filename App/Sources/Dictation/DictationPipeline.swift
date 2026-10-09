import Foundation
import MurmurCore
import os

/// A dictation in progress.
struct ActiveDictation: Sendable {
    enum Source: Sendable {
        case keyboard
        case inApp
    }

    let requestId: UUID
    let documentIdentifier: UUID?
    let style: StylePreset?
    let source: Source
    let startedAt: Date
}

/// Turns a finished recording into the text the keyboard inserts:
/// on-device transcript → AI cleanup (Claude, via the `cleanup` function) → `DictationResult`.
/// Falls back to `LocalFormatter` when cleanup is off, unavailable, or the dictation is tiny.
@MainActor
final class DictationPipeline {
    private let logger = Logger(subsystem: "Murmur", category: "Pipeline")
    private let cleanup: CleanupClient
    private let settings = SharedSettings.shared

    init(cleanup: CleanupClient) {
        self.cleanup = cleanup
    }

    /// Personal dictionary and snippets. Populated from the data store in Phase 4.
    var dictionary: [DictionaryTerm] = []
    var snippets: [SnippetDefinition] = []

    func contextualStrings() -> [String] {
        Array(dictionary.map(\.term).prefix(100))
    }

    func complete(
        _ dictation: ActiveDictation,
        transcriber: Transcriber,
        language: String?,
        audioSeconds: Double,
        stoppedAt: ContinuousClock.Instant
    ) async -> DictationResult {
        let raw: String
        do {
            raw = try await transcriber.finishUtterance()
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            return result(dictation, text: "", status: .failed,
                          message: "Couldn't transcribe that. Please try again.", metrics: nil)
        }
        let transcriptMs = Self.milliseconds(since: stoppedAt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return result(dictation, text: "", status: .empty,
                          message: "We didn't catch anything. Please try speaking again.",
                          metrics: .init(audioSeconds: audioSeconds, stopToTranscriptMs: transcriptMs, words: 0))
        }

        let localText = LocalFormatter(dictionary: dictionary, snippets: snippets).format(trimmed)
        var text = localText
        var status = ResultStatus.raw
        var cleanupMs: Int?

        if settings.aiCleanupEnabled, cleanup.isConfigured, WordCounter.count(trimmed) > 3 {
            let started = ContinuousClock.now
            do {
                let response = try await cleanup.clean(
                    dictationId: dictation.requestId,
                    transcript: trimmed,
                    language: language,
                    style: dictation.style ?? settings.defaultStyle,
                    dictionary: dictionary,
                    snippets: snippets)
                cleanupMs = Self.milliseconds(since: started)
                if response.status == "cleaned" {
                    text = SnippetPlaceholders.substitute(in: response.text, snippets: snippets)
                    status = .cleaned
                }
            } catch .limitReached {
                return result(dictation, text: localText, status: .limitReached,
                              message: "Dictation limit reached. Get unlimited access in Murmur.",
                              metrics: .init(audioSeconds: audioSeconds, stopToTranscriptMs: transcriptMs,
                                             words: WordCounter.count(localText)))
            } catch {
                cleanupMs = Self.milliseconds(since: started)
                logger.notice("Cleanup unavailable, using local formatting: \(String(describing: error), privacy: .public)")
            }
        }

        let metrics = DictationMetrics(
            audioSeconds: audioSeconds,
            stopToTranscriptMs: transcriptMs,
            cleanupMs: cleanupMs,
            stopToResultMs: Self.milliseconds(since: stoppedAt),
            words: WordCounter.count(text))
        logger.info("Dictation done: \(metrics.words) words, ASR \(transcriptMs) ms, cleanup \(cleanupMs ?? -1) ms")
        return result(dictation, text: text, status: status, message: nil, metrics: metrics)
    }

    private func result(_ dictation: ActiveDictation, text: String, status: ResultStatus,
                        message: String?, metrics: DictationMetrics?) -> DictationResult {
        DictationResult(
            requestId: dictation.requestId,
            documentIdentifier: dictation.documentIdentifier,
            text: text,
            status: status,
            message: message,
            createdAt: Date(),
            metrics: metrics)
    }

    static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - instant
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
