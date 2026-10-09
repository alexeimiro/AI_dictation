import Foundation
import MurmurCore

/// Publishes the app's `HotState`. Thread-safe: the status is set on the main actor and the mic
/// level on the audio thread. Every publish bumps the sequence number, which the keyboard uses
/// as a liveness signal.
final class HotStatePublisher: @unchecked Sendable {
    private let transport: IPCTransport
    private let lock = NSLock()
    private var state = HotState.off

    init(transport: IPCTransport) {
        self.transport = transport
    }

    var current: HotState {
        lock.withLock { state }
    }

    func set(_ status: SessionStatus, requestTag: UInt16 = 0) {
        publish { state in
            state.status = status
            state.requestTag = requestTag
            if status != .recording { state.level = 0 }
        }
    }

    /// Audio thread. Only published while recording (the keyboard animates it).
    func setLevel(_ level: Float) {
        let snapshot = lock.withLock { () -> HotState? in
            guard state.status == .recording else { return nil }
            state.level = UInt8(max(0, min(1, level)) * 255)
            state.sequence &+= 1
            return state
        }
        if let snapshot { transport.publish(snapshot) }
    }

    /// Heartbeat while idle.
    func tick() {
        publish { _ in }
    }

    private func publish(_ mutate: (inout HotState) -> Void) {
        let snapshot = lock.withLock { () -> HotState in
            mutate(&state)
            state.sequence &+= 1
            return state
        }
        transport.publish(snapshot)
    }
}
