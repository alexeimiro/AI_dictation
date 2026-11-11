import AppIntents
import Foundation

/// "New Murmur Note": Notes on a new note, optionally dictating into it.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Murmur Note"
    static let description = IntentDescription("Opens Murmur on a new note.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Start Dictating", default: false)
    var dictate: Bool

    init() {}

    init(dictate: Bool) {
        self.dictate = dictate
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveActivityActions.model?.openNewNote(dictating: dictate)
        return .result()
    }
}

/// Murmur's actions in Shortcuts, Spotlight and Siri, ready to put on the Action Button.
struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: ["Dictate with \(.applicationName)", "Start \(.applicationName)", "\(.applicationName) dictation"],
            shortTitle: "Dictate",
            systemImageName: "waveform")
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New \(.applicationName) note", "Take a note in \(.applicationName)"],
            shortTitle: "New Note",
            systemImageName: "note.text.badge.plus")
    }
}
