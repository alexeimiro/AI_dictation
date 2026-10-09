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
    func sessionClientDidChange(_ client: KeyboardSessionClient)
}

/// Keyboard-side dictation state machine. Lives in MurmurCore so it can be unit-tested against
/// `InMemoryIPCTransport`.
///
/// Flow: mic tap → write `start` command → wait ≤500 ms for the app to report `recording` with
/// our request tag → otherwise open the app (one-time token) and auto-start when we reappear.
@MainActor
public final class KeyboardSessionClient {
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
    /// Style override chosen in the keyboard's style pill, sent with the next dictation.
    public var styleOverride: StylePreset?

    public weak var host: KeyboardSessionHost?

    private let transport: IPCTransport
    private let clock: () -> Date
    private let ackTimeout: Duration
    private let resultTimeout: Duration
    private let staleAfter: TimeInterval
    private var observations: [IPCObservation] = []
    private var ackTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var activeDocumentIdentifier: UUID?
    private var lastSequence: UInt32 = 0
    private var lastSequenceChange = Date.distantPast

    public init(
        transport: IPCTransport,
        clock: @escaping () -> Date = Date.init,
        ackTimeout: Duration = .milliseconds(500),
        resultTimeout: Duration = .seconds(20),
        staleAfter: TimeInterval = 2.5
    ) {
        self.transport = transport
        self.clock = clock
        self.ackTimeout = ackTimeout
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
        writeKeyboardStatus()
        refresh()
        checkForResult()
    }

    /// Call from `viewWillDisappear`. A dictation in progress is stopped so it lands in history.
    public func deactivate() {
        if case .listening(let id, _) = phase {
            send(.stop, requestId: id)
            phase = .processing(id)
        }
        observations.forEach { $0.cancel() }
        observations = []
        ackTask?.cancel()
        listenTask?.cancel()
        resultTask?.cancel()
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
        case .openingApp:
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
        ackTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, !Task.isCancelled else { return }
                if self.checkAck(requestId) { return }
            }
            guard let self, !Task.isCancelled else { return }
            if case .starting(requestId) = self.phase {
                self.openApp(for: requestId)
            }
        }
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
                requestId: requestId, documentIdentifier: activeDocumentIdentifier, createdAt: now))
        } catch {
            // Writing to the App Group fails without Full Access.
            setPhase(.needsFullAccess)
            return
        }
        setPhase(.openingApp(requestId))
        host?.openContainingApp(Brand.sessionStartURL(token: token.token))
    }

    /// After the bounce: once the app reports `ready`, start the dictation the user asked for.
    private func resumePendingStartIfNeeded() {
        guard let pending = transport.payloads.readPendingStart() else { return }
        let age = clock().timeIntervalSince(pending.createdAt)
        guard age < 90 else {
            transport.payloads.clearPendingStart()
            if case .openingApp = phase { setPhase(.idle) }
            return
        }
        guard transport.currentState().status == .ready else { return }
        transport.payloads.clearPendingStart()
        if case .listening = phase { return }
        if let expected = pending.documentIdentifier, let current = host?.currentDocumentIdentifier,
           expected != current {
            setPhase(.idle)
            return
        }
        activeDocumentIdentifier = pending.documentIdentifier ?? host?.currentDocumentIdentifier
        sendStart(pending.requestId)
    }

    // MARK: Listening

    private func startListeningLoop(_ requestId: UUID) {
        listenTask?.cancel()
        lastSequence = transport.currentState().sequence
        lastSequenceChange = clock()
        listenTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                guard case .listening(requestId, _) = self.phase else { return }
                self.pollListening(requestId)
                tick += 1
                if tick % 20 == 0 { self.writeKeyboardStatus(listening: requestId) }
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
        }
    }

    // MARK: State sync

    private func refresh() {
        let state = transport.currentState()
        trackSequence(state)
        sessionStatus = state.status
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
                resumePendingStartIfNeeded()
            }
        case .needsReconnect:
            if state.status == .ready { setPhase(.idle) }
        case .needsFullAccess, .notice:
            break
        }
        notifyHost()
    }

    private func checkForResult() {
        switch phase {
        case .processing(let id), .listening(let id, _):
            if let result = transport.payloads.readResult(id) {
                deliver(result)
                return
            }
        default:
            break
        }
        if pendingResult == nil, let latest = transport.payloads.latestResult(), latest.isInsertable,
           clock().timeIntervalSince(latest.createdAt) < 120,
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
            return
        }
        setPhase(.idle)
        let sameField = result.documentIdentifier == nil
            || result.documentIdentifier == host?.currentDocumentIdentifier
        let fresh = clock().timeIntervalSince(result.createdAt) < 60
        if sameField, fresh, transport.payloads.claim(result.requestId) {
            host?.insertDictation(result)
        } else if !transport.payloads.isClaimed(result.requestId) {
            pendingResult = result
        }
        notifyHost()
    }

    // MARK: Helpers

    @discardableResult
    private func send(_ kind: CommandKind, requestId: UUID) -> Bool {
        let command = KeyboardCommand(
            requestId: requestId, kind: kind, createdAt: clock(),
            documentIdentifier: activeDocumentIdentifier, styleOverride: styleOverride)
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

    private func writeKeyboardStatus(listening requestId: UUID? = nil) {
        guard let host else { return }
        let now = clock()
        let status = KeyboardStatus(
            fullAccessAt: host.hasFullAccess ? now : nil, lastSeenAt: now,
            listeningRequestId: requestId, listeningHeartbeatAt: requestId == nil ? nil : now)
        // Fails silently without Full Access, which is expected.
        try? transport.payloads.write(keyboardStatus: status)
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
