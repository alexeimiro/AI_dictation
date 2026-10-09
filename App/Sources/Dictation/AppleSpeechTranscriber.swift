@preconcurrency import AVFoundation
import Foundation
import os
import Speech

/// On-device recognition with SpeechAnalyzer (iOS 26).
///
/// A finished analyzer can't be reused, so the next one is created and prepared
/// (`prepareToAnalyze`) as soon as a dictation ends; with `modelRetention: .processLifetime`
/// the model stays loaded for the session. Mic audio is converted to the analyzer's format with
/// `AVAudioConverter` on the audio thread and fed through an `AsyncStream`.
final class AppleSpeechTranscriber: Transcriber, @unchecked Sendable {
    enum Kind {
        /// `SpeechTranscriber`: the iOS 26 model, punctuates automatically.
        case speech
        /// `DictationTranscriber`: older model; honors contextual strings (≤100).
        case dictation
    }

    let kind: Kind
    let contextualStrings: [String]
    var displayName: String { kind == .speech ? "SpeechTranscriber" : "DictationTranscriber" }

    private let lock = NSLock()
    private let logger = Logger(subsystem: "Murmur", category: "ASR")
    private var locale = Locale.current
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var prepared: Utterance?
    private var current: Utterance?
    private var preparingTask: Task<Void, Never>?
    /// Buffers that arrive before a prepared analyzer is available.
    private var backlog: [AVAudioPCMBuffer] = []
    private var waitingForAnalyzer = false

    private final class Utterance: @unchecked Sendable {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<String, Error>

        init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation,
             results: Task<String, Error>) {
            self.analyzer = analyzer
            self.continuation = continuation
            self.results = results
        }
    }

    init(kind: Kind, contextualStrings: [String]) {
        self.kind = kind
        self.contextualStrings = Array(contextualStrings.prefix(100))
    }

    // MARK: Transcriber

    func prepare(micFormat: AVAudioFormat, locale requested: Locale) async throws {
        let resolved = try await resolveLocale(requested)
        let module = makeModule(locale: resolved)
        try await ensureAssets(for: module)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module], considering: micFormat) else {
            throw TranscriberError.noCompatibleFormat
        }
        guard let converter = AVAudioConverter(from: micFormat, to: format) else {
            throw TranscriberError.noCompatibleFormat
        }
        converter.primeMethod = .none
        lock.withLock {
            self.locale = resolved
            self.analyzerFormat = format
            self.converter = converter
        }
        logger.info("Prepared \(self.displayName, privacy: .public) for \(resolved.identifier, privacy: .public) at \(format.sampleRate, privacy: .public) Hz")
        let utterance = try await makeUtterance()
        lock.withLock { prepared = utterance }
    }

    func beginUtterance() {
        let needsAnalyzer = lock.withLock { () -> Bool in
            backlog.removeAll()
            if let prepared {
                current = prepared
                self.prepared = nil
                waitingForAnalyzer = false
                return false
            }
            current = nil
            waitingForAnalyzer = true
            return preparingTask == nil
        }
        if needsAnalyzer { prepareNext() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        lock.withLock {
            if let current {
                current.continuation.yield(AnalyzerInput(buffer: converted))
            } else if waitingForAnalyzer {
                backlog.append(converted)
            }
        }
    }

    func finishUtterance() async throws -> String {
        await waitForAnalyzerIfNeeded()
        guard let utterance = lock.withLock({ () -> Utterance? in
            defer { current = nil }
            return current
        }) else { return "" }
        utterance.continuation.finish()
        try await utterance.analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await utterance.results.value
        prepareNext()
        return Self.normalize(text)
    }

    func cancelUtterance() async {
        let utterance = lock.withLock { () -> Utterance? in
            defer {
                current = nil
                waitingForAnalyzer = false
                backlog.removeAll()
            }
            return current
        }
        if let utterance {
            utterance.continuation.finish()
            await utterance.analyzer.cancelAndFinishNow()
            utterance.results.cancel()
        }
        prepareNext()
    }

    func shutdown() async {
        preparingTask?.cancel()
        let utterances = lock.withLock { () -> [Utterance] in
            defer {
                current = nil
                prepared = nil
            }
            return [current, prepared].compactMap { $0 }
        }
        for utterance in utterances {
            utterance.continuation.finish()
            await utterance.analyzer.cancelAndFinishNow()
            utterance.results.cancel()
        }
        await SpeechModels.endRetention()
    }

    // MARK: Analyzer lifecycle

    private func makeModule(locale: Locale) -> any SpeechModule {
        switch kind {
        case .speech:
            SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        case .dictation:
            DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }
    }

    private func makeUtterance() async throws -> Utterance {
        let (locale, format) = lock.withLock { (self.locale, self.analyzerFormat) }
        let module = makeModule(locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if kind == .dictation, !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let results = Task { try await Self.collectFinalText(from: module) }
        try await analyzer.start(inputSequence: stream)
        return Utterance(analyzer: analyzer, continuation: continuation, results: results)
    }

    private static func collectFinalText(from module: any SpeechModule) async throws -> String {
        var text = ""
        if let transcriber = module as? SpeechTranscriber {
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
        } else if let transcriber = module as? DictationTranscriber {
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
        }
        return text
    }

    private func prepareNext() {
        preparingTask?.cancel()
        preparingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let utterance = try await self.makeUtterance()
                self.adopt(utterance)
            } catch {
                self.logger.error("Preparing next analyzer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A newly prepared analyzer becomes current if a dictation is waiting for one.
    private func adopt(_ utterance: Utterance) {
        lock.withLock {
            if waitingForAnalyzer, current == nil {
                current = utterance
                waitingForAnalyzer = false
                for buffer in backlog {
                    utterance.continuation.yield(AnalyzerInput(buffer: buffer))
                }
                backlog.removeAll()
            } else {
                prepared = utterance
            }
        }
    }

    private func waitForAnalyzerIfNeeded() async {
        for _ in 0..<50 {
            let waiting = lock.withLock { waitingForAnalyzer && current == nil }
            guard waiting else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Helpers

    private func resolveLocale(_ requested: Locale) async throws -> Locale {
        let locale: Locale? = switch kind {
        case .speech: await SpeechTranscriber.supportedLocale(equivalentTo: requested)
        case .dictation: await DictationTranscriber.supportedLocale(equivalentTo: requested)
        }
        guard let locale else { throw TranscriberError.unsupportedLocale(requested.identifier) }
        return locale
    }

    private func ensureAssets(for module: any SpeechModule) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            logger.info("Downloading speech assets…")
            try await request.downloadAndInstall()
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let (converter, format) = lock.withLock({ () -> (AVAudioConverter, AVAudioFormat)? in
            guard let converter, let analyzerFormat else { return nil }
            return (converter, analyzerFormat)
        }) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let supplied = SuppliedFlag()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private final class SuppliedFlag: @unchecked Sendable {
        var value = false
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranscriberError: LocalizedError {
        case unsupportedLocale(String)
        case noCompatibleFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let identifier):
                "On-device dictation isn't available for \(identifier) on this iPhone."
            case .noCompatibleFormat:
                "Couldn't configure audio for speech recognition."
            }
        }
    }
}
