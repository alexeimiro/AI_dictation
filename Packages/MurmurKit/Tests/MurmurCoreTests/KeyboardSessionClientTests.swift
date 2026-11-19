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
    /// With "Type as I speak": the engine, and the field the keyboard hands it.
    var liveTyping: LiveTyping?
    var field: FakeTextField?

    func openContainingApp(_ url: URL) { openedURLs.append(url) }

    /// As the keyboard does it: the final text replaces the words typed live, or goes in at the
    /// cursor.
    func insertDictation(_ result: DictationResult) {
        inserted.append(result)
        guard let field, liveTyping?.place(result) == nil else { return }
        field.insertText(TextJoiner.prepare(result.text, traits: InsertionTraits(
            contextBefore: field.contextBeforeCursor, singleLine: field.isSingleLine, language: result.language)))
    }
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

/// A keyboard with "Type as I speak" that listens to a dictation in `field`.
@MainActor
private struct TypingLive {
    let transport: InMemoryIPCTransport
    let app: FakeApp
    let host: FakeHost
    let client: KeyboardSessionClient
    let typing: LiveTyping
    let field: FakeTextField
    let id: UUID

    var record: LiveTypedRecord? { transport.payloads.readLiveTyped() }
}

/// A keyboard with "Type as I speak" over `field`, its session `live` or not, before any tap.
@MainActor
private func typingKeyboard(
    _ field: FakeTextField, on transport: InMemoryIPCTransport = InMemoryIPCTransport(), live: Bool = true,
    enabled: @escaping () -> Bool = { true }, resultTimeout: Duration = .seconds(20), staleAfter: TimeInterval = 2.5,
    wordsUsedUp: @escaping () -> Bool = { false }
) -> (app: FakeApp, host: FakeHost, client: KeyboardSessionClient, typing: LiveTyping) {
    let app = FakeApp(transport: transport)
    app.previews = true
    let typing = LiveTyping(store: transport.payloads, isEnabled: enabled)
    typing.field = field
    let host = FakeHost()
    host.liveTyping = typing
    host.field = field
    let client = KeyboardSessionClient(transport: transport, resultTimeout: resultTimeout, staleAfter: staleAfter,
                                       wordsUsedUp: wordsUsedUp, liveTyping: typing)
    client.host = host
    if live { app.publish(.ready) }
    client.activate()
    return (app, host, client, typing)
}

/// Taps the mic on a live session, with "Type as I speak", and waits until the keyboard listens.
/// `before` runs between making the keyboard and the tap.
@MainActor
private func typeLive(
    into field: FakeTextField = FakeTextField(), enabled: @escaping () -> Bool = { true },
    resultTimeout: Duration = .seconds(20), staleAfter: TimeInterval = 2.5,
    wordsUsedUp: @escaping () -> Bool = { false }, before: (KeyboardSessionClient) -> Void = { _ in }
) async throws -> TypingLive {
    let transport = InMemoryIPCTransport()
    let (app, host, client, typing) = typingKeyboard(
        field, on: transport, enabled: enabled, resultTimeout: resultTimeout, staleAfter: staleAfter,
        wordsUsedUp: wordsUsedUp)
    before(client)
    client.micTapped()
    #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
    let id: UUID? = if case .listening(let id, _) = client.phase { id } else { nil }
    return TypingLive(transport: transport, app: app, host: host, client: client, typing: typing, field: field,
                      id: try #require(id))
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

    /// The words on screen are only a picture of what was heard: without "Type as I speak" none
    /// of them reaches the field. When the server refuses the dictation for the week's words,
    /// none of them is typed or offered, though the keyboard had them and their file is still
    /// there. (With "Type as I speak" the settled ones are typed, and taken out again then:
    /// `wordsTypedLiveGoWhenTheDictationEndsWithNothing`.)
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

    // MARK: Type as I speak

    /// With "Type as I speak", a dictation that began on the tap itself has its settled words
    /// typed into the field as the app publishes them, and its final text replaces them: the
    /// field ends as it would have without the feature.
    @Test func theSettledWordsAreTypedAndTheFinalTextReplacesThem() async throws {
        let live = try await typeLive(into: FakeTextField("Dear Anna, ", after: "\nBest, A."))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        #expect(live.typing.isTyping(id))
        #expect(field.text == "Dear Anna, \nBest, A.")

        try app.say(id, "", "so i")
        try app.say(id, "so i was thinking", " we could")
        #expect(await waitUntil { field.text == "Dear Anna, so i was thinking\nBest, A." })
        #expect(client.livePreview?.unsettled == " we could", "the newest words stay on the keyboard")
        #expect(live.typing.typedRequestId == id)
        try app.say(id, "so i was thinking we could meet", " on thursday")
        #expect(await waitUntil { field.text == "Dear Anna, so i was thinking we could meet\nBest, A." })
        #expect(live.record?.typed == "so i was thinking we could meet")

        client.stopTapped()
        #expect(field.text == "Dear Anna, so i was thinking we could meet\nBest, A.", "the words wait for the text")
        try app.finish(id, text: "So I was thinking we could meet on Thursday.",
                       document: host.currentDocumentIdentifier)
        #expect(await waitUntil { host.inserted.count == 1 })
        // Joined as any dictation is: after the comma, "So" loses its capital.
        #expect(field.text == "Dear Anna, so I was thinking we could meet on Thursday.\nBest, A.")
        // Every typed character went and the whole text came, in one insertion.
        #expect(field.deletions == "so i was thinking we could meet".count)
        #expect(field.insertions.last == "so I was thinking we could meet on Thursday.")
        #expect(client.pendingResult == nil)
        #expect(client.phase == .idle)
        #expect(host.outcomes == [.ready])
        #expect(live.record == nil)
        #expect(live.typing.typedRequestId == nil)

        // Nothing comes twice.
        live.transport.post(.resultReady)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(host.inserted.count == 1)
        #expect(field.text == "Dear Anna, so I was thinking we could meet on Thursday.\nBest, A.")
    }

    /// The switch is off, or the plan is Basic: the keyboard has the engine all the same, and a
    /// dictation goes as it always did. Nothing reaches the field until the final text.
    @Test func withTypeAsISpeakOffNothingIsTypedUntilTheEnd() async throws {
        var enabled = false
        let live = try await typeLive(into: FakeTextField("Hi. "), enabled: { enabled })
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        #expect(!live.typing.isTyping(id))
        // Turned on in Settings meanwhile: it counts from the next dictation.
        enabled = true
        try app.say(id, "so i was thinking", " we could")
        #expect(await waitUntil { client.livePreview?.settled == "so i was thinking" })
        #expect(field.text == "Hi. ")
        #expect(live.record == nil)

        client.stopTapped()
        try app.finish(id, text: "So I was thinking.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(field.text == "Hi. So I was thinking.")
        #expect(field.insertions == ["So I was thinking."])
        #expect(field.deletions == 0)
    }

    /// Translate's words on the keyboard are in the language spoken, not the one the text will
    /// be in: they are never typed.
    @Test func aTranslationIsNeverTypedLive() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "), before: { $0.translationTargetLanguage = "tr-TR" })
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "so i was thinking", " we could")
        #expect(await waitUntil { client.livePreview?.settled == "so i was thinking" })
        #expect(field.text == "Hi. ")
        #expect(!live.typing.isTyping(id))

        client.stopTapped()
        try app.finish(id, text: "Düşünüyordum.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(field.text == "Hi. Düşünüyordum.")
    }

    /// The words are joined, while they are typed, by the rules of the language the dictation is
    /// in. That is the primary language while the keyboard's pill shows it, which is the usual
    /// case and leaves the override nil.
    @Test func theSpokenLanguageJoinsTheTypedWords() async throws {
        let live = try await typeLive(into: FakeTextField("Привет,"), before: { $0.primaryLanguage = "ru-RU" })
        try live.app.say(live.id, "Я думаю")
        #expect(await waitUntil { live.field.text == "Привет, я думаю" })
        #expect(live.record?.language == "ru-RU")

        // Auto-detect names no language until the text comes: the primary one's rules, too.
        let automatic = try await typeLive(into: FakeTextField("Привет,"), before: {
            $0.primaryLanguage = "ru-RU"
            $0.languageOverride = DictationLanguage.automatic.tag
        })
        try automatic.app.say(automatic.id, "Я думаю")
        #expect(await waitUntil { automatic.field.text == "Привет, я думаю" })
        #expect(automatic.record?.language == "ru-RU")

        // Another language picked in the pill is the one.
        let picked = try await typeLive(into: FakeTextField("Привет,"), before: {
            $0.primaryLanguage = "ru-RU"
            $0.languageOverride = "en-US"
        })
        try picked.app.say(picked.id, "Я думаю")
        #expect(await waitUntil { picked.field.text == "Привет, Я думаю" })
        #expect(picked.record?.language == "en-US")
    }

    /// The cross discards the dictation, and with it the words that were typed as it was said.
    @Test func theCrossTakesTheTypedWordsOut() async throws {
        let listening = try await typeLive(into: FakeTextField("Dear Anna,", after: "\nBest, A."))
        try listening.app.say(listening.id, "I will be late", " today")
        #expect(await waitUntil { listening.field.text == "Dear Anna, I will be late\nBest, A." })
        listening.client.cancelTapped()
        #expect(listening.field.text == "Dear Anna,\nBest, A.")
        #expect(listening.record == nil)
        #expect(listening.typing.typedRequestId == nil)
        #expect(listening.client.phase == .idle)
        // The app's last words crossed the cross: they bring nothing back.
        try listening.app.say(listening.id, "I will be late today")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(listening.field.text == "Dear Anna,\nBest, A.")

        // While the text is being written, too.
        let processing = try await typeLive(into: FakeTextField("Dear Anna,"))
        try processing.app.say(processing.id, "I will be late")
        #expect(await waitUntil { processing.field.text == "Dear Anna, I will be late" })
        processing.client.stopTapped()
        processing.client.cancelTapped()
        #expect(processing.field.text == "Dear Anna,")
        #expect(processing.record == nil)
        #expect(processing.host.inserted.isEmpty)
    }

    /// A dictation that ends with nothing to insert (nothing was recognized after all, it failed,
    /// or the server refused it for the week's words) leaves nothing: the words typed live go.
    @Test func wordsTypedLiveGoWhenTheDictationEndsWithNothing() async throws {
        let empty = try await typeLive(into: FakeTextField("Hi. "))
        try empty.app.say(empty.id, "um")
        #expect(await waitUntil { empty.field.text == "Hi. um" })
        empty.client.stopTapped()
        try empty.app.finish(empty.id, text: "", document: empty.host.currentDocumentIdentifier, status: .empty,
                             message: "We didn't catch anything")
        #expect(await waitUntil { empty.client.phase == .notice("We didn't catch anything") })
        #expect(empty.field.text == "Hi. ")
        #expect(empty.record == nil)
        #expect(empty.host.inserted.isEmpty)
        #expect(empty.host.outcomes == [.problem])

        let refused = try await typeLive(into: FakeTextField("Hi. "))
        try refused.app.say(refused.id, "words heard on the iPhone", " and shown")
        #expect(await waitUntil { refused.field.text == "Hi. words heard on the iPhone" })
        refused.client.stopTapped()
        try refused.app.finish(refused.id, text: "words heard on the iPhone and shown",
                               document: refused.host.currentDocumentIdentifier, status: .limitReached,
                               message: Brand.limitReachedMessage)
        #expect(await waitUntil { refused.client.phase == .notice(Brand.limitReachedMessage) })
        #expect(refused.field.text == "Hi. ")
        #expect(refused.record == nil)
        #expect(refused.host.inserted.isEmpty)
        #expect(refused.client.pendingResult == nil)
    }

    /// The user moved the cursor while speaking: no more words are typed, and the final text is
    /// not put beside the raw ones unasked. It waits as "Insert last dictation", and the tap on
    /// that replaces the words once the cursor is back after them.
    @Test func aFieldThatChangedHoldsTheFinalTextAsTheCard() async throws {
        let live = try await typeLive(into: FakeTextField("Dear Anna, "))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "I will be late")
        #expect(await waitUntil { field.text == "Dear Anna, I will be late" })
        field.moveCursor(to: 4)
        try app.say(id, "I will be late today")
        #expect(await waitUntil { client.livePreview?.settled == "I will be late today" })
        #expect(field.text == "Dear Anna, I will be late")
        #expect(!live.typing.isTyping(id))

        client.stopTapped()
        try app.finish(id, text: "I'll be late today.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { client.pendingResult?.requestId == id })
        #expect(host.inserted.isEmpty)
        #expect(field.text == "Dear Anna, I will be late")
        #expect(host.outcomes == [.ready])
        #expect(live.record?.typed == "I will be late", "the record stays for the card")
        #expect(!live.transport.payloads.isClaimed(id))

        field.moveCursorToEnd()
        client.insertPendingResult()
        #expect(host.inserted.count == 1)
        #expect(field.text == "Dear Anna, I'll be late today.")
        #expect(live.record == nil)
        #expect(client.pendingResult == nil)
    }

    /// The card tapped with the cursor somewhere else puts the text there, as it does for any
    /// dictation; the raw words stay where they are, as text.
    @Test func theCardTappedElsewhereInsertsAtTheCursor() async throws {
        let live = try await typeLive(into: FakeTextField("Dear Anna, "))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "I will be late")
        #expect(await waitUntil { field.text == "Dear Anna, I will be late" })
        field.moveCursor(to: "Dear Anna,".count)
        client.stopTapped()
        try app.finish(id, text: "I'll be late today.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { client.pendingResult?.requestId == id })
        #expect(host.inserted.isEmpty)

        client.insertPendingResult()
        #expect(host.inserted.count == 1)
        #expect(field.text == "Dear Anna, I'll be late today. I will be late")
        #expect(live.record == nil)
        #expect(live.typing.typedRequestId == nil)
    }

    /// The focus moved to another field while the text was written: the result is held, as it
    /// always was, and the words typed live stay in the field they are in until the user asks.
    @Test func aResultForAnotherFieldIsHeldWithItsTypedWords() async throws {
        let live = try await typeLive(into: FakeTextField("Dear Anna, "))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        let tappedIn = host.currentDocumentIdentifier
        try app.say(id, "I will be late")
        #expect(await waitUntil { field.text == "Dear Anna, I will be late" })
        client.stopTapped()

        host.currentDocumentIdentifier = UUID()
        field.focusElsewhere("Subject: ")
        try app.finish(id, text: "I'll be late today.", document: tappedIn)
        #expect(await waitUntil { client.pendingResult?.requestId == id })
        #expect(host.inserted.isEmpty)
        #expect(field.text == "Subject: ")
        #expect(field.deletions == 0)
        #expect(live.record?.typed == "I will be late")

        client.insertPendingResult()
        #expect(host.inserted.count == 1)
        #expect(field.text == "Subject: I'll be late today.")
        #expect(live.record == nil)
    }

    /// The focus moved to another field before the first word settled: nothing is typed there,
    /// where the final text wouldn't go unasked either.
    @Test func wordsAreNotTypedIntoAnotherFieldThanTheOneTapped() async throws {
        let live = try await typeLive(into: FakeTextField("Dear Anna, "))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        #expect(live.typing.isTyping(id))
        host.currentDocumentIdentifier = UUID()
        field.focusElsewhere("Subject: ")
        try app.say(id, "I will be late")
        #expect(await waitUntil { client.livePreview?.settled == "I will be late" })
        #expect(field.text == "Subject: ")
        #expect(!live.typing.isTyping(id))
        #expect(live.record == nil)
    }

    /// The keyboard opened the app for the dictation, and the app was recording before the
    /// keyboard came back: its words are shown, and never typed. The final text goes in as ever.
    @Test func aDictationTheAppWasOpenedForIsNeverTypedLive() async throws {
        let transport = InMemoryIPCTransport()
        let field = FakeTextField("Hi. ")
        let (app, host, client, typing) = typingKeyboard(field, on: transport, live: false)
        client.micTapped()
        guard case .openingApp(let requestId) = client.phase else { Issue.record("no openingApp"); return }
        client.deactivate()
        try transport.payloads.write(livePreview: LivePreview(requestId: requestId, settled: "said in the app"))
        #expect(try #require(app.autoStart()) == requestId)

        client.activate()
        app.publish(.recording, tag: requestId.tag16)
        #expect(await waitUntil { client.livePreview?.settled == "said in the app" })
        try app.say(requestId, "said in the app and after", " coming back")
        #expect(await waitUntil { client.livePreview?.settled == "said in the app and after" })
        #expect(field.text == "Hi. ")
        #expect(!typing.isTyping(requestId))
        #expect(transport.payloads.readLiveTyped() == nil)

        client.stopTapped()
        try app.finish(requestId, text: "Said in the app and after coming back.", document: nil)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(field.text == "Hi. Said in the app and after coming back.")
        #expect(field.deletions == 0)

        // Nor one the app hadn't started yet, which the keyboard starts itself once it is back.
        let later = InMemoryIPCTransport()
        let laterField = FakeTextField("Hi. ")
        let waiting = typingKeyboard(laterField, on: later, live: false)
        waiting.client.micTapped()
        guard case .openingApp(let laterId) = waiting.client.phase else { Issue.record("no openingApp"); return }
        waiting.client.deactivate()
        waiting.app.publish(.ready)
        waiting.client.activate()
        #expect(await waitUntil { waiting.client.phase.isListening(to: laterId) })
        #expect(waiting.client.livePreview != nil)
        try waiting.app.say(laterId, "said after the trip")
        #expect(await waitUntil { waiting.client.livePreview?.settled == "said after the trip" })
        #expect(laterField.text == "Hi. ")
        #expect(!waiting.typing.isTyping(laterId))
    }

    /// The keyboard left the screen and came back to the dictation: what it had typed stays, no
    /// more is typed, and the final text replaces what is there.
    @Test func aDictationComeBackToTypesNoMore() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "so i was")
        #expect(await waitUntil { field.text == "Hi. so i was" })

        client.deactivate()
        #expect(!live.typing.isTyping(id))
        #expect(live.record?.frozen == true)
        try app.say(id, "so i was thinking", " while away")
        client.activate()
        app.publish(.recording, tag: id.tag16)
        #expect(await waitUntil { client.livePreview?.settled == "so i was thinking" })
        try app.say(id, "so i was thinking we could", " meet")
        #expect(await waitUntil { client.livePreview?.settled == "so i was thinking we could" })
        #expect(field.text == "Hi. so i was")
        #expect(live.typing.typedRequestId == id)

        client.stopTapped()
        try app.finish(id, text: "So I was thinking we could meet.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(field.text == "Hi. So I was thinking we could meet.")
        #expect(live.record == nil)
    }

    /// iOS ended the keyboard while it was away and made a new one: it follows the dictation,
    /// types nothing, and still replaces what the first one typed, which it finds in the record.
    @Test func aKeyboardRelaunchedMidDictationReplacesWhatTheFirstTyped() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "))
        let (transport, app, field, id) = (live.transport, live.app, live.field, live.id)
        try app.say(id, "so i was")
        #expect(await waitUntil { field.text == "Hi. so i was" })
        live.client.deactivate()

        let typing = LiveTyping(store: transport.payloads, isEnabled: { true })
        typing.field = field
        let host = FakeHost()
        host.liveTyping = typing
        host.field = field
        let relaunched = KeyboardSessionClient(transport: transport, liveTyping: typing)
        relaunched.host = host
        relaunched.activate()
        #expect(relaunched.phase.isListening(to: id))
        #expect(typing.typedRequestId == id)
        app.publish(.recording, tag: id.tag16)
        try app.say(id, "so i was thinking", " we could")
        #expect(await waitUntil { relaunched.livePreview?.settled == "so i was thinking" })
        #expect(field.text == "Hi. so i was")
        #expect(!typing.isTyping(id))

        relaunched.stopTapped()
        try app.finish(id, text: "So I was thinking we could.", document: UUID())
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(field.text == "Hi. So I was thinking we could.")
        #expect(transport.payloads.readLiveTyped() == nil)
    }

    /// The app can take its words away and write them again (a write of its own that crossed a
    /// removal). The keyboard's empty stand-in for them is not the dictation starting over: the
    /// typing goes on.
    @Test func wordsTakenAwayAndWrittenAgainGoOnBeingTyped() async throws {
        let live = try await typeLive(into: FakeTextField())
        let (app, client, field, id) = (live.app, live.client, live.field, live.id)
        try app.say(id, "One two")
        #expect(await waitUntil { field.text == "One two" })
        app.takeWordsAway()
        #expect(await waitUntil { client.livePreview == LivePreview(requestId: id) })
        #expect(live.typing.isTyping(id))
        try app.say(id, "One two three")
        #expect(await waitUntil { field.text == "One two three" })
        #expect(field.insertions == ["One two", " three"])
    }

    /// No result came (the app is gone, or the text is taking too long): the typed words stay
    /// and so does their record, so the text that arrives late, as "Insert last dictation",
    /// still replaces them.
    @Test func aLateResultStillReplacesTheTypedWords() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "), resultTimeout: .milliseconds(300))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "so i was thinking")
        #expect(await waitUntil { field.text == "Hi. so i was thinking" })
        client.stopTapped()
        #expect(await waitUntil { if case .notice = client.phase { true } else { false } })
        #expect(field.text == "Hi. so i was thinking")
        #expect(live.record?.typed == "so i was thinking")

        try app.finish(id, text: "So I was thinking.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { client.pendingResult?.requestId == id })
        #expect(field.text == "Hi. so i was thinking")
        client.insertPendingResult()
        #expect(field.text == "Hi. So I was thinking.")
        #expect(live.record == nil)
    }

    /// A web page's field hands the keyboard only the end of the text before the cursor. The
    /// person cut a word out of the raw words while the text was written, and what is handed over
    /// still reads as the typed words end. That confirms nothing of the rest: a replacement
    /// would delete as many characters as were typed and take the person's own text with them.
    /// The text waits as the card, whose tap puts it in at the cursor and leaves the raw words;
    /// and neither the cross nor a dictation that ends with nothing deletes anything there.
    @Test func whereOnlyTheEndOfTheTypedWordsShowsNothingIsReplacedOrRemoved() async throws {
        let edited = "Dear Anna, So I was we could meet tomorrow at ten"
        func typedThenEdited() async throws -> TypingLive {
            let live = try await typeLive(into: FakeTextField("Dear Anna, "))
            try live.app.say(live.id, "So I was thinking we could meet tomorrow at ten")
            #expect(await waitUntil { live.record?.typed.count == 47 })
            live.client.stopTapped()
            live.field.contextWindow = 25
            live.field.focusElsewhere(edited)
            #expect(live.field.contextBeforeCursor == "ould meet tomorrow at ten")
            return live
        }

        let live = try await typedThenEdited()
        try live.app.finish(live.id, text: "I was thinking we could meet tomorrow at 10.",
                            document: live.host.currentDocumentIdentifier)
        #expect(await waitUntil { live.client.pendingResult?.requestId == live.id })
        #expect(live.host.inserted.isEmpty)
        #expect(live.field.text == edited)
        #expect(live.field.deletions == 0)
        #expect(live.record?.typed.count == 47, "the record stays for the card")
        // The tap on the card: 47 deletions would take "ar Anna, " with the 38 characters left.
        live.client.insertPendingResult()
        #expect(live.host.inserted.count == 1)
        #expect(live.field.deletions == 0)
        #expect(live.field.text == edited + " I was thinking we could meet tomorrow at 10.")
        #expect(live.record == nil)
        #expect(live.typing.typedRequestId == nil)

        let crossed = try await typedThenEdited()
        crossed.client.cancelTapped()
        #expect(crossed.field.text == edited)
        #expect(crossed.field.deletions == 0)
        #expect(crossed.record == nil)

        let failed = try await typedThenEdited()
        try failed.app.finish(failed.id, text: "", document: failed.host.currentDocumentIdentifier, status: .failed,
                              message: "Something went wrong")
        #expect(await waitUntil { failed.client.phase == .notice("Something went wrong") })
        #expect(failed.field.text == edited)
        #expect(failed.field.deletions == 0)
        #expect(failed.record == nil)
    }

    /// The keyboard left the screen while it listened and came back in another field, whose text
    /// happens to end as the typed words do. A dictation come back to goes into whichever field
    /// is focused, but its typed words are not there to be replaced: nothing is deleted, and the
    /// text waits as the card.
    @Test func inAnotherFieldThatEndsAsTheTypedWordsDoNothingIsReplacedUnasked() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "see you at ten")
        #expect(await waitUntil { field.text == "Hi. see you at ten" })

        client.deactivate()
        host.currentDocumentIdentifier = UUID()
        field.focusElsewhere("ten")
        client.activate()
        app.publish(.recording, tag: id.tag16)
        #expect(client.phase.isListening(to: id))
        client.stopTapped()
        try app.finish(id, text: "See you at 10.", document: UUID())
        #expect(await waitUntil { client.pendingResult?.requestId == id })
        #expect(host.inserted.isEmpty)
        #expect(field.text == "ten")
        #expect(field.deletions == 0)
    }

    /// A dictation that ends with nothing to insert takes its typed words out also when no
    /// keyboard was waiting for it: iOS made the keyboard anew while the text was written.
    @Test func aKeyboardMadeAgainTakesOutTheWordsOfADictationThatEndedWithNothing() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "))
        let (transport, app, field, id) = (live.transport, live.app, live.field, live.id)
        try app.say(id, "so i was")
        #expect(await waitUntil { field.text == "Hi. so i was" })
        live.client.stopTapped()
        live.client.deactivate()

        let typing = LiveTyping(store: transport.payloads, isEnabled: { true })
        typing.field = field
        let host = FakeHost()
        host.liveTyping = typing
        host.field = field
        let again = KeyboardSessionClient(transport: transport, liveTyping: typing)
        again.host = host
        again.activate()
        #expect(again.phase == .idle, "it waits for nothing")
        #expect(field.text == "Hi. so i was")

        try app.finish(id, text: "", document: nil, status: .limitReached, message: Brand.limitReachedMessage)
        #expect(await waitUntil { field.text == "Hi. " })
        #expect(field.deletions == "so i was".count)
        #expect(transport.payloads.readLiveTyped() == nil)
        #expect(typing.typedRequestId == nil)
        #expect(transport.payloads.isClaimed(id))
        #expect(host.inserted.isEmpty)
        #expect(again.pendingResult == nil)
        // And says why, as a keyboard that waited would.
        #expect(again.phase == .notice(Brand.limitReachedMessage))
        #expect(host.outcomes == [.problem])
    }

    /// Only while that result is recent. A keyboard that first comes up long after finds the
    /// words where they were left: they have been the person's text since (of a failed dictation
    /// the only copy), and nothing takes them out unasked. Their record goes.
    @Test func wordsOfADictationThatEndedWithNothingLongAgoStayAsText() async throws {
        func madeAgain(resultAge: TimeInterval) async throws -> (field: FakeTextField, typing: LiveTyping, live: TypingLive) {
            let live = try await typeLive(into: FakeTextField("Hi. "))
            try live.app.say(live.id, "so i was thinking")
            #expect(await waitUntil { live.field.text == "Hi. so i was thinking" })
            live.client.stopTapped()
            live.client.deactivate()
            // It failed while no keyboard was up.
            try live.transport.payloads.write(result: DictationResult(
                requestId: live.id, documentIdentifier: nil, text: "", status: .failed,
                message: "Something went wrong", createdAt: Date().addingTimeInterval(-resultAge)))

            let typing = LiveTyping(store: live.transport.payloads, isEnabled: { true })
            typing.field = live.field
            let host = FakeHost()
            host.liveTyping = typing
            host.field = live.field
            let again = KeyboardSessionClient(transport: live.transport, liveTyping: typing)
            again.host = host
            again.activate()
            return (live.field, typing, live)
        }

        // Two days on.
        let old = try await madeAgain(resultAge: 2 * 86_400)
        #expect(old.field.text == "Hi. so i was thinking")
        #expect(old.field.deletions == 0)
        #expect(old.live.record == nil)
        #expect(old.typing.typedRequestId == nil)
        #expect(old.live.transport.payloads.isClaimed(old.live.id))

        // Within the time a dictation that ended while the keyboard was away is still offered.
        let recent = try await madeAgain(resultAge: KeyboardSessionClient.awayInsertWindow - 60)
        #expect(recent.field.text == "Hi. ")
        #expect(recent.field.deletions == "so i was thinking".count)
        #expect(recent.live.record == nil)
    }

    /// The same ten minutes hold for the keyboard that was still waiting when it left the screen:
    /// whether iOS kept that keyboard or made a new one decides nothing.
    @Test func theKeyboardThatWaitedLeavesWordsOfADictationThatEndedLongAgo() async throws {
        func backAfter(resultAge: TimeInterval, whileListening: Bool) async throws -> TypingLive {
            let live = try await typeLive(into: FakeTextField("Hi. "))
            try live.app.say(live.id, "so i was thinking")
            #expect(await waitUntil { live.field.text == "Hi. so i was thinking" })
            if !whileListening { live.client.stopTapped() }
            live.client.deactivate()
            try live.transport.payloads.write(result: DictationResult(
                requestId: live.id, documentIdentifier: nil, text: "", status: whileListening ? .empty : .failed,
                message: "Something went wrong", createdAt: Date().addingTimeInterval(-resultAge)))
            if whileListening { live.app.publish(.ready) }
            live.client.activate()
            #expect(await waitUntil { live.record == nil })
            return live
        }

        for whileListening in [false, true] {
            // Fifteen minutes on: the words have been the person's text since.
            let old = try await backAfter(resultAge: 900, whileListening: whileListening)
            #expect(old.field.text == "Hi. so i was thinking")
            #expect(old.field.deletions == 0)
            #expect(old.typing.typedRequestId == nil)

            let recent = try await backAfter(resultAge: KeyboardSessionClient.awayInsertWindow - 60,
                                             whileListening: whileListening)
            #expect(recent.field.text == "Hi. ")
            #expect(recent.field.deletions == "so i was thinking".count)
        }
    }

    /// A keyboard at rest says nothing of a result that old: no message of a dictation from days
    /// ago as it comes up, in whatever app. One still showing that the dictation "will be saved"
    /// has that notice replaced at any age.
    @Test func aKeyboardAtRestSaysNothingOfAResultFromLongAgo() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "))
        try live.app.say(live.id, "so i was thinking")
        #expect(await waitUntil { live.field.text == "Hi. so i was thinking" })
        live.client.stopTapped()
        live.client.deactivate()
        try live.transport.payloads.write(result: DictationResult(
            requestId: live.id, documentIdentifier: nil, text: "", status: .limitReached,
            message: Brand.limitReachedMessage, createdAt: Date().addingTimeInterval(-2 * 86_400)))

        // Another app's field, two days on.
        let other = FakeTextField("Shopping list: ")
        let typing = LiveTyping(store: live.transport.payloads, isEnabled: { true })
        typing.field = other
        let host = FakeHost()
        host.liveTyping = typing
        host.field = other
        let again = KeyboardSessionClient(transport: live.transport, liveTyping: typing)
        again.host = host
        again.activate()

        #expect(again.phase == .idle)
        #expect(host.outcomes.isEmpty)
        #expect(other.text == "Shopping list: ")
        #expect(live.record == nil)
        #expect(live.transport.payloads.isClaimed(live.id))
    }

    /// Reconnect and the Full Access page are not a keyboard at rest: the words go, and what the
    /// keyboard shows stays.
    @Test func aResultWithNothingToInsertLeavesReconnectStanding() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "), resultTimeout: .milliseconds(300))
        try live.app.say(live.id, "so i was thinking")
        #expect(await waitUntil { live.field.text == "Hi. so i was thinking" })
        live.client.stopTapped()
        #expect(await waitUntil { if case .notice = live.client.phase { true } else { false } })
        live.client.dismissNotice()
        live.app.publish(.needsReconnect)
        #expect(await waitUntil { live.client.phase == .needsReconnect })
        try live.transport.payloads.write(result: DictationResult(
            requestId: live.id, documentIdentifier: nil, text: "", status: .failed,
            message: "Something went wrong", createdAt: Date()))
        live.transport.post(.resultReady)
        #expect(await waitUntil { live.record == nil })

        #expect(live.field.text == "Hi. ")
        #expect(live.client.phase == .needsReconnect)
        #expect(live.host.outcomes == [.problem])
    }

    /// Or when the keyboard had stopped waiting: the text took longer than the notice, and then
    /// there was nothing to insert. Only words that all still show before the cursor go. The
    /// notice that the dictation "will be saved" doesn't stay standing: the result's own message
    /// takes its place, with the outcome a keyboard that waited would report.
    @Test func aResultWithNothingToInsertAfterTheNoticeTakesTheTypedWordsOut() async throws {
        func noticed(_ words: String) async throws -> TypingLive {
            let live = try await typeLive(into: FakeTextField("Hi. "), resultTimeout: .milliseconds(300))
            try live.app.say(live.id, words)
            #expect(await waitUntil { live.field.text == "Hi. " + words })
            live.client.stopTapped()
            #expect(await waitUntil { if case .notice = live.client.phase { true } else { false } })
            #expect(live.field.text == "Hi. " + words)
            #expect(live.record?.typed == words)
            return live
        }

        let refused = try await noticed("words heard on the iPhone")
        try refused.app.finish(refused.id, text: "words heard on the iPhone and shown",
                               document: refused.host.currentDocumentIdentifier, status: .limitReached,
                               message: Brand.limitReachedMessage)
        #expect(await waitUntil { refused.field.text == "Hi. " })
        #expect(refused.record == nil)
        #expect(refused.transport.payloads.isClaimed(refused.id))
        #expect(refused.client.pendingResult == nil)
        #expect(refused.host.inserted.isEmpty)
        #expect(refused.client.phase == .notice(Brand.limitReachedMessage))
        // One for the notice that it was taking long, one for how it ended.
        #expect(refused.host.outcomes == [.problem, .problem])

        // A dictation the app dropped: its `cancelled` result is never the latest one, and is
        // found by the dictation's own id.
        let dropped = try await noticed("so i was thinking")
        try dropped.transport.payloads.write(result: DictationResult(
            requestId: dropped.id, documentIdentifier: nil, text: "", status: .cancelled, createdAt: Date()),
            updatesLatest: false)
        dropped.transport.post(.resultReady)
        #expect(await waitUntil { dropped.field.text == "Hi. " })
        #expect(dropped.record == nil)
        // A dictation that was dropped says nothing: the notice goes, and no second outcome comes.
        #expect(dropped.client.phase == .idle)
        #expect(dropped.host.outcomes == [.problem])

        // The cursor is no longer after the words: they stay, as text, and their record goes.
        let moved = try await noticed("so i was thinking")
        moved.field.moveCursor(to: 4)
        try moved.app.finish(moved.id, text: "", document: nil, status: .empty, message: "We didn't catch anything")
        #expect(await waitUntil { moved.record == nil })
        #expect(moved.field.text == "Hi. so i was thinking")
        #expect(moved.field.deletions == 0)
        #expect(moved.transport.payloads.isClaimed(moved.id))
        #expect(moved.client.phase == .notice("We didn't catch anything"))
        #expect(moved.host.outcomes == [.problem, .problem])
    }

    /// The card put away with its ✕: the text is not wanted here, and nothing of that dictation
    /// waits in the shared container any more. The words typed live stay as ordinary text.
    @Test func puttingTheCardAwayForgetsTheTypedWords() async throws {
        let live = try await typeLive(into: FakeTextField("Dear Anna, "))
        let (app, host, client, field, id) = (live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "I will be late")
        #expect(await waitUntil { field.text == "Dear Anna, I will be late" })
        field.moveCursor(to: 4)
        client.stopTapped()
        try app.finish(id, text: "I'll be late today.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { client.pendingResult?.requestId == id })
        #expect(live.record?.typed == "I will be late")

        client.dismissPendingResult()
        #expect(client.pendingResult == nil)
        #expect(live.transport.payloads.isClaimed(id))
        #expect(live.record == nil)
        #expect(live.typing.typedRequestId == nil)
        #expect(field.text == "Dear Anna, I will be late")
        #expect(field.deletions == 0)
        #expect(host.inserted.isEmpty)
        // Nothing brings the card back, and the words are text: nothing takes them out later.
        field.moveCursorToEnd()
        live.transport.post(.resultReady)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.pendingResult == nil)
        #expect(field.text == "Dear Anna, I will be late")
    }

    /// Another dictation's card put away leaves the record alone: the text that is still to come
    /// for the typed words replaces them.
    @Test func puttingAnotherDictationsCardAwayKeepsTheTypedWordsRecord() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "), resultTimeout: .milliseconds(300))
        let (transport, app, host, client, field, id) =
            (live.transport, live.app, live.host, live.client, live.field, live.id)
        try app.say(id, "so i was thinking")
        #expect(await waitUntil { field.text == "Hi. so i was thinking" })
        client.stopTapped()
        #expect(await waitUntil { if case .notice = client.phase { true } else { false } })

        // An earlier dictation's text, never inserted, is offered meanwhile.
        let earlier = UUID()
        try transport.payloads.write(result: DictationResult(
            requestId: earlier, documentIdentifier: UUID(), text: "An earlier one.", status: .cleaned,
            createdAt: Date()))
        transport.post(.resultReady)
        #expect(await waitUntil { client.pendingResult?.requestId == earlier })
        client.dismissPendingResult()
        #expect(transport.payloads.isClaimed(earlier))
        #expect(live.record?.typed == "so i was thinking")
        #expect(live.typing.typedRequestId == id)

        try app.finish(id, text: "So I was thinking.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { client.pendingResult?.requestId == id })
        client.insertPendingResult()
        #expect(field.text == "Hi. So I was thinking.")
        #expect(live.record == nil)
    }

    /// The app stopped answering mid-dictation: the words it had settled stay in the field. The
    /// next tap on the mic starts a new dictation, and the old words are ordinary text from then.
    @Test func theNextDictationLeavesTheEarlierWordsAsText() async throws {
        let live = try await typeLive(into: FakeTextField("Hi. "), staleAfter: 0.2)
        let (app, client, field, id) = (live.app, live.client, live.field, live.id)
        try app.say(id, "so i was thinking")
        #expect(await waitUntil {
            app.publish(.recording, tag: id.tag16)
            return field.text == "Hi. so i was thinking"
        })
        // From here the app publishes nothing more.
        #expect(await waitUntil { client.phase == .notice("Murmur stopped listening. Tap the mic to start again.") })
        #expect(field.text == "Hi. so i was thinking")
        #expect(live.record?.typed == "so i was thinking")
        #expect(live.typing.typedRequestId == id)

        app.publish(.ready)
        client.micTapped()
        #expect(live.record == nil)
        #expect(live.typing.typedRequestId == nil)
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })
        guard case .listening(let next, _) = client.phase else { return }
        #expect(next != id)
        try app.say(next, "and then")
        #expect(await waitUntil { field.text == "Hi. so i was thinking and then" })
        #expect(live.record?.requestId == next)
        #expect(field.deletions == 0)
    }

    /// While the week's words are used up no words are shown, and so none are typed.
    @Test func noWordsAreTypedWhileTheWeeksWordsAreUsedUp() async throws {
        var usedUp = false
        let live = try await typeLive(into: FakeTextField(), wordsUsedUp: { usedUp })
        let (app, client, field, id) = (live.app, live.client, live.field, live.id)
        try app.say(id, "Words within the week's")
        #expect(await waitUntil { field.text == "Words within the week's" })
        usedUp = true
        try app.say(id, "Words within the week's and words past them")
        #expect(await waitUntil { client.livePreview == LivePreview(requestId: id) })
        try app.say(id, "Words within the week's and words past them and more")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(field.text == "Words within the week's")
    }
}

private extension KeyboardSessionClient.Phase {
    func isListening(to requestId: UUID) -> Bool {
        if case .listening(requestId, _) = self { true } else { false }
    }
}
