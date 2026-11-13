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
    /// BCP-47 tag chosen in the keyboard's language pill; nil means the primary language.
    public var languageOverride: String?
    /// BCP-47 output language. Nil keeps the recognized language (ordinary dictation).
    public var translationTargetLanguage: String?
    /// With a stop: when the keyboard began showing that it listens to this dictation, for the
    /// app's timings (the tap on the mic → listening).
    public var listeningSince: Date?

    public init(
        id: UUID = UUID(), requestId: UUID, kind: CommandKind, createdAt: Date,
        documentIdentifier: UUID? = nil, styleOverride: StylePreset? = nil, languageOverride: String? = nil,
        translationTargetLanguage: String? = nil, listeningSince: Date? = nil
    ) {
        self.id = id
        self.requestId = requestId
        self.kind = kind
        self.createdAt = createdAt
        self.documentIdentifier = documentIdentifier
        self.styleOverride = styleOverride
        self.languageOverride = languageOverride
        self.translationTargetLanguage = translationTargetLanguage
        self.listeningSince = listeningSince
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
    /// BCP-47 tag of the language the dictation was recognized in, so the keyboard can apply the
    /// matching joining rules without reading settings.
    public var language: String?

    public init(requestId: UUID, documentIdentifier: UUID?, text: String, status: ResultStatus,
                message: String? = nil, createdAt: Date, metrics: DictationMetrics? = nil,
                language: String? = nil) {
        self.requestId = requestId
        self.documentIdentifier = documentIdentifier
        self.text = text
        self.status = status
        self.message = message
        self.createdAt = createdAt
        self.metrics = metrics
        self.language = language
    }

    /// `limitReached` still carries the locally formatted text, so the dictation isn't lost; the
    /// keyboard inserts it and then shows the message.
    public var isInsertable: Bool {
        (status == .cleaned || status == .raw || status == .limitReached) && !text.isEmpty
    }
}

/// Why the app's session failed to start (e.g. a language model isn't downloaded). Written by the
/// app next to publishing `SessionStatus.error`, so the keyboard can show the reason.
public struct SessionFailure: Codable, Sendable, Equatable {
    public var message: String
    public var createdAt: Date

    public init(message: String, createdAt: Date) {
        self.message = message
        self.createdAt = createdAt
    }
}

/// Written by the keyboard. A recent `fullAccessAt` proves Full Access, because without it the
/// keyboard cannot write to the App Group at all.
public struct KeyboardStatus: Codable, Sendable, Equatable {
    public var fullAccessAt: Date?
    /// Refreshed every `KeyboardSessionClient.visibilityInterval` while the keyboard is on screen.
    public var lastSeenAt: Date
    /// When the keyboard went off screen. Older than `lastSeenAt` (or nil) while it's on screen.
    public var hiddenAt: Date?
    public var listeningRequestId: UUID?
    public var listeningHeartbeatAt: Date?
    /// The dictation the keyboard left running when it went off screen (the screen locked, or
    /// another app): the app records on until the keyboard is back, the 5-minute cap, or the Lock
    /// Screen's Stop, instead of finishing it when the heartbeats stop.
    public var awayRequestId: UUID?
    /// When that dictation began, for the timer of a keyboard that iOS relaunched meanwhile.
    public var awayListeningSince: Date?

    public init(fullAccessAt: Date?, lastSeenAt: Date, hiddenAt: Date? = nil, listeningRequestId: UUID? = nil,
                listeningHeartbeatAt: Date? = nil, awayRequestId: UUID? = nil, awayListeningSince: Date? = nil) {
        self.fullAccessAt = fullAccessAt
        self.lastSeenAt = lastSeenAt
        self.hiddenAt = hiddenAt
        self.listeningRequestId = listeningRequestId
        self.listeningHeartbeatAt = listeningHeartbeatAt
        self.awayRequestId = awayRequestId
        self.awayListeningSince = awayListeningSince
    }

    /// When the keyboard stopped being on screen: when it said so, or shortly after its last
    /// heartbeat if it was suspended or killed without saying so.
    public var inactiveSince: Date {
        if let hiddenAt, hiddenAt >= lastSeenAt { return hiddenAt }
        return lastSeenAt.addingTimeInterval(IdleStop.keyboardGrace)
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

/// The dictation the keyboard asked for when it opened the app. With `autoStart`, the app starts
/// recording it as soon as it has the microphone, so the user can talk while getting back to
/// their app, and the keyboard attaches to it when it reappears. Without it (a keyboard from
/// before), the keyboard sends the start itself once the session is ready.
public struct PendingStart: Codable, Sendable, Equatable {
    public var requestId: UUID
    public var documentIdentifier: UUID?
    public var createdAt: Date
    public var autoStart: Bool?
    /// The options a `start` command would carry; the app needs them to start on its own.
    public var styleOverride: StylePreset?
    public var languageOverride: String?
    public var translationTargetLanguage: String?
    /// When the user tapped the mic, if that was before `createdAt`: the keyboard first sent a
    /// start to a session that didn't answer. For the app's timings.
    public var tappedAt: Date?

    public init(requestId: UUID, documentIdentifier: UUID?, createdAt: Date, autoStart: Bool? = nil,
                styleOverride: StylePreset? = nil, languageOverride: String? = nil,
                translationTargetLanguage: String? = nil, tappedAt: Date? = nil) {
        self.requestId = requestId
        self.documentIdentifier = documentIdentifier
        self.createdAt = createdAt
        self.autoStart = autoStart
        self.styleOverride = styleOverride
        self.languageOverride = languageOverride
        self.translationTargetLanguage = translationTargetLanguage
        self.tappedAt = tappedAt
    }
}

/// A word the keyboard's ☰ menu added to the personal dictionary, queued in the App Group
/// until the app moves it into its library (the keyboard can't reach the library's store).
public struct DictionaryAddition: Codable, Sendable, Equatable {
    public var term: String
    public var createdAt: Date

    public init(term: String, createdAt: Date) {
        self.term = term
        self.createdAt = createdAt
    }
}

/// Darwin notification names. They carry no payload; data lives in the files above.
public enum IPCEvent: String, Sendable, CaseIterable {
    case command = "cmd"
    case stateChanged = "state"
    case resultReady = "result"
    case keyboardStatus = "kbstatus"
    case dictionaryAdded = "dict"

    public func notificationName(group: String) -> String {
        "\(group).\(rawValue)"
    }
}
