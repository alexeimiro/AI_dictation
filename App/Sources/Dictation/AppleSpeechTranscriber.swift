@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import os
import Speech

/// On-device recognition with SpeechAnalyzer (iOS 26).
///
/// A finished analyzer can't be reused, so the next one is created and prepared
/// (`prepareToAnalyze`) as soon as a dictation ends; with `modelRetention: .processLifetime`
/// the model stays loaded for the session. Mic audio is converted to the analyzer's format with
/// `AVAudioConverter` on the audio thread and fed through an `AsyncStream`. The engine
/// (SpeechTranscriber or DictationTranscriber) is chosen per language by `SpeechAssetManager`;
/// switching languages prepares a new analyzer in the background while audio is buffered.
final class AppleSpeechTranscriber: Transcriber, @unchecked Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// `SpeechTranscriber`: the iOS 26 model, punctuates automatically.
        case speech
        /// `DictationTranscriber`: older model; honors contextual strings (≤100).
        case dictation

        var displayName: String {
            self == .speech ? "SpeechTranscriber" : "DictationTranscriber"
        }
    }

    private let lock = NSLock()
    private let logger = Logger(subsystem: "Murmur", category: "ASR")
    private let signposter = OSSignposter(subsystem: "Murmur", category: "ASR")
    private var micFormat: AVAudioFormat?
    private var language: ResolvedLanguage?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var prepared: Utterance?
    private var current: Utterance?
    private var preparingTask: Task<Void, Never>?
    private var preparingGeneration: UInt64 = 0
    private var preparingInFlight = false
    /// Copies of mic buffers that arrived before an analyzer was available. They are converted
    /// when the analyzer is adopted, because a language switch can change the target format.
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

    var displayName: String {
        lock.withLock { language.map { "\($0.engine.displayName) (\($0.tag))" } ?? "SpeechAnalyzer" }
    }

    var currentLanguage: ResolvedLanguage? {
        lock.withLock { language }
    }

    // MARK: Transcriber

    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        let interval = signposter.beginInterval("prepare")
        defer { signposter.endInterval("prepare", interval) }
        await discardPreparedAnalyzer()
        let module = SpeechAssetManager.makeModule(language.engine, locale: language.locale)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw TranscriberError.assetsMissing(language.tag)
        }
        let (format, converter) = try await Self.makeConverter(micFormat: micFormat, module: module)
        lock.withLock {
            self.micFormat = micFormat
            self.language = language
            self.analyzerFormat = format
            self.converter = converter
        }
        logger.info("Prepared \(language.engine.displayName, privacy: .public) for \(language.tag, privacy: .public) at \(format.sampleRate, privacy: .public) Hz")
        let utterance = try await makeUtterance(language: language, format: format)
        adopt(utterance)
    }

    func setLanguage(_ language: ResolvedLanguage) {
        let changed = lock.withLock { () -> Bool in
            guard self.language != language else { return false }
            self.language = language
            analyzerFormat = nil
            converter = nil
            return true
        }
        guard changed else { return }
        logger.info("Switching to \(language.engine.displayName, privacy: .public) for \(language.tag, privacy: .public)")
        signposter.emitEvent("switchLanguage")
        prepareNext()
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
            return !preparingInFlight
        }
        if needsAnalyzer { prepareNext() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (utterance, converter, format, waiting) = lock.withLock {
            (current, self.converter, analyzerFormat, waitingForAnalyzer && current == nil)
        }
        if let utterance, let converter, let format {
            if let converted = Self.convert(buffer, with: converter, to: format) {
                utterance.continuation.yield(AnalyzerInput(buffer: converted))
            }
        } else if waiting, let copy = Self.copy(buffer) {
            lock.withLock {
                if waitingForAnalyzer, current == nil, backlog.count < 500 { backlog.append(copy) }
            }
        }
    }

    func finishUtterance() async throws -> String {
        await waitForAnalyzerIfNeeded()
        let utterance = lock.withLock { () -> Utterance? in
            defer {
                current = nil
                waitingForAnalyzer = false
                backlog.removeAll()
            }
            return current
        }
        guard let utterance else { return "" }
        let interval = signposter.beginInterval("finalize")
        defer { signposter.endInterval("finalize", interval) }
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
        if let utterance { await Self.discard(utterance) }
        prepareNext()
    }

    func shutdown() async {
        let utterances = lock.withLock { () -> [Utterance] in
            preparingTask?.cancel()
            defer {
                current = nil
                prepared = nil
                backlog.removeAll()
            }
            return [current, prepared].compactMap { $0 }
        }
        for utterance in utterances { await Self.discard(utterance) }
        await SpeechModels.endRetention()
    }

    // MARK: Analyzer lifecycle

    private static func makeConverter(micFormat: AVAudioFormat, module: any SpeechModule) async throws
        -> (AVAudioFormat, AVAudioConverter) {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module], considering: micFormat) else {
            throw TranscriberError.noCompatibleFormat
        }
        guard let converter = AVAudioConverter(from: micFormat, to: format) else {
            throw TranscriberError.noCompatibleFormat
        }
        converter.primeMethod = .none
        return (format, converter)
    }

    private func makeUtterance(language: ResolvedLanguage, format: AVAudioFormat) async throws -> Utterance {
        let module = SpeechAssetManager.makeModule(language.engine, locale: language.locale)
        let analyzer = SpeechAnalyzer(
            modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if language.engine == .dictation, !language.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(language.contextualStrings.prefix(100))
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
                appendSegment(String(result.text.characters), to: &text)
            }
        } else if let transcriber = module as? DictationTranscriber {
            for try await result in transcriber.results where result.isFinal {
                appendSegment(String(result.text.characters), to: &text)
            }
        }
        return text
    }

    /// Final segments usually carry their own leading space; add one when they don't.
    private static func appendSegment(_ segment: String, to text: inout String) {
        guard !segment.isEmpty else { return }
        if let last = text.last, let first = segment.first,
           last.isLetter || last.isNumber, first.isLetter || first.isNumber {
            text += " "
        }
        text += segment
    }

    /// Prepares the analyzer for the next dictation in the background, discarding a previously
    /// prepared one (it may be for another language).
    private func prepareNext() {
        let (stale, generation) = lock.withLock { () -> (Utterance?, UInt64) in
            preparingTask?.cancel()
            preparingGeneration &+= 1
            preparingInFlight = true
            defer { prepared = nil }
            return (prepared, preparingGeneration)
        }
        let task = Task { [weak self] in
            if let stale { await Self.discard(stale) }
            guard let self else { return }
            await self.prepareAnalyzer(generation: generation)
        }
        lock.withLock {
            if preparingGeneration == generation { preparingTask = task }
        }
    }

    private func prepareAnalyzer(generation: UInt64) async {
        defer {
            lock.withLock {
                if preparingGeneration == generation {
                    preparingInFlight = false
                    preparingTask = nil
                }
            }
        }
        do {
            guard let (language, micFormat) = lock.withLock({ () -> (ResolvedLanguage, AVAudioFormat)? in
                guard let language, let micFormat else { return nil }
                return (language, micFormat)
            }) else { return }
            var format = lock.withLock { analyzerFormat }
            if format == nil {
                let module = SpeechAssetManager.makeModule(language.engine, locale: language.locale)
                let (newFormat, newConverter) = try await Self.makeConverter(micFormat: micFormat, module: module)
                try Task.checkCancellation()
                lock.withLock {
                    analyzerFormat = newFormat
                    converter = newConverter
                }
                format = newFormat
            }
            guard let format else { return }
            let utterance = try await makeUtterance(language: language, format: format)
            if Task.isCancelled {
                await Self.discard(utterance)
                return
            }
            adopt(utterance)
        } catch is CancellationError {
            // Superseded by a newer preparation.
        } catch {
            logger.error("Preparing next analyzer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A newly prepared analyzer becomes current if a dictation is waiting for one; the buffered
    /// audio is converted with the (possibly new) converter and fed in.
    private func adopt(_ utterance: Utterance) {
        let (buffers, converter, format, stale) = lock.withLock {
            () -> ([AVAudioPCMBuffer], AVAudioConverter?, AVAudioFormat?, Utterance?) in
            if waitingForAnalyzer, current == nil {
                current = utterance
                waitingForAnalyzer = false
                defer { backlog.removeAll() }
                return (backlog, self.converter, analyzerFormat, nil)
            }
            defer { prepared = utterance }
            return ([], nil, nil, prepared)
        }
        if let stale { Task { await Self.discard(stale) } }
        guard let converter, let format else { return }
        for buffer in buffers {
            if let converted = Self.convert(buffer, with: converter, to: format) {
                utterance.continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    private func discardPreparedAnalyzer() async {
        let stale = lock.withLock { () -> Utterance? in
            preparingTask?.cancel()
            defer { prepared = nil }
            return prepared
        }
        if let stale { await Self.discard(stale) }
    }

    private static func discard(_ utterance: Utterance) async {
        utterance.continuation.finish()
        await utterance.analyzer.cancelAndFinishNow()
        utterance.results.cancel()
    }

    /// A model load after a language switch can take seconds on first use; wait for it rather
    /// than returning an empty transcript.
    private func waitForAnalyzerIfNeeded() async {
        for _ in 0..<750 {
            let waiting = lock.withLock { waitingForAnalyzer && current == nil && preparingInFlight }
            guard waiting else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Audio helpers

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
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

    /// The engine owns tap buffers only for the duration of the callback, so backlog entries
    /// must be copies.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    private final class SuppliedFlag: @unchecked Sendable {
        var value = false
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranscriberError: LocalizedError {
        case assetsMissing(String)
        case noCompatibleFormat

        var errorDescription: String? {
            switch self {
            case .assetsMissing(let tag):
                "The \(DictationLanguage(tag: tag).localizedName) speech model isn't installed. Open Murmur › Languages to download it."
            case .noCompatibleFormat:
                "Couldn't configure audio for speech recognition."
            }
        }
    }
}
