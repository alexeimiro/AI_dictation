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
/// switching languages prepares a new analyzer in the background while audio is buffered. A
/// dictation already under way can be taken up too (`appendRecorded`): what it recorded so far
/// goes in first.
final class AppleSpeechTranscriber: Transcriber, LiveWordsProviding, ReplayableTranscriber, @unchecked Sendable {
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
    /// Set by `shutdown`, so a teardown or preparation that ends after it leaves no analyzer
    /// running for the rest of the process. A later `prepare` clears it.
    private var isShutDown = false
    /// The live-words handler of a dictation that began before its analyzer was ready; `adopt` hands it over.
    private var waitingHandler: LiveWordsHandler?
    /// Moves on with every dictation begun or ended, so a buffer copied for one never reaches the next.
    private var utteranceNumber: UInt64 = 0

    private final class Utterance: @unchecked Sendable {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<String, Error>
        let live: LiveWordsSink

        init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation,
             results: Task<String, Error>, live: LiveWordsSink) {
            self.analyzer = analyzer
            self.continuation = continuation
            self.results = results
            self.live = live
        }
    }

    /// Where an analyzer's results task reports the words so far. The task starts with the analyzer,
    /// before any dictation exists; the dictation that takes the analyzer sets its handler, and
    /// ending the dictation takes it away.
    private final class LiveWordsSink: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: LiveWordsHandler?
        func set(_ handler: LiveWordsHandler?) { lock.withLock { self.handler = handler } }
        /// The results task. The newest words are formatted only when somebody listens (the fold keeps
        /// the settled ones up to date either way); the handler runs outside the lock.
        func report(_ fold: LiveWordsFold) {
            guard let handler = lock.withLock({ handler }) else { return }
            handler(fold.settled, fold.unsettled)
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
        lock.withLock { isShutDown = false }
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
        begin(liveWords: nil)
    }

    /// The iPhone's own recognizer has words for every dictation; late, when its analyzer is still
    /// being prepared.
    func beginUtterance(liveWords handler: @escaping LiveWordsHandler) -> Bool {
        begin(liveWords: handler)
        return true
    }

    private func begin(liveWords handler: LiveWordsHandler?) {
        let needsAnalyzer = lock.withLock { () -> Bool in
            backlog.removeAll()
            utteranceNumber &+= 1
            current?.live.set(nil)          // one the caller never ended keeps no handler
            if let prepared {
                prepared.live.set(handler)
                current = prepared
                self.prepared = nil
                waitingForAnalyzer = false
                waitingHandler = nil
                return false
            }
            current = nil
            waitingForAnalyzer = true
            waitingHandler = handler
            return !preparingInFlight
        }
        if needsAnalyzer { prepareNext() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (utterance, converter, format, waiting, number) = lock.withLock {
            (current, self.converter, analyzerFormat, waitingForAnalyzer && current == nil, utteranceNumber)
        }
        if let utterance, let converter, let format {
            if let converted = Self.convert(buffer, with: converter, to: format) {
                utterance.continuation.yield(AnalyzerInput(buffer: converted))
            }
        } else if waiting, let copy = Self.copy(buffer) {
            lock.withLock {
                guard utteranceNumber == number else { return }
                if waitingForAnalyzer, current == nil {
                    if backlog.count < 500 { backlog.append(copy) }
                } else if let current, let converter = self.converter, let format = analyzerFormat,
                          let converted = Self.convert(copy, with: converter, to: format) {
                    // The analyzer was adopted while this buffer was copied: it follows the kept
                    // ones, inside the lock as they were fed, instead of being lost between them
                    // and the next buffer.
                    current.continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
        }
    }

    /// The audio a dictation recorded before this transcriber took it up (`OpenAITranscriber`'s
    /// late join): converted to the analyzer's format with a converter of its own, about a second
    /// at a time, and fed before the microphone's buffers. Nothing else feeds the analyzer while
    /// this runs: the caller sends the microphone's buffers only afterwards.
    func appendRecorded(_ samples: ArraySlice<Float>, sampleRate: Double) -> Bool {
        let (utterance, format) = lock.withLock { (current, analyzerFormat) }
        guard let utterance, let format else { return false }
        guard !samples.isEmpty else { return true }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: source, to: format) else { return false }
        converter.primeMethod = .none
        let step = max(1, Int(sampleRate))
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + step, samples.endIndex)
            let count = end - start
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return false }
            samples[start..<end].withUnsafeBufferPointer { piece in
                if let base = piece.baseAddress { channel.update(from: base, count: count) }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let converted = Self.convert(buffer, with: converter, to: format) {
                utterance.continuation.yield(AnalyzerInput(buffer: converted))
            }
            start = end
        }
        return true
    }

    func finishUtterance() async throws -> String {
        await waitForAnalyzerIfNeeded()
        let utterance = lock.withLock { () -> Utterance? in
            defer {
                current = nil
                waitingForAnalyzer = false
                waitingHandler = nil
                backlog.removeAll()
                utteranceNumber &+= 1
            }
            return current
        }
        guard let utterance else { return "" }
        utterance.live.set(nil)
        let interval = signposter.beginInterval("finalize")
        defer { signposter.endInterval("finalize", interval) }
        utterance.continuation.finish()
        try await utterance.analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await utterance.results.value
        prepareNext()
        return LiveWordsFold.normalize(text)
    }

    /// On-device, the transcript alone: the pipeline translates it.
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        UtteranceOutput(transcript: try await finishUtterance())
    }

    func cancelUtterance() async {
        let utterance = lock.withLock { () -> Utterance? in
            defer {
                current = nil
                waitingForAnalyzer = false
                waitingHandler = nil
                backlog.removeAll()
                utteranceNumber &+= 1
            }
            return current
        }
        utterance?.live.set(nil)
        if let utterance { await Self.discard(utterance) }
        prepareNext()
    }

    /// Detaches the dictation's analyzer under the lock and discards it in the background, as
    /// `cancelUtterance` does. A dictation that begins right after takes the prepared analyzer or
    /// waits for its own, out of the teardown's reach.
    func abandonUtterance() {
        let utterance = lock.withLock { () -> Utterance? in
            defer {
                current = nil
                waitingForAnalyzer = false
                waitingHandler = nil
                backlog.removeAll()
                utteranceNumber &+= 1
            }
            return current
        }
        utterance?.live.set(nil)
        Task { [weak self] in
            if let utterance { await Self.discard(utterance) }
            self?.prepareNextIfIdle()
        }
    }

    func shutdown() async {
        let utterances = lock.withLock { () -> [Utterance] in
            isShutDown = true
            preparingTask?.cancel()
            defer {
                current = nil
                prepared = nil
                waitingHandler = nil
                backlog.removeAll()
            }
            return [current, prepared].compactMap { $0 }
        }
        for utterance in utterances {
            utterance.live.set(nil)
            await Self.discard(utterance)
        }
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
        let live = LiveWordsSink()
        let results = Task { try await Self.collectFinalText(from: module, live: live) }
        try await analyzer.start(inputSequence: stream)
        return Utterance(analyzer: analyzer, continuation: continuation, results: results, live: live)
    }

    /// The transcript is made of the final results; the ones before them only feed the live words.
    private static func collectFinalText(from module: any SpeechModule, live: LiveWordsSink) async throws -> String {
        var fold = LiveWordsFold()
        if let transcriber = module as? SpeechTranscriber {
            for try await result in transcriber.results {
                fold.add(String(result.text.characters), isFinal: result.isFinal)
                live.report(fold)
            }
        } else if let transcriber = module as? DictationTranscriber {
            for try await result in transcriber.results {
                fold.add(String(result.text.characters), isFinal: result.isFinal)
                live.report(fold)
            }
        }
        return fold.text
    }

    /// Prepares the analyzer for the next dictation in the background, discarding a previously
    /// prepared one (it may be for another language).
    private func prepareNext() {
        guard !lock.withLock({ isShutDown }) else { return }
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

    /// `prepareNext` after an abandoned dictation's teardown, which can finish after the next
    /// dictation began. Skipped when that one has an analyzer or is waiting for its own, or one is
    /// already prepared or on its way: restarting would only delay it.
    private func prepareNextIfIdle() {
        let idle = lock.withLock { current == nil && !waitingForAnalyzer && prepared == nil && !preparingInFlight }
        if idle { prepareNext() }
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
        let stale = lock.withLock { () -> Utterance? in
            // Ready only after `shutdown`: discarded like a stale one.
            if isShutDown { return utterance }
            if waitingForAnalyzer, current == nil {
                utterance.live.set(waitingHandler)
                waitingHandler = nil
                // Inside the lock and before `current` is published: the audio thread converts
                // with this same converter once it sees `current`, and would otherwise convert
                // beside this loop and get ahead of the kept audio. It waits here instead, once,
                // for a few milliseconds (at most 500 buffers).
                if let converter, let format = analyzerFormat {
                    for buffer in backlog {
                        if let converted = Self.convert(buffer, with: converter, to: format) {
                            utterance.continuation.yield(AnalyzerInput(buffer: converted))
                        }
                    }
                }
                backlog.removeAll()
                current = utterance
                waitingForAnalyzer = false
                return nil
            }
            defer { prepared = utterance }
            return prepared
        }
        if let stale { Task { await Self.discard(stale) } }
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
