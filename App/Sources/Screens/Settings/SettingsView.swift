import MurmurCore
import MurmurUI
import SwiftUI

/// Settings: every row says in a line what it does. General, the keyboard, audio, formatting,
/// then data and privacy, with the version and plan at the bottom.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingLanguages = false
    @State private var showsActionButtonGuide = false
    @State private var toast: String?

    var body: some View {
        @Bindable var settings = model.settings
        List {
            Group {
                // Also while signed out: the keyboard's button for opening Murmur lands here.
                if let account = model.account, account.isSignedOut || account.isGuest {
                    header("Account")
                    Button { model.signInSheet = .options } label: {
                        SettingLabel("Sign in…", detail: Self.accountFooter(phrase: account.phrase, guest: account.isGuest)) {
                            chevron
                        }
                    }
                    .settingRow()
                }
                header("General")
                    .accessibilityIdentifier(AccessibilityID.screen("settings"))
                Button { choosingLanguages = true } label: {
                    SettingLabel("Set language", detail: "Choose your dictation languages") {
                        Text(LanguagePickerSheet.summary(settings.dictationLanguages))
                        chevron
                    }
                }
                .settingRow()
                SettingPicker("Turn off after", detail: "When the microphone turns off while unused",
                              selection: $settings.disableAfter, value: settings.disableAfter.title) {
                    ForEach(DisableAfter.allCases) { Text($0.title).tag($0) }
                }
                .settingRow()
                Button { showsActionButtonGuide = true } label: {
                    SettingLabel("Action Button shortcut", detail: "Dictate faster with the Action Button") {
                        chevron
                    }
                }
                .settingRow()
                Toggle(isOn: $settings.autoOpenNote) {
                    SettingLabel("Auto open note", detail: "Start a new note when you open the app")
                }
                .settingRow()
                Toggle(isOn: $settings.lowDataMode) {
                    SettingLabel("Low data mode", detail: "Upload smaller audio, for slow or limited networks. On while iOS’s Low Data Mode is.")
                }
                .settingRow()
                Toggle(isOn: $settings.liveActivities) {
                    SettingLabel("Allow Live Activities", detail: "Show \(Brand.name) on the Lock Screen and in the Dynamic Island while it’s on")
                }
                .settingRow()
                if !model.hasProSubscription {
                    Button { model.showsPaywall = true } label: {
                        SettingLabel("Upgrade to Pro", detail: "Unlimited words, every week") {
                            chevron
                        }
                    }
                    .settingRow()
                }
            }
            .buttonStyle(.plain)
            .plainListRow()

            Group {
                header("Keyboard")
                SettingPicker("Layout", detail: "What the \(Brand.name) keyboard shows first",
                              selection: $settings.keyboardLayout, value: Self.layoutTitle(settings.keyboardLayout)) {
                    ForEach([KeyboardLayoutPreference.voice, .numbers, .qwerty], id: \.self) {
                        Text(Self.layoutTitle($0)).tag($0)
                    }
                }
                .settingRow()
                Toggle(isOn: $settings.keyboardFullQwerty) {
                    SettingLabel("Show full QWERTY keyboard",
                                 detail: "Show letters on the \(Brand.name) keyboard instead of switching to your default keyboard for letters")
                }
                .settingRow()
                SettingPicker("Appearance", detail: "Light, dark, or like the app you’re writing in",
                              selection: $settings.keyboardAppearance, value: settings.keyboardAppearance.title) {
                    ForEach(KeyboardAppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                .settingRow()
                Toggle(isOn: $settings.keyboardFeedback) {
                    SettingLabel("Keyboard feedback", detail: "A light tap as you press keys")
                }
                .settingRow()
                Toggle(isOn: $settings.readyHaptic) {
                    SettingLabel("Vibrate when text is ready", detail: "So you don’t have to watch the screen")
                }
                .settingRow()
                if model.hostReturn.isAvailable {
                    Toggle(isOn: $settings.autoReturn) {
                        SettingLabel("Return to the app automatically",
                                     detail: "After the keyboard opens \(Brand.name) to start listening, go back to the app you were writing in")
                    }
                    .settingRow()
                }
                Toggle(isOn: $settings.keepScreenAwake) {
                    SettingLabel("Keep the screen on while dictating", detail: "So Auto-Lock doesn’t cut a long dictation short")
                }
                .settingRow()

                header("Audio")
                Toggle(isOn: $settings.interactionSounds) {
                    SettingLabel("Interaction sounds", detail: "Play sounds when a dictation starts and stops")
                }
                .settingRow()
                Toggle(isOn: $settings.useBuiltInMic) {
                    SettingLabel("Built-in mic", detail: "Use your iPhone’s mic for all dictations, even with headphones connected")
                }
                .settingRow()

                header("Personalization")
                Toggle(isOn: $settings.smartFormatting) {
                    SettingLabel("Smart formatting",
                                 detail: "Drop “um” and “uh”, and turn “new line” or “comma” into what they say. Every style but Word for word always does.")
                }
                .settingRow()
            }
            .buttonStyle(.plain)
            .plainListRow()

            Group {
                header("Data and privacy")
                // The answer to "Before Murmur listens"; off, the microphone stays off.
                Toggle(isOn: Binding(get: { model.aiConsent.isGranted }, set: { model.setAIConsent($0) })) {
                    SettingLabel(AIConsentCopy.settingTitle, detail: AIConsentCopy.settingDetail)
                }
                .settingRow()
                if model.account != nil {
                    Toggle(isOn: Binding(get: { model.dataSharing },
                                         set: { on in Task { toast = await model.setDataSharing(on) } })) {
                        SettingLabel("Improve \(Brand.name) for everyone",
                                     detail: "Let us review your transcripts and edits to improve transcription and cleanup")
                    }
                    .settingRow()
                }
                Toggle(isOn: $settings.keepRecordings) {
                    SettingLabel("Keep recordings", detail: "Save each dictation’s audio on this iPhone to play it back")
                }
                .settingRow()
                SettingPicker("Local data storage", detail: "When transcripts and recordings are deleted",
                              selection: $settings.transcriptRetention,
                              value: Self.retentionTitle(settings.transcriptRetention)) {
                    ForEach(TranscriptRetention.allCases) { Text(Self.retentionTitle($0)).tag($0) }
                }
                .settingRow()
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
                    .settingRow()
                }
                Text(Self.privacyFootnote(signedIn: model.account?.isSignedIn == true))
                    .font(.murmur(.footnote))
                    .foregroundStyle(Theme.third)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Hairline() }

                #if DEBUG
                Button { model.router.open(.debug) } label: {
                    SettingLabel("Debug", detail: "The speech engine, timings and a field to test the keyboard in") {
                        chevron
                    }
                }
                .settingRow()
                .padding(.top, 12)
                #endif

                Text(Self.versionLine(plan: model.quota?.planName))
                    .font(.murmur(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(Theme.third)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
            }
            .buttonStyle(.plain)
            .plainListRow()
        }
        .plainList()
        .tint(Theme.ink)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // The keyboard's menu may have changed its switches while Murmur stayed in front.
        .onAppear { model.settings.reloadFromKeyboard() }
        .toast($toast)
        .sheet(isPresented: $choosingLanguages) {
            LanguagePickerSheet()
        }
        .fullScreenCover(isPresented: $showsActionButtonGuide) {
            ActionButtonGuide()
        }
    }

    private func header(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.top, 24)
            .padding(.bottom, 6)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.third)
            .accessibilityHidden(true)
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

    /// Under Data and privacy: where each kind of data is kept, and who else gets a dictation.
    /// It names no style: every style can send the text on.
    static func privacyFootnote(signedIn: Bool) -> String {
        let kept = signedIn
            ? "Your dictionary, snippets and notes are saved to your account, so they’re on every device you sign in on. Transcripts and recordings stay on this iPhone."
            : "Transcripts, recordings, your dictionary, snippets and notes stay on this iPhone; sign in to have the dictionary, snippets and notes on your other devices too."
        return kept + " OpenAI gets each recording to turn it into text, and Anthropic gets that text when it needs tidying or translating. Neither trains on them, and Murmur’s servers don’t keep either."
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
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.third)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.murmur(.body))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.murmur(.footnote))
                    .foregroundStyle(Theme.third)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A menu's label centers its lines otherwise.
            .multilineTextAlignment(.leading)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 6) { trailing }
                .font(.murmur(.subhead))
                .foregroundStyle(Theme.second)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

extension View {
    /// A settings row: at least 60 pt tall, with a line above it.
    func settingRow() -> some View {
        padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .overlay(alignment: .top) { Hairline() }
    }
}
