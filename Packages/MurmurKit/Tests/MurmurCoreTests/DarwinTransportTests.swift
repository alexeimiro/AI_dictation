import Foundation
import Testing
@testable import MurmurCore

/// Exercises the real libnotify plumbing. Two transports with the same group behave like the
/// app and the keyboard (state and notifications are system-wide per name).
@MainActor
struct DarwinTransportTests {
    @Test func stateSetByOneTransportIsVisibleToAnother() {
        let group = "test.murmur.\(UUID().uuidString)"
        let container = SharedContainer.temporary()
        let app = DarwinIPCTransport(container: container, group: group)
        let keyboard = DarwinIPCTransport(container: container, group: group)

        let state = HotState(status: .recording, level: 77, requestTag: 4242, sequence: 9)
        app.publish(state)
        #expect(keyboard.currentState() == state)
    }

    @Test func postedEventsReachObservers() async {
        let group = "test.murmur.\(UUID().uuidString)"
        let container = SharedContainer.temporary()
        let app = DarwinIPCTransport(container: container, group: group)
        let keyboard = DarwinIPCTransport(container: container, group: group)

        let received = Counter()
        let observation = app.observe(.command) { received.increment() }
        keyboard.post(.command)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while received.value == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(received.value == 1)
        observation.cancel()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
