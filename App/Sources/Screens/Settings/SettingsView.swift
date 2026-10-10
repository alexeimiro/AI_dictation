import MurmurCore
import MurmurUI
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Dictation") {
                NavigationLink(value: Route.languages) {
                    LabeledContent("Languages", value: languagesSummary)
                }
                Toggle("AI cleanup", isOn: $settings.aiCleanupEnabled)
                Picker("Default style", selection: $settings.defaultStyle) {
                    ForEach(StylePreset.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Use built-in mic", isOn: $settings.useBuiltInMic)
                Picker("Disable after", selection: $settings.disableAfter) {
                    ForEach(DisableAfter.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Keyboard") {
                Picker("Layout", selection: $settings.keyboardLayout) {
                    Text("Numbers first").tag(KeyboardLayoutPreference.numbers)
                    Text("QWERTY").tag(KeyboardLayoutPreference.qwerty)
                }
                Toggle("Keyboard feedback", isOn: $settings.keyboardFeedback)
                Toggle("Interaction sounds", isOn: $settings.interactionSounds)
            }
            Section("System") {
                Toggle("Live Activities", isOn: $settings.liveActivities)
            }
            Section {
                Picker("Auto-delete transcripts", selection: $settings.transcriptRetention) {
                    ForEach(TranscriptRetention.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Transcripts stay on this iPhone. Your voice is recognized on the device; only the text goes to the cleanup service.")
            }
            Section {
                NavigationLink("Debug", value: Route.debug)
            }
            Section("About") {
                LabeledContent("Version", value: Self.version)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var languagesSummary: String {
        let languages = model.languages
        let primary = DictationLanguage(tag: languages.primary).localizedName
        if let secondary = languages.secondary {
            return "\(primary), \(DictationLanguage(tag: secondary).localizedName)"
        }
        return primary
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
