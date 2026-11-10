import Foundation

/// What the keyboard extension provides to `KeyboardSessionClient`.
@MainActor
public protocol KeyboardSessionHost: AnyObject {
    var hasFullAccess: Bool { get }
    /// `textDocumentProxy.documentIdentifier` of the focused field.
    var currentDocumentIdentifier: UUID? { get }
    func openContainingApp(_ url: URL)
    /// Insert a finished dictation into the focused field.
    func insertDictation(_ result: DictationResult)
    /// A dictation the keyboard was waiting on came back (or is running late), so the user can be
    /// told without watching the screen.
    func dictationDidFinish(_ outcome: DictationOutcome)
    func sessionClientDidChange(_ client: KeyboardSessionClient)
}

/// How a dictation the keyboard was waiting on ended.
public enum DictationOutcome: Equatable, Sendable {
    /// The text went into the field, or is held for "Insert last dictation".
    case ready
    /// Nothing usable came back, or the result is running late.
    case problem
}

/// Keyboard-side dictation state machine. Lives in MurmurCore so it can be unit-tested against
/// `InMemoryIPCTransport`.
///
/// Flow: mic tap → write `start` command → wait ≤500 ms for the app to report `recording` with
/// our request tag → otherwise open the app (one-time token). The app starts recording that
/// dictation as soon as it has the microphone and, like Wispr Flow, sends the user back; the
/// keyboard attaches to the recording when it reappears.
@MainActor
public final class KeyboardSessionClient {
    /// How often the keyboard tells the app it's still on screen, which keeps the session from
    /// timing out while it's in use (see `IdleStop`).
    public static let visibilityInterval: Duration = .seconds(5)
    /// How long a dictation that ended while the keyboard was away (the cap, the Lock Screen's
    /// Stop) is offered as "Insert last dictation", instead of `Transcript.insertWindow`.
    public static let awayInsertWindow: TimeInterval = 600

    public enum Phase: Equatable, Sendable {
        case idle
        case needsFullAccess
        case starting(UUID)
        case openingApp(UUID)
        case listening(UUID, since: Date)
        case processing(UUID)
        case needsReconnect
        /// A transient message, e.g. "We didn't catch anything".
        case notice(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var sessionStatus: SessionStatus = .off
    /// Mic level 0...1 while listening.
    public private(set) var level: Double = 0
    /// A finished dictation that couldn't be inserted automatically (other field, or late).
    public private(set) var pendingResult: DictationResult?
    /// The style in the keyboard's style pill, sent with each dictation; nil leaves it to the app's
    /// Default style.
    public var styleOverride: StylePreset?
    /// BCP-47 tag chosen in the keyboard's language pill; nil means the primary language.
    public var languageOverride: String?
    /// Nil for normal dictation; otherwise the model translates into this BCP-47 language.
    public var translationTargetLanguage: String?

    public weak var host: KeyboardSessionHost?

    private let transport: IPCTransport
    private let clock: () -> Date
    private let ackTimeout: Duration
    /// How long a start the app queued (it was finishing the previous dictation) may wait.
    private let busyTimeout: Duration
    private let resultTimeout: Duration
    private let staleAfter: TimeInterval
    private var observations: [IPCObservation] = []
    private var ackTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var activeDocumentIdentifier: UUID?
    private var lastSequence: UInt32 = 0
    private var lastSequenceChange = Date.distantPast
    /// The session failure already shown as a notice, so dismissing it doesn't bring it back.
    private var shownFailureAt: Date?
    /// The dictation left running when the keyboard went off screen, and when it began.
    private var away: (requestId: UUID, since: Date)?
    /// A dictation followed again after the keyboard came back: its text goes into whichever field
    /// is focused now, since that is where the user is looking.
    private var resumedRequestId: UUID?

    public init(
        transport: IPCTransport,
        clock: @escaping () -> Date = Date.init,
        ackTimeout: Duration = .milliseconds(500),
        busyTimeout: Duration = .seconds(15),
        resultTimeout: Duration = .seconds(20),
        staleAfter: TimeInterval = 2.5
    ) {
        self.transport = transport
        self.clock = clock
        self.ackTimeout = ackTimeout
        self.busyTimeout = busyTimeout
        self.resultTimeout = resultTimeout
        self.staleAfter = staleAfter
    }

    // MARK: Lifecycle

    /// Call from `viewWillAppear`. Darwin notifications can be missed while the extension is
    /// suspended, so this re-reads everything.
    public func activate() {
        if observations.isEmpty {
            observations = [
                transport.observe(.stateChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.refresh() }
                },
                transport.observe(.resultReady) { [weak self] in
                    MainActor.assumeIsolated { self?.checkForResult() }
                },
            ]
        }
        resumeAwayDictation()
        writeKeyboardStatus()
        transport.post(.keyboardStatus)
        startVisibilityHeartbeat()
        refresh()
        checkForResult()
    }

    /// Call from `viewWillDisappear`. A dictation in progress keeps recording, so a screen lock or
    /// a trip to another app doesn't cut a long one: the app finishes it on ✓ once the keyboard is
    /// back (`activate`), at the 5-minute cap, or from the Lock Screen's Stop. While opening the
    /// app nothing is cancelled: the bounce is why the keyboard disappeared.
    public func deactivate() {
        switch phase {
        case .listening(let id, let since):
            away = (id, since)
        case .starting(let id):
            // Gone before the app answered (or while it was busy): don't record for a field
            // nobody is looking at, and don't come back stuck waiting.
            send(.cancel, requestId: id)
            phase = .idle
        default:
            break
        }
        observations.forEach { $0.cancel() }
        observations = []
        ackTask?.cancel()
        listenTask?.cancel()
        resultTask?.cancel()
        visibilityTask?.cancel()
        writeKeyboardStatus(hidden: true)
        transport.post(.keyboardStatus)
    }

    // MARK: User actions

    /// The mic button: starts a dictation, or stops the one in progress.
    public func micTapped() {
        switch phase {
        case .listening(let id, _):
            stop(id)
            return
        case .starting, .openingApp, .processing:
            return
        case .idle, .needsFullAccess, .needsReconnect, .notice:
            break
        }
        guard let host, host.hasFullAccess else {
            setPhase(.needsFullAccess)
            return
        }
        resumedRequestId = nil
        let requestId = UUID()
        activeDocumentIdentifier = host.currentDocumentIdentifier
        pendingResult = nil
        if transport.currentState().status.isLive {
            sendStart(requestId)
        } else {
            openApp(for: requestId)
        }
    }

    /// ✓ — stop and insert.
    public func stopTapped() {
        if case .listening(let id, _) = phase { stop(id) }
    }

    /// X — discard the dictation.
    public func cancelTapped() {
        switch phase {
        case .listening(let id, _), .starting(let id), .processing(let id):
            send(.cancel, requestId: id)
            transport.payloads.claim(id)
            cancelTasks()
            setPhase(.idle)
        case .openingApp(let id):
            // The app may already be recording it: it starts as soon as it has the microphone.
            send(.cancel, requestId: id)
            transport.payloads.claim(id)
            transport.payloads.clearPendingStart()
            setPhase(.idle)
        default:
            break
        }
    }

    /// The "Insert last dictation" chip.
    public func insertPendingResult() {
        guard let result = pendingResult else { return }
        pendingResult = nil
        if transport.payloads.claim(result.requestId) {
            host?.insertDictation(result)
        }
        notifyHost()
    }

    public func dismissPendingResult() {
        if let result = pendingResult { transport.payloads.claim(result.requestId) }
        pendingResult = nil
        notifyHost()
    }

    /// The system refused to open the app (e.g. Full Access is off).
    public func containingAppOpenFailed() {
        guard case .openingApp = phase else { return }
        transport.payloads.clearPendingStart()
        setPhase(.notice("Open Murmur to turn on dictation."))
    }

    public func dismissNotice() {
        switch phase {
        case .notice, .needsFullAccess: setPhase(.idle)
        default: break
        }
    }

    // MARK: Start handshake

    private func sendStart(_ requestId: UUID) {
        guard send(.start, requestId: requestId) else {
            setPhase(.needsFullAccess)
            return
        }
        setPhase(.starting(requestId))
        ackTask?.cancel()
        let timeout = ackTimeout
        let busyTimeout = busyTimeout
        ackTask = Task { [weak self] in
            let clock = ContinuousClock()
            let sentAt = clock.now
            var deadline = sentAt.advanced(by: timeout)
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled else { return }
                if self.checkAck(requestId) { return }
                // Accepted, but the app is finishing the previous dictation first. It's running,
                // so opening it wouldn't help.
                if self.isQueued(requestId) { deadline = sentAt.advanced(by: busyTimeout) }
            }
            guard let self, !Task.isCancelled, case .starting(requestId) = self.phase else { return }
            if self.isQueued(requestId) {
                self.send(.cancel, requestId: requestId)
                self.setPhase(.notice("Murmur is still finishing your last dictation. Try again in a moment."))
            } else {
                self.openApp(for: requestId)
            }
        }
    }

    /// The app published `starting` with our tag: it took the start and begins it when it's free.
    private func isQueued(_ requestId: UUID) -> Bool {
        let state = transport.currentState()
        return state.status == .starting && state.requestTag == requestId.tag16
    }

    @discardableResult
    private func checkAck(_ requestId: UUID) -> Bool {
        guard case .starting(requestId) = phase else { return false }
        let state = transport.currentState()
        if state.status == .recording, state.requestTag == requestId.tag16 {
            ackTask?.cancel()
            setPhase(.listening(requestId, since: clock()))
            startListeningLoop(requestId)
            return true
        }
        return false
    }

    private func openApp(for requestId: UUID) {
        let now = clock()
        let token = LaunchToken(requestId: requestId, createdAt: now)
        do {
            try transport.payloads.write(launchToken: token)
            try transport.payloads.write(pendingStart: PendingStart(
                requestId: requestId, documentIdentifier: activeDocumentIdentifier, createdAt: now, autoStart: true,
                styleOverride: styleOverride, languageOverride: languageOverride,
                translationTargetLanguage: translationTargetLanguage))
        } catch {
            // Writing to the App Group fails without Full Access.
            setPhase(.needsFullAccess)
            return
        }
        setPhase(.openingApp(requestId))
        host?.openContainingApp(Brand.sessionStartURL(token: token.token))
    }

    /// After the bounce. The app records the dictation as soon as it has the microphone, so join
    /// that recording; an app that hasn't started it (an older build, or one that's still busy)
    /// gets the start command once it's ready. The request is read from disk, so this also works
    /// for a keyboard that was relaunched while the user was away.
    private func attachToPendingStart() {
        guard let pending = transport.payloads.readPendingStart() else {
            // The app dropped it: the keyboard took too long to come back.
            if case .openingApp = phase { setPhase(.idle) }
            return
        }
        let age = clock().timeIntervalSince(pending.createdAt)
        guard age < 90 else {
            transport.payloads.clearPendingStart()
            if case .openingApp = phase { setPhase(.idle) }
            return
        }
        let state = transport.currentState()
        let ours = state.requestTag == pending.requestId.tag16
        switch state.status {
        case .ready: break
        case .recording where ours, .processing where ours: break
        default: return // still starting: wait for the next state change
        }
        transport.payloads.clearPendingStart()
        if case .listening = phase { return }
        // The field can't be recognized by its documentIdentifier: iOS gives it a new one after the
        // trip to the app (seen on the iPhone, iOS 26.6). As in Wispr Flow, the dictation goes into
        // the field the user came back to, and its result follows the request.
        activeDocumentIdentifier = host?.currentDocumentIdentifier ?? pending.documentIdentifier
        resumedRequestId = pending.requestId
        switch state.status {
        case .recording:
            setPhase(.listening(pending.requestId, since: clock()))
            startListeningLoop(pending.requestId)
        case .processing:
            setPhase(.processing(pending.requestId))
            waitForResult(pending.requestId)
            checkForResult()
        default:
            sendStart(pending.requestId)
        }
    }

    /// Back on screen after leaving a dictation running: follow it again (the timer keeps its
    /// start), or, when the app ended it meanwhile, wait for its result. A keyboard that iOS
    /// relaunched while away finds the dictation in the status it left.
    private func resumeAwayDictation() {
        let left = away ?? transport.payloads.readKeyboardStatus().flatMap { status in
            status.awayRequestId.map { (requestId: $0, since: status.awayListeningSince ?? clock()) }
        }
        away = nil
        guard let left else { return }
        resumedRequestId = left.requestId
        let state = transport.currentState()
        if state.status == .recording, state.requestTag == left.requestId.tag16 {
            activeDocumentIdentifier = host?.currentDocumentIdentifier
            setPhase(.listening(left.requestId, since: left.since))
            startListeningLoop(left.requestId)
        } else if case .listening(left.requestId, _) = phase {
            setPhase(.processing(left.requestId))
            waitForResult(left.requestId)
        }
        // Relaunched after the app ended it: `checkForResult` offers its text.
    }

    // MARK: Listening

    private func startListeningLoop(_ requestId: UUID) {
        listenTask?.cancel()
        lastSequence = transport.currentState().sequence
        lastSequenceChange = clock()
        // Right away: it tells the app the keyboard is following this dictation, which matters
        // when the app started it on its own and is waiting for the keyboard to come back.
        writeKeyboardStatus()
        listenTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                guard case .listening(requestId, _) = self.phase else { return }
                self.pollListening(requestId)
                tick += 1
                if tick % 20 == 0 { self.writeKeyboardStatus() }
            }
        }
    }

    private func pollListening(_ requestId: UUID) {
        let state = transport.currentState()
        trackSequence(state)
        if state.status == .recording, state.requestTag == requestId.tag16 {
            level = Double(state.level) / 255
            if clock().timeIntervalSince(lastSequenceChange) > staleAfter {
                // The app stopped publishing: it was killed or suspended.
                cancelTasks()
                sessionStatus = .off
                setPhase(.notice("Murmur stopped listening. Tap the mic to start again."))
            } else {
                notifyHost()
            }
        } else {
            refresh()
        }
    }

    private func stop(_ requestId: UUID) {
        listenTask?.cancel()
        send(.stop, requestId: requestId)
        setPhase(.processing(requestId))
        waitForResult(requestId)
    }

    private func waitForResult(_ requestId: UUID) {
        resultTask?.cancel()
        let timeout = resultTimeout
        resultTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                guard case .processing(requestId) = self.phase else { return }
                self.checkForResult()
            }
            guard let self, !Task.isCancelled, case .processing(requestId) = self.phase else { return }
            self.setPhase(.notice("This is taking longer than usual. Your dictation will be saved in Murmur."))
            self.host?.dictationDidFinish(.problem)
        }
    }

    // MARK: State sync

    private func refresh() {
        let state = transport.currentState()
        trackSequence(state)
        sessionStatus = state.status
        if state.status == .error, showSessionFailure() {
            notifyHost()
            return
        }
        switch phase {
        case .starting(let id):
            if !checkAck(id), state.status == .needsReconnect { openApp(for: id) }
        case .listening(let id, _):
            if state.requestTag == id.tag16, state.status == .recording {
                level = Double(state.level) / 255
            } else if state.status == .needsReconnect {
                cancelTasks()
                setPhase(.needsReconnect)
            } else {
                // The app ended the dictation (5-minute cap, interruption): wait for its result.
                listenTask?.cancel()
                setPhase(.processing(id))
                waitForResult(id)
                checkForResult()
            }
        case .processing:
            checkForResult()
        case .openingApp, .idle:
            if state.status == .needsReconnect, case .idle = phase {
                setPhase(.needsReconnect)
            } else {
                attachToPendingStart()
            }
        case .needsReconnect:
            if state.status == .ready { setPhase(.idle) }
        case .needsFullAccess, .notice:
            break
        }
        notifyHost()
    }

    /// The app's session failed to start (for example, the language model isn't downloaded).
    /// Shows the app's reason once; tapping the mic opens the app again. Returns true when the
    /// phase changed.
    private func showSessionFailure() -> Bool {
        let failure = transport.payloads.readSessionFailure()
        let freshFailure = failure.flatMap { clock().timeIntervalSince($0.createdAt) < 60 ? $0 : nil }
        switch phase {
        case .starting, .openingApp:
            break
        case .idle, .needsReconnect:
            guard let freshFailure, freshFailure.createdAt != shownFailureAt else { return false }
        case .listening, .processing, .needsFullAccess, .notice:
            return false
        }
        cancelTasks()
        transport.payloads.clearPendingStart()
        shownFailureAt = freshFailure?.createdAt
        setPhase(.notice(freshFailure?.message ?? "Murmur couldn't start. Open the app to see why."))
        return true
    }

    private func checkForResult() {
        switch phase {
        case .processing(let id), .listening(let id, _):
            if let result = transport.payloads.readResult(id) {
                deliver(result)
                return
            }
            // The app also saves every completed dictation as the latest result. If the
            // request-specific file is briefly unavailable (for example after the extension was
            // suspended), recover the matching saved result immediately instead of making the
            // user wait or tap "Insert last dictation". The ID check prevents an older dictation
            // from being inserted for the current recording.
            if let latest = transport.payloads.latestResult(), latest.requestId == id {
                deliver(latest)
                return
            }
        default:
            break
        }
        let window = transport.payloads.latestResult()?.requestId == resumedRequestId
            ? Self.awayInsertWindow : Transcript.insertWindow
        if pendingResult == nil, let latest = transport.payloads.latestResult(), latest.isInsertable,
           clock().timeIntervalSince(latest.createdAt) < window,
           !transport.payloads.isClaimed(latest.requestId) {
            pendingResult = latest
            notifyHost()
        }
    }

    private func deliver(_ result: DictationResult) {
        cancelTasks()
        guard result.isInsertable else {
            transport.payloads.claim(result.requestId)
            if let message = result.message, result.status != .cancelled {
                setPhase(.notice(message))
            } else {
                setPhase(.idle)
            }
            if result.status != .cancelled { host?.dictationDidFinish(.problem) }
            return
        }
        setPhase(.idle)
        let sameField = result.requestId == resumedRequestId || result.documentIdentifier == nil
            || result.documentIdentifier == host?.currentDocumentIdentifier
        let fresh = clock().timeIntervalSince(result.createdAt) < 60
        if sameField, fresh, transport.payloads.claim(result.requestId) {
            host?.insertDictation(result)
            host?.dictationDidFinish(.ready)
            if let message = result.message { setPhase(.notice(message)) }
        } else if !transport.payloads.isClaimed(result.requestId) {
            pendingResult = result
            host?.dictationDidFinish(.ready)
        }
        notifyHost()
    }

    // MARK: Helpers

    @discardableResult
    private func send(_ kind: CommandKind, requestId: UUID) -> Bool {
        let command = KeyboardCommand(
            requestId: requestId, kind: kind, createdAt: clock(),
            documentIdentifier: activeDocumentIdentifier, styleOverride: styleOverride,
            languageOverride: languageOverride, translationTargetLanguage: translationTargetLanguage)
        do {
            try transport.payloads.write(command: command)
        } catch {
            return false
        }
        transport.post(.command)
        return true
    }

    private func trackSequence(_ state: HotState) {
        if state.sequence != lastSequence {
            lastSequence = state.sequence
            lastSequenceChange = clock()
        }
    }

    /// The listening fields come from the phase, so the visibility heartbeat never clears them
    /// (the app would end the dictation, thinking the keyboard was gone). Off screen, a dictation
    /// still listening is reported as away instead.
    private func writeKeyboardStatus(hidden: Bool = false) {
        guard let host else { return }
        let now = clock()
        let listening: UUID? = if case .listening(let id, _) = phase, !hidden { id } else { nil }
        let left = hidden ? away : nil
        let status = KeyboardStatus(
            fullAccessAt: host.hasFullAccess ? now : nil, lastSeenAt: now, hiddenAt: hidden ? now : nil,
            listeningRequestId: listening, listeningHeartbeatAt: listening == nil ? nil : now,
            awayRequestId: left?.requestId, awayListeningSince: left?.since)
        // Fails silently without Full Access, which is expected.
        try? transport.payloads.write(keyboardStatus: status)
    }

    /// While the keyboard is on screen the app keeps the session on, however long the user types.
    private func startVisibilityHeartbeat() {
        visibilityTask?.cancel()
        let interval = Self.visibilityInterval
        visibilityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.writeKeyboardStatus()
            }
        }
    }

    private func cancelTasks() {
        ackTask?.cancel()
        listenTask?.cancel()
        resultTask?.cancel()
        level = 0
    }

    private func setPhase(_ newPhase: Phase) {
        guard phase != newPhase else { return }
        phase = newPhase
        if case .listening = newPhase {} else { level = 0 }
        notifyHost()
    }

    private func notifyHost() {
        host?.sessionClientDidChange(self)
    }
}
