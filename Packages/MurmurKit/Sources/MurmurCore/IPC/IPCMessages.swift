import Foundation

public enum CommandKind: String, Codable, Sendable {
    case start, stop, cancel
}

/// A request from the keyboard, written to `command.json` before posting `IPCEvent.command`.
public struct KeyboardCommand: Codable, Sendable, Equatable {
    public var id: UUID
    public var requestId: UUID
    public var kind: CommandKind
    public var createdAt: Date
    /// `textDocumentProxy.documentIdentifier` of the field being dictated into.
    public var documentIdentifier: UUID?
    public var styleOverride: StylePreset?

    public init(
        id: UUID = UUID(), requestId: UUID, kind: CommandKind, createdAt: Date,
        documentIdentifier: UUID? = nil, styleOverride: StylePreset? = nil
    ) {
        self.id = id
        self.requestId = requestId
        self.kind = kind
        self.createdAt = createdAt
        self.documentIdentifier = documentIdentifier
        self.styleOverride = styleOverride
    }
}

public enum ResultStatus: String, Codable, Sendable {
    /// Cleaned by the AI cleanup service.
    case cleaned
    /// Local formatting only (offline, timeout, refusal, AI cleanup off).
    case raw
    /// Nothing was recognized.
    case empty
    case limitReached
    case cancelled
    case failed
}

public struct DictationMetrics: Codable, Sendable, Equatable {
    public var audioSeconds: Double
    public var stopToTranscriptMs: Int?
    public var cleanupMs: Int?
    public var stopToResultMs: Int?
    public var words: Int

    public init(audioSeconds: Double, stopToTranscriptMs: Int? = nil, cleanupMs: Int? = nil,
                stopToResultMs: Int? = nil, words: Int) {
        self.audioSeconds = audioSeconds
        self.stopToTranscriptMs = stopToTranscriptMs
        self.cleanupMs = cleanupMs
        self.stopToResultMs = stopToResultMs
        self.words = words
    }
}

/// A finished dictation, written by the app to `results/<requestId>.json`.
public struct DictationResult: Codable, Sendable, Equatable {
    public var requestId: UUID
    public var documentIdentifier: UUID?
    public var text: String
    public var status: ResultStatus
    /// User-facing message for non-success statuses.
    public var message: String?
    public var createdAt: Date
    public var metrics: DictationMetrics?

    public init(requestId: UUID, documentIdentifier: UUID?, text: String, status: ResultStatus,
                message: String? = nil, createdAt: Date, metrics: DictationMetrics? = nil) {
        self.requestId = requestId
        self.documentIdentifier = documentIdentifier
        self.text = text
        self.status = status
        self.message = message
        self.createdAt = createdAt
        self.metrics = metrics
    }

    public var isInsertable: Bool {
        (status == .cleaned || status == .raw) && !text.isEmpty
    }
}

/// Written by the keyboard. A recent `fullAccessAt` proves Full Access, because without it the
/// keyboard cannot write to the App Group at all.
public struct KeyboardStatus: Codable, Sendable, Equatable {
    public var fullAccessAt: Date?
    public var lastSeenAt: Date
    public var listeningRequestId: UUID?
    public var listeningHeartbeatAt: Date?

    public init(fullAccessAt: Date?, lastSeenAt: Date, listeningRequestId: UUID? = nil,
                listeningHeartbeatAt: Date? = nil) {
        self.fullAccessAt = fullAccessAt
        self.lastSeenAt = lastSeenAt
        self.listeningRequestId = listeningRequestId
        self.listeningHeartbeatAt = listeningHeartbeatAt
    }
}

/// One-time token proving that a `murmur://session/start` link came from our keyboard, so a web
/// page cannot silently turn on the microphone.
public struct LaunchToken: Codable, Sendable, Equatable {
    public var token: String
    public var requestId: UUID
    public var createdAt: Date

    public init(token: String = UUID().uuidString, requestId: UUID, createdAt: Date) {
        self.token = token
        self.requestId = requestId
        self.createdAt = createdAt
    }
}

/// A dictation the keyboard wants to start automatically once the session is up (after the
/// bounce to the app and back).
public struct PendingStart: Codable, Sendable, Equatable {
    public var requestId: UUID
    public var documentIdentifier: UUID?
    public var createdAt: Date

    public init(requestId: UUID, documentIdentifier: UUID?, createdAt: Date) {
        self.requestId = requestId
        self.documentIdentifier = documentIdentifier
        self.createdAt = createdAt
    }
}

/// Darwin notification names. They carry no payload; data lives in the files above.
public enum IPCEvent: String, Sendable, CaseIterable {
    case command = "cmd"
    case stateChanged = "state"
    case resultReady = "result"
    case keyboardStatus = "kbstatus"

    public func notificationName(group: String) -> String {
        "\(group).\(rawValue)"
    }
}
