import MurmurCore
import MurmurUI
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            // Also while signed out: the keyboard's button for opening Murmur lands here.
            if let account = model.account, account.isSignedOut || account.isGuest {
                Section {
                    Button("Sign in…") { model.signInSheet = .options }
                } header: {
                    Text("Account")
                } footer: {
                    Text(Self.accountFooter(phrase: account.phrase, guest: account.isGuest))
                }
            }
            Section("Dictation") {
                NavigationLink(value: Route.languages) {
                    LabeledContent("Languages", value: languagesSummary)
                }
                Toggle("Use built-in mic", isOn: $settings.useBuiltInMic)
                    .tint(Palette.toggleGreen)
                Picker("Disable after", selection: $settings.disableAfter) {
                    ForEach(DisableAfter.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker("Layout", selection: $settings.keyboardLayout) {
                    Text("Voice").tag(KeyboardLayoutPreference.voice)
                    Text("Numbers first").tag(KeyboardLayoutPreference.numbers)
                    Text("QWERTY").tag(KeyboardLayoutPreference.qwerty)
                }
                Picker("Appearance", selection: $settings.keyboardAppearance) {
                    ForEach(KeyboardAppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Haptic feedback", isOn: $settings.keyboardFeedback)
                    .tint(Palette.toggleGreen)
                Toggle("Vibrate when text is ready", isOn: $settings.readyHaptic)
                    .tint(Palette.toggleGreen)
                Toggle("Start and stop sounds", isOn: $settings.interactionSounds)
                    .tint(Palette.toggleGreen)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("The voice keyboard needs Allow Full Access; until it's on, the keyboard shows Numbers first.")
            }
            Section("System") {
                Toggle("Live Activities", isOn: $settings.liveActivities)
                    .tint(Palette.toggleGreen)
            }
            Section {
                Picker("Auto-delete transcripts", selection: $settings.transcriptRetention) {
                    ForEach(TranscriptRetention.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Transcripts stay on this iPhone. To write your text, the recording and its transcript go to OpenAI; Murmur's servers don't keep either.")
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
        .toolbar(.hidden, for: .tabBar)
    }

    /// What signing in brings back, after a sign-out or "Continue without an account". No word on
    /// a guest's plan: it's whatever the server grants a new user. `phrase`: how the copy names
    /// the remembered account (`AccountModel.Account.phrase`).
    static func accountFooter(phrase: String?, guest: Bool) -> String {
        if guest {
            let signIn = phrase.map { "Sign in \($0) to get it back." } ?? "Sign in to get it back."
            return "You're using Murmur as a guest, without your account's plan. \(signIn)"
        }
        let signIn = phrase.map { "Sign in again \($0)" } ?? "Sign in again"
        return "You're signed out. \(signIn) to keep cloud dictation and your plan."
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
