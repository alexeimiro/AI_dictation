@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MurmurCore
import Observation
import os
import Speech
import UIKit

/// The dictation session: a hot mic in the app that the keyboard drives through IPC.
///
/// Lifecycle: `start()` (foreground only) → `ready` ⇄ `recording` → `processing` → `ready` …
/// → `stop()` after the "Disable after" idle timeout, from the Live Activity, or manually.
@MainActor
@Observable
final class SessionController {
    enum Phase: Equatable {
        case off
        case starting
        case ready
        case recording(UUID)
        case processing(UUID)
        /// Audio couldn't be reactivated after an interruption; reopening the app fixes it.
        case needsReconnect
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var engineName = ""
    /// Extra detail while starting (e.g. the first-run speech model download).
    private(set) var startDetail: String?

    var isLive: Bool {
        switch phase {
        case .ready, .recording, .processing: true
        default: false
        }
    }

    @ObservationIgnored private let transport: IPCTransport
    @ObservationIgnored private let publisher: HotStatePublisher
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let assets: SpeechAssetManager
    @ObservationIgnored private let history: any TranscriptSink
    @ObservationIgnored private let settings = SharedSettings.shared
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Session")
    @ObservationIgnored private var transcriber: Transcriber?
    @ObservationIgnored private var active: ActiveDictation?
    @ObservationIgnored private var handledCommands: Set<UUID> = []
    @ObservationIgnored private var commandObservation: IPCObservation?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var capTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Languages whose models are loaded and ready, keyed by BCP-47 tag.
    @ObservationIgnored private var languages: [String: ResolvedLanguage] = [:]
    @ObservationIgnored private var primaryTag = DictationLanguage.englishUS.tag
    @ObservationIgnored private var pendingLanguageReload = false
    @ObservationIgnored private var secondaryTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    /// Wispr Flow caps dictations at 5 minutes; we do the same.
    static let maxDictationSeconds: TimeInterval = 300
    /// With "Disable after: Immediately", a session that isn't used still ends after this.
    static let immediateIdleGrace: TimeInterval = 60

    init(transport: IPCTransport, pipeline: DictationPipeline, assets: SpeechAssetManager, history: any TranscriptSink) {
        self.transport = transport
        self.publisher = HotStatePublisher(transport: transport)
        self.pipeline = pipeline
        self.assets = assets
        self.history = history
        publisher.set(.off)
        commandObservation = transport.observe(.command) { [weak self] in
            MainActor.assumeIsolated { self?.handleCommand() }
        }
        observeAudioNotifications()
        transport.payloads.prune(olderThan: 24 * 3600)
    }

    // MARK: Session lifecycle

    /// Starts the hot mic. Must be called while the app is in the foreground.
    func start() async {
        switch phase {
        case .ready, .recording, .processing, .starting: return
        default: break
        }
        phase = .starting
        publisher.set(.starting)
        transport.post(.stateChanged)
        do {
            guard await Self.requestMicrophonePermission() else { throw SessionError.microphoneDenied }
            try await activateAudioSession()
            try audio.startEngine()
            guard let micFormat = audio.inputFormat else { throw AudioCapture.CaptureError.noInput }

            defer { startDetail = nil }
            let primary = try await readyPrimaryLanguage()
            let transcriber: Transcriber = TranscriberEngine.current == .stub
                ? StubTranscriber() : AppleSpeechTranscriber()
            try await transcriber.prepare(micFormat: micFormat, language: primary)
            self.transcriber = transcriber
            engineName = transcriber.displayName
            audio.setBufferHandler { [transcriber] buffer in transcriber.append(buffer) }
            audio.setLevelHandler { [publisher] level in publisher.setLevel(level) }

            transport.payloads.clearSessionFailure()
            phase = .ready
            publisher.set(.ready)
            transport.post(.stateChanged)
            startHeartbeat()
            scheduleIdleTimeout()
            if settings.liveActivities { await liveActivity.start() }
            logger.info("Session started with \(transcriber.displayName, privacy: .public)")
        } catch {
            logger.error("Session start failed: \(String(describing: error), privacy: .public)")
            tearDownAudio()
            let message = Self.userMessage(for: error)
            phase = .failed(message)
            // The keyboard shows the reason; `.error` also stops it from bouncing to the app again.
            try? transport.payloads.write(sessionFailure: SessionFailure(message: message, createdAt: Date()))
            publisher.set(.error)
            transport.post(.stateChanged)
        }
    }

    /// Resolves the primary language and makes its model ready, reporting the first-run
    /// download in `startDetail`. The secondary language is readied in the background.
    private func readyPrimaryLanguage() async throws -> ResolvedLanguage {
        let tag = await LanguageResolver.primaryTag(settings: settings)
        primaryTag = tag
        let name = DictationLanguage(tag: tag).localizedName
        startDetail = "Preparing \(name) speech recognition… The first time, this downloads the language model."
        let primary: ResolvedLanguage
        if TranscriberEngine.current == .stub {
            primary = ResolvedLanguage(tag: tag, locale: Locale(identifier: tag), engine: .speech)
        } else {
            primary = try await assets.ensureReady(
                tag: tag, contextualStrings: pipeline.contextualStrings(),
                override: TranscriberEngine.current.kindOverride
            ) { [weak self] event in
                Task { @MainActor in
                    if let detail = Self.detail(for: event, language: name) { self?.startDetail = detail }
                }
            }
        }
        languages = [tag: primary]
        prepareSecondaryLanguage()
        return primary
    }

    private static func detail(for event: SpeechAssetManager.InstallEvent, language name: String) -> String? {
        switch event {
        case .downloading(let fraction, _): "Downloading \(name)… \(Int((fraction * 100).rounded()))%"
        case .validating: "Checking \(name) speech recognition…"
        case .ready: nil
        }
    }

    /// Loads the secondary language's model so the keyboard's language pill can switch to it
    /// without a wait.
    private func prepareSecondaryLanguage() {
        guard let tag = settings.secondaryLanguage, tag != primaryTag, languages[tag] == nil else { return }
        if TranscriberEngine.current == .stub {
            languages[tag] = ResolvedLanguage(tag: tag, locale: Locale(identifier: tag), engine: .speech)
            return
        }
        secondaryTask?.cancel()
        secondaryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await assets.ensureReady(
                    tag: tag, contextualStrings: pipeline.contextualStrings(),
                    override: TranscriberEngine.current.kindOverride)
                guard !Task.isCancelled, settings.secondaryLanguage == tag else { return }
                languages[tag] = resolved
                logger.info("Secondary language ready: \(tag, privacy: .public)")
            } catch {
                logger.error("Secondary language \(tag, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Called by the Languages UI after the primary or secondary language changed. Applied at
    /// once when idle, otherwise after the current dictation.
    func languagesDidChange() {
        guard isLive else { return }
        guard phase == .ready else {
            pendingLanguageReload = true
            return
        }
        Task { await reloadLanguages() }
    }

    private func reloadLanguages() async {
        pendingLanguageReload = false
        let tag = await LanguageResolver.primaryTag(settings: settings)
        primaryTag = tag
        if languages[tag] == nil {
            if TranscriberEngine.current == .stub {
                languages[tag] = ResolvedLanguage(tag: tag, locale: Locale(identifier: tag), engine: .speech)
            } else {
                do {
                    languages[tag] = try await assets.ensureReady(
                        tag: tag, contextualStrings: pipeline.contextualStrings(),
                        override: TranscriberEngine.current.kindOverride)
                } catch {
                    logger.error("Couldn't prepare \(tag, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if phase == .ready, let primary = languages[tag], let transcriber, transcriber.currentLanguage != primary {
            transcriber.setLanguage(primary)
        }
        let keep = [tag, settings.secondaryLanguage].compactMap { $0 }
        languages = languages.filter { keep.contains($0.key) }
        prepareSecondaryLanguage()
        await assets.reconcileReservations(keep: keep)
    }

    /// Ends the session and releases the microphone.
    func stop() {
        if active != nil { endDictation(commit: true) }
        heartbeatTask?.cancel()
        idleTask?.cancel()
        capTask?.cancel()
        tearDownAudio()
        secondaryTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        if let transcriber {
            Task { await transcriber.shutdown() }
        }
        transcriber = nil
        languages = [:]
        transport.payloads.clearSessionFailure()
        phase = .off
        publisher.set(.off)
        transport.post(.stateChanged)
        liveActivity.end()
        logger.info("Session stopped")
    }

    /// Called when the app becomes active: recover from interruptions that left us stranded.
    func appDidBecomeActive() {
        if phase == .needsReconnect {
            requestReconnect()
        }
    }

    // MARK: Dictation

    /// In-app dictation (e.g. Scratchpad) uses the same pipeline as the keyboard.
    func beginInAppDictation() -> UUID? {
        let id = UUID()
        return beginDictation(requestId: id, documentIdentifier: nil, style: nil, languageOverride: nil,
                              source: .inApp) ? id : nil
    }

    @discardableResult
    private func beginDictation(requestId: UUID, documentIdentifier: UUID?, style: StylePreset?,
                                languageOverride: String?, source: ActiveDictation.Source) -> Bool {
        guard phase == .ready, let transcriber else {
            logger.notice("Start ignored in phase \(String(describing: self.phase), privacy: .public)")
            return false
        }
        let language: ResolvedLanguage
        if let languageOverride, languageOverride != primaryTag {
            guard let ready = languages[languageOverride] else {
                let name = DictationLanguage(tag: languageOverride).localizedName
                logger.notice("Dictation in \(languageOverride, privacy: .public) requested before its model is ready")
                rejectDictation(requestId: requestId, documentIdentifier: documentIdentifier, language: languageOverride,
                                message: "\(name) is still being set up in Murmur. Try again in a moment.")
                prepareSecondaryLanguage()
                return false
            }
            language = ready
        } else {
            guard let primary = languages[primaryTag] else {
                logger.error("No primary language loaded")
                return false
            }
            language = primary
        }
        if transcriber.currentLanguage != language {
            transcriber.setLanguage(language)
        }
        idleTask?.cancel()
        transcriber.beginUtterance()
        audio.openGate()
        active = ActiveDictation(requestId: requestId, documentIdentifier: documentIdentifier,
                                 style: style, language: language.tag, source: source, startedAt: Date())
        phase = .recording(requestId)
        publisher.set(.recording, requestTag: requestId.tag16)
        transport.post(.stateChanged)
        playSound(.start)
        liveActivity.update(.recording, since: Date())
        capTask?.cancel()
        capTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxDictationSeconds))
            guard !Task.isCancelled else { return }
            self?.endDictation(commit: true)
        }
        return true
    }

    /// Acknowledges a start the keyboard asked for (so it doesn't bounce to the app), then ends
    /// it with a reason instead of recording.
    private func rejectDictation(requestId: UUID, documentIdentifier: UUID?, language: String, message: String) {
        phase = .recording(requestId)
        publisher.set(.recording, requestTag: requestId.tag16)
        transport.post(.stateChanged)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, case .recording(requestId) = self.phase, self.active == nil else { return }
            self.deliver(DictationResult(
                requestId: requestId, documentIdentifier: documentIdentifier, text: "", status: .failed,
                message: message, createdAt: Date(), language: language))
            self.becomeReady()
        }
    }

    /// Ends the current dictation; `commit: false` discards it.
    func endDictation(commit: Bool) {
        guard let dictation = active, let transcriber else { return }
        active = nil
        capTask?.cancel()
        let frames = audio.closeGate()
        let audioSeconds = Double(frames) / (audio.inputFormat?.sampleRate ?? 48_000)
        playSound(.stop)

        guard commit else {
            Task { await transcriber.cancelUtterance() }
            becomeReady()
            return
        }

        phase = .processing(dictation.requestId)
        publisher.set(.processing, requestTag: dictation.requestId.tag16)
        transport.post(.stateChanged)
        liveActivity.update(.processing, since: nil)
        let stoppedAt = ContinuousClock.now
        beginBackgroundWork()
        Task {
            let outcome = await pipeline.complete(
                dictation, transcriber: transcriber, audioSeconds: audioSeconds, stoppedAt: stoppedAt)
            // The keyboard first, then history, so the save never delays the insertion.
            deliver(outcome.result)
            history.record(outcome.transcript)
            becomeReady()
            if settings.disableAfter == .immediately {
                stop()
            }
            endBackgroundWork()
        }
    }

    private func deliver(_ result: DictationResult) {
        do {
            try transport.payloads.write(result: result)
        } catch {
            logger.error("Couldn't write result: \(error.localizedDescription, privacy: .public)")
        }
        transport.post(.resultReady)
    }

    /// Back to `ready` after a dictation. Not from `needsReconnect`: a dictation that ended
    /// because of an interruption must not report a working mic.
    private func becomeReady(afterReconnect: Bool = false) {
        guard transcriber != nil else { return }
        switch phase {
        case .off, .starting, .failed: return
        case .needsReconnect where !afterReconnect: return
        default: break
        }
        phase = .ready
        publisher.set(.ready)
        transport.post(.stateChanged)
        liveActivity.update(.ready, since: nil)
        scheduleIdleTimeout()
        if pendingLanguageReload {
            Task { await reloadLanguages() }
        }
    }

    // MARK: Keyboard commands

    private func handleCommand() {
        guard let command = transport.payloads.readCommand(),
              !handledCommands.contains(command.id) else { return }
        handledCommands.insert(command.id)
        guard Date().timeIntervalSince(command.createdAt) < 15 else {
            logger.notice("Ignoring stale \(command.kind.rawValue, privacy: .public) command")
            return
        }
        switch command.kind {
        case .start:
            beginDictation(requestId: command.requestId, documentIdentifier: command.documentIdentifier,
                           style: command.styleOverride, languageOverride: command.languageOverride,
                           source: .keyboard)
        case .stop:
            if active?.requestId == command.requestId { endDictation(commit: true) }
        case .cancel:
            if active?.requestId == command.requestId { endDictation(commit: false) }
        }
    }

    // MARK: Timers

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.heartbeat()
            }
        }
    }

    private func heartbeat() {
        switch phase {
        case .recording(let requestId):
            // If the keyboard was killed mid-dictation, finish it so it lands in history.
            guard let dictation = active, dictation.source == .keyboard,
                  Date().timeIntervalSince(dictation.startedAt) > 5 else { return }
            let status = transport.payloads.readKeyboardStatus()
            let heartbeat = status?.listeningRequestId == requestId ? status?.listeningHeartbeatAt : nil
            if Date().timeIntervalSince(heartbeat ?? dictation.startedAt) > 4 {
                logger.notice("Keyboard heartbeat lost; finishing dictation")
                endDictation(commit: true)
            }
        case .ready, .processing:
            publisher.tick()
        default:
            break
        }
    }

    private func scheduleIdleTimeout() {
        idleTask?.cancel()
        guard let timeout = settings.disableAfter.idleTimeout else { return }
        // "Immediately" stops right after a delivered result; a session that is never used, or
        // whose dictation was cancelled, still gets a short grace period instead of staying on.
        let delay = timeout > 0 ? timeout : Self.immediateIdleGrace
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.phase == .ready else { return }
            self.logger.info("Idle timeout reached")
            self.stop()
        }
    }

    // MARK: Interruptions and route changes

    private func observeAudioNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated { self?.handleInterruption(type, options: options) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.handleRouteChange(reason) }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAudioPath(reason: "engine configuration change") }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?,
                                    options: AVAudioSession.InterruptionOptions) {
        guard isLive || phase == .needsReconnect else { return }
        switch type {
        case .began:
            logger.notice("Audio interrupted")
            if active != nil { endDictation(commit: true) }
            phase = .needsReconnect
            publisher.set(.needsReconnect)
            transport.post(.stateChanged)
        case .ended:
            if options.contains(.shouldResume) {
                requestReconnect()
            } else {
                // The system says not to resume (another app took the audio); the keyboard
                // offers Reconnect, which reopens the app and reconnects from `appDidBecomeActive`.
                logger.notice("Interruption ended without shouldResume")
            }
        default:
            break
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        guard isLive else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            rebuildAudioPath(reason: "route change")
        default:
            break
        }
    }

    /// Input format can change with the route: rebuild the tap and the transcriber's converter.
    private func rebuildAudioPath(reason: String) {
        guard isLive else { return }
        logger.notice("Rebuilding audio path after \(reason, privacy: .public)")
        if active != nil { endDictation(commit: true) }
        requestReconnect()
    }

    /// Route changes and engine configuration changes often arrive together; run one reconnect.
    private func requestReconnect() {
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnect()
            self?.reconnectTask = nil
        }
    }

    private func handleMediaServicesReset() {
        logger.error("Media services were reset")
        let wasLive = isLive
        stop()
        if wasLive {
            phase = .needsReconnect
            publisher.set(.needsReconnect)
            transport.post(.stateChanged)
        }
    }

    private func reconnect() async {
        guard let transcriber else {
            phase = .off
            await start()
            return
        }
        do {
            try await activateAudioSession()
            try audio.restartEngine()
            if let format = audio.inputFormat,
               let language = transcriber.currentLanguage ?? languages[primaryTag] {
                try await transcriber.prepare(micFormat: format, language: language)
            }
            becomeReady(afterReconnect: true)
            logger.info("Audio reconnected")
        } catch {
            // Typically '!int' when reactivating from the background after a call.
            logger.error("Reconnect failed: \(error.localizedDescription, privacy: .public)")
            phase = .needsReconnect
            publisher.set(.needsReconnect)
            transport.post(.stateChanged)
        }
    }

    // MARK: Helpers

    /// Recording can only begin while the app is active. Right after the microphone permission
    /// alert, or while the app is still opening from the keyboard's link, it is briefly
    /// inactive and activation fails ("Session activation failed"), so wait, then retry once.
    private func activateAudioSession() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while UIApplication.shared.applicationState != .active, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        do {
            try audio.activateSession(preferBuiltInMic: settings.useBuiltInMic)
        } catch {
            logger.notice("Audio session activation failed (\(String(describing: error), privacy: .public)); retrying")
            try await Task.sleep(for: .milliseconds(400))
            try audio.activateSession(preferBuiltInMic: settings.useBuiltInMic)
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let sessionError = error as? SessionError { return sessionError.localizedDescription }
        if let languageError = error as? SpeechAssetManager.LanguageError { return languageError.localizedDescription }
        if let transcriberError = error as? AppleSpeechTranscriber.TranscriberError {
            return transcriberError.localizedDescription
        }
        if let captureError = error as? AudioCapture.CaptureError { return captureError.localizedDescription }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Murmur couldn't reach the internet to download the speech model. Check your connection and try again."
        }
        if nsError.domain == SFSpeechError.errorDomain {
            return "Speech recognition failed to start (\(nsError.localizedDescription)). Open Murmur › Languages and tap Verify."
        }
        if nsError.domain == NSOSStatusErrorDomain {
            switch AVAudioSession.ErrorCode(rawValue: nsError.code) {
            case .insufficientPriority:
                return "Another app is using the microphone. Finish there, then try again."
            case .cannotStartRecording, .cannotInterruptOthers:
                return "Couldn't start the microphone. Make sure Murmur is open, then try again."
            default:
                return "Couldn't start audio capture. Check that no other app is using the microphone."
            }
        }
        return "Couldn't start Murmur: \(error.localizedDescription)"
    }

    private func tearDownAudio() {
        audio.setBufferHandler(nil)
        audio.setLevelHandler(nil)
        audio.stopEngine()
        audio.deactivateSession()
    }

    private enum Sound: SystemSoundID {
        case start = 1113
        case stop = 1114
    }

    private func playSound(_ sound: Sound) {
        guard settings.interactionSounds else { return }
        AudioServicesPlaySystemSound(sound.rawValue)
    }

    private func beginBackgroundWork() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    enum SessionError: LocalizedError {
        case microphoneDenied

        var errorDescription: String? {
            "Murmur needs microphone access. Turn it on in Settings › Murmur."
        }
    }
}
