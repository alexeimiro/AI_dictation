import Foundation
import Testing
@testable import MurmurCore

@MainActor
private final class FakeHost: KeyboardSessionHost {
    var hasFullAccess = true
    var currentDocumentIdentifier: UUID? = UUID()
    var openedURLs: [URL] = []
    var inserted: [DictationResult] = []
    var outcomes: [DictationOutcome] = []
    /// `livePreview` as the host first heard that each dictation is being listened to.
    var heardListening: [(id: UUID, preview: LivePreview?)] = []
    /// Times the host was told of a change while the client held a preview that wasn't the
    /// listening dictation's.
    var strayPreviews = 0

    func openContainingApp(_ url: URL) { openedURLs.append(url) }
    func insertDictation(_ result: DictationResult) { inserted.append(result) }
    func dictationDidFinish(_ outcome: DictationOutcome) { outcomes.append(outcome) }

    func sessionClientDidChange(_ client: KeyboardSessionClient) {
        if case .listening(let id, _) = client.phase, heardListening.last?.id != id {
            heardListening.append((id, client.livePreview))
        }
        if let preview = client.livePreview {
            if case .listening(preview.requestId, _) = client.phase {} else { strayPreviews += 1 }
        }
    }
}

/// Plays the app's side of the protocol.
@MainActor
private final class FakeApp {
    let transport: IPCTransport
    var sequence: UInt32 = 1
    var acknowledges = true
    /// Finishing a previous dictation: a start is queued and acknowledged as `starting`.
    var busy = false
    /// An on-device model hears the dictations: each gets a preview, empty until the first word.
    var previews = false
    private(set) var queued: UUID?
    private var observation: IPCObservation?

    init(transport: IPCTransport) {
        self.transport = transport
        observation = transport.observe(.command) { [weak self] in
            MainActor.assumeIsolated { self?.handleCommand() }
        }
    }

    func publish(_ status: SessionStatus, tag: UInt16 = 0) {
        sequence += 1
        transport.publish(HotState(status: status, level: 128, requestTag: tag, sequence: sequence))
        transport.post(.stateChanged)
    }

    func fail(message: String, at date: Date = Date()) throws {
        try transport.payloads.write(sessionFailure: SessionFailure(message: message, createdAt: date))
        publish(.error)
    }

    func finish(_ requestId: UUID, text: String, document: UUID?, status: ResultStatus = .cleaned,
                message: String? = nil) throws {
        try transport.payloads.write(result: DictationResult(
            requestId: requestId, documentIdentifier: document, text: text, status: status, message: message,
            createdAt: Date()))
        publish(.ready)
        transport.post(.resultReady)
    }

    /// The app's side of the bounce: once it has the microphone, it records the pending request.
    func autoStart() -> UUID? {
        guard let pending = transport.payloads.readPendingStart(), pending.autoStart == true else { return nil }
        publish(.recording, tag: pending.requestId.tag16)
        return pending.requestId
    }

    func finishBusy() {
        busy = false
        if let queued { publish(.recording, tag: queued.tag16) }
    }

    /// The words so far: the app writes the preview, then says so (`posts: false` is an event
    /// that never reached the keyboard).
    func say(_ id: UUID, _ settled: String, _ unsettled: String = "", posts: Bool = true) throws {
        try transport.payloads.write(livePreview: LivePreview(requestId: id, settled: settled, unsettled: unsettled))
        if posts { transport.post(.livePreview) }
    }

    /// The app removes the preview, as it does when the dictation ends.
    func takeWordsAway() {
        transport.payloads.clearLivePreview()
        transport.post(.livePreview)
    }

    private func handleCommand() {
        guard acknowledges, let command = transport.payloads.readCommand() else { return }
        switch command.kind {
        case .start where busy:
            queued = command.requestId
            publish(.starting, tag: command.requestId.tag16)
        case .start:
            // Before it reports `recording`, as the app does.
            if previews { try? transport.payloads.write(livePreview: LivePreview(requestId: command.requestId)) }
            publish(.recording, tag: command.requestId.tag16)
        case .stop: publish(.processing, tag: command.requestId.tag16)
        case .cancel: publish(.ready)
        }
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A keyboard that listens to a dictation the fake app records.
@MainActor
private struct Listening {
    let transport: InMemoryIPCTransport
    let app: FakeApp
    let host: FakeHost
    let client: KeyboardSessionClient
    let id: UUID
}

/// Taps the mic on a live session and waits until the keyboard listens. With `previews`, the app
/// publishes the dictation's (empty) preview before it reports `recording`.
@MainActor
private func listen(
    previews: Bool, on transport: InMemoryIPCTransport = InMemoryIPCTransport(), staleAfter: TimeInterval = 2.5,
    wordsUsedUp: @escaping () -> Bool = { false }
) async throws -> Listening {
    let app = FakeApp(transport: transport)
    app.previews = previews
    let host = FakeHost()
    let client = KeyboardSessionClient(transport: transport, staleAfter: staleAfter, wordsUsedUp: wordsUsedUp)
    client.host = host
    app.publish(.ready)
    client.activate()
    client.micTapped()
    #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
    let id: UUID? = if case .listening(let id, _) = client.phase { id } else { nil }
    return Listening(transport: transport, app: app, host: host, client: client, id: try #require(id))
}

@MainActor
struct KeyboardSessionClientTests {
    @Test func dictatesIntoTheSameFieldExactlyOnce() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()

        client.micTapped()
        guard case .starting(let requestId) = client.phase else {
            Issue.record("expected .starting, got \(client.phase)")
            return
        }
        let start = try #require(transport.payloads.readCommand())
        #expect(start.kind == .start && start.listeningSince == nil)
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        guard case .listening(_, let since) = client.phase else { return }

        client.stopTapped()
        // The stop says when this keyboard began to listen: with the start's own time, that is how
        // long the tap took to show.
        let stop = try #require(transport.payloads.readCommand())
        #expect(stop.kind == .stop)
        // To the millisecond: the command's dates are written as whole milliseconds.
        let reported = try #require(stop.listeningSince)
        #expect(abs(reported.timeIntervalSince(since)) < 0.002)
        #expect(reported.timeIntervalSince(start.createdAt) > -0.002)
        try app.finish(requestId, text: "Hello world.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(host.inserted.first?.text == "Hello world.")
        #expect(host.outcomes == [.ready])

        // A second resultReady must not insert again.
        transport.post(.resultReady)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(host.inserted.count == 1)
        #expect(host.outcomes == [.ready])
        #expect(client.phase == .idle)
        #expect(host.openedURLs.isEmpty)
    }

    @Test func opensTheAppWhenThereIsNoSessionThenAutoStarts() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()

        client.micTapped()
        #expect(host.openedURLs.count == 1)
        let url = try #require(host.openedURLs.first)
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "t" }?.value
        #expect(token != nil)
        guard case .openingApp(let requestId) = client.phase else {
            Issue.record("expected .openingApp, got \(client.phase)")
            return
        }

        // Opened at once: the request's own time is the tap.
        #expect(try #require(transport.payloads.readPendingStart()).tappedAt == nil)

        // The app validates the token and starts the session; the keyboard then starts recording.
        #expect(transport.payloads.consumeLaunchToken(token!, maxAge: 10, now: Date())?.requestId == requestId)
        app.publish(.ready)
        #expect(await waitUntil {
            if case .listening(requestId, _) = client.phase { true } else { false }
        })
        #expect(transport.payloads.readPendingStart() == nil)
    }

    @Test func fallsBackToOpeningTheAppWhenTheAckTimesOut() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        app.acknowledges = false
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport, ackTimeout: .milliseconds(150))
        client.host = host
        app.publish(.ready)
        client.activate()

        client.micTapped()
        let start = try #require(transport.payloads.readCommand())
        #expect(await waitUntil { host.openedURLs.count == 1 })
        if case .openingApp = client.phase {} else { Issue.record("expected .openingApp, got \(client.phase)") }
        // The request the app is opened with says when the tap was: the wait for the session that
        // didn't answer is part of what the user waited.
        let pending = try #require(transport.payloads.readPendingStart())
        let tappedAt = try #require(pending.tappedAt)
        #expect(pending.requestId == start.requestId)
        #expect(abs(tappedAt.timeIntervalSince(start.createdAt)) < 0.01)
        #expect(pending.createdAt.timeIntervalSince(tappedAt) >= 0.14)
    }

    @Test func resultForAnotherFieldIsOfferedInsteadOfInserted() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()

        client.micTapped()
        guard case .starting(let requestId) = client.phase else { return }
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        client.stopTapped()

        host.currentDocumentIdentifier = UUID() // user moved to another field
        try app.finish(requestId, text: "Elsewhere.", document: UUID())
        #expect(await waitUntil { client.pendingResult != nil })
        #expect(host.inserted.isEmpty)
        #expect(host.outcomes == [.ready])

        client.insertPendingResult()
        #expect(host.inserted.map(\.text) == ["Elsewhere."])
        client.insertPendingResult()
        #expect(host.inserted.count == 1)
        #expect(host.outcomes == [.ready], "inserting a held result is the user's own tap")
    }

    @Test func matchingLatestResultIsInsertedWhenRequestFileIsUnavailable() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()

        client.micTapped()
        guard case .starting(let requestId) = client.phase else { return }
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        client.stopTapped()

        let result = DictationResult(
            requestId: requestId, documentIdentifier: host.currentDocumentIdentifier,
            text: "Recovered immediately.", status: .cleaned, createdAt: Date())
        try transport.payloads.write(result: result)
        try FileManager.default.removeItem(at: transport.payloads.container
            .directory("results").appendingPathComponent("\(requestId.uuidString).json"))
        transport.post(.resultReady)

        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(host.inserted.map(\.text) == ["Recovered immediately."])
        #expect(client.pendingResult == nil)
        #expect(host.outcomes == [.ready])
    }

    @Test func emptyResultIsAProblemAndCancellingIsSilent() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()

        client.micTapped()
        guard case .starting(let first) = client.phase else { return }
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        client.stopTapped()
        try app.finish(first, text: "", document: host.currentDocumentIdentifier, status: .empty,
                       message: "We didn't catch anything")
        #expect(await waitUntil { if case .notice = client.phase { true } else { false } })
        #expect(host.outcomes == [.problem])

        client.micTapped()
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        client.stopTapped()
        client.cancelTapped()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.phase == .idle)
        #expect(host.outcomes == [.problem])
    }

    @Test func aSlowResultIsAProblemOnce() async {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport, resultTimeout: .milliseconds(300))
        client.host = host
        app.publish(.ready)
        client.activate()

        client.micTapped()
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        client.stopTapped()
        #expect(await waitUntil { if case .notice = client.phase { true } else { false } })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(host.outcomes == [.problem])
    }

    @Test func sessionFailureShowsTheAppsReasonWhileOpeningTheApp() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()

        client.micTapped()
        guard case .openingApp = client.phase else {
            Issue.record("expected .openingApp, got \(client.phase)")
            return
        }
        try app.fail(message: "Russian needs a one-time download.")
        #expect(await waitUntil { client.phase == .notice("Russian needs a one-time download.") })
        #expect(transport.payloads.readPendingStart() == nil)

        // Dismissing the notice doesn't bring the same failure back on the next refresh.
        client.dismissNotice()
        app.publish(.error)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.phase == .idle)
    }

    @Test func staleSessionFailureIsIgnoredWhenIdle() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()

        try app.fail(message: "Old news.", at: Date().addingTimeInterval(-120))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.phase == .idle)
    }

    @Test func languageOverrideIsSentWithTheCommand() async {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()

        client.languageOverride = "ru-RU"
        client.translationTargetLanguage = "tr-TR"
        client.micTapped()
        #expect(transport.payloads.readCommand()?.languageOverride == "ru-RU")
        #expect(transport.payloads.readCommand()?.translationTargetLanguage == "tr-TR")
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
    }

    /// The week's free words are used up: the mic shows the way to Pro, every time it's tapped,
    /// and nothing is sent to the app or opens it.
    @Test func withTheWordsUsedUpTheMicShowsTheLimitInsteadOfRecording() async {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        var usedUp = true
        let client = KeyboardSessionClient(transport: transport, wordsUsedUp: { usedUp })
        client.host = host
        app.publish(.ready)
        client.activate()

        // An earlier dictation waiting as "Insert last dictation" would hide the card: the tap puts it away.
        try? app.finish(UUID(), text: "An earlier dictation.", document: UUID())
        #expect(await waitUntil { client.pendingResult != nil })
        client.micTapped()
        #expect(client.phase == .notice(Brand.limitReachedMessage))
        #expect(client.pendingResult == nil)
        client.dismissNotice()
        #expect(client.phase == .idle)
        client.micTapped()
        #expect(client.phase == .notice(Brand.limitReachedMessage))
        #expect(transport.payloads.readCommand() == nil)
        #expect(host.openedURLs.isEmpty)

        // A new week, or Pro: the next tap records.
        usedUp = false
        client.micTapped()
        guard case .starting = client.phase else {
            Issue.record("expected .starting, got \(client.phase)")
            return
        }
        #expect(transport.payloads.readCommand()?.kind == .start)
    }

    /// The server refused the dictation for the week's words: nothing goes in, the notice says why.
    @Test func aDictationRefusedAtTheLimitInsertsNothing() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()
        client.micTapped()
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        guard case .listening(let id, _) = client.phase else { return }
        client.stopTapped()
        try app.finish(id, text: "words heard on the iPhone", document: host.currentDocumentIdentifier,
                       status: .limitReached, message: Brand.limitReachedMessage)
        #expect(await waitUntil { client.phase == .notice(Brand.limitReachedMessage) })
        #expect(host.inserted.isEmpty)
        #expect(client.pendingResult == nil)
        #expect(host.outcomes == [.problem])
    }

    /// The last dictation the server wrote before the words ran out goes in, then says so.
    @Test func theDictationThatUsedTheLastWordsGoesInWithTheNotice() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()
        client.micTapped()
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        guard case .listening(let id, _) = client.phase else { return }
        client.stopTapped()
        try app.finish(id, text: "The last words this week.", document: host.currentDocumentIdentifier,
                       status: .raw, message: Brand.limitReachedMessage)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(client.phase == .notice(Brand.limitReachedMessage))
    }

    @Test func withoutFullAccessAsksForIt() {
        let transport = InMemoryIPCTransport()
        let host = FakeHost()
        host.hasFullAccess = false
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.micTapped()
        #expect(client.phase == .needsFullAccess)
        #expect(host.openedURLs.isEmpty)
    }

    // MARK: The bounce

    @Test func theBounceCarriesTheDictationsOptions() throws {
        let transport = InMemoryIPCTransport()
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()

        client.styleOverride = .grammar
        client.languageOverride = "ru-RU"
        client.translationTargetLanguage = "en-US"
        client.micTapped()
        let pending = try #require(transport.payloads.readPendingStart())
        #expect(pending.autoStart == true)
        #expect(pending.documentIdentifier == host.currentDocumentIdentifier)
        #expect(pending.styleOverride == .grammar)
        #expect(pending.languageOverride == "ru-RU")
        #expect(pending.translationTargetLanguage == "en-US")
    }

    @Test func attachesToTheDictationTheAppStartedDuringTheBounce() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()

        client.micTapped()
        guard case .openingApp(let requestId) = client.phase else {
            Issue.record("expected .openingApp, got \(client.phase)")
            return
        }
        client.deactivate() // the app comes to the front
        #expect(client.phase == .openingApp(requestId), "the bounce itself mustn't cancel anything")
        #expect(try #require(app.autoStart()) == requestId)

        client.activate() // back in the app the user came from
        guard case .listening(requestId, _) = client.phase else {
            Issue.record("expected .listening, got \(client.phase)")
            return
        }
        #expect(transport.payloads.readPendingStart() == nil)
        #expect(transport.payloads.readCommand() == nil, "the app started it; no start command")
        #expect(transport.payloads.readKeyboardStatus()?.listeningRequestId == requestId,
                "the app learns at once that the keyboard is back")
    }

    @Test func aKeyboardRelaunchedWhileAwayAttachesToo() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let first = KeyboardSessionClient(transport: transport)
        first.host = host
        first.activate()
        first.micTapped()
        first.deactivate()
        let requestId = try #require(app.autoStart())

        // iOS killed the extension while the user was in Murmur; a fresh one starts out idle.
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()
        guard case .listening(requestId, _) = client.phase else {
            Issue.record("expected .listening, got \(client.phase)")
            return
        }
    }

    /// iOS gives the field a new documentIdentifier after the trip to the app, so the keyboard
    /// follows the dictation in the field it comes back to, and types it there.
    @Test func comingBackWithANewFieldIdentifierFollowsTheDictation() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()
        let tappedIn = host.currentDocumentIdentifier
        client.micTapped()
        client.deactivate()
        let requestId = try #require(app.autoStart())

        host.currentDocumentIdentifier = UUID()
        client.activate()
        guard case .listening(requestId, _) = client.phase else {
            Issue.record("expected .listening, got \(client.phase)")
            return
        }
        #expect(transport.payloads.readCommand() == nil, "nothing cancelled it")

        client.stopTapped()
        // The app's result still names the field the mic was tapped in.
        try app.finish(requestId, text: "Said on the way back.", document: tappedIn)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(host.inserted.first?.text == "Said on the way back.")
    }

    @Test func cancellingWhileOpeningTheAppStopsTheRecordingThere() throws {
        let transport = InMemoryIPCTransport()
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()
        client.micTapped()
        guard case .openingApp(let requestId) = client.phase else { return }

        client.cancelTapped()
        #expect(client.phase == .idle)
        #expect(transport.payloads.readPendingStart() == nil)
        let command = try #require(transport.payloads.readCommand())
        #expect(command.kind == .cancel)
        #expect(command.requestId == requestId)
        #expect(transport.payloads.isClaimed(requestId))
    }

    @Test func aDictationTheAppDroppedLeavesTheKeyboardIdle() async {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        client.activate()
        client.micTapped()
        client.deactivate()

        // The keyboard didn't come back in time: the app discarded the recording.
        transport.payloads.clearPendingStart()
        app.publish(.ready)
        client.activate()
        #expect(client.phase == .idle)
        #expect(host.openedURLs.count == 1)
    }

    // MARK: A busy app

    @Test func aBusyAppQueuesTheStartInsteadOfBeingOpened() async {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport, ackTimeout: .milliseconds(150), busyTimeout: .seconds(5))
        client.host = host
        app.publish(.processing)
        client.activate()

        app.busy = true
        client.micTapped()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(host.openedURLs.isEmpty)
        if case .starting = client.phase {} else { Issue.record("expected .starting, got \(client.phase)") }

        app.finishBusy()
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        #expect(host.openedURLs.isEmpty)
    }

    @Test func leavingWhileTheStartIsQueuedCancelsIt() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport, ackTimeout: .milliseconds(100), busyTimeout: .seconds(5))
        client.host = host
        app.publish(.processing)
        client.activate()

        app.busy = true
        client.micTapped()
        guard case .starting(let requestId) = client.phase else { return }
        client.deactivate()
        #expect(client.phase == .idle)
        let command = try #require(transport.payloads.readCommand())
        #expect(command.kind == .cancel)
        #expect(command.requestId == requestId)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(host.openedURLs.isEmpty)
    }

    @Test func aStartQueuedForTooLongGivesUpWithoutOpeningTheApp() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport, ackTimeout: .milliseconds(100),
                                           busyTimeout: .milliseconds(300))
        client.host = host
        app.publish(.processing)
        client.activate()

        app.busy = true
        client.micTapped()
        #expect(await waitUntil { if case .notice = client.phase { true } else { false } })
        #expect(host.openedURLs.isEmpty)
        #expect(try #require(transport.payloads.readCommand()).kind == .cancel)
    }

    // MARK: Visibility

    /// A screen lock or a trip to another app no longer ends a dictation: the app records on, and
    /// the keyboard follows it again when it is back, inserting into whichever field is focused.
    @Test func aDictationOutlivesTheKeyboardLeavingTheScreen() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)
        client.activate()
        client.micTapped()
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        guard case .listening(let requestId, let since) = client.phase else { return }

        client.deactivate()
        #expect(transport.payloads.readCommand()?.kind == .start, "nothing stopped it")
        let away = try #require(transport.payloads.readKeyboardStatus())
        #expect(away.awayRequestId == requestId)
        // The status file keeps dates to the second or so.
        #expect(abs(away.awayListeningSince?.timeIntervalSince(since) ?? .infinity) < 1)
        #expect(away.listeningRequestId == nil)

        host.currentDocumentIdentifier = UUID()
        client.activate()
        #expect(client.phase == .listening(requestId, since: since))
        let back = try #require(transport.payloads.readKeyboardStatus())
        #expect(back.awayRequestId == nil)
        #expect(back.listeningRequestId == requestId)

        client.stopTapped()
        #expect(transport.payloads.readCommand()?.kind == .stop)
        try app.finish(requestId, text: "A long thought.", document: UUID())
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(host.inserted.first?.text == "A long thought.")
    }

    /// iOS may relaunch the keyboard while it is away: the new one finds the dictation in the
    /// status the old one left, timer and all.
    @Test func aKeyboardRelaunchedWhileADictationRanFollowsIt() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let firstHost = FakeHost()
        let first = KeyboardSessionClient(transport: transport)
        first.host = firstHost
        app.publish(.ready)
        first.activate()
        first.micTapped()
        #expect(await waitUntil { if case .listening = first.phase { true } else { false } })
        guard case .listening(let requestId, let since) = first.phase else { return }
        first.deactivate()

        let host = FakeHost()
        let relaunched = KeyboardSessionClient(transport: transport)
        relaunched.host = host
        relaunched.activate()
        guard case .listening(requestId, let resumedSince) = relaunched.phase else {
            Issue.record("expected to follow \(requestId), got \(relaunched.phase)")
            return
        }
        #expect(abs(resumedSince.timeIntervalSince(since)) < 1, "the timer keeps its start")
    }

    /// The cap or the Lock Screen's Stop ended it while the keyboard was away: its text is offered
    /// for ten minutes, not the two a leftover gets.
    @Test func aDictationThatEndedWhileAwayIsOfferedLonger() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        var now = Date()
        let firstHost = FakeHost()
        let first = KeyboardSessionClient(transport: transport, clock: { now })
        first.host = firstHost
        app.publish(.ready)
        first.activate()
        first.micTapped()
        #expect(await waitUntil { if case .listening = first.phase { true } else { false } })
        guard case .listening(let requestId, _) = first.phase else { return }
        first.deactivate()
        try app.finish(requestId, text: "Ended at the cap.", document: nil)

        now = now.addingTimeInterval(300)
        let host = FakeHost()
        let relaunched = KeyboardSessionClient(transport: transport, clock: { now })
        relaunched.host = host
        relaunched.activate()
        #expect(relaunched.pendingResult?.requestId == requestId)
    }

    @Test func theAppHearsWhenTheKeyboardComesAndGoes() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport)
        client.host = host
        app.publish(.ready)

        client.activate()
        let shown = try #require(transport.payloads.readKeyboardStatus())
        #expect(shown.hiddenAt == nil)
        #expect(transport.postedEvents.contains(.keyboardStatus))

        client.micTapped()
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        guard case .listening(let requestId, _) = client.phase else { return }
        client.activate() // any status write while listening keeps the listening fields
        #expect(transport.payloads.readKeyboardStatus()?.listeningRequestId == requestId)

        client.deactivate()
        let hidden = try #require(transport.payloads.readKeyboardStatus())
        #expect(hidden.hiddenAt != nil)
        #expect(hidden.inactiveSince == hidden.hiddenAt)
        #expect(hidden.listeningRequestId == nil)
        #expect(transport.postedEvents.filter { $0 == .keyboardStatus }.count == 3)
    }

    // MARK: Live words

    /// The app publishes an empty preview before it reports `recording`, and the keyboard reads
    /// it before its host hears that it listens: the listening screen is laid out for words once,
    /// and then the words come.
    @Test func aDictationWithAPreviewShowsItsWords() async throws {
        let listening = try await listen(previews: true)
        let (app, host, client, id) = (listening.app, listening.host, listening.client, listening.id)
        #expect(client.livePreview == LivePreview(requestId: id))
        let heard = try #require(host.heardListening.first)
        #expect(heard.id == id)
        #expect(heard.preview == LivePreview(requestId: id), "the host heard of listening before the preview was read")

        try app.say(id, "So I was thinking", " we could")
        // On the app's event: sooner than the once-a-second read would bring them.
        #expect(await waitUntil(timeout: .milliseconds(500)) {
            client.livePreview == LivePreview(requestId: id, settled: "So I was thinking", unsettled: " we could")
        })
        try app.say(id, "So I was thinking we could meet", " on Thursday")
        #expect(await waitUntil { client.livePreview?.text == "So I was thinking we could meet on Thursday" })
        if case .listening(id, _) = client.phase {} else { Issue.record("expected .listening, got \(client.phase)") }
        #expect(host.strayPreviews == 0)
        #expect(host.inserted.isEmpty)
    }

    /// Whether a dictation has a preview is settled as listening begins. One that began without
    /// (no on-device model heard its start) keeps the plain listening screen to its end, whatever
    /// is published later.
    @Test func aDictationThatBeganWithoutAPreviewNeverGetsOne() async throws {
        let listening = try await listen(previews: false)
        let (app, host, client, id) = (listening.app, listening.host, listening.client, listening.id)
        #expect(client.livePreview == nil)
        #expect(try #require(host.heardListening.first).preview == nil)

        try app.say(id, "Words that came too late")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.livePreview == nil)

        // Nor when the keyboard leaves the screen and comes back to the dictation.
        client.deactivate()
        client.activate()
        if case .listening(id, _) = client.phase {} else { Issue.record("expected .listening, got \(client.phase)") }
        #expect(client.livePreview == nil)
    }

    /// A preview is shown only for the dictation it names: one that another dictation left
    /// behind (the app was killed while it recorded) is not this one's.
    @Test func aPreviewLeftByAnotherDictationIsNotShown() async throws {
        let transport = InMemoryIPCTransport()
        let left = LivePreview(requestId: UUID(), settled: "Words of a dictation that is over")
        try transport.payloads.write(livePreview: left)

        let listening = try await listen(previews: false, on: transport)
        let client = listening.client
        #expect(client.livePreview == nil)
        transport.post(.livePreview)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.livePreview == nil)
        // Removing it is the app's business.
        #expect(transport.payloads.readLivePreview() == left)
    }

    /// Should the file come to hold another dictation's words, none of them are shown: this
    /// dictation's own words go, and its layout stays.
    @Test func wordsOfAnotherDictationEmptyThisOnes() async throws {
        let listening = try await listen(previews: true)
        let (app, host, client, id) = (listening.app, listening.host, listening.client, listening.id)
        try app.say(id, "My own words")
        #expect(await waitUntil { client.livePreview?.settled == "My own words" })

        try app.say(UUID(), "Somebody else's words")
        #expect(await waitUntil { client.livePreview == LivePreview(requestId: id) })
        #expect(host.strayPreviews == 0)
    }

    /// The app removes the preview the moment the dictation ends, which the keyboard can hear
    /// of before it hears that the phase moved on. The words go at once; the screen keeps its
    /// layout (an empty preview, not none) for as long as it listens.
    @Test func theWordsGoWhenTheAppTakesThemAwayAndTheLayoutStays() async throws {
        let listening = try await listen(previews: true)
        let (app, client, id) = (listening.app, listening.client, listening.id)
        try app.say(id, "Words that are", " about to go")
        #expect(await waitUntil { client.livePreview?.text == "Words that are about to go" })

        app.takeWordsAway()
        #expect(await waitUntil { client.livePreview == LivePreview(requestId: id) })
        if case .listening(id, _) = client.phase {} else { Issue.record("expected .listening, got \(client.phase)") }

        // And what the app writes after that is shown again.
        try app.say(id, "And back")
        #expect(await waitUntil { client.livePreview?.settled == "And back" })
    }

    /// The words belong to the listening screen. However listening ends (✓, ✕, or the app ending
    /// the dictation itself), they are gone in the same change, whatever is still in the file.
    @Test func theWordsGoWhenListeningEnds() async throws {
        let stopped = try await listen(previews: true)
        try stopped.app.say(stopped.id, "Said before the check")
        #expect(await waitUntil { stopped.client.livePreview?.settled == "Said before the check" })
        stopped.client.stopTapped()
        #expect(stopped.client.livePreview == nil)
        #expect(stopped.client.phase == .processing(stopped.id))
        // A last write of the app's crossed the check: it brings nothing back.
        try stopped.app.say(stopped.id, "Said before the check", " and just after")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(stopped.client.livePreview == nil)
        #expect(stopped.host.strayPreviews == 0)

        let cancelled = try await listen(previews: true)
        try cancelled.app.say(cancelled.id, "Said before the cross")
        #expect(await waitUntil { cancelled.client.livePreview?.settled == "Said before the cross" })
        cancelled.client.cancelTapped()
        #expect(cancelled.client.livePreview == nil)
        #expect(cancelled.client.phase == .idle)
        #expect(cancelled.host.strayPreviews == 0)

        // The 5-minute cap, an interruption: the app ends it without the keyboard asking.
        let ended = try await listen(previews: true)
        try ended.app.say(ended.id, "Said before the cap")
        #expect(await waitUntil { ended.client.livePreview?.settled == "Said before the cap" })
        ended.app.publish(.processing, tag: ended.id.tag16)
        #expect(await waitUntil { ended.client.phase == .processing(ended.id) })
        #expect(ended.client.livePreview == nil)
        #expect(ended.host.strayPreviews == 0)
    }

    /// An app that was killed mid-dictation can't remove its preview. The keyboard that listens
    /// to that dictation does, when it notices that the app stopped answering, and only its own
    /// dictation's.
    @Test func aPreviewTheAppLeftBehindIsRemovedWhenItStopsAnswering() async throws {
        let notice = KeyboardSessionClient.Phase.notice("Murmur stopped listening. Tap the mic to start again.")

        let listening = try await listen(previews: true, staleAfter: 0.2)
        let (transport, app, client, id) = (listening.transport, listening.app, listening.client, listening.id)
        try app.say(id, "The last words it heard")
        #expect(await waitUntil {
            // Still answering until the words are on screen.
            app.publish(.recording, tag: id.tag16)
            return client.livePreview?.settled == "The last words it heard"
        })
        // From here the app publishes nothing more.
        #expect(await waitUntil { client.phase == notice })
        #expect(client.livePreview == nil)
        #expect(transport.payloads.readLivePreview() == nil)
        #expect(listening.host.strayPreviews == 0)

        // The file has become another dictation's: that one is not the keyboard's to remove.
        let other = try await listen(previews: true, staleAfter: 0.2)
        let foreign = LivePreview(requestId: UUID(), settled: "Not this dictation's")
        try other.transport.payloads.write(livePreview: foreign)
        #expect(await waitUntil { other.client.phase == notice })
        #expect(other.client.livePreview == nil)
        #expect(other.transport.payloads.readLivePreview() == foreign)
    }

    /// Darwin notifications can be lost, so the listening loop reads the preview once a second
    /// whether it was told or not.
    @Test func aMissedEventIsCaughtWithinASecond() async throws {
        // The read comes after twenty real ticks, which a busy machine stretches: the wait is long,
        // and the app, silent meanwhile, is not taken for gone.
        let listening = try await listen(previews: true, staleAfter: 60)
        let (app, client, id) = (listening.app, listening.client, listening.id)
        try app.say(id, "Said without a word to the keyboard", posts: false)
        #expect(client.livePreview == LivePreview(requestId: id))
        #expect(await waitUntil(timeout: .seconds(10)) {
            client.livePreview?.settled == "Said without a word to the keyboard"
        })
    }

    /// Off screen nothing shows the words, so the keyboard lets go of them and keeps only the
    /// layout. Coming back to the dictation reads what the app has by then, as soon as the app
    /// shows that it is still recording it.
    @Test func comingBackToADictationReadsItsWordsAgain() async throws {
        let listening = try await listen(previews: true)
        let (app, host, client, id) = (listening.app, listening.host, listening.client, listening.id)
        try app.say(id, "Before it left")
        #expect(await waitUntil { client.livePreview?.settled == "Before it left" })

        client.deactivate()
        #expect(client.livePreview == LivePreview(requestId: id))
        try app.say(id, "Before it left", " and while it was away")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.livePreview == LivePreview(requestId: id), "nothing is read while the keyboard is away")

        client.activate()
        #expect(client.livePreview == LivePreview(requestId: id), "the words wait for a sign of the app")
        app.publish(.recording, tag: id.tag16)
        #expect(await waitUntil(timeout: .milliseconds(500)) {
            client.livePreview?.text == "Before it left and while it was away"
        })
        #expect(host.strayPreviews == 0)
    }

    /// The app died while the keyboard was away: its state still says `recording` and its file
    /// still holds the words. The keyboard that comes back shows none of them, and removes the
    /// file when it notices that the app is gone.
    @Test func comingBackToADictationWhoseAppIsGoneShowsNoWords() async throws {
        let listening = try await listen(previews: true, staleAfter: 0.3)
        let (transport, app, host, client, id) =
            (listening.transport, listening.app, listening.host, listening.client, listening.id)
        try app.say(id, "The last words", " it heard")
        #expect(await waitUntil {
            app.publish(.recording, tag: id.tag16)
            return client.livePreview?.text == "The last words it heard"
        })
        client.deactivate()
        // From here the app publishes nothing more.

        var shown: Set<String> = []
        client.activate()
        if case .listening(id, _) = client.phase {} else { Issue.record("expected .listening, got \(client.phase)") }
        #expect(await waitUntil {
            if let text = client.livePreview?.text { shown.insert(text) }
            return client.phase == .notice("Murmur stopped listening. Tap the mic to start again.")
        })
        #expect(shown == [""], "words of a dictation whose app is gone were shown")
        #expect(transport.payloads.readLivePreview() == nil)
        #expect(host.strayPreviews == 0)

        // A keyboard that iOS relaunched meanwhile finds the same and shows as little.
        let again = try await listen(previews: true, staleAfter: 0.3)
        try again.app.say(again.id, "Words for a new keyboard")
        #expect(await waitUntil {
            again.app.publish(.recording, tag: again.id.tag16)
            return again.client.livePreview?.settled == "Words for a new keyboard"
        })
        again.client.deactivate()
        let relaunchedHost = FakeHost()
        let relaunched = KeyboardSessionClient(transport: again.transport, staleAfter: 0.3)
        relaunched.host = relaunchedHost
        relaunched.activate()
        if case .listening(again.id, _) = relaunched.phase {} else { Issue.record("expected .listening, got \(relaunched.phase)") }
        #expect(try #require(relaunchedHost.heardListening.first).preview == LivePreview(requestId: again.id))
        #expect(relaunched.livePreview == LivePreview(requestId: again.id))
        // The app is there after all: its words come with its next sign of life.
        again.app.publish(.recording, tag: again.id.tag16)
        #expect(await waitUntil(timeout: .milliseconds(500)) {
            relaunched.livePreview?.settled == "Words for a new keyboard"
        })
    }

    /// Whatever the keyboard's own copy holds when it comes back, none of it is shown until the
    /// app shows that it is there. Here the copy was filled again while away, by an event already
    /// on its way when the keyboard left (this transport still delivers it; libnotify drops one
    /// whose registration was cancelled), and the app never shows.
    @Test func wordsThatCameAsTheKeyboardLeftAreNotShownOnComingBack() async throws {
        let listening = try await listen(previews: true, staleAfter: 0.3)
        let (transport, app, host, client, id) =
            (listening.transport, listening.app, listening.host, listening.client, listening.id)
        try app.say(id, "The first words")
        #expect(await waitUntil {
            app.publish(.recording, tag: id.tag16)
            return client.livePreview?.settled == "The first words"
        })

        // Written and announced; the keyboard leaves before the event is delivered.
        try app.say(id, "The first words", " and the last it heard")
        client.deactivate()
        try? await Task.sleep(for: .milliseconds(60))
        // From here the app publishes nothing more.

        var shown: Set<String> = []
        client.activate()
        if case .listening(id, _) = client.phase {} else { Issue.record("expected .listening, got \(client.phase)") }
        #expect(await waitUntil {
            if let text = client.livePreview?.text { shown.insert(text) }
            return client.phase == .notice("Murmur stopped listening. Tap the mic to start again.")
        })
        #expect(shown == [""], "words of a dictation whose app is gone were shown")
        #expect(transport.payloads.readLivePreview() == nil)
        #expect(host.strayPreviews == 0)
    }

    /// The app can die a moment before ✓ or ✕, sooner than the keyboard could notice: the
    /// keyboard removes the preview of the dictation it stops following, and only that one's.
    @Test func thePreviewGoesWithTheCheckAndTheCrossEvenIfTheAppIsGone() async throws {
        let stopped = try await listen(previews: true)
        try stopped.app.say(stopped.id, "Said before the check")
        #expect(await waitUntil { stopped.client.livePreview?.settled == "Said before the check" })
        stopped.app.acknowledges = false   // gone: it answers nothing from here
        stopped.client.stopTapped()
        #expect(stopped.transport.payloads.readLivePreview() == nil)

        let cancelled = try await listen(previews: true)
        try cancelled.app.say(cancelled.id, "Said before the cross")
        #expect(await waitUntil { cancelled.client.livePreview?.settled == "Said before the cross" })
        cancelled.app.acknowledges = false
        cancelled.client.cancelTapped()
        #expect(cancelled.transport.payloads.readLivePreview() == nil)

        // Another dictation's file is not the keyboard's to remove.
        let other = try await listen(previews: true)
        let foreign = LivePreview(requestId: UUID(), settled: "Not this dictation's")
        try other.transport.payloads.write(livePreview: foreign)
        other.client.stopTapped()
        #expect(other.transport.payloads.readLivePreview() == foreign)
    }

    /// The app learns that the week's words are used up while a dictation is still listened to:
    /// from then on the keyboard shows none of its words.
    @Test func noWordsAreShownWhileTheWeeksWordsAreUsedUp() async throws {
        var usedUp = false
        let listening = try await listen(previews: true, wordsUsedUp: { usedUp })
        let (app, client, id) = (listening.app, listening.client, listening.id)
        try app.say(id, "Words within the week's")
        #expect(await waitUntil { client.livePreview?.settled == "Words within the week's" })

        usedUp = true
        try app.say(id, "Words within the week's", " and words past them")
        #expect(await waitUntil { client.livePreview == LivePreview(requestId: id) })
        try app.say(id, "Words within the week's and words past them", " and more")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.livePreview == LivePreview(requestId: id))
    }

    /// The words on screen are only a picture of what was heard. When the server refuses the
    /// dictation for the week's words, none of them is typed or offered, though the keyboard had
    /// them and their file is still there.
    @Test func thePreviewIsNeverInserted() async throws {
        let listening = try await listen(previews: true)
        let (transport, app, host, client, id) =
            (listening.transport, listening.app, listening.host, listening.client, listening.id)
        try app.say(id, "words heard on the iPhone", " and shown")
        #expect(await waitUntil { client.livePreview?.text == "words heard on the iPhone and shown" })

        client.stopTapped()
        // The app's last write crossed the check, so the file is there again.
        try app.say(id, "words heard on the iPhone", " and shown")
        try app.finish(id, text: "words heard on the iPhone and shown", document: host.currentDocumentIdentifier,
                       status: .limitReached, message: Brand.limitReachedMessage)
        #expect(await waitUntil { client.phase == .notice(Brand.limitReachedMessage) })
        #expect(host.inserted.isEmpty)
        #expect(client.pendingResult == nil)
        #expect(client.livePreview == nil)

        // Nor later, when the events come again.
        transport.post(.livePreview)
        transport.post(.resultReady)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(transport.payloads.readLivePreview()?.requestId == id)
        #expect(host.inserted.isEmpty)
        #expect(client.pendingResult == nil)
        #expect(client.livePreview == nil)
    }

    /// The keyboard opened the app for the dictation, and the app was recording it (words and all)
    /// before the keyboard came back. `recording` may by then be what an app that died left behind,
    /// so the keyboard that joins the dictation lays out for words and shows none until the app's
    /// state moves on.
    @Test func aDictationJoinedAfterTheBounceShowsItsWordsOnceTheAppShowsLife() async throws {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport, staleAfter: 0.4)
        client.host = host
        client.activate()
        client.micTapped()
        guard case .openingApp(let requestId) = client.phase else { Issue.record("no openingApp"); return }
        client.deactivate()
        try transport.payloads.write(livePreview: LivePreview(requestId: requestId, settled: "said in the app"))
        #expect(try #require(app.autoStart()) == requestId)

        client.activate()
        #expect(client.livePreview == LivePreview(requestId: requestId))
        #expect(try #require(host.heardListening.first).preview == LivePreview(requestId: requestId))

        app.publish(.recording, tag: requestId.tag16)
        #expect(await waitUntil(timeout: .milliseconds(500)) { client.livePreview?.settled == "said in the app" })
    }
}
