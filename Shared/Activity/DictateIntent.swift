import AppIntents
import Foundation

// Compiled into both the app and the widget extension, like the Live Activity intents: the
// Control Center button needs the type, and as an audio recording intent its perform() runs in
// the app process, through the app's `LiveActivityActions`.

/// "Dictate with Murmur", for the Action Button, Control Center, Back Tap and Shortcuts. With
/// Murmur on and its keyboard on screen, it starts a dictation the keyboard types out, and the
/// next press stops it, without leaving the app you're writing in. Otherwise Murmur opens on a new
/// note and dictates into it.
struct DictateIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Dictate with Murmur"
    static let description = IntentDescription(
        "Starts a dictation, or stops the one in progress. With the Murmur keyboard open, the text is typed where you're writing; otherwise Murmur opens a new note.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    init() {}

    func perform() async throws -> some IntentResult {
        if await LiveActivityActions.toggleDictation() { return .result() }
        try await continueInForeground(alwaysConfirm: false)
        await LiveActivityActions.dictateIntoNewNote()
        return .result()
    }
}
