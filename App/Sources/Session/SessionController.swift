@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
import MurmurCore
import Observation
import os
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
    /// Recent results, newest first (debug view; replaced by History in Phase 4).
    private(set) var recentResults: [DictationResult] = []

    var isLive: Bool {
        switch phase {
        case .ready, .recording, .processing: true
        default: false
        }
    }

    @ObservationIgnored private let transport: IPCTransport
    @ObservationIgnored private let publisher: HotStatePublisher
    @ObservationIgnored private let pipeline: DictationPipeline
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

    /// Wispr Flow caps dictations at 5 minutes; we do the same.
    static let maxDictationSeconds: TimeInterval = 300

    init(transport: IPCTransport, pipeline: DictationPipeline) {
        self.transport = transport
        self.publisher = HotStatePublisher(transport: transport)
        self.pipeline = pipeline
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

            let transcriber = TranscriberEngine.current.make(contextualStrings: pipeline.contextualStrings())
            startDetail = "Preparing speech recognition… The first time, this downloads the language model."
            defer { startDetail = nil }
            try await transcriber.prepare(micFormat: micFormat, locale: dictationLocale)
            self.transcriber = transcriber
            engineName = transcriber.displayName
            audio.setBufferHandler { [transcriber] buffer in transcriber.append(buffer) }
            audio.setLevelHandler { [publisher] level in publisher.setLevel(level) }

            phase = .ready
            publisher.set(.ready)
            transport.post(.stateChanged)
            startHeartbeat()
            scheduleIdleTimeout()
            liveActivity.start()
            logger.info("Session started with \(transcriber.displayName, privacy: .public)")
        } catch {
            logger.error("Session start failed: \(String(describing: error), privacy: .public)")
            tearDownAudio()
            phase = .failed(Self.userMessage(for: error))
            publisher.set(.off)
            transport.post(.stateChanged)
        }
    }

    /// Ends the session and releases the microphone.
    func stop() {
        if active != nil { endDictation(commit: true) }
        heartbeatTask?.cancel()
        idleTask?.cancel()
        capTask?.cancel()
        tearDownAudio()
        if let transcriber {
            Task { await transcriber.shutdown() }
        }
        transcriber = nil
        phase = .off
        publisher.set(.off)
        transport.post(.stateChanged)
        liveActivity.end()
        logger.info("Session stopped")
    }

    /// Called when the app becomes active: recover from interruptions that left us stranded.
    func appDidBecomeActive() {
        if phase == .needsReconnect {
            Task { await reconnect() }
        }
    }

    // MARK: Dictation

    /// In-app dictation (e.g. Scratchpad) uses the same pipeline as the keyboard.
    func beginInAppDictation() -> UUID? {
        let id = UUID()
        return beginDictation(requestId: id, documentIdentifier: nil, style: nil, source: .inApp) ? id : nil
    }

    @discardableResult
    private func beginDictation(requestId: UUID, documentIdentifier: UUID?, style: StylePreset?,
                                source: ActiveDictation.Source) -> Bool {
        guard phase == .ready, let transcriber else {
            logger.notice("Start ignored in phase \(String(describing: self.phase), privacy: .public)")
            return false
        }
        idleTask?.cancel()
        transcriber.beginUtterance()
        audio.openGate()
        active = ActiveDictation(requestId: requestId, documentIdentifier: documentIdentifier,
                                 style: style, source: source, startedAt: Date())
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
            let result = await pipeline.complete(
                dictation, transcriber: transcriber, language: dictationLocale.identifier(.bcp47),
                audioSeconds: audioSeconds, stoppedAt: stoppedAt)
            deliver(result)
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
        recentResults.insert(result, at: 0)
        if recentResults.count > 50 { recentResults.removeLast() }
    }

    private func becomeReady() {
        guard transcriber != nil, phase != .off else { return }
        phase = .ready
        publisher.set(.ready)
        transport.post(.stateChanged)
        liveActivity.update(.ready, since: nil)
        scheduleIdleTimeout()
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
                           style: command.styleOverride, source: .keyboard)
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
        guard let timeout = settings.disableAfter.idleTimeout, timeout > 0 else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
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
            Task { await reconnect() }
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
        Task { await reconnect() }
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
            if let format = audio.inputFormat {
                try await transcriber.prepare(micFormat: format, locale: dictationLocale)
            }
            becomeReady()
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
        if let transcriberError = error as? AppleSpeechTranscriber.TranscriberError {
            return transcriberError.localizedDescription
        }
        let code = AVAudioSession.ErrorCode(rawValue: (error as NSError).code)
        switch code {
        case .insufficientPriority:
            return "Another app is using the microphone. Finish there, then try again."
        case .cannotStartRecording, .cannotInterruptOthers:
            return "Couldn't start the microphone. Make sure Murmur is open, then try again."
        default:
            return "Couldn't start audio capture. Check that no other app is using the microphone."
        }
    }

    private var dictationLocale: Locale {
        settings.dictationLocale.map(Locale.init(identifier:)) ?? .current
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
