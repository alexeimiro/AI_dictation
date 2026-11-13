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
/// → `stop()` after the "Turn off after" idle timeout, from the Live Activity, or manually.
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
    @ObservationIgnored private let transcription: (any CloudTranscribing)?
    /// Translates a cloud dictation in the request that transcribes it.
    @ObservationIgnored private let dictate: (any Dictating)?
    /// Gets the token and `dictate` ready while the user speaks.
    @ObservationIgnored private let warmup: BackendWarmup?
    /// This session transcribes with OpenAI (decided when it starts).
    @ObservationIgnored private var usesCloud = false
    /// In the cloud, the on-device languages already installed, for when a request fails.
    @ObservationIgnored private var onDeviceFallbacks: [String: ResolvedLanguage] = [:]
    @ObservationIgnored private let history: any TranscriptSink
    /// Where each dictation's audio is kept for playback ("Keep recordings"); nil keeps none.
    @ObservationIgnored private let recordings: RecordingStore?
    /// Where each dictation's timings go (Debug screen); nil keeps none.
    @ObservationIgnored private let timingsLog: TimingsLog?
    @ObservationIgnored private let settings: SharedSettings
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
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    /// The dictation the keyboard asked for when it opened the app, started once the session is ready.
    @ObservationIgnored private var requestedStart: PendingStart?
    /// The last dictation started that way, to start again if the audio path is rebuilt before
    /// the keyboard is back.
    @ObservationIgnored private var autoStarted: PendingStart?
    /// A start that arrived while the previous dictation was still being processed.
    @ObservationIgnored private var queuedStart: KeyboardCommand?
    /// Requests the keyboard cancelled, so a start armed or queued for them is dropped.
    @ObservationIgnored private var cancelledRequests: Set<UUID> = []
    /// Where an in-app dictation's result goes (the note dictated into); nil drops it.
    @ObservationIgnored var inAppResultHandler: ((DictationResult) -> Void)?
    /// "Turn off after" counts from the latest of these and the keyboard leaving the screen.
    @ObservationIgnored private var idleSince = Date()
    @ObservationIgnored private var backgroundSince: Date?
    @ObservationIgnored private var interruptedAt: Date?
    @ObservationIgnored private var keyboardObservation: IPCObservation?
    /// The user's OK to send recordings to the AI services that write them, asked if it hasn't
    /// been given (`AIConsent.ensure`). No session, so no dictation, starts without it.
    @ObservationIgnored private let consent: @MainActor () async -> Bool

    /// A dictation ends by itself after 5 minutes.
    static let maxDictationSeconds: TimeInterval = 300
    /// With "Turn off after: Immediately", a session that isn't used still ends after this.
    static let immediateIdleGrace: TimeInterval = 60
    /// How long a dictation the app started for the keyboard waits for it to come back. The
    /// automatic start expires after that.
    static let keyboardReturnWindow: TimeInterval = 10
    /// How long a start that arrived while the app was busy stays valid.
    static let queuedStartLifetime: TimeInterval = 15
    /// Calls and Siri can hold the audio hardware for a moment after they end.
    static let reconnectDelays: [Duration] = [.zero, .milliseconds(500), .seconds(1), .seconds(2)]

    init(transport: IPCTransport, pipeline: DictationPipeline, assets: SpeechAssetManager, history: any TranscriptSink,
         recordings: RecordingStore? = nil, transcription: (any CloudTranscribing)? = nil, dictate: (any Dictating)? = nil,
         warmup: BackendWarmup? = nil, timingsLog: TimingsLog? = nil, settings: SharedSettings = .shared,
         consent: @escaping @MainActor () async -> Bool = { true }) {
        self.consent = consent
        self.transport = transport
        self.publisher = HotStatePublisher(transport: transport)
        self.pipeline = pipeline
        self.assets = assets
        self.transcription = transcription
        self.dictate = dictate
        self.warmup = warmup
        self.history = history
        self.recordings = recordings
        self.timingsLog = timingsLog
        self.settings = settings
        publisher.set(.off)
        commandObservation = transport.observe(.command) { [weak self] in
            MainActor.assumeIsolated { self?.handleCommand() }
        }
        keyboardObservation = transport.observe(.keyboardStatus) { [weak self] in
            MainActor.assumeIsolated { self?.keyboardStatusChanged() }
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
        let startedAt = ContinuousClock.now
        phase = .starting
        publisher.set(.starting)
        transport.post(.stateChanged)
        // Before the microphone: what is recorded from here on goes to the AI services. Nothing is
        // set up yet, so a "Not now" has no audio to take down.
        guard await consent() else { return failStart(SessionError.aiNotAllowed) }
        do {
            guard await Self.requestMicrophonePermission() else { throw SessionError.microphoneDenied }
            try await activateAudioSession(waitForForeground: true)
            try audio.startEngine()
            guard let micFormat = audio.inputFormat else { throw AudioCapture.CaptureError.noInput }

            defer { startDetail = nil }
            usesCloud = TranscriberEngine.current.usesCloud(cloudAvailable: transcription?.isConfigured == true)
            let primary = try await readyPrimaryLanguage()
            let transcriber = makeTranscriber()
            try await transcriber.prepare(micFormat: micFormat, language: primary)
            self.transcriber = transcriber
            engineName = transcriber.displayName
            audio.setBufferHandler { [transcriber] buffer in transcriber.append(buffer) }
            audio.setLevelHandler { [publisher] level in publisher.setLevel(level) }

            transport.payloads.clearSessionFailure()
            phase = .ready
            idleSince = Date()
            publisher.set(.ready)
            transport.post(.stateChanged)
            startHeartbeat()
            scheduleIdleStop()
            if settings.liveActivities { await liveActivity.start() }
            logger.info("Session started with \(transcriber.displayName, privacy: .public) in \(DictationPipeline.milliseconds(since: startedAt)) ms")
            beginQueuedStart()
            beginRequestedStart()
            prepareFallbackInBackground()
        } catch {
            tearDownAudio()
            failStart(error)
        }
    }

    /// A start that didn't happen: the phase says why, and so does the keyboard.
    private func failStart(_ error: any Error) {
        logger.error("Session start failed: \(String(describing: error), privacy: .public)")
        requestedStart = nil
        let message = Self.userMessage(for: error)
        phase = .failed(message)
        // The keyboard shows the reason; `.error` also stops it from bouncing to the app again.
        try? transport.payloads.write(sessionFailure: SessionFailure(message: message, createdAt: Date()))
        publisher.set(.error)
        transport.post(.stateChanged)
    }

    #if DEBUG
    /// Tests: where `start()` leaves the session, ready with `transcriber`, but without the
    /// microphone, so a dictation can go through the session.
    func startForTesting(with transcriber: Transcriber, language: ResolvedLanguage) {
        self.transcriber = transcriber
        primaryTag = language.tag
        languages = [language.tag: language]
        phase = .ready
    }

    /// Set by `pinForScreenshots`: the app becoming active must not restart a pinned session.
    @ObservationIgnored private var isPinnedForScreenshots = false

    /// Holds a phase for screenshots (`-session-fixture`). Nothing is started except the Live
    /// Activity, for the phases that have one, so the Lock Screen and the Dynamic Island can be
    /// shot too.
    func pinForScreenshots(_ phase: Phase) {
        self.phase = phase
        isPinnedForScreenshots = true
        let shown: SessionActivityAttributes.ContentState.Phase? = switch phase {
        case .ready: .ready
        case .recording: .recording
        case .processing: .processing
        case .off, .starting, .needsReconnect, .failed: nil
        }
        guard let shown, settings.liveActivities else { return }
        Task {
            await liveActivity.start()
            liveActivity.update(shown, since: shown == .recording ? Date().addingTimeInterval(-12) : nil)
        }
    }
    #endif

    /// The keyboard opened the app for `request`: turn the microphone on and record that
    /// dictation straight away, so the user can talk while getting back to their app.
    func start(beginning request: PendingStart?) async {
        if let request, request.autoStart == true { requestedStart = request }
        await recoverForForeground()
        await start()
        beginRequestedStart()
    }

    /// The keyboard opens the app when the session doesn't answer. One that still looks ready
    /// may have lost its audio in the background; in the foreground it can be rebuilt.
    private func recoverForForeground() async {
        guard phase == .needsReconnect || (phase == .ready && !audio.isEngineRunning) else { return }
        logger.notice("The session didn't answer the keyboard; reconnecting in the foreground")
        requestReconnect()
        await reconnectTask?.value
        if phase == .needsReconnect { stop() }
    }

    /// Records the dictation the keyboard asked for when it opened the app, once the session is
    /// ready. Dropped if the keyboard cancelled it (X also removes the pending start) or it's old.
    private func beginRequestedStart() {
        guard phase == .ready, let request = requestedStart else { return }
        requestedStart = nil
        guard transport.payloads.readPendingStart()?.requestId == request.requestId,
              !cancelledRequests.contains(request.requestId),
              Date().timeIntervalSince(request.createdAt) < 90 else { return }
        if beginDictation(requestId: request.requestId, documentIdentifier: request.documentIdentifier,
                          style: request.styleOverride, languageOverride: request.languageOverride,
                          translationTargetLanguage: request.translationTargetLanguage, source: .keyboard) {
            autoStarted = request
            logger.info("Recording the keyboard's dictation while the user goes back")
        }
    }

    private func makeTranscriber() -> Transcriber {
        if TranscriberEngine.current == .stub { return StubTranscriber() }
        guard usesCloud, let transcription else { return AppleSpeechTranscriber() }
        return OpenAITranscriber(client: transcription, dictation: dictate, fallback: AppleSpeechTranscriber(),
                                 fallbackLanguages: onDeviceFallbacks)
    }

    /// Resolves the primary language and makes its model ready, reporting the first-run
    /// download in `startDetail`. The secondary language is readied in the background. In the
    /// cloud nothing is downloaded: an on-device model is used only if it's already installed.
    private func readyPrimaryLanguage() async throws -> ResolvedLanguage {
        let tag = await LanguageResolver.primaryTag(settings: settings)
        primaryTag = tag
        let name = DictationLanguage(tag: tag).localizedName
        let primary: ResolvedLanguage
        if TranscriberEngine.current == .stub {
            primary = ResolvedLanguage(tag: tag, locale: Locale(identifier: tag), engine: .speech)
        } else if usesCloud {
            // The installed on-device model (the fallback) is found and prepared once the session
            // is ready, so the trip to the app doesn't wait for it.
            primary = cloudLanguage(tag)
            onDeviceFallbacks = [:]
        } else {
            startDetail = "Preparing \(name) speech recognition… The first time, this downloads the language model."
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

    /// For OpenAI the language is just its tag, plus the dictionary terms as keyword hints, and
    /// under Auto-detect the languages picked in Settings, which the speech is detected among.
    private func cloudLanguage(_ tag: String) -> ResolvedLanguage {
        ResolvedLanguage(tag: tag, locale: Locale(identifier: tag), engine: .speech,
                         contextualStrings: pipeline.contextualStrings(),
                         languageHints: DictationLanguage(tag: tag).isAutomatic ? settings.dictationLanguages : [])
    }

    /// The on-device model for `tag` if it's already downloaded and verified. Never downloads.
    private func installedOnDeviceLanguage(_ tag: String) async -> ResolvedLanguage? {
        guard await assets.status(for: tag).isReady else { return nil }
        return try? await assets.ensureReady(
            tag: tag, contextualStrings: pipeline.contextualStrings(), override: TranscriberEngine.current.kindOverride)
    }

    /// Lets a running cloud session fall back to a language whose model turned up later.
    private func addFallback(_ language: ResolvedLanguage) {
        onDeviceFallbacks[language.tag] = language
        (transcriber as? OpenAITranscriber)?.addFallbackLanguage(language)
        updateAutomaticFallback()
    }

    /// Under Auto-detect only the cloud knows the language, so a failed request is covered by a
    /// guess: the last automatic dictation's language, else the phone's, else the primary, whichever
    /// has an installed model. None installed: no fallback under Auto.
    private func updateAutomaticFallback() {
        guard let cloud = transcriber as? OpenAITranscriber else { return }
        let guesses = [settings.lastDetectedLanguage].compactMap { $0 } + settings.dictationLanguages
            + [Locale.preferredLanguages.first, primaryTag].compactMap { $0 }
        let installed = guesses.lazy.compactMap { tag in
            let code = DictationLanguage(normalizing: tag).languageCode
            return self.onDeviceFallbacks.values.first { $0.language.languageCode == code }
        }.first
        cloud.setAutomaticFallback(installed)
    }

    /// In the cloud, the installed on-device model covers failed requests. Finding and preparing
    /// it takes a while, so it runs after the session is ready (and after a reconnect, when the
    /// mic format may have changed); the first dictation may go without it.
    private func prepareFallbackInBackground() {
        guard usesCloud, let cloud = transcriber as? OpenAITranscriber else { return }
        let previous = fallbackTask
        fallbackTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.transcriber === cloud else { return }
            let tag = primaryTag
            if onDeviceFallbacks[tag] == nil, let onDevice = await installedOnDeviceLanguage(tag) {
                addFallback(onDevice)
            }
            guard !Task.isCancelled, self.transcriber === cloud else { return }
            updateAutomaticFallback()
            await cloud.prepareFallback()
            engineName = cloud.displayName
        }
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
        if usesCloud {
            languages[tag] = cloudLanguage(tag)
            secondaryTask = Task { [weak self] in
                guard let self, let onDevice = await installedOnDeviceLanguage(tag), !Task.isCancelled else { return }
                addFallback(onDevice)
            }
            return
        }
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
            } else if usesCloud {
                languages[tag] = cloudLanguage(tag)
                if let onDevice = await installedOnDeviceLanguage(tag) { addFallback(onDevice) }
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
        prepareFallbackInBackground()
        await assets.reconcileReservations(keep: keep)
    }

    /// Ends the session and releases the microphone.
    func stop() {
        if active != nil { endDictation(commit: true) }
        requestedStart = nil
        autoStarted = nil
        queuedStart = nil
        cancelledRequests = []
        heartbeatTask?.cancel()
        idleTask?.cancel()
        capTask?.cancel()
        tearDownAudio()
        secondaryTask?.cancel()
        fallbackTask?.cancel()
        fallbackTask = nil
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

    /// Called when the app becomes active: no "Turn off after" countdown while it's on screen, and
    /// recover from interruptions that left us stranded.
    func appDidBecomeActive() {
        #if DEBUG
        guard !isPinnedForScreenshots else { return }
        #endif
        backgroundSince = nil
        idleTask?.cancel()
        if phase == .needsReconnect {
            requestReconnect()
        }
    }

    /// The countdown starts (again) when the app leaves the screen.
    func appDidEnterBackground() {
        backgroundSince = Date()
        scheduleIdleStop()
    }

    // MARK: Dictation

    /// In-app dictation (the mic in a note) uses the same pipeline as the keyboard, in the
    /// keyboard's Speak language (Auto-detect until one is picked there). Its result goes to
    /// `inAppResultHandler` instead of the keyboard.
    func beginInAppDictation() -> UUID? {
        let id = UUID()
        let speak = KeyboardLanguageDefaults.source(
            saved: settings.translationSourceLanguage, autoDetectApplied: settings.autoDetectDefaultApplied)
        return beginDictation(requestId: id, documentIdentifier: nil, style: nil, languageOverride: speak.tag,
                              translationTargetLanguage: nil, source: .inApp) ? id : nil
    }

    /// The Action Button, Control Center or a shortcut asked for a dictation while the Murmur
    /// keyboard is on screen: recorded like one the keyboard asks for when it opens the app, with
    /// the keyboard's options, so the keyboard joins it (`attachToPendingStart`) and types it out.
    /// One still being processed is waited for. False without a session to record with.
    func beginDictationForKeyboard() -> Bool {
        guard isLive else { return false }
        let speak = KeyboardLanguageDefaults.source(
            saved: settings.translationSourceLanguage, autoDetectApplied: settings.autoDetectDefaultApplied)
        let target = settings.translationEnabled ? KeyboardLanguageDefaults.target(
            saved: settings.translationTargetLanguage.map(DictationLanguage.init(tag:)), source: speak,
            preferred: Locale.preferredLanguages, available: DictationLanguage.cloudLanguages,
            recent: settings.recentTranslationLanguages.map(DictationLanguage.init(tag:))) : nil
        let request = PendingStart(
            requestId: UUID(), documentIdentifier: nil, createdAt: Date(), autoStart: true,
            styleOverride: settings.defaultStyle, languageOverride: speak.tag, translationTargetLanguage: target?.tag)
        do {
            try transport.payloads.write(pendingStart: request)
        } catch {
            logger.error("Couldn't hand a shortcut's dictation to the keyboard: \(error.localizedDescription, privacy: .public)")
            return false
        }
        requestedStart = request
        beginRequestedStart()
        return true
    }

    /// The Murmur keyboard is on screen in some app (its heartbeat is recent and it hasn't left).
    var keyboardIsOnScreen: Bool {
        transport.payloads.readKeyboardStatus().map { $0.inactiveSince > Date() } ?? false
    }

    @discardableResult
    private func beginDictation(requestId: UUID, documentIdentifier: UUID?, style: StylePreset?,
                                languageOverride: String?, translationTargetLanguage: String?,
                                source: ActiveDictation.Source) -> Bool {
        guard phase == .ready, let transcriber else {
            logger.notice("Start ignored in phase \(String(describing: self.phase), privacy: .public)")
            return false
        }
        let language: ResolvedLanguage
        // The keyboard asks for Auto-detect by default; on-device recognition needs a language,
        // so it listens in the primary one.
        let languageOverride = languageOverride.flatMap { tag in
            !usesCloud && DictationLanguage(tag: tag).isAutomatic ? nil : tag
        }
        if let languageOverride, languageOverride != primaryTag {
            if usesCloud, DictationLanguage(tag: languageOverride).isAutomatic {
                // Fresh each time: the languages picked in Settings may have changed since.
                language = cloudLanguage(languageOverride)
            } else if let ready = languages[languageOverride] {
                language = ready
            } else if usesCloud {
                let cloud = cloudLanguage(languageOverride)
                languages[languageOverride] = cloud
                language = cloud
            } else {
                let requested = DictationLanguage(tag: languageOverride)
                let name = requested.localizedName
                logger.notice("Dictation in \(languageOverride, privacy: .public) requested before its model is ready")
                rejectDictation(requestId: requestId, documentIdentifier: documentIdentifier, language: languageOverride,
                                message: "\(name) is still being set up in Murmur. Try again in a moment.")
                prepareSecondaryLanguage()
                return false
            }
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
        // The last Auto-detect dictation may have been in another language.
        if language.language.isAutomatic { updateAutomaticFallback() }
        idleTask?.cancel()
        transcriber.beginUtterance()
        audio.openGate()
        active = ActiveDictation(requestId: requestId, documentIdentifier: documentIdentifier,
                                 style: style, language: language.tag,
                                 translationTargetLanguage: translationTargetLanguage,
                                 source: source, startedAt: Date())
        phase = .recording(requestId)
        publisher.set(.recording, requestTag: requestId.tag16)
        transport.post(.stateChanged)
        playSound(.start)
        // After the acknowledgement: nothing here may delay it.
        let usesDictate = translationTargetLanguage != nil || (style ?? settings.defaultStyle) == .grammar
        // Low data mode sends nothing ahead of the dictation.
        if !NetworkConditions.shared.savesData(settings: settings) {
            warmup?.dictationDidStart(requestId, usesDictate: usesDictate && usesCloud)
        }
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

    /// Ends the current dictation; `commit: false` discards it. `requestedAt`: the keyboard's stop
    /// command, for the timings.
    func endDictation(commit: Bool, requestedAt: Date? = nil) {
        if let requestedAt {
            active?.stopRequestedAt = requestedAt
            active?.tapToStopMs = Date().milliseconds(since: requestedAt)
        }
        guard let dictation = active, let transcriber else { return }
        active = nil
        capTask?.cancel()
        let frames = audio.closeGate()
        let audioSeconds = Double(frames) / (audio.inputFormat?.sampleRate ?? 48_000)
        playSound(.stop)

        guard commit else {
            // At once, not in a task: the next dictation can begin before a task would run
            // (`becomeReady` starts a queued one, `handleStart` a replacement).
            transcriber.abandonUtterance()
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
            // The keyboard (or the note) first, then history and the timings, so saving never
            // delays the insertion.
            if dictation.source == .inApp {
                inAppResultHandler?(outcome.result)
            } else {
                deliver(outcome.result)
            }
            history.record(outcome.transcript)
            if let recording = outcome.recording, settings.keepRecordings {
                recordings?.save(recording, for: outcome.transcript.id)
            }
            if var timings = outcome.timings {
                timings.warmup = warmup?.takeTiming(for: dictation.requestId)
                timingsLog?.append(timings)
            }
            becomeReady()
            // Not while a dictation the keyboard asked for in the meantime has just begun.
            if settings.disableAfter == .immediately, active == nil {
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
        idleSince = Date()
        publisher.set(.ready)
        transport.post(.stateChanged)
        liveActivity.update(.ready, since: nil)
        scheduleIdleStop()
        if pendingLanguageReload {
            Task { await reloadLanguages() }
        }
        beginQueuedStart()
        beginRequestedStart()
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
            handleStart(command)
        case .stop:
            if active?.requestId == command.requestId { endDictation(commit: true, requestedAt: command.createdAt) }
        case .cancel:
            cancelledRequests.insert(command.requestId)
            if queuedStart?.requestId == command.requestId {
                queuedStart = nil
                republishPhase()
            }
            if active?.requestId == command.requestId { endDictation(commit: false) }
        }
    }

    private func handleStart(_ command: KeyboardCommand) {
        if let active, active.requestId == command.requestId {
            // The app started it when the keyboard opened it; the keyboard wants its ack.
            publisher.set(.recording, requestTag: command.requestId.tag16)
            transport.post(.stateChanged)
            return
        }
        if requestedStart?.requestId == command.requestId { requestedStart = nil }
        switch phase {
        case .ready:
            beginDictation(from: command)
        case .recording:
            // From a keyboard that doesn't know about the current dictation: the one that did is
            // gone. Drop it if nobody ever attached to it, otherwise save it, then start this one.
            guard let active, active.source == .keyboard else { break }
            if active.keyboardAttachedAt == nil {
                expireUnattachedDictation()
                beginDictation(from: command)
            } else {
                endDictation(commit: true)
                queue(command)
            }
        case .processing, .starting:
            queue(command)
        default:
            logger.notice("Start ignored in phase \(String(describing: self.phase), privacy: .public)")
        }
    }

    /// Begins `command` once the previous dictation is done. Publishing `starting` with its tag
    /// tells the keyboard it was accepted, so it waits instead of opening the app.
    private func queue(_ command: KeyboardCommand) {
        queuedStart = command
        publisher.set(.starting, requestTag: command.requestId.tag16)
        transport.post(.stateChanged)
    }

    private func beginQueuedStart() {
        guard phase == .ready, let command = queuedStart else { return }
        queuedStart = nil
        guard !cancelledRequests.contains(command.requestId),
              Date().timeIntervalSince(command.createdAt) < Self.queuedStartLifetime else { return }
        beginDictation(from: command)
    }

    /// After a queued start was cancelled, the published state is the session's own again.
    private func republishPhase() {
        switch phase {
        case .processing(let id): publisher.set(.processing, requestTag: id.tag16)
        case .starting: publisher.set(.starting)
        case .ready: publisher.set(.ready)
        default: return
        }
        transport.post(.stateChanged)
    }

    @discardableResult
    private func beginDictation(from command: KeyboardCommand) -> Bool {
        beginDictation(requestId: command.requestId, documentIdentifier: command.documentIdentifier,
                       style: command.styleOverride, languageOverride: command.languageOverride,
                       translationTargetLanguage: command.translationTargetLanguage, source: .keyboard)
    }

    /// The app started this dictation for the keyboard, which never came back for it. It's
    /// dropped, not saved, since nobody confirmed it. A keyboard
    /// attaching at this very moment finds a `cancelled` result instead of waiting for one.
    private func expireUnattachedDictation() {
        guard let dictation = active, dictation.keyboardAttachedAt == nil else { return }
        transport.payloads.clearPendingStart(dictation.requestId)
        try? transport.payloads.write(result: DictationResult(
            requestId: dictation.requestId, documentIdentifier: dictation.documentIdentifier, text: "",
            status: .cancelled, createdAt: Date(), language: dictation.language), updatesLatest: false)
        autoStarted = nil
        endDictation(commit: false)
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
            guard let dictation = active, dictation.source == .keyboard else { return }
            let status = transport.payloads.readKeyboardStatus()
            // The keyboard left it running (the screen locked, another app): it records on until
            // the keyboard is back, the cap, or the Lock Screen's Stop.
            if status?.awayRequestId == requestId {
                if active?.keyboardAttachedAt == nil { active?.keyboardAttachedAt = status?.lastSeenAt }
                return
            }
            let heartbeat = status?.listeningRequestId == requestId ? status?.listeningHeartbeatAt : nil
            guard let attachedAt = dictation.keyboardAttachedAt else {
                // Started before the keyboard was back (after it opened the app), or just now.
                if let heartbeat {
                    active?.keyboardAttachedAt = heartbeat
                } else if Date().timeIntervalSince(dictation.startedAt) > Self.keyboardReturnWindow {
                    logger.notice("The keyboard didn't come back for the dictation; dropping it")
                    expireUnattachedDictation()
                }
                return
            }
            // If the keyboard was killed mid-dictation, finish it so it lands in history.
            if Date().timeIntervalSince(heartbeat ?? attachedAt) > 4 {
                logger.notice("Keyboard heartbeat lost; finishing dictation")
                endDictation(commit: true)
            }
        case .ready, .processing:
            publisher.tick()
        default:
            break
        }
    }

    /// "Turn off after" counts only while the app is in the background and the keyboard is off
    /// screen (`IdleStop`), so typing on the keyboard keeps the session on.
    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard let deadline = idleStopDate() else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            // The keyboard may have been on screen meanwhile, which moves the deadline.
            guard let deadline = idleStopDate(), deadline <= Date() else { return scheduleIdleStop() }
            logger.info("Idle timeout reached")
            stop()
        }
    }

    private func idleStopDate() -> Date? {
        guard phase == .ready || phase == .needsReconnect, let timeout = settings.disableAfter.idleTimeout else {
            return nil
        }
        // "Immediately" stops right after a delivered result; a session that is never used, or
        // whose dictation was cancelled, still gets a short grace period instead of staying on.
        return IdleStop.date(timeout: timeout > 0 ? timeout : Self.immediateIdleGrace, idleSince: idleSince,
                             backgroundSince: backgroundSince, keyboard: transport.payloads.readKeyboardStatus())
    }

    /// The keyboard appeared or went away: the countdown restarts from there.
    private func keyboardStatusChanged() {
        if phase == .ready || phase == .needsReconnect { scheduleIdleStop() }
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
            interruptedAt = Date()
            // Nothing waiting may start on a microphone that's gone.
            requestedStart = nil
            queuedStart = nil
            if let active {
                if active.source == .keyboard, active.keyboardAttachedAt == nil {
                    expireUnattachedDictation()
                } else {
                    endDictation(commit: true)
                }
            }
            phase = .needsReconnect
            idleSince = Date()
            publisher.set(.needsReconnect)
            transport.post(.stateChanged)
            scheduleIdleStop()
        case .ended:
            // Resume after a call or Siri unless it outlasted "Turn off after", whatever
            // `shouldResume` says. If it can't, the keyboard offers Reconnect.
            let lasted = interruptedAt.map { Date().timeIntervalSince($0) } ?? 0
            interruptedAt = nil
            logger.notice("Interruption ended after \(Int(lasted)) s (shouldResume: \(options.contains(.shouldResume)))")
            if settings.disableAfter.resumesAfterInterruption(lasting: lasted) {
                requestReconnect()
            } else {
                stop()
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
        if let active {
            // Recorded on its own, before the keyboard is back: start it again once the audio
            // works rather than end it a moment after it began (and deliver nothing).
            let restart = active.keyboardAttachedAt == nil && autoStarted?.requestId == active.requestId
                ? autoStarted : nil
            endDictation(commit: restart == nil)
            requestedStart = restart
        }
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
        for delay in Self.reconnectDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }
            // Stopped meanwhile: by the user, the idle timer or a media services reset.
            guard self.transcriber === transcriber else { return }
            do {
                // In the background there's no foreground to wait for; trying at once keeps the
                // app from being suspended with its audio stopped.
                try await activateAudioSession(waitForForeground: UIApplication.shared.applicationState == .inactive)
                try audio.restartEngine()
                if let format = audio.inputFormat,
                   let language = transcriber.currentLanguage ?? languages[primaryTag] {
                    try await transcriber.prepare(micFormat: format, language: language)
                }
                becomeReady(afterReconnect: true)
                prepareFallbackInBackground()
                logger.info("Audio reconnected")
                return
            } catch {
                // Typically '!int' when reactivating from the background right after a call.
                logger.error("Reconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        phase = .needsReconnect
        publisher.set(.needsReconnect)
        transport.post(.stateChanged)
    }

    // MARK: Helpers

    /// Recording can only begin while the app is active. Right after the microphone permission
    /// alert, or while the app is still opening from the keyboard's link, it is briefly
    /// inactive and activation fails ("Session activation failed"), so wait, then retry once.
    private func activateAudioSession(waitForForeground: Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while waitForForeground, UIApplication.shared.applicationState != .active, clock.now < deadline {
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
        /// The user answered "Not now" to sending recordings to the AI services (`AIConsent`).
        case aiNotAllowed

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Murmur needs microphone access. Turn it on in Settings › Murmur."
            // Shown on Home over "Try again", and on the keyboard, whose mic opens Murmur again.
            case .aiNotAllowed: "Murmur needs your OK to use its AI services. Try again to allow it."
            }
        }
    }
}

#if DEBUG
extension SessionController.Phase {
    /// The names `-session-fixture` takes.
    init?(fixture: String) {
        switch fixture {
        case "off": self = .off
        case "starting": self = .starting
        case "on": self = .ready
        case "listening": self = .recording(UUID())
        case "writing": self = .processing(UUID())
        case "failed": self = .failed(SessionController.SessionError.microphoneDenied.localizedDescription)
        case "reconnect": self = .needsReconnect
        default: return nil
        }
    }
}
#endif
