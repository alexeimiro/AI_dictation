import AppKit
import MurmurCore
import SwiftUI

/// Settings (⌘,): the mock's toolbar of four tabs, then the chosen tab's sections.
struct SettingsWindow: View {
    let model: MacAppModel
    @Bindable private var router = SettingsRouter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsRouter.Tab.allCases) { tab in
                    Button { router.tab = tab } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbol).font(.system(size: 17, weight: .regular))
                            Text(tab.title).font(.system(size: 11, weight: router.tab == tab ? .semibold : .regular))
                        }
                        .frame(width: 78, height: 52)
                        .background(RoundedRectangle(cornerRadius: 8).fill(router.tab == tab ? Color(hex: 0xEDEDED) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
            ScrollView {
                Group {
                    switch router.tab {
                    case .general: GeneralSettings(model: model)
                    case .account: AccountSettings(model: model)
                    case .plan: PlanSettings(model: model)
                    case .privacy: PrivacySettings(model: model)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 20)
            }
        }
        .frame(width: 720)
        .frame(minHeight: 560)
        .foregroundStyle(Mac.Palette.ink)
        .background(Mac.Palette.canvas)
        .environment(\.colorScheme, .light)
        .navigationTitle(router.tab.title)
        .task { await model.refreshAccount() }
    }
}

// MARK: - General

struct GeneralSettings: View {
    let model: MacAppModel
    @Bindable private var settings = MacSettings.shared
    @State private var recordingKey = false
    @State private var keyMonitor: Any?
    @State private var keyHint: String?
    @State private var tester = MicTester()
    @State private var speak = SharedSettings.shared.autoDetectDefaultApplied
        ? SharedSettings.shared.translationSourceLanguage : nil
    @State private var translateTo = SharedSettings.shared.translationEnabled
        ? SharedSettings.shared.translationTargetLanguage : nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("Shortcuts") {
                SettingsRow(title: "Push to talk", detail: keyHint ?? "Hold to talk, let go to finish", first: true) {
                    if recordingKey {
                        Text("Press the new shortcut…").font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
                    } else {
                        Keycaps(keys: settings.trigger.caps, prefix: "Hold")
                    }
                    Button(recordingKey ? "Cancel" : "Change") { recordingKey ? stopRecording() : startRecording() }
                        .buttonStyle(SmallOutlineButtonStyle())
                }
                SettingsRow(title: "Hands-free", detail: "Start and stop without holding a key") {
                    if settings.handsFree {
                        Keycaps(keys: settings.trigger.caps, prefix: "Double-tap")
                    } else {
                        Text("Off").font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
                    }
                    Menu("Change") {
                        Button("Double-tap \(settings.trigger.name)") { settings.handsFree = true }
                        Button("Off") { settings.handsFree = false }
                    }
                    .menuStyle(.button).buttonStyle(SmallOutlineButtonStyle()).menuIndicator(.hidden).fixedSize()
                }
                SettingsRow(title: "Command mode", detail: "Select text, hold, and say how to change it") {
                    Keycaps(keys: settings.trigger.caps + [settings.trigger == .rightControl ? "Left ⌃" : "⌃"])
                    Text("Pro").font(Mac.Font.badge).padding(.horizontal, 7).padding(.vertical, 1)
                        .overlay(Capsule(style: .circular).strokeBorder(Mac.Palette.ink, lineWidth: 1.5))
                }
                SettingsRow(title: "Paste last transcript", detail: "Puts your last dictation where the cursor is") {
                    if settings.pasteLastShortcut {
                        Keycaps(keys: ["⌃", "⌘", "V"])
                    } else {
                        Text("Off").font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
                    }
                    Menu("Change") {
                        Button("⌃⌘V") { settings.pasteLastShortcut = true }
                        Button("Off") { settings.pasteLastShortcut = false }
                    }
                    .menuStyle(.button).buttonStyle(SmallOutlineButtonStyle()).menuIndicator(.hidden).fixedSize()
                }
                SettingsRow(title: "Cancel while listening") { Keycaps(keys: ["esc"]) }
            }
            if settings.trigger == .function, model.globeKeyAction != .doNothing {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Your 🌐 key also \(globeAction) each time you let go. Set “Press 🌐 key to” to “Do Nothing”, or pick another key above.")
                        .font(Mac.Font.caption).foregroundStyle(Mac.Palette.second)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Keyboard Settings") { MacPermissions.openKeyboardSettings() }
                        .buttonStyle(SmallOutlineButtonStyle())
                }
                .padding(.horizontal, 4)
                .padding(.top, -8)
            }
            SettingsSection("Microphone") {
                SettingsRow(title: "Microphone", first: true) {
                    PopupMenu(title: microphoneTitle) {
                        Button("System input\(AudioInputs.defaultInputName.map { " (\($0))" } ?? "")") {
                            settings.microphoneUID = nil
                        }
                        Divider()
                        ForEach(AudioInputs.all()) { device in
                            Button(device.name) { settings.microphoneUID = device.uid }
                        }
                    }
                }
                SettingsRow(title: "Input level", detail: "Talk to test. Built-in or wired mics work best.") {
                    LevelMeter(level: tester.level)
                    Button(tester.running ? "Stop" : "Test") { tester.running ? tester.stop() : tester.start() }
                        .buttonStyle(SmallOutlineButtonStyle())
                }
            }
            SettingsSection("Language") {
                SettingsRow(title: "Speak", detail: "Redmic works out the language of each dictation", first: true) {
                    PopupMenu(title: speak.map { DictationLanguage(tag: $0).localizedName } ?? "Auto-detect") {
                        Button("Auto-detect") { setSpeak(nil) }
                        Divider()
                        ForEach(DictationLanguage.cloudLanguagesByName, id: \.tag) { language in
                            Button(language.localizedName) { setSpeak(language.tag) }
                        }
                    }
                }
                SettingsRow(title: "Translate to", detail: "Speak one language, type in another") {
                    PopupMenu(title: translateTo.map { DictationLanguage(tag: $0).localizedName } ?? "Don’t translate") {
                        Button("Don’t translate") { setTranslate(nil) }
                        Divider()
                        ForEach(DictationLanguage.cloudLanguagesByName, id: \.tag) { language in
                            Button(language.localizedName) { setTranslate(language.tag) }
                        }
                    }
                }
            }
            SettingsSection("App") {
                SettingsRow(title: "Launch at login", detail: "Redmic waits in the menu bar", first: true) {
                    Toggle("", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                        .toggleStyle(InkToggleStyle()).labelsHidden().fixedSize()
                }
                SettingsRow(title: "Show the floating bar", detail: "Keeps it above the Dock. It appears anyway while you talk.") {
                    Toggle("", isOn: $settings.showFloatingBar).toggleStyle(InkToggleStyle()).labelsHidden().fixedSize()
                }
                SettingsRow(title: "Sounds", detail: "A soft click when listening starts and stops") {
                    Toggle("", isOn: $settings.sounds).toggleStyle(InkToggleStyle()).labelsHidden().fixedSize()
                }
            }
        }
        .onDisappear {
            stopRecording()
            tester.stop()
        }
    }

    private var microphoneTitle: String {
        if let uid = settings.microphoneUID, let device = AudioInputs.device(uid: uid) { return device.name }
        return AudioInputs.defaultInputName ?? "System input"
    }

    private var globeAction: String {
        switch model.globeKeyAction {
        case .changeInputSource: "switches the input source"
        case .showEmoji: "opens Emoji & Symbols"
        case .startDictation: "starts Apple’s dictation"
        case .doNothing: ""
        }
    }

    private func setSpeak(_ tag: String?) {
        speak = tag
        let shared = SharedSettings.shared
        shared.translationSourceLanguage = tag
        shared.autoDetectDefaultApplied = tag != nil
    }

    private func setTranslate(_ tag: String?) {
        translateTo = tag
        let shared = SharedSettings.shared
        shared.translationEnabled = tag != nil
        if let tag { shared.translationTargetLanguage = tag }
    }

    /// Listens for the next modifier key while this window is in front.
    private func startRecording() {
        recordingKey = true
        keyHint = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stopRecording() } else { keyHint = "Use fn, or the right ⌥, ⌘ or ⌃ key" }
                return nil
            }
            if let key = MacSettings.TriggerKey(keyCode: Int64(event.keyCode)) {
                settings.trigger = key
                stopRecording()
            } else if event.modifierFlags.isEmpty == false {
                keyHint = "Use fn, or the right ⌥, ⌘ or ⌃ key"
            }
            return event
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingKey = false
    }
}

/// The input-level test: the microphone is open only between Test and Stop.
@MainActor
@Observable
final class MicTester {
    private(set) var level: Float = 0
    private(set) var running = false
    @ObservationIgnored private let capture = MacAudioCapture()

    func start() {
        guard !running, MacPermissions.microphone == .authorized else { return }
        do {
            try capture.start(device: DictationEngine.pickedMicrophone(), buffers: { _ in },
                              levels: { [weak self] value in Task { @MainActor in self?.level = value } })
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        guard running else { return }
        capture.stop()
        running = false
        level = 0
    }
}

// MARK: - Account

struct AccountSettings: View {
    let model: MacAppModel
    @State private var syncing = false
    @State private var synced = false
    @State private var confirmDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isSignedIn {
                HStack(spacing: 12) {
                    Text(String(model.displayName.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .overlay(Circle().strokeBorder(Mac.Palette.ink, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).font(Mac.Font.cardTitle)
                        Text([model.accountEmail, providerLine].compactMap { $0 }.joined(separator: " · "))
                            .font(Mac.Font.small).foregroundStyle(Mac.Palette.third)
                    }
                }
                SettingsSection("Sync") {
                    SettingsRow(title: "Dictionary, snippets, notes and style",
                                detail: "The same on this Mac and on Redmic for iPhone", first: true) {
                        if syncing {
                            ProgressView().controlSize(.small)
                        } else if synced {
                            Label("Up to date", systemImage: "checkmark").font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                        }
                        Button("Sync now") {
                            syncing = true
                            Task {
                                await model.syncAccountData()
                                syncing = false
                                synced = true
                            }
                        }
                        .buttonStyle(SmallOutlineButtonStyle())
                        .disabled(syncing)
                    }
                    SettingsRow(title: "History", detail: "Stays on this Mac. Your iPhone keeps its own.") { EmptyView() }
                }
                Button("Sign out") { Task { await model.signOut() } }.buttonStyle(OutlineButtonStyle())
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete account").font(.system(size: 14, weight: .semibold))
                        Text("Deletes your account and everything synced with it, and signs Redmic out on all your devices. It doesn’t cancel a subscription: cancel Pro first.")
                            .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                            .fixedSize(horizontal: false, vertical: true)
                        if let deleteError { Text(deleteError).font(Mac.Font.caption).padding(.top, 4) }
                    }
                    Spacer(minLength: 0)
                    Button("Delete account…") { confirmDelete = true }.buttonStyle(SmallOutlineButtonStyle())
                }
                .padding(14)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Mac.Palette.line, lineWidth: 1))
            } else {
                SignedOutPanel(model: model)
            }
        }
        .confirmationDialog("Delete your Redmic account?", isPresented: $confirmDelete) {
            Button("Delete account", role: .destructive) { delete() }
        } message: {
            Text("Your dictionary, snippets, notes and style are deleted from every device. This can’t be undone.")
        }
    }

    private var providerLine: String? {
        switch model.account?.state?.account.provider {
        case "apple": "Signed in with Apple"
        case "google": "Signed in with Google"
        case "email": "Signed in with email"
        default: nil
        }
    }

    private func delete() {
        Task {
            do {
                try await model.accountService?.deleteAccount()
                await model.signOut()
            } catch {
                deleteError = "Couldn’t delete the account: \(error.localizedDescription)"
            }
        }
    }
}

/// Sign in, for the Account tab when no one is signed in.
struct SignedOutPanel: View {
    @Bindable var model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to Redmic").font(Mac.Font.cardTitle)
            Text("Use the account you use on your iPhone, so your words, snippets, notes and Pro come with you.")
                .font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            Button { Task { await model.signInWithApple() } } label: {
                Label("Continue with Apple", systemImage: "apple.logo").frame(width: 240)
            }
            .buttonStyle(InkButtonStyle())
            .disabled(model.signInBusy)
            Button { Task { await model.signInWithGoogle() } } label: {
                Text("Continue with Google").frame(width: 240)
            }
            .buttonStyle(OutlineButtonStyle())
            .disabled(model.signInBusy)
            EmailCodeForm(model: model)
            if let error = model.signInError { Text(error).font(Mac.Font.caption) }
        }
    }
}

/// Email, then the code Murmur sends to it.
struct EmailCodeForm: View {
    @Bindable var model: MacAppModel

    var body: some View {
        if let sentTo = model.codeSentTo {
            Text("Enter the code sent to \(sentTo)").font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            HStack(spacing: 8) {
                TextField("Code", text: $model.code).textFieldStyle(.roundedBorder).frame(width: 140)
                Button("Sign in") { Task { await model.verifyEmailCode() } }
                    .buttonStyle(InkButtonStyle(height: 28)).disabled(model.signInBusy)
                Button("Back") { model.cancelEmailCode() }.buttonStyle(SmallOutlineButtonStyle())
            }
        } else {
            HStack(spacing: 8) {
                TextField("Email", text: $model.email).textFieldStyle(.roundedBorder).frame(width: 240)
                Button("Email me a code") { Task { await model.sendEmailCode() } }
                    .buttonStyle(SmallOutlineButtonStyle()).disabled(model.signInBusy)
            }
        }
    }
}

// MARK: - Plan

struct PlanSettings: View {
    let model: MacAppModel
    @Environment(\.openWindow) private var openWindow
    @State private var copiedInvite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let quota = model.quota { yourPlan(quota) }
            HStack(alignment: .top, spacing: 12) {
                planCard(name: "Basic", price: "Free", lines: ["1,000 words a week", "Dictionary, snippets and notes", "On your Mac and iPhone"], pro: false)
                planCard(name: "Pro", price: "$9.99", lines: ["Unlimited words, every week", "Translate and polish as much as you like", "Command mode in any app"], pro: true)
            }
            Text("Pro belongs to your Redmic account, so it works on your Mac and your iPhone. Bought Pro on your iPhone? It’s already on here.")
                .font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite a friend").font(.system(size: 14, weight: .semibold))
                    Text("They get a month of Pro. You get a month when they first dictate.")
                        .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                }
                Spacer(minLength: 0)
                Button {
                    guard let code = model.referrals?.code else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(MacLinks.invite)?code=\(code)", forType: .string)
                    copiedInvite = true
                } label: {
                    Label(copiedInvite ? "Copied" : "Copy invite link", systemImage: copiedInvite ? "checkmark" : "link")
                }
                .buttonStyle(SmallOutlineButtonStyle())
                .disabled(model.referrals == nil)
            }
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Mac.Palette.line, lineWidth: 1))
        }
    }

    private func yourPlan(_ quota: AccountService.Quota) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(planTitle(quota)).font(Mac.Font.cardTitle)
                Spacer()
                if let line = quota.usageLine() {
                    Text(line.replacingOccurrences(of: " in trial", with: "")).font(Mac.Font.caption.monospacedDigit())
                        .foregroundStyle(Mac.Palette.third)
                }
            }
            if let left = quota.trialDaysLeft() {
                let used = min(quota.trialLength, max(0, quota.trialLength - left))
                HStack(spacing: 2) {
                    ForEach(0..<quota.trialLength, id: \.self) { day in
                        RoundedRectangle(cornerRadius: 2).fill(day < used ? Mac.Palette.ink : Mac.Palette.track).frame(height: 4)
                    }
                }
                Text("After the trial you move to Basic: free, with 1,000 words a week. Pro keeps everything unlimited.")
                    .font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Mac.Palette.fill))
    }

    private func planTitle(_ quota: AccountService.Quota) -> String {
        if let left = quota.trialDaysLeft() { return "Trial · \(left) \(left == 1 ? "day" : "days") left" }
        return quota.isPro ? "Pro" : "Basic"
    }

    private func planCard(name: String, price: String, lines: [String], pro: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 17, weight: .bold))
                if pro { Badge(text: "Save 33% yearly") }
                Spacer()
            }
            if pro {
                (Text("$9.99 ").font(.system(size: 15, weight: .semibold))
                 + Text("a month, or $79.99 a year").font(Mac.Font.small).foregroundStyle(Mac.Palette.third))
            } else {
                Text(price).font(.system(size: 15, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "checkmark").font(Mac.Font.small)
                }
            }
            Spacer(minLength: 0)
            if pro, !(model.quota?.isPro == true && model.quota?.onTrial == false) {
                Button {
                    NSApp.activate()
                    openWindow(id: "main")
                    model.sheet = .paywall
                } label: {
                    Text("Upgrade to Pro").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(pro ? Mac.Palette.ink : Mac.Palette.line, lineWidth: pro ? 1.5 : 1))
    }
}

// MARK: - Privacy

struct PrivacySettings: View {
    let model: MacAppModel
    @State private var consent = MacConsent.isGranted
    @State private var confirmDeleteHistory = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("AI") {
                SettingsRow(title: "Write with AI services",
                            detail: "Send your recordings to OpenAI and their text to Anthropic, which write what you say. Redmic can’t dictate without them.",
                            first: true) {
                    Toggle("", isOn: Binding(get: { consent }, set: { on in
                        consent = on
                        if on {
                            SharedSettings.shared.aiConsentVersion = MacConsent.currentVersion
                        } else {
                            MacConsent.withdraw()
                        }
                    }))
                    .toggleStyle(InkToggleStyle()).labelsHidden().fixedSize()
                }
                if !consent {
                    Text("With this off, Redmic asks again before your next dictation.")
                        .font(Mac.Font.caption).foregroundStyle(Mac.Palette.second)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
                }
            }
            SettingsSection("History") {
                SettingsRow(title: "History", detail: "What you dictated stays on this Mac and isn’t synced", first: true) {
                    Button("Delete history…") { confirmDeleteHistory = true }.buttonStyle(SmallOutlineButtonStyle())
                }
            }
            Button { openURL(MacLinks.privacy) } label: {
                Label("Privacy Policy", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(.plain)
            .font(Mac.Font.label)
            .underline()
        }
        .confirmationDialog("Delete everything you dictated on this Mac?", isPresented: $confirmDeleteHistory) {
            Button("Delete history", role: .destructive) {
                model.history.deleteAll()
                model.apps.removeAll()
            }
        } message: {
            Text("Your notes, dictionary and snippets stay.")
        }
    }
}

/// "Privacy Policy ↗": the icon after the title.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 10, weight: .semibold))
        }
    }
}
