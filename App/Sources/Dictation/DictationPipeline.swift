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
    /// The keyboard's stop command, and how long it took to reach the app. Nil when the app
    /// ended the dictation itself.
    var stopRequestedAt: Date?
    var tapToStopMs: Int?
}

/// What the session gets back: the IPC result for the keyboard, the history record, and the
/// timings log's entry. The raw transcript stays out of the App Group files.
struct DictationOutcome: Sendable {
    let result: DictationResult
    let transcript: Transcript
    let timings: DictationTimings?
    /// The audio as uploaded, for the transcript's playback; nil when none was encoded.
    var recording: EncodedAudio?
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
/// A translation or an Improve my grammar dictation the transcriber had written in the same request
/// (`dictate`) skips the cleanup call, and its reply is judged as `cleanup`'s would be.
/// Falls back to `LocalFormatter` when cleanup is unavailable, the dictation is tiny, or
/// `CleanupGate` finds nothing in a Word for word transcript for the model to write differently.
@MainActor
final class DictationPipeline {
    private let logger = Logger(subsystem: "Murmur", category: "Pipeline")
    private let cleanup: any Cleaning
    private let settings: SharedSettings

    /// `settings`: tests pass their own, so the default style is the default one.
    init(cleanup: any Cleaning, settings: SharedSettings = .shared) {
        self.cleanup = cleanup
        self.settings = settings
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
        // The model writes a translation, or Improve my grammar, in the request that transcribes.
        // Word for word is transcribed alone.
        let request = targetLanguage != nil || style == .grammar
            ? ModelRequest(dictationId: dictation.requestId, targetLanguage: targetLanguage, style: style,
                           dictionary: dictionary, snippets: snippets)
            : nil
        let output: UtteranceOutput
        do {
            output = try await transcriber.finishUtterance(model: request)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            let utterance = (transcriber as? UtteranceTimingProviding)?.takeTimings()
            // What the user said stays playable even when no text came of it.
            let recording = (transcriber as? RecordingProviding)?.takeRecording()
            let limited = (error as? CloudTranscriptionError) == .limitReached
            // The on-device fallback failed after the cloud refused a signed-out account: trying
            // again won't help, signing in will.
            let message = utterance?.cloudFailure == .signedOut
                ? Self.signedOutMessage : Self.transcriptionMessage(for: error)
            return outcome(
                dictation, raw: "", text: "", status: limited ? .limitReached : .failed,
                message: message, errorReason: error.localizedDescription,
                style: style, cleanupModel: nil,
                metrics: TranscriptMetrics(audioSeconds: audioSeconds, words: 0, asrMs: Self.milliseconds(since: stoppedAt)),
                utterance: utterance, recording: recording)
        }
        let finishedMs = Self.milliseconds(since: stoppedAt)
        let utterance = (transcriber as? UtteranceTimingProviding)?.takeTimings()
        let recording = (transcriber as? RecordingProviding)?.takeRecording()
        // The model's part of a single request, so recognition stays comparable with two requests.
        let singleCallModelMs = output.modelReply == nil ? nil : utterance?.requests.first?.server?.modelMs
        let transcriptMs = max(0, finishedMs - (singleCallModelMs ?? 0))
        let trimmed = output.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Under Auto-detect, the language the transcript turned out to be in: the formatting, the
        // cleanup's language rules, the insertion and history follow it. The fallback guesses it
        // next time the cloud can't answer.
        let spoken = output.detectedLanguage ?? language
        if let detected = output.detectedLanguage { settings.lastDetectedLanguage = detected }
        guard !trimmed.isEmpty else {
            return outcome(
                dictation, spoken: spoken, raw: "", text: "", status: .empty,
                message: "We didn't catch anything. Please try speaking again.", errorReason: nil,
                style: style, cleanupModel: nil,
                metrics: TranscriptMetrics(audioSeconds: audioSeconds, words: 0, asrMs: transcriptMs),
                utterance: utterance, recording: recording)
        }

        // A translation never inserts the transcript, so it needs no local text.
        let localText = targetLanguage != nil
            ? "" : LocalFormatter(dictionary: dictionary, snippets: snippets, language: spoken,
                                  removesFillers: settings.smartFormatting).format(trimmed)
        var cleaned: CleanupOutcome
        if let reply = output.modelReply {
            var judged = judge(reply, targetLanguage: targetLanguage, localText: localText)
            judged.cleanupMs = singleCallModelMs
            cleaned = judged
            // `dictate` kept the transcript but couldn't translate it (out of time, or the model
            // failed): one more try through `cleanup`, with its own 9 s, before nothing goes in.
            if targetLanguage != nil, case .failure(.unavailable) = reply {
                logger.notice("dictate couldn't translate; retrying through cleanup")
                cleaned = await runCleanup(
                    dictationId: dictation.requestId, raw: trimmed, language: spoken,
                    targetLanguage: targetLanguage, style: style, localText: localText)
            }
        } else {
            cleaned = await runCleanup(
                dictationId: dictation.requestId, raw: trimmed, language: spoken,
                targetLanguage: targetLanguage, style: style, localText: localText)
        }
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
                dictation, spoken: spoken, raw: trimmed, text: "", status: status,
                message: cleaned.message ?? "Couldn't translate that. Check your connection and try again.",
                errorReason: cleaned.errorReason, style: style, cleanupModel: cleaned.model, metrics: metrics,
                utterance: utterance, cleanupRequest: cleaned.request, recording: recording)
        }
        // The cloud refused a signed-out account and the on-device fallback wrote the text. It still
        // goes in, and the keyboard says why, also when no cleanup ran to fail the same way (cleanup
        // off, a short dictation, nothing to fix).
        let signedOut = utterance?.cloudFailure == .signedOut && cleaned.status != .cleaned
        return outcome(
            dictation, spoken: spoken, raw: trimmed, text: cleaned.text, status: cleaned.status,
            message: cleaned.message ?? (signedOut ? Self.signedOutMessage : nil),
            errorReason: cleaned.errorReason ?? (signedOut ? BackendError.signedOut.localizedDescription : nil),
            style: style, cleanupModel: cleaned.model, metrics: metrics,
            utterance: utterance, cleanupRequest: cleaned.request, recording: recording)
    }

    /// Re-runs the cleanup on a stored transcript (Retry / Regenerate). Throws when the service
    /// couldn't be reached, leaving the stored transcript untouched.
    func recleanup(_ transcript: Transcript) async throws(CleanupClient.Failure) -> Transcript {
        guard cleanup.isConfigured else { throw .notConfigured }
        let localText = LocalFormatter(dictionary: dictionary, snippets: snippets, language: transcript.language,
                                       removesFillers: settings.smartFormatting)
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
        /// The cleanup request's timing, when it got a reply.
        var request: RequestTiming?
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
        guard targetLanguage != nil || force
                || (WordCounter.count(raw) > 3
                    && CleanupGate.needsModel(raw, style: style, smartFormatting: settings.smartFormatting)) else {
            return outcome
        }
        let started = ContinuousClock.now
        let result: Result<CleanupClient.Response, CleanupClient.Failure>
        do {
            result = .success(try await cleanup.clean(
                dictationId: dictationId, transcript: raw, language: language,
                targetLanguage: targetLanguage, style: style,
                dictionary: dictionary, snippets: snippets))
        } catch {
            result = .failure(error)
        }
        outcome = judge(result, targetLanguage: targetLanguage, localText: localText)
        outcome.cleanupMs = Self.milliseconds(since: started)
        return outcome
    }

    /// What a cleanup's or a translation's reply comes to, from `cleanup` or from the request
    /// that also transcribed (`dictate`). `localText` is kept when there's nothing better.
    private func judge(
        _ result: Result<CleanupClient.Response, CleanupClient.Failure>, targetLanguage: String?,
        localText: String
    ) -> CleanupOutcome {
        var outcome = CleanupOutcome(text: localText, status: .raw)
        switch result {
        case .success(let response):
            outcome.ttftMs = response.ttftMs
            outcome.model = response.model
            outcome.request = response.request
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
            } else if response.reason != "short" {
                // "short": `dictate` leaves three words or fewer as they were, as `runCleanup` does.
                outcome.errorReason = "The cleanup returned the transcript unchanged."
            }
        case .failure(.limitReached):
            outcome.status = .limitReached
            outcome.message = Brand.limitReachedMessage
            outcome.errorReason = "Dictation limit reached."
        case .failure(let error):
            outcome.failure = error
            outcome.errorReason = Self.describe(error)
            // A dictation still gets its local text, and the keyboard shows this after inserting
            // it; a translation shows it instead of blaming the connection.
            if case .signedOut = error { outcome.message = Self.signedOutMessage }
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

    /// What the keyboard shows while the account is signed out (`BackendError.signedOut`): the
    /// cloud stays closed until the user signs in again in Murmur.
    static let signedOutMessage = "You're signed out. Open Murmur to sign in again."

    /// What the keyboard shows when no text came back.
    static func transcriptionMessage(for error: Error) -> String {
        switch error as? CloudTranscriptionError {
        case .limitReached: Brand.limitReachedMessage
        case .rateLimited: "Too many dictations in a minute. Try again shortly."
        case .unavailable: "Couldn't reach transcription. Check your connection and try again."
        case .signedOut: signedOutMessage
        // A cancelled dictation is normally gone before anyone sees this, and an undeployed
        // `dictate` is retried through `transcribe`.
        case .notConfigured, .cancelled, .notDeployed, nil: "Couldn't transcribe that. Please try again."
        }
    }

    private static func describe(_ failure: CleanupClient.Failure) -> String {
        switch failure {
        case .notConfigured: "Cleanup isn't configured."
        case .limitReached: "Dictation limit reached."
        case .rateLimited: "Too many requests; try again in a minute."
        case .unavailable(let reason): "Cleanup unavailable: \(reason)"
        case .signedOut: BackendError.signedOut.localizedDescription
        }
    }

    /// `spoken`: the language the transcript is in, when Auto-detect found it (else the
    /// dictation's). `utterance` and `cleanupRequest`: what the transcriber and the cleanup
    /// measured, for the timings log.
    private func outcome(
        _ dictation: ActiveDictation, spoken: String? = nil, raw: String, text: String, status: ResultStatus,
        message: String?, errorReason: String?, style: StylePreset, cleanupModel: String?, metrics: TranscriptMetrics,
        utterance: UtteranceTimings?, cleanupRequest: RequestTiming? = nil, recording: EncodedAudio? = nil
    ) -> DictationOutcome {
        let now = Date()
        let spoken = spoken ?? dictation.language
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
            language: dictation.translationTargetLanguage ?? spoken)
        let transcript = Transcript(
            id: dictation.requestId,
            createdAt: now,
            language: spoken,
            style: style,
            rawText: raw,
            cleanedText: text.isEmpty ? nil : text,
            status: TranscriptStatus(status),
            errorReason: errorReason,
            metrics: metrics,
            cleanupModel: cleanupModel,
            source: dictation.source == .keyboard ? .keyboard : .inApp)
        let requests = (utterance?.requests ?? []) + [cleanupRequest].compactMap { $0 }
        let timings = DictationTimings(
            requestId: dictation.requestId, createdAt: now,
            kind: dictation.translationTargetLanguage == nil ? .dictation : .translation,
            audioSeconds: metrics.audioSeconds, stopRequestedAt: dictation.stopRequestedAt,
            tapToStopMs: dictation.tapToStopMs, encodeMs: utterance?.encodeMs, audioBytes: utterance?.audioBytes,
            tokenMs: DictationTimings.sum(requests.map(\.tokenMs)), stopToResultMs: metrics.totalMs ?? metrics.asrMs,
            requests: requests, cleanupModel: cleanupModel, status: status.rawValue,
            insertable: result.isInsertable, cloudTranscript: utterance?.cloudTranscript ?? false)
        return DictationOutcome(result: result, transcript: transcript, timings: timings, recording: recording)
    }

    static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        instant.elapsedMilliseconds
    }
}
