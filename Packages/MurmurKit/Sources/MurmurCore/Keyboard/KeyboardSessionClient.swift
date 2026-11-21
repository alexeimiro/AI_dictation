import Foundation

/// What the keyboard extension provides to `KeyboardSessionClient`.
@MainActor
public protocol KeyboardSessionHost: AnyObject {
    var hasFullAccess: Bool { get }
    /// `textDocumentProxy.documentIdentifier` of the focused field.
    var currentDocumentIdentifier: UUID? { get }
    func openContainingApp(_ url: URL)
    /// Insert a finished dictation into the focused field. With "Type as I speak" the keyboard
    /// asks `LiveTyping.place` first, which replaces the words typed live with it; this stays the
    /// one way a dictation's text is placed.
    func insertDictation(_ result: DictationResult)
    /// A dictation the keyboard was waiting on came back (or is running late), so the user can be
    /// told without watching the screen. Also a dictation whose words were typed live and that
    /// ended with nothing to insert while the keyboard was not waiting for it.
    func dictationDidFinish(_ outcome: DictationOutcome)
    func sessionClientDidChange(_ client: KeyboardSessionClient)
}

/// How a dictation the keyboard was waiting on, or had typed words for, ended.
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
/// dictation as soon as it has the microphone and sends the user back; the
/// keyboard attaches to the recording when it reappears.
@MainActor
public final class KeyboardSessionClient {
    /// How often the keyboard tells the app it's still on screen, which keeps the session from
    /// timing out while it's in use (see `IdleStop`).
    public static let visibilityInterval: Duration = .seconds(5)
    /// How long a dictation that ended while the keyboard was away (the cap, the Lock Screen's
    /// Stop) is offered as "Insert last dictation", instead of `Transcript.insertWindow`. And how
    /// long one that ended with nothing to insert, unwaited for, still has the words typed live
    /// for it taken out of the field.
    public static let awayInsertWindow: TimeInterval = 600
    /// How long after the keyboard comes on screen nothing is typed live for a dictation it
    /// joins there (`attachToPendingStart`): the first second after the trip to the app. A field
    /// that is not ready yet would drop the insertion while the keyboard's own copy of the text
    /// shows it, and the final text's replacement would then delete the person's own text in
    /// place of the words.
    static let attachSettle: TimeInterval = 1

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
    /// The words of the dictation being listened to, as the app last published them. Nil while
    /// not listening, and for a dictation without a preview (no on-device model listened to it).
    /// Whether a dictation has one is settled as listening begins: the app publishes an empty
    /// preview before it reports `recording`, and this is read before the host hears of the new
    /// phase. A dictation that began without a preview never gets one; one that began with it
    /// keeps it until the phase moves on, emptied if the app takes the words away first. So the
    /// listening screen never changes its layout midway. It is shown, not inserted: only "Type as
    /// I speak" (`liveTyping`) puts any of it into the field, and only the settled words.
    public private(set) var livePreview: LivePreview?
    /// A finished dictation that couldn't be inserted automatically (other field, or late).
    public private(set) var pendingResult: DictationResult?
    /// The style in the keyboard's style pill, sent with each dictation; nil leaves it to the app's
    /// Default style.
    public var styleOverride: StylePreset?
    /// BCP-47 tag chosen in the keyboard's language pill; nil means the primary language.
    public var languageOverride: String?
    /// BCP-47 tag of the primary language, which a dictation is in while the pill shows it (the
    /// override is nil then). The words typed live are joined by its rules (`liveWordsLanguage`).
    public var primaryLanguage: String?
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
    /// The free words are used up (`SharedSettings.wordsUsedUp`): the mic shows the way to Pro
    /// instead of recording.
    private let wordsUsedUp: () -> Bool
    /// "Type as I speak": types the settled words of a dictation this keyboard follows from its
    /// start, and has its final text replace them. That is one the mic began on a live session,
    /// and one the app began for the keyboard, which joins it when it is back on screen
    /// (`typingOffer`); never one the keyboard left and came back to. Nil types nothing.
    private let liveTyping: LiveTyping?
    /// The keyboard's log: how a dictation started, whether its words are typed live and why
    /// not, in fixed words. Never any of the dictation's or the field's text.
    private let trace: (String) -> Void
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
    /// A dictation come back to whose app hasn't shown since that it is still there (its state
    /// hasn't moved on): what the file holds may be a dead app's words, so none are shown yet.
    private var unconfirmedResume: UUID?
    /// The last start command and when it was sent: the tap, should the app have to be opened for
    /// that dictation after all.
    private var startSent: (requestId: UUID, at: Date)?
    /// The dictation "Type as I speak" may still be armed for, with the options it was begun with.
    /// The mic tap makes it, and so does joining a dictation the app began for the keyboard
    /// (`attached`). `armLiveTyping` uses it up, armed or refused, and leaving the screen drops
    /// it: a dictation the keyboard comes back to is never armed. It counts only while its
    /// dictation is the one listened to. `since`: when a join on the trip to the app made it,
    /// which `attachSettle` counts from as well (the far past for the others).
    private var typingOffer: (id: UUID, translating: Bool, language: String?, attached: Bool, since: Date)?
    /// When the keyboard last came on screen, for `attachSettle`.
    private var activatedAt = Date.distantPast

    public init(
        transport: IPCTransport,
        clock: @escaping () -> Date = Date.init,
        ackTimeout: Duration = .milliseconds(500),
        busyTimeout: Duration = .seconds(15),
        resultTimeout: Duration = .seconds(20),
        staleAfter: TimeInterval = 2.5,
        wordsUsedUp: @escaping () -> Bool = { false },
        liveTyping: LiveTyping? = nil,
        trace: @escaping (String) -> Void = { _ in }
    ) {
        self.wordsUsedUp = wordsUsedUp
        self.liveTyping = liveTyping
        self.trace = trace
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
        activatedAt = clock()
        if observations.isEmpty {
            observations = [
                transport.observe(.stateChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.refresh() }
                },
                transport.observe(.resultReady) { [weak self] in
                    MainActor.assumeIsolated { self?.checkForResult() }
                },
                transport.observe(.livePreview) { [weak self] in
                    MainActor.assumeIsolated { self?.refreshLivePreview() }
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
        if case .listening(let id, _) = phase {
            if liveTyping?.isTyping(id) == true { trace("typing stopped: left the screen") }
            if typingOffer?.id == id { trace("typing not armed: left the screen") }
        }
        // Off screen the keyboard's edits have no effect: no more words are typed for this
        // dictation, also once the keyboard is back.
        liveTyping?.suspend()
        // Nor is the typing begun for it then: a dictation the keyboard left while its words were
        // still on the way is never armed. (The bounce to the app drops the tap's offer here too;
        // joining that dictation makes a new one.)
        typingOffer = nil
        switch phase {
        case .listening(let id, let since):
            away = (id, since)
            // Off screen nothing shows them; coming back reads them again.
            if livePreview != nil { livePreview = LivePreview(requestId: id) }
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
        case .listening(let id, let since):
            stop(id, listeningSince: since)
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
        // Closing the card doesn't bring the words back: every tap shows it again, until the
        // week resets or Pro (the app clears it when it hears either).
        guard !wordsUsedUp() else {
            // As a dictation would, the tap puts away "Insert last dictation", which would hide the card.
            pendingResult = nil
            setPhase(.notice(Brand.limitReachedMessage))
            return
        }
        resumedRequestId = nil
        let requestId = UUID()
        activeDocumentIdentifier = host.currentDocumentIdentifier
        pendingResult = nil
        // Words typed live for an earlier dictation are ordinary text from here.
        liveTyping?.forget()
        typingOffer = (requestId, translationTargetLanguage != nil, liveWordsLanguage, false, .distantPast)
        trace("start tap")
        if transport.currentState().status.isLive {
            sendStart(requestId)
        } else {
            openApp(for: requestId)
        }
    }

    /// ✓ — stop and insert.
    public func stopTapped() {
        if case .listening(let id, let since) = phase { stop(id, listeningSince: since) }
    }

    /// X — discard the dictation.
    public func cancelTapped() {
        switch phase {
        case .listening(let id, _), .starting(let id), .processing(let id):
            send(.cancel, requestId: id)
            transport.payloads.claim(id)
            // Discarded words least of all outlive the dictation, should the app be gone.
            removeLivePreview(of: id)
            cancelTasks()
            // Nor do the ones typed into the field as they were said.
            liveTyping?.discard(id)
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

    /// The card's ✕: the text is not wanted here. Nothing of that dictation waits in the shared
    /// container afterwards, so the note of the words typed live for it goes too, and they stay
    /// as the ordinary text they are.
    public func dismissPendingResult() {
        if let result = pendingResult {
            transport.payloads.claim(result.requestId)
            liveTyping?.forget(result.requestId)
        }
        pendingResult = nil
        notifyHost()
    }

    /// The system refused to open the app (e.g. Full Access is off).
    public func containingAppOpenFailed() {
        guard case .openingApp = phase else { return }
        transport.payloads.clearPendingStart()
        setPhase(.notice("Open Redmic to turn on dictation."))
    }

    public func dismissNotice() {
        switch phase {
        case .notice, .needsFullAccess: setPhase(.idle)
        default: break
        }
    }

    // MARK: Start handshake

    private func sendStart(_ requestId: UUID) {
        startSent = (requestId, clock())
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
                self.setPhase(.notice("Redmic is still finishing your last dictation. Try again in a moment."))
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
            // The app's preview, empty until its first word, is there before it reports `recording`.
            if let preview = livePreview { typeLive(preview) } else { dropOfferWithoutWords(requestId) }
            startListeningLoop(requestId)
            return true
        }
        return false
    }

    /// Decides, once, whether "Type as I speak" types the dictation `preview` is of. It is asked
    /// with every preview the app published for the dictation being listened to (`typeLive`), and
    /// does something only while `typingOffer` names that dictation: one the mic began on a live
    /// session, decided as it begins to listen, in the field the mic was tapped in; or one the
    /// app began for the keyboard, decided once the keyboard has been on screen for
    /// `attachSettle`, in the field that has the focus then (iOS gives the field a new
    /// identifier after the trip to the app). The second kind has been recorded for a while by
    /// then, and its first words may come seconds later, many of them at once: they are typed as
    /// any are.
    ///
    /// Whatever the decision, the offer is used up: a dictation refused here is not typed later,
    /// when the field or the switch has changed. Never armed: a dictation the keyboard left and
    /// came back to (leaving dropped the offer), and one the app begins while words typed for an
    /// earlier dictation still wait in a field for their text (a tap on the mic makes those
    /// ordinary text first; nobody tapped for this one).
    private func armLiveTyping(for preview: LivePreview) {
        guard let offer = typingOffer, offer.id == preview.requestId else { return }
        if offer.attached {
            // Not yet, and the offer stays: the next words ask again, and the listening loop
            // within a second. The second counts from when the keyboard came on screen and from
            // the join itself: a keyboard that joins before it has been told it left (Murmur is
            // in front, the old keyboard still runs) came on screen long ago.
            if clock().timeIntervalSince(max(activatedAt, offer.since)) < Self.attachSettle { return }
            // Nor while no field holds the keyboard (it has let go, or isn't back yet): what would
            // be typed would go nowhere, and count as typed.
            if host?.currentDocumentIdentifier == nil { return }
        }
        typingOffer = nil
        guard let liveTyping else { return trace("typing not armed: off") }
        // `begin` replaces the record: never over words that are still in a field. Asked of the
        // shared container now, not of what this keyboard read when it was made: another
        // keyboard object may have typed them since.
        guard !liveTyping.hasTypedWords else { return trace("typing not armed: earlier words") }
        // The field the keyboard came back to, as iOS names it now.
        if offer.attached { activeDocumentIdentifier = host?.currentDocumentIdentifier }
        guard host?.currentDocumentIdentifier == activeDocumentIdentifier else {
            return trace("typing not armed: other field")
        }
        liveTyping.begin(offer.id, translating: offer.translating, language: offer.language)
        if liveTyping.isTyping(offer.id) {
            trace("typing armed")
        } else {
            trace("typing not armed: \(liveTyping.refusal(translating: offer.translating) ?? "refused")")
        }
    }

    /// A dictation that began without a preview never gets one (`refreshLivePreview`): there
    /// will be no words to type, so the offer goes.
    private func dropOfferWithoutWords(_ requestId: UUID) {
        guard livePreview == nil, typingOffer?.id == requestId else { return }
        typingOffer = nil
        trace("typing not armed: no words")
    }

    /// The language whose rules join a dictation's words while they are typed live: the one the
    /// pill names, and otherwise the primary language. That is also the choice for Auto-detect,
    /// whose language is known only when the final text comes, which is joined by its own.
    public var liveWordsLanguage: String? {
        Self.liveWordsLanguage(override: languageOverride, primary: primaryLanguage)
    }

    /// `liveWordsLanguage` for a dictation begun with the language `override` (nil: the primary one).
    static func liveWordsLanguage(override: String?, primary: String?) -> String? {
        if let override, !DictationLanguage(tag: override).isAutomatic { return override }
        return primary
    }

    /// Hands "Type as I speak" the words the app published: never the keyboard's own empty
    /// stand-in for them, which would read as the dictation starting over. The first of them
    /// settle whether the dictation is typed at all (`armLiveTyping`). Once the focus is in
    /// another field than the one the typing began in, no more are typed: the final text
    /// wouldn't go there unasked either.
    private func typeLive(_ preview: LivePreview) {
        armLiveTyping(for: preview)
        guard let liveTyping, liveTyping.isTyping(preview.requestId) else { return }
        guard host?.currentDocumentIdentifier == activeDocumentIdentifier else {
            liveTyping.suspend()
            return trace("typing stopped: other field")
        }
        liveTyping.apply(preview)
        if !liveTyping.isTyping(preview.requestId) { trace("typing stopped") }
    }

    private func openApp(for requestId: UUID) {
        let now = clock()
        let token = LaunchToken(requestId: requestId, createdAt: now)
        do {
            try transport.payloads.write(launchToken: token)
            try transport.payloads.write(pendingStart: PendingStart(
                requestId: requestId, documentIdentifier: activeDocumentIdentifier, createdAt: now, autoStart: true,
                styleOverride: styleOverride, languageOverride: languageOverride,
                translationTargetLanguage: translationTargetLanguage,
                // The tap was earlier when a start went unanswered first.
                tappedAt: startSent?.requestId == requestId ? startSent?.at : nil))
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
        let onTheTrip = if case .openingApp = phase { true } else { false }
        // The field can't be recognized by its documentIdentifier: iOS gives it a new one after the
        // trip to the app (seen on the iPhone, iOS 26.6). The dictation goes into the field the
        // user came back to, and its result follows the request.
        activeDocumentIdentifier = host?.currentDocumentIdentifier ?? pending.documentIdentifier
        resumedRequestId = pending.requestId
        if state.status != .processing {
            // Followed from here to its end, so its words may be typed live. By the request's
            // options, which the app begins it with, not this keyboard's own: a shortcut's
            // request carries the app's, and a keyboard iOS made anew has only what its settings
            // say by now. Joined on the trip to the app (this keyboard opened it), the second of
            // `attachSettle` counts from here too.
            typingOffer = (pending.requestId, pending.translationTargetLanguage != nil,
                           Self.liveWordsLanguage(override: pending.languageOverride, primary: primaryLanguage), true,
                           onTheTrip ? clock() : .distantPast)
        }
        switch state.status {
        case .recording:
            trace("start attach")
            // As in `resumeAwayDictation`: the app may have died since it began recording this.
            unconfirmedResume = pending.requestId
            // The preview read here is the keyboard's stand-in until the app shows that it is
            // there: nothing is typed, or decided about typing, on that.
            setPhase(.listening(pending.requestId, since: clock()))
            dropOfferWithoutWords(pending.requestId)
            startListeningLoop(pending.requestId)
        case .processing:
            setPhase(.processing(pending.requestId))
            waitForResult(pending.requestId)
            checkForResult()
        default:
            if transport.payloads.readResult(pending.requestId) != nil {
                // Recorded and written while the keyboard was away (something else stopped it on
                // the way): its text is there. Starting the request again would record a second
                // dictation under its name, whose words would be typed and then replaced by the
                // first one's text.
                trace("start attach-written")
                typingOffer = nil
                setPhase(.processing(pending.requestId))
                waitForResult(pending.requestId)
                checkForResult()
            } else {
                // The app hasn't begun it, so this keyboard's start does, with this keyboard's
                // options as they are now: the typing goes by the same.
                typingOffer?.translating = translationTargetLanguage != nil
                typingOffer?.language = liveWordsLanguage
                trace("start attach-ready")
                sendStart(pending.requestId)
            }
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
        // Left and come back to: "Type as I speak" is never armed for it (again).
        typingOffer = nil
        let state = transport.currentState()
        if state.status == .recording, state.requestTag == left.requestId.tag16 {
            activeDocumentIdentifier = host?.currentDocumentIdentifier
            // `recording` may be what an app that died meanwhile left behind.
            unconfirmedResume = left.requestId
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
        // Coming back to a dictation leaves the phase as it was, so `setPhase` settles nothing:
        // its preview is brought here to what may be shown now, which is no words until the app
        // shows that it is there (`trackSequence` reads them then).
        refreshLivePreview()
        listenTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                guard case .listening(requestId, _) = self.phase else { return }
                self.pollListening(requestId)
                tick += 1
                // Once a second; the preview too, for a notification that was missed, and for
                // words "Type as I speak" was shown before it could be armed.
                if tick % 20 == 0 { self.writeKeyboardStatus(); self.refreshLivePreview(offeringAgain: true) }
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
                // It can't take its preview away any more, so the keyboard does: the words don't outlive it.
                removeLivePreview(of: requestId)
                setPhase(.notice("Redmic stopped listening. Tap the mic to start again."))
            } else {
                notifyHost()
            }
        } else {
            refresh()
        }
    }

    private func stop(_ requestId: UUID, listeningSince: Date) {
        listenTask?.cancel()
        send(.stop, requestId: requestId, listeningSince: listeningSince)
        // The app removes its preview when it hears this; one that died a moment ago can't.
        removeLivePreview(of: requestId)
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
            self.setPhase(.notice("This is taking longer than usual. Your dictation will be saved in Redmic."))
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
        setPhase(.notice(freshFailure?.message ?? "Redmic couldn't start. Open the app to see why."))
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
        // The dictation whose words were typed live ended with nothing to insert, and this
        // keyboard wasn't waiting for it: iOS made it anew, or it gave up after `resultTimeout`.
        // Read by the dictation's own id: a `cancelled` result is never the latest one.
        if let typed = liveTyping?.typedRequestId, let ended = transport.payloads.readResult(typed),
           !ended.isInsertable {
            transport.payloads.claim(typed)
            let recent = clock().timeIntervalSince(ended.createdAt) < Self.awayInsertWindow
            takeOutTypedWords(of: ended)
            // And the person hears of it as in `deliver`, where the keyboard is at rest. The
            // message also takes the place of the notice that the dictation "will be saved".
            switch phase {
            case .idle where recent, .notice:
                if let message = ended.message, ended.status != .cancelled {
                    setPhase(.notice(message))
                } else if case .notice = phase {
                    setPhase(.idle)
                }
                if ended.status != .cancelled { host?.dictationDidFinish(.problem) }
            default:
                break
            }
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

    /// Nothing replaces the words typed live for a dictation that ended with nothing to insert:
    /// they go, if all of them still show before the cursor. Only while its result is recent,
    /// whichever way the keyboard comes to it.
    private func takeOutTypedWords(of ended: DictationResult) {
        if clock().timeIntervalSince(ended.createdAt) < Self.awayInsertWindow {
            liveTyping?.discard(ended.requestId)
        } else {
            liveTyping?.forget(ended.requestId)
        }
    }

    private func deliver(_ result: DictationResult) {
        cancelTasks()
        guard result.isInsertable else {
            transport.payloads.claim(result.requestId)
            takeOutTypedWords(of: result)
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
        // Asked before claiming: when the text before the cursor no longer shows all of the words
        // typed live, the final text isn't put beside them unasked, and waits as "Insert last
        // dictation".
        let replaces = liveTyping?.canPlace(result.requestId) ?? true
        trace(replaces ? "deliver: can place" : "deliver: cannot place")
        if sameField, fresh, replaces, transport.payloads.claim(result.requestId) {
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

    /// `listeningSince`: with a stop, when this keyboard began listening to the dictation.
    @discardableResult
    private func send(_ kind: CommandKind, requestId: UUID, listeningSince: Date? = nil) -> Bool {
        let command = KeyboardCommand(
            requestId: requestId, kind: kind, createdAt: clock(),
            documentIdentifier: activeDocumentIdentifier, styleOverride: styleOverride,
            languageOverride: languageOverride, translationTargetLanguage: translationTargetLanguage,
            listeningSince: listeningSince)
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
            // The app is there: the words of the dictation come back to are its own.
            if unconfirmedResume != nil {
                unconfirmedResume = nil
                refreshLivePreview()
            }
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
        if case .listening(let id, _) = newPhase {
            // Before the host hears of the phase, so the listening screen is laid out once.
            livePreview = storedLivePreview(for: id)
        } else {
            level = 0
            livePreview = nil
        }
        notifyHost()
    }

    /// The app's preview, if it is `requestId`'s. Never while the week's words are used up.
    private func storedLivePreview(for requestId: UUID) -> LivePreview? {
        guard !wordsUsedUp(), let stored = transport.payloads.readLivePreview(),
              stored.requestId == requestId else { return nil }
        return unconfirmedResume == requestId ? LivePreview(requestId: requestId) : stored
    }

    /// Removes the preview if it is still `requestId`'s: when the keyboard stops following that
    /// dictation, in case the app is no longer there to remove it. A live app removes it too, and
    /// removes again what a last write of its own may bring back.
    private func removeLivePreview(of requestId: UUID) {
        if transport.payloads.readLivePreview()?.requestId == requestId {
            transport.payloads.clearLivePreview()
        }
    }

    /// New words for the dictation being listened to: on the app's event, on coming back (once
    /// the app has shown that it is there), and once a second. Only a dictation that began with a
    /// preview is refreshed; when the file is gone or another dictation's, its words go and its
    /// layout stays. The 20 Hz poll hands the change to the host, so nothing is notified here (a
    /// notification would also shift the rings' level history). "Type as I speak" gets the words
    /// the app published, never the empty stand-in for words that are gone or withheld.
    ///
    /// `offeringAgain`, once a second: while "Type as I speak" still waits to be armed for this
    /// dictation (`attachSettle`), it gets the app's words also when they are no news, so words
    /// that came during that second are typed though no newer ones follow.
    private func refreshLivePreview(offeringAgain: Bool = false) {
        guard case .listening(let id, _) = phase, livePreview != nil else { return }
        let stored = storedLivePreview(for: id)
        let latest = stored ?? LivePreview(requestId: id)
        guard latest != livePreview || (offeringAgain && typingOffer?.id == id) else { return }
        livePreview = latest
        if let stored, unconfirmedResume != id { typeLive(stored) }
    }

    private func notifyHost() {
        host?.sessionClientDidChange(self)
    }
}
