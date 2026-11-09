import MurmurCore
import MurmurUI
import SwiftUI

/// Settings as in Wispr Flow: every row says in a line what it does. General, the keyboard, audio,
/// formatting, then data and privacy, with the version and plan at the bottom.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingLanguages = false
    @State private var showsActionButtonGuide = false
    @State private var toast: String?

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
            Section("General") {
                Button { choosingLanguages = true } label: {
                    SettingLabel("Set language", detail: "Choose your dictation languages") {
                        Text(LanguagePickerSheet.summary(settings.dictationLanguages))
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                    }
                }
                SettingPicker("Disable \(Brand.name) after", detail: "When the microphone turns off while unused",
                              selection: $settings.disableAfter, value: settings.disableAfter.title) {
                    ForEach(DisableAfter.allCases) { Text($0.title).tag($0) }
                }
                Button { showsActionButtonGuide = true } label: {
                    SettingLabel("Action Button shortcut", detail: "Dictate faster with the Action Button") {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).accessibilityHidden(true)
                    }
                }
                Toggle(isOn: $settings.autoOpenNote) {
                    SettingLabel("Auto open note", detail: "Start a new note when you open the app")
                }
                Toggle(isOn: $settings.lowDataMode) {
                    SettingLabel("Low data mode", detail: "Upload smaller audio, for slow or limited networks. On while iOS's Low Data Mode is.")
                }
                Toggle(isOn: $settings.liveActivities) {
                    SettingLabel("Allow Live Activities", detail: "Show \(Brand.name) on the Lock Screen and in the Dynamic Island while it's on")
                }
                if !model.pro.isSubscribed {
                    Button { model.showsPaywall = true } label: {
                        SettingLabel("Upgrade to Pro", detail: "Unlimited words, every week") {
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            Section("Keyboard") {
                SettingPicker("Layout", detail: "What the \(Brand.name) keyboard shows first",
                              selection: $settings.keyboardLayout, value: Self.layoutTitle(settings.keyboardLayout)) {
                    ForEach([KeyboardLayoutPreference.voice, .numbers, .qwerty], id: \.self) {
                        Text(Self.layoutTitle($0)).tag($0)
                    }
                }
                Toggle(isOn: $settings.keyboardFullQwerty) {
                    SettingLabel("Show full QWERTY keyboard",
                                 detail: "Show letters on the \(Brand.name) keyboard instead of switching to your default keyboard for letters")
                }
                SettingPicker("Appearance", detail: "Light, dark, or like the app you're writing in",
                              selection: $settings.keyboardAppearance, value: settings.keyboardAppearance.title) {
                    ForEach(KeyboardAppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.keyboardFeedback) {
                    SettingLabel("Keyboard feedback", detail: "A light tap as you press keys")
                }
                Toggle(isOn: $settings.readyHaptic) {
                    SettingLabel("Vibrate when text is ready", detail: "So you don't have to watch the screen")
                }
            }
            Section("Audio") {
                Toggle(isOn: $settings.interactionSounds) {
                    SettingLabel("Interaction sounds", detail: "Play sounds when a dictation starts and stops")
                }
                Toggle(isOn: $settings.useBuiltInMic) {
                    SettingLabel("Built-in mic", detail: "Use your iPhone's mic for all dictations, even with headphones connected")
                }
            }
            Section("Personalization") {
                Toggle(isOn: $settings.smartFormatting) {
                    SettingLabel("Smart formatting",
                                 detail: "Drop \u{201C}um\u{201D} and \u{201C}uh\u{201D}, and turn \u{201C}new line\u{201D} or \u{201C}comma\u{201D} into what they say. Improve my grammar always does.")
                }
            }
            Section {
                if model.account != nil {
                    Toggle(isOn: Binding(get: { model.dataSharing },
                                         set: { on in Task { toast = await model.setDataSharing(on) } })) {
                        SettingLabel("Improve \(Brand.name) for everyone",
                                     detail: "Let us review your transcripts and edits to improve transcription and cleanup")
                    }
                }
                Toggle(isOn: $settings.keepRecordings) {
                    SettingLabel("Keep recordings", detail: "Save each dictation's audio on this iPhone to play it back")
                }
                SettingPicker("Local data storage", detail: "When transcripts and recordings are deleted",
                              selection: $settings.transcriptRetention,
                              value: Self.retentionTitle(settings.transcriptRetention)) {
                    ForEach(TranscriptRetention.allCases) { Text(Self.retentionTitle($0)).tag($0) }
                }
                if let sync = model.librarySync, model.account?.isSignedIn == true {
                    Button {
                        Task {
                            await sync.sync(full: true)
                            toast = sync.lastError ?? "Your words, snippets and notes are up to date"
                        }
                    } label: {
                        SettingLabel("Refresh from cloud", detail: Self.syncDetail(sync.lastSyncedAt)) {
                            if sync.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(sync.isSyncing)
                }
            } header: {
                Text("Data and privacy")
            } footer: {
                Text(model.account?.isSignedIn == true
                     ? "Your dictionary, snippets and notes are saved to your account, so they're on every device you sign in on. Transcripts and recordings stay on this iPhone. To write your text, the recording and its transcript go to OpenAI, which doesn't train on them; Murmur's servers don't keep either."
                     : "Transcripts, recordings, your dictionary, snippets and notes stay on this iPhone; sign in to have the dictionary, snippets and notes on your other devices too. To write your text, the recording and its transcript go to OpenAI, which doesn't train on them; Murmur's servers don't keep either.")
            }
            Section {
                NavigationLink("Debug", value: Route.debug)
            }
            Section {
            } footer: {
                Text(Self.versionLine(plan: model.quota?.badge))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .tint(Palette.toggleGreen)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toast($toast)
        .sheet(isPresented: $choosingLanguages) {
            LanguagePickerSheet()
        }
        .fullScreenCover(isPresented: $showsActionButtonGuide) {
            ActionButtonGuide()
        }
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

    static func layoutTitle(_ layout: KeyboardLayoutPreference) -> String {
        switch layout {
        case .voice: "Voice"
        case .numbers: "Numbers first"
        case .qwerty: "QWERTY"
        }
    }

    /// "Get the latest words, snippets and notes · Synced 5 min. ago".
    static func syncDetail(_ lastSyncedAt: Date?, now: Date = Date()) -> String {
        let detail = "Get your words, snippets and notes from your account"
        guard let lastSyncedAt else { return detail }
        let ago = now.timeIntervalSince(lastSyncedAt) < 60
            ? "just now" : lastSyncedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(detail). Synced \(ago)"
    }

    static func retentionTitle(_ retention: TranscriptRetention) -> String {
        retention == .never ? "Keep stored" : "After \(retention.title)"
    }

    /// "Murmur 1.0 (202611091404) · Pro Trial", the line under everything.
    static func versionLine(plan: String?) -> String {
        [Brand.name + " " + version, plan].compactMap { $0 }.joined(separator: " · ")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A choice in a settings row: the title and its explanation, the current value on the right, and
/// a menu of the options. (A `Picker` row puts the value under a two-line label.)
struct SettingPicker<Value: Hashable, Options: View>: View {
    let title: String
    let detail: String
    @Binding var selection: Value
    let value: String
    @ViewBuilder let options: Options

    init(_ title: String, detail: String, selection: Binding<Value>, value: String,
         @ViewBuilder options: () -> Options) {
        self.title = title
        self.detail = detail
        _selection = selection
        self.value = value
        self.options = options()
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }
                .pickerStyle(.inline)
        } label: {
            SettingLabel(title, detail: detail) {
                Text(value)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(value)
    }
}

/// A settings row's title with its one-line explanation under it, and what goes on the right.
struct SettingLabel<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At the accessibility sizes the value goes under the text, which keeps the width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.ui(17, .medium))
                    .foregroundStyle(Palette.text)
                Text(detail)
                    .font(.ui(14))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A menu's label centers its lines otherwise.
            .multilineTextAlignment(.leading)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 6) { trailing }
                .font(.ui(15))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
