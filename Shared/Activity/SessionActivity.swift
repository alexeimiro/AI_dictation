import ActivityKit
import AppIntents
import Foundation

// Compiled into both the app and the widget extension (see project.yml). The intents' perform()
// runs in the app process; each target provides its own `LiveActivityActions`.

struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case ready
            case recording
            case processing
        }

        var phase: Phase
        /// Start of the current dictation, for the live timer.
        var recordingStartedAt: Date?
    }
}

/// "Stop" while recording: ends the dictation and keeps the session on.
struct StopDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.stopDictation()
        return .result()
    }
}

/// Power button: turns the session off and releases the microphone.
struct EndSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turn Off Murmur"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        await LiveActivityActions.endSession()
        return .result()
    }
}
