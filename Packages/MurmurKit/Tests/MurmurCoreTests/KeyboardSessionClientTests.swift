import Foundation
import Testing
@testable import MurmurCore

@MainActor
private final class FakeHost: KeyboardSessionHost {
    var hasFullAccess = true
    var currentDocumentIdentifier: UUID? = UUID()
    var openedURLs: [URL] = []
    var inserted: [DictationResult] = []

    func openContainingApp(_ url: URL) { openedURLs.append(url) }
    func insertDictation(_ result: DictationResult) { inserted.append(result) }
    func sessionClientDidChange(_ client: KeyboardSessionClient) {}
}

/// Plays the app's side of the protocol.
@MainActor
private final class FakeApp {
    let transport: IPCTransport
    var sequence: UInt32 = 1
    var acknowledges = true
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

    func finish(_ requestId: UUID, text: String, document: UUID?) throws {
        try transport.payloads.write(result: DictationResult(
            requestId: requestId, documentIdentifier: document, text: text, status: .cleaned, createdAt: Date()))
        publish(.ready)
        transport.post(.resultReady)
    }

    private func handleCommand() {
        guard acknowledges, let command = transport.payloads.readCommand() else { return }
        switch command.kind {
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
        #expect(await waitUntil { if case .listening = client.phase { true } else { false } })

        client.stopTapped()
        #expect(transport.payloads.readCommand()?.kind == .stop)
        try app.finish(requestId, text: "Hello world.", document: host.currentDocumentIdentifier)
        #expect(await waitUntil { host.inserted.count == 1 })
        #expect(host.inserted.first?.text == "Hello world.")

        // A second resultReady must not insert again.
        transport.post(.resultReady)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(host.inserted.count == 1)
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

        // The app validates the token and starts the session; the keyboard then starts recording.
        #expect(transport.payloads.consumeLaunchToken(token!, maxAge: 10, now: Date())?.requestId == requestId)
        app.publish(.ready)
        #expect(await waitUntil {
            if case .listening(requestId, _) = client.phase { true } else { false }
        })
        #expect(transport.payloads.readPendingStart() == nil)
    }

    @Test func fallsBackToOpeningTheAppWhenTheAckTimesOut() async {
        let transport = InMemoryIPCTransport()
        let app = FakeApp(transport: transport)
        app.acknowledges = false
        let host = FakeHost()
        let client = KeyboardSessionClient(transport: transport, ackTimeout: .milliseconds(150))
        client.host = host
        app.publish(.ready)
        client.activate()

        client.micTapped()
        #expect(await waitUntil { host.openedURLs.count == 1 })
        if case .openingApp = client.phase {} else { Issue.record("expected .openingApp, got \(client.phase)") }
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

        client.insertPendingResult()
        #expect(host.inserted.map(\.text) == ["Elsewhere."])
        client.insertPendingResult()
        #expect(host.inserted.count == 1)
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
}
