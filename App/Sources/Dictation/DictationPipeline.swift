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
    /// BCP-47 tag of the language the dictation is recognized in.
    let language: String
    /// BCP-47 output language, or nil for ordinary dictation.
    let translationTargetLanguage: String?
    let source: Source
    let startedAt: Date
    /// When the keyboard first reported following this dictation. Nil while the app records one
    /// it started on its own after the keyboard opened it (the user is still on the way back).
    var keyboardAttachedAt: Date?
}

/// What the session gets back: the IPC result for the keyboard, and the history record. The
/// raw transcript stays out of the App Group files.
struct DictationOutcome: Sendable {
    let result: DictationResult
    let transcript: Transcript
}

/// The cleanup service as the pipeline sees it (`CleanupClient` in the app, a fake in tests).
@MainActor
protocol Cleaning: AnyObject {
    var isConfigured: Bool { get }
    func clean(
        dictationId: UUID, transcript: String, language: String?, targetLanguage: String?, style: StylePreset,
        dictionary: [DictionaryTerm], snippets: [SnippetDefinition]
    ) async throws(CleanupClient.Failure) -> CleanupClient.Response
}

/// Turns a finished recording into the text the keyboard inserts:
/// transcript (OpenAI, or on-device) → AI cleanup (OpenAI, via the `cleanup` function) → `DictationResult`.
/// Falls back to `LocalFormatter` when cleanup is off, unavailable, the dictation is tiny, or
/// `CleanupGate` finds nothing in the transcript for the model to rewrite.
@MainActor
final class DictationPipeline {
    private let logger = Logger(subsystem: "Murmur", category: "Pipeline")
    private let cleanup: any Cleaning
    private let settings = SharedSettings.shared

    init(cleanup: any Cleaning) {
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
        audioSeconds: Double,
        stoppedAt: ContinuousClock.Instant
    ) async -> DictationOutcome {
        let language = dictation.language
        let targetLanguage = dictation.translationTargetLanguage
        let style = dictation.style ?? settings.defaultStyle
        let raw: String
        do {
            raw = try await transcriber.finishUtterance()
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            let limited = (error as? CloudTranscriptionError) == .limitReached
            return outcome(
                dictation, raw: "", text: "", status: limited ? .limitReached : .failed,
                message: Self.transcriptionMessage(for: error), errorReason: error.localizedDescription,
                style: style, cleanupModel: nil,
                metrics: TranscriptMetrics(audioSeconds: audioSeconds, words: 0, asrMs: Self.milliseconds(since: stoppedAt)))
        }
        let transcriptMs = Self.milliseconds(since: stoppedAt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return outcome(
                dictation, raw: "", text: "", status: .empty,
                message: "We didn't catch anything. Please try speaking again.", errorReason: nil,
                style: style, cleanupModel: nil,
                metrics: TranscriptMetrics(audioSeconds: audioSeconds, words: 0, asrMs: transcriptMs))
        }

        let localText = LocalFormatter(dictionary: dictionary, snippets: snippets, language: language).format(trimmed)
        let cleaned = await runCleanup(
            dictationId: dictation.requestId, raw: trimmed, language: language,
            targetLanguage: targetLanguage, style: style, localText: localText)
        let metrics = TranscriptMetrics(
            audioSeconds: audioSeconds,
            words: WordCounter.count(cleaned.text),
            asrMs: transcriptMs,
            cleanupMs: cleaned.cleanupMs,
            ttftMs: cleaned.ttftMs,
            totalMs: Self.milliseconds(since: stoppedAt))
        logger.info("Dictation done: \(metrics.words) words, ASR \(transcriptMs) ms, cleanup \(cleaned.cleanupMs ?? -1) ms")
        if targetLanguage != nil, cleaned.status != .cleaned {
            let status: ResultStatus = cleaned.status == .limitReached ? .limitReached : .failed
            return outcome(
                dictation, raw: trimmed, text: "", status: status,
                message: cleaned.message ?? "Couldn't translate that. Check your connection and try again.",
                errorReason: cleaned.errorReason, style: style, cleanupModel: cleaned.model, metrics: metrics)
        }
        return outcome(
            dictation, raw: trimmed, text: cleaned.text, status: cleaned.status, message: cleaned.message,
            errorReason: cleaned.errorReason, style: style, cleanupModel: cleaned.model, metrics: metrics)
    }

    /// Re-runs the cleanup on a stored transcript (Retry / Regenerate). Throws when the service
    /// couldn't be reached, leaving the stored transcript untouched.
    func recleanup(_ transcript: Transcript) async throws(CleanupClient.Failure) -> Transcript {
        guard cleanup.isConfigured else { throw .notConfigured }
        let localText = LocalFormatter(dictionary: dictionary, snippets: snippets, language: transcript.language)
            .format(transcript.rawText)
        let cleaned = await runCleanup(
            dictationId: transcript.id, raw: transcript.rawText, language: transcript.language,
            targetLanguage: nil, style: transcript.style, localText: localText, force: true)
        if let failure = cleaned.failure { throw failure }
        var updated = transcript
        updated.cleanedText = cleaned.text
        updated.status = TranscriptStatus(cleaned.status)
        updated.errorReason = cleaned.errorReason
        updated.metrics.words = WordCounter.count(cleaned.text)
        updated.metrics.cleanupMs = cleaned.cleanupMs
        updated.metrics.ttftMs = cleaned.ttftMs
        updated.cleanupModel = cleaned.model ?? transcript.cleanupModel
        updated.regeneratedAt = Date()
        return updated
    }

    // MARK: Cleanup

    private struct CleanupOutcome {
        var text: String
        var status: ResultStatus
        var message: String?
        var errorReason: String?
        var cleanupMs: Int?
        var ttftMs: Int?
        var model: String?
        /// Set when the call itself failed (offline, timeout, 5xx), as opposed to a raw answer.
        var failure: CleanupClient.Failure?
    }

    /// The cleanup step shared by live dictations and Retry / Regenerate. Dictations of three
    /// words or fewer, and transcripts already as the speaker meant them, skip the model unless
    /// `force` is set.
    private func runCleanup(
        dictationId: UUID, raw: String, language: String?, targetLanguage: String?,
        style: StylePreset, localText: String,
        force: Bool = false
    ) async -> CleanupOutcome {
        var outcome = CleanupOutcome(text: localText, status: .raw)
        guard cleanup.isConfigured else {
            if targetLanguage != nil {
                outcome.failure = .notConfigured
                outcome.errorReason = "Translation isn't configured."
            }
            return outcome
        }
        guard targetLanguage != nil || force || (settings.aiCleanupEnabled && WordCounter.count(raw) > 3
                                                  && CleanupGate.needsModel(raw, style: style)) else {
            return outcome
        }
        let started = ContinuousClock.now
        do {
            let response = try await cleanup.clean(
                dictationId: dictationId, transcript: raw, language: language,
                targetLanguage: targetLanguage, style: style,
                dictionary: dictionary, snippets: snippets)
            outcome.cleanupMs = Self.milliseconds(since: started)
            outcome.ttftMs = response.ttftMs
            outcome.model = response.model
            if let targetLanguage, !Self.isTranslation(response, into: targetLanguage) {
                // A cleanup in the spoken language must never be inserted as the translation.
                outcome.errorReason = "The cleanup service didn't translate. Deploy the latest cleanup function."
                outcome.message = "Translation isn't available right now. Please try again later."
            } else if response.status == "cleaned" {
                outcome.text = SnippetPlaceholders.substitute(in: response.text, snippets: snippets)
                outcome.status = .cleaned
            } else if targetLanguage != nil {
                outcome.errorReason = response.reason == "untranslated"
                    ? "The translation came back in the spoken language."
                    : "The translation was unusable (\(response.reason ?? "no reason given"))."
                outcome.message = "Couldn't translate that. Please try again."
            } else {
                outcome.errorReason = "The cleanup returned the transcript unchanged."
            }
        } catch .limitReached {
            outcome.cleanupMs = Self.milliseconds(since: started)
            outcome.status = .limitReached
            outcome.message = "Dictation limit reached. Get unlimited access in Murmur."
            outcome.errorReason = "Dictation limit reached."
        } catch {
            outcome.cleanupMs = Self.milliseconds(since: started)
            outcome.failure = error
            outcome.errorReason = Self.describe(error)
            logger.notice("Cleanup unavailable, using local formatting: \(String(describing: error), privacy: .public)")
        }
        return outcome
    }

    /// A reply is a translation only when the server says which language it wrote. A cleanup
    /// function deployed before translation ignores `targetLanguage` and answers with a cleanup in
    /// the spoken language, marked "cleaned" like any other.
    private static func isTranslation(_ response: CleanupClient.Response, into target: String) -> Bool {
        guard let written = response.targetLanguage else { return false }
        return DictationLanguage(tag: written).languageCode == DictationLanguage(tag: target).languageCode
    }

    /// What the keyboard shows when no text came back.
    static func transcriptionMessage(for error: Error) -> String {
        switch error as? CloudTranscriptionError {
        case .limitReached: "Dictation limit reached. Get unlimited access in Murmur."
        case .rateLimited: "Too many dictations in a minute. Try again shortly."
        case .unavailable: "Couldn't reach transcription. Check your connection and try again."
        case .notConfigured, nil: "Couldn't transcribe that. Please try again."
        }
    }

    private static func describe(_ failure: CleanupClient.Failure) -> String {
        switch failure {
        case .notConfigured: "Cleanup isn't configured."
        case .limitReached: "Dictation limit reached."
        case .rateLimited: "Too many requests; try again in a minute."
        case .unavailable(let reason): "Cleanup unavailable: \(reason)"
        }
    }

    private func outcome(
        _ dictation: ActiveDictation, raw: String, text: String, status: ResultStatus, message: String?,
        errorReason: String?, style: StylePreset, cleanupModel: String?, metrics: TranscriptMetrics
    ) -> DictationOutcome {
        let now = Date()
        let result = DictationResult(
            requestId: dictation.requestId,
            documentIdentifier: dictation.documentIdentifier,
            text: text,
            status: status,
            message: message,
            createdAt: now,
            metrics: DictationMetrics(
                audioSeconds: metrics.audioSeconds, stopToTranscriptMs: metrics.asrMs, cleanupMs: metrics.cleanupMs,
                stopToResultMs: metrics.totalMs, words: metrics.words),
            language: dictation.translationTargetLanguage ?? dictation.language)
        let transcript = Transcript(
            id: dictation.requestId,
            createdAt: now,
            language: dictation.language,
            style: style,
            rawText: raw,
            cleanedText: text.isEmpty ? nil : text,
            status: TranscriptStatus(status),
            errorReason: errorReason,
            metrics: metrics,
            cleanupModel: cleanupModel,
            source: dictation.source == .keyboard ? .keyboard : .inApp)
        return DictationOutcome(result: result, transcript: transcript)
    }

    static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - instant
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
