import Foundation

/// Session status published by the app. Raw values are part of the IPC wire format.
public enum SessionStatus: UInt8, Sendable, Codable, CaseIterable {
    /// No session: the keyboard must open the app to start one.
    case off = 0
    case starting = 1
    /// Hot mic running, waiting for a dictation.
    case ready = 2
    case recording = 3
    case processing = 4
    /// Audio could not be reactivated (e.g. after a phone call); reopening the app fixes it.
    case needsReconnect = 5
    case error = 6

    public var isLive: Bool {
        switch self {
        case .ready, .recording, .processing: true
        default: false
        }
    }
}

/// The fast-changing session state, packed into the 64-bit libnotify state of one name so the
/// keyboard can poll it at 20 Hz without touching the file system or cfprefsd.
///
/// Layout (most significant first): status (8) | level (8) | request tag (16) | sequence (32).
public struct HotState: Equatable, Sendable, CustomStringConvertible {
    public var status: SessionStatus
    /// Microphone level, 0...255.
    public var level: UInt8
    /// Low 16 bits of the active dictation's request id (see `UUID.tag16`).
    public var requestTag: UInt16
    /// Incremented on every publish; a value that stops moving means the app is gone.
    public var sequence: UInt32

    public init(status: SessionStatus, level: UInt8 = 0, requestTag: UInt16 = 0, sequence: UInt32 = 0) {
        self.status = status
        self.level = level
        self.requestTag = requestTag
        self.sequence = sequence
    }

    public init(packed: UInt64) {
        status = SessionStatus(rawValue: UInt8(truncatingIfNeeded: packed >> 56)) ?? .error
        level = UInt8(truncatingIfNeeded: packed >> 48)
        requestTag = UInt16(truncatingIfNeeded: packed >> 32)
        sequence = UInt32(truncatingIfNeeded: packed)
    }

    public var packed: UInt64 {
        UInt64(status.rawValue) << 56
            | UInt64(level) << 48
            | UInt64(requestTag) << 32
            | UInt64(sequence)
    }

    public static let off = HotState(status: .off)

    public var description: String {
        "HotState(\(status), level: \(level), tag: \(requestTag), seq: \(sequence))"
    }
}

extension UUID {
    /// 16-bit tag identifying a request inside `HotState`.
    public var tag16: UInt16 {
        let bytes = uuid
        let tag = UInt16(bytes.0) << 8 | UInt16(bytes.1)
        // 0 means "no request", so never produce it.
        return tag == 0 ? 1 : tag
    }
}
