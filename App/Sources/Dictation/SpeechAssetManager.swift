@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import os
import Speech

/// Downloads, validates and reserves the on-device speech models per language, and remembers
/// which engine passed validation so a session can start without repeating the check.
///
/// `supportedLocale(equivalentTo:)` has misreported support before (Apple confirmed Arabic was
/// listed while its asset could not be downloaded), so a language only counts as ready after a
/// short validation transcription succeeds. SpeechTranscriber is tried first, then
/// DictationTranscriber.
actor SpeechAssetManager {
    typealias Engine = AppleSpeechTranscriber.Kind

    enum InstallEvent: Sendable {
        case downloading(fraction: Double, engine: Engine)
        case validating(Engine)
        case ready(ResolvedLanguage)
    }

    /// Sendable mirror of `AssetInventory.Status`.
    enum AssetState: String, Sendable, Equatable {
        case unsupported, supported, downloading, installed

        init(_ status: AssetInventory.Status) {
            switch status {
            case .unsupported: self = .unsupported
            case .supported: self = .supported
            case .downloading: self = .downloading
            case .installed: self = .installed
            @unknown default: self = .unsupported
            }
        }
    }

    struct LanguageStatus: Sendable, Equatable {
        let tag: String
        /// nil when the engine doesn't support the language at all.
        let speech: AssetState?
        let dictation: AssetState?
        let verified: VerifiedEngineRecord?
        let reserved: Bool

        var isReady: Bool {
            guard let verified else { return false }
            let status = verified.engine == Engine.speech.rawValue ? speech : dictation
            return status == .installed
        }
    }

    enum LanguageError: LocalizedError {
        case unsupported(String)
        case offline(String)
        case downloadFailed(String, String)
        case validationFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let tag):
                "\(Self.name(tag)) isn't available for on-device dictation on this iPhone."
            case .offline(let tag):
                "\(Self.name(tag)) needs a one-time download. Connect to the internet and try again."
            case .downloadFailed(let tag, let reason):
                "Couldn't download the \(Self.name(tag)) speech model (\(reason))."
            case .validationFailed(let tag, let reason):
                "\(Self.name(tag)) speech recognition isn't working on this iPhone (\(reason))."
            }
        }

        private static func name(_ tag: String) -> String {
            DictationLanguage(tag: tag).localizedName
        }
    }

    private enum ValidationError: LocalizedError {
        case noCompatibleFormat
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noCompatibleFormat: "no compatible audio format"
            case .timedOut: "the model didn't respond in time"
            }
        }
    }

    private let settings: SharedSettings
    private let logger = Logger(subsystem: "Murmur", category: "ASR")
    /// Re-validate after an OS update or every 30 days.
    private static let verificationLifetime: TimeInterval = 30 * 24 * 3600
    private static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    init(settings: SharedSettings = .shared) {
        self.settings = settings
    }

    /// Makes `tag` ready for recognition: picks the engine, downloads the model if needed,
    /// validates it once per OS version, and reserves the locale.
    func ensureReady(
        tag: String,
        contextualStrings: [String] = [],
        override: Engine? = nil,
        progress: (@Sendable (InstallEvent) -> Void)? = nil
    ) async throws -> ResolvedLanguage {
        let candidates = override.map { [$0] } ?? Engine.allCases
        var supported: [(engine: Engine, locale: Locale)] = []
        for engine in candidates {
            if let locale = await Self.supportedLocale(for: engine, equivalentTo: tag) {
                supported.append((engine, locale))
            }
        }
        guard !supported.isEmpty else { throw LanguageError.unsupported(tag) }

        // Fast path: verified on this OS version recently, and the asset is still installed
        // (the system may drop assets an app hasn't used for a while).
        if let record = settings.verifiedEngines[tag], record.osVersion == Self.osVersion,
           Date().timeIntervalSince(record.verifiedAt) < Self.verificationLifetime,
           let match = supported.first(where: { $0.engine.rawValue == record.engine }),
           await AssetInventory.status(forModules: [Self.makeModule(match.engine, locale: match.locale)]) == .installed {
            return ResolvedLanguage(tag: tag, locale: match.locale, engine: match.engine,
                                    contextualStrings: contextualStrings)
        }

        var failure = LanguageError.unsupported(tag)
        for (engine, locale) in supported {
            let module = Self.makeModule(engine, locale: locale)
            do {
                try await download(module, engine: engine, progress: progress)
            } catch {
                logger.error("Downloading \(engine.displayName, privacy: .public) for \(tag, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if Self.isOffline(error) { throw LanguageError.offline(tag) }
                failure = .downloadFailed(tag, error.localizedDescription)
                continue
            }
            progress?(.validating(engine))
            do {
                try await Self.withTimeout(seconds: 15) { try await Self.validate(module) }
            } catch {
                logger.error("Validating \(engine.displayName, privacy: .public) for \(tag, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failure = .validationFailed(tag, error.localizedDescription)
                continue
            }
            await reserve(locale, keeping: keptTags())
            settings.verifiedEngines[tag] = VerifiedEngineRecord(
                engine: engine.rawValue, osVersion: Self.osVersion, verifiedAt: Date())
            let resolved = ResolvedLanguage(tag: tag, locale: locale, engine: engine,
                                            contextualStrings: contextualStrings)
            progress?(.ready(resolved))
            logger.info("Verified \(engine.displayName, privacy: .public) for \(tag, privacy: .public)")
            return resolved
        }
        throw failure
    }

    func status(for tag: String) async -> LanguageStatus {
        var speech: AssetState?
        var dictation: AssetState?
        if let locale = await Self.supportedLocale(for: .speech, equivalentTo: tag) {
            speech = AssetState(await AssetInventory.status(forModules: [Self.makeModule(.speech, locale: locale)]))
        }
        if let locale = await Self.supportedLocale(for: .dictation, equivalentTo: tag) {
            dictation = AssetState(await AssetInventory.status(forModules: [Self.makeModule(.dictation, locale: locale)]))
        }
        let reserved = await AssetInventory.reservedLocales.contains { $0.identifier(.bcp47) == tag }
        return LanguageStatus(tag: tag, speech: speech, dictation: dictation,
                              verified: settings.verifiedEngines[tag], reserved: reserved)
    }

    /// Forces a fresh download check and validation on the next `ensureReady`.
    func forgetVerification(tag: String) {
        settings.verifiedEngines[tag] = nil
    }

    /// Releases every reserved locale that is no longer a chosen language.
    func reconcileReservations(keep tags: [String]) async {
        let keep = Set(tags)
        for locale in await AssetInventory.reservedLocales where !keep.contains(locale.identifier(.bcp47)) {
            _ = await AssetInventory.release(reservedLocale: locale)
            logger.info("Released speech assets for \(locale.identifier(.bcp47), privacy: .public)")
        }
    }

    /// Everything the device reports about the engines, for the Debug screen and bug reports.
    func diagnostics() async -> String {
        var lines = ["iOS \(Self.osVersion)"]
        lines.append("SpeechTranscriber supported: \(Self.tags(await SpeechTranscriber.supportedLocales))")
        lines.append("SpeechTranscriber installed: \(Self.tags(await SpeechTranscriber.installedLocales))")
        lines.append("DictationTranscriber supported: \(Self.tags(await DictationTranscriber.supportedLocales))")
        lines.append("DictationTranscriber installed: \(Self.tags(await DictationTranscriber.installedLocales))")
        var probes = ["ru-RU", "en-US"]
        for tag in keptTags() where !probes.contains(tag) { probes.append(tag) }
        for tag in probes {
            let speech = await Self.supportedLocale(for: .speech, equivalentTo: tag)?.identifier ?? "—"
            let dictation = await Self.supportedLocale(for: .dictation, equivalentTo: tag)?.identifier ?? "—"
            let status = await status(for: tag)
            lines.append(
                "\(tag): speech=\(speech) [\(Self.describe(status.speech))], dictation=\(dictation) [\(Self.describe(status.dictation))], verified=\(status.verified?.engine ?? "no"), reserved=\(status.reserved)")
        }
        let reserved = await AssetInventory.reservedLocales
        lines.append("Reserved: \(Self.tags(reserved)) (max \(AssetInventory.maximumReservedLocales))")
        lines.append("DictationTranscriber long-dictation options: \(DictationTranscriber.Preset.progressiveLongDictation.transcriptionOptions)")
        lines.append("SpeechTranscriber options: \(SpeechTranscriber.Preset.progressiveTranscription.transcriptionOptions)")
        return lines.joined(separator: "\n")
    }

    // MARK: Modules

    nonisolated static func makeModule(_ engine: Engine, locale: Locale) -> any SpeechModule {
        switch engine {
        case .speech: SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        case .dictation: DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }
    }

    nonisolated static func supportedLocale(for engine: Engine, equivalentTo tag: String) async -> Locale? {
        let locale = Locale(identifier: tag)
        switch engine {
        case .speech: return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        case .dictation: return await DictationTranscriber.supportedLocale(equivalentTo: locale)
        }
    }

    // MARK: Steps

    private func download(_ module: any SpeechModule, engine: Engine,
                          progress: (@Sendable (InstallEvent) -> Void)?) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        logger.info("Downloading speech assets for \(engine.displayName, privacy: .public)")
        let poller = Task.detached {
            while !Task.isCancelled {
                progress?(.downloading(fraction: request.progress.fractionCompleted, engine: engine))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poller.cancel() }
        try await request.downloadAndInstall()
        progress?(.downloading(fraction: 1, engine: engine))
    }

    /// Loads the model and runs half a second of silence through it. Any failure (including the
    /// "asset not found after attempted download" case) disqualifies the engine for this
    /// language. The retained model is reused by the session, so the cost is paid once.
    private static func validate(_ module: any SpeechModule) async throws {
        let analyzer = SpeechAnalyzer(
            modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw ValidationError.noCompatibleFormat
        }
        try await analyzer.prepareToAnalyze(in: format)
        let drain = Task { try await drainResults(of: module) }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        do {
            try await analyzer.start(inputSequence: stream)
            if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 2)) {
                silence.frameLength = silence.frameCapacity
                for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                continuation.yield(AnalyzerInput(buffer: silence))
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await drain.value
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            drain.cancel()
            throw error
        }
    }

    private static func drainResults(of module: any SpeechModule) async throws {
        if let transcriber = module as? SpeechTranscriber {
            for try await _ in transcriber.results {}
        } else if let transcriber = module as? DictationTranscriber {
            for try await _ in transcriber.results {}
        }
    }

    private func reserve(_ locale: Locale, keeping keptTags: [String]) async {
        if (try? await AssetInventory.reserve(locale: locale)) == true { return }
        // Over the per-app limit: free a locale that is no longer chosen and retry once.
        let tag = locale.identifier(.bcp47)
        let keep = Set(keptTags + [tag])
        guard let victim = await AssetInventory.reservedLocales.first(where: { !keep.contains($0.identifier(.bcp47)) }) else {
            logger.notice("Couldn't reserve speech assets for \(tag, privacy: .public); limit \(AssetInventory.maximumReservedLocales)")
            return
        }
        _ = await AssetInventory.release(reservedLocale: victim)
        if (try? await AssetInventory.reserve(locale: locale)) != true {
            logger.notice("Couldn't reserve speech assets for \(tag, privacy: .public) after releasing \(victim.identifier(.bcp47), privacy: .public)")
        }
    }

    private func keptTags() -> [String] {
        [settings.primaryLanguage, settings.secondaryLanguage].compactMap { $0 }
    }

    // MARK: Helpers

    private static func withTimeout(seconds: Double, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ValidationError.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func isOffline(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                NSURLErrorTimedOut, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(nsError.code)
    }

    private static func tags(_ locales: [Locale]) -> String {
        let tags = locales.map { $0.identifier(.bcp47) }.sorted()
        return tags.isEmpty ? "none" : tags.joined(separator: " ")
    }

    private static func describe(_ status: AssetState?) -> String {
        status?.rawValue ?? "n/a"
    }
}
