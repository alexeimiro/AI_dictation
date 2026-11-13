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

    func openContainingApp(_ url: URL) { openedURLs.append(url) }
    func insertDictation(_ result: DictationResult) { inserted.append(result) }
    func dictationDidFinish(_ outcome: DictationOutcome) { outcomes.append(outcome) }
    func sessionClientDidChange(_ client: KeyboardSessionClient) {}
}

/// Plays the app's side of the protocol.
@MainActor
private final class FakeApp {
    let transport: IPCTransport
    var sequence: UInt32 = 1
    var acknowledges = true
    /// Finishing a previous dictation: a start is queued and acknowledged as `starting`.
    var busy = false
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

    private func handleCommand() {
        guard acknowledges, let command = transport.payloads.readCommand() else { return }
        switch command.kind {
        case .start where busy:
            queued = command.requestId
            publish(.starting, tag: command.requestId.tag16)
        case .start: publish(.recording, tag: command.requestId.tag16)
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
}
