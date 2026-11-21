import AppKit
import MurmurBrand
import MurmurCore
import SwiftUI

/// The first run (960×640): Welcome, then four steps (Sign in, Two permissions, Hold fn to talk,
/// Try it here) and You're set. Each step has its words on the left and a picture on the right.
struct OnboardingWindow: View {
    enum Step: String, CaseIterable {
        case welcome, signIn, permissions, shortcut, practice, done

        /// "1 of 4" … "4 of 4"; nil for Welcome and You're set.
        var number: Int? {
            switch self {
            case .signIn: 1
            case .permissions: 2
            case .shortcut: 3
            case .practice: 4
            case .welcome, .done: nil
            }
        }
    }

    @Bindable var model: MacAppModel
    var fixtureStep: String?
    @State private var step: Step = .welcome
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(model: MacAppModel, fixtureStep: String? = nil) {
        self.model = model
        self.fixtureStep = fixtureStep
        _step = State(initialValue: fixtureStep.flatMap(Step.init(rawValue:)) ?? .welcome)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let number = step.number { progress(number) }
                content
            }
            .padding(.horizontal, 56)
            .padding(.top, step == .welcome ? 96 : step == .done ? 80 : 64)
            .padding(.bottom, step == .welcome ? 48 : 40)
            .frame(width: 440, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(step == .done ? Color(hex: 0xE6E6E8) : Mac.Palette.fill))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(12)
        }
        .frame(width: 960, height: 640)
        .background(Mac.Palette.canvas)
        .foregroundStyle(Mac.Palette.ink)
        .environment(\.colorScheme, .light)
        .onChange(of: step) { _, new in
            model.shortcutTestActive = new == .shortcut
            if new == .shortcut { model.resetShortcutTest() }
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            if signedIn, step == .signIn { step = .permissions }
        }
        .onDisappear { model.shortcutTestActive = false }
    }

    private func progress(_ number: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(1...4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(index <= number ? Mac.Palette.ink : Mac.Palette.track)
                        .frame(width: 28, height: 4)
                }
            }
            Text("\(number) of 4").font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
        }
        .padding(.bottom, 28)
        .accessibilityLabel("Step \(number) of 4")
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .signIn: signIn
        case .permissions: permissions
        case .shortcut: shortcut
        case .practice: practice
        case .done: done
        }
    }

    @ViewBuilder private var picture: some View {
        switch step {
        case .welcome: WelcomePicture()
        case .signIn: AccountPicture()
        case .permissions: AccessibilityPicture(granted: model.accessibilityGranted)
        case .shortcut: KeyPicture(model: model)
        case .practice: PracticePicture(model: model)
        case .done: MenuBarPicture()
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MarkView(size: 24)
                wordmarkName().font(.system(size: 22, weight: .semibold)).tracking(-0.5)
            }
            Text("Talk instead of typing.")
                .font(.system(size: 40, weight: .bold)).tracking(-1.2)
                .padding(.top, 28).padding(.bottom, 14)
            Text("Redmic writes what you say into any app on your Mac. Hold \(keyName), talk, and let go.")
                .font(.system(size: 16)).foregroundStyle(Mac.Palette.second).lineSpacing(4)
            Spacer(minLength: 20)
            Button { step = model.isSignedIn ? .permissions : .signIn } label: {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle(height: 44))
            .font(.system(size: 15, weight: .semibold))
            Text("Use Redmic on your iPhone? Sign in with the same account and your words come with you.")
                .font(Mac.Font.small).foregroundStyle(Mac.Palette.third)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
    }

    @State private var showEmail = false

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Sign in")
            lede("Use the account you have on your iPhone, or make one. Your dictionary, snippets, notes and style come with it.")
                .padding(.bottom, 24)
            VStack(spacing: 10) {
                Button { Task { await model.signInWithApple() } } label: {
                    Label("Continue with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle(height: 44))
                Button { Task { await model.signInWithGoogle() } } label: {
                    Text("Continue with Google").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle(height: 44))
                if showEmail {
                    VStack(alignment: .leading, spacing: 8) {
                        EmailCodeForm(model: model)
                        Text("We email you a 6-digit code. No password.").font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } else {
                    Button { showEmail = true } label: {
                        Text("Continue with email").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OutlineButtonStyle(height: 44))
                }
            }
            .disabled(model.signInBusy)
            if let error = model.signInError {
                Text(error).font(Mac.Font.caption).padding(.top, 10)
            }
            Spacer(minLength: 16)
            (Text("By continuing you agree to the ") + Text("[Terms of Use](\(MacLinks.terms.absoluteString))")
             + Text(" and the ") + Text("[Privacy Policy](\(MacLinks.privacy.absoluteString))") + Text("."))
                .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third).tint(Mac.Palette.ink)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Two permissions")
            lede("Redmic needs to hear you and to type for you. The mic only opens while you hold the key.")
                .padding(.bottom, 22)
            VStack(spacing: 0) {
                permissionRow(symbol: "mic", title: "Microphone", detail: "To hear you while you hold the key",
                              granted: model.microphone == .authorized, action: "Allow", ink: true) {
                    if model.microphone == .notDetermined {
                        Task { await model.requestMicrophone() }
                    } else {
                        MacPermissions.openMicrophoneSettings()
                    }
                }
                Rectangle().fill(Mac.Palette.line).frame(height: 1)
                permissionRow(symbol: "accessibility", title: "Accessibility",
                              detail: "To type your words into the app you’re using",
                              granted: model.accessibilityGranted, action: "Open Settings", ink: false) {
                    model.requestAccessibility()
                    MacPermissions.openAccessibilitySettings()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Mac.Palette.line, lineWidth: 1))
            Spacer(minLength: 16)
            continueButton(enabled: model.microphone == .authorized && model.accessibilityGranted) { step = .shortcut }
        }
        .onAppear(perform: model.refreshPermissions)
        .task {
            // Murmur notices the switch by itself: System Settings doesn't tell it.
            while !Task.isCancelled, !(model.accessibilityGranted && model.microphone == .authorized) {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
            }
        }
    }

    @State private var showKeys = false

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Hold \(keyName) to talk")
            lede(MacSettings.shared.trigger == .function
                 ? "The fn key is bottom left on your keyboard. Redmic listens while you hold it and writes when you let go. Try it now: hold fn, or press and hold the key on the right."
                 : "Redmic listens while you hold \(MacSettings.shared.trigger.name) and writes when you let go. Try it now, or press and hold the key on the right.")
                .padding(.bottom, 18)
            if showKeys {
                FlowChips(selection: Binding(get: { MacSettings.shared.trigger },
                                             set: { MacSettings.shared.trigger = $0; model.resetShortcutTest() }))
            } else {
                Button("Use a different key") { showKeys = true }
                    .buttonStyle(.plain).font(.system(size: 14, weight: .semibold)).underline()
            }
            if MacSettings.shared.trigger == .function, model.globeKeyAction != .doNothing {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("If fn opens emoji or changes your keyboard language, set System Settings › Keyboard › “Press Globe key to” Do Nothing. ")
                        .foregroundStyle(Mac.Palette.second)
                    + Text("Open Keyboard settings").fontWeight(.semibold)
                }
                .font(Mac.Font.caption).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Mac.Palette.fill))
                .onTapGesture { MacPermissions.openKeyboardSettings() }
                .padding(.top, 18)
            }
            Spacer(minLength: 16)
            continueButton(enabled: true, title: model.shortcutTried ? "Continue" : "Skip for now",
                           prominent: model.shortcutTried) { step = .practice }
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Try it here")
            lede("Click the reply box, hold \(keyName), read this out loud, then let go:").padding(.bottom, 14)
            Text("“Running ten minutes late, start without me. I’ll join from the car.”")
                .font(.system(size: 17, weight: .semibold)).lineSpacing(3).padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) { Keycaps(keys: ["esc"]); Text("Changed your mind? Esc throws it away.") }
                if MacSettings.shared.handsFree {
                    HStack(spacing: 8) {
                        Keycaps(keys: MacSettings.shared.trigger.caps)
                        Text("Long thought? Double-tap \(keyName) and talk hands-free.")
                    }
                }
            }
            .font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            Spacer(minLength: 16)
            continueButton(enabled: true, title: model.practiceText.isEmpty ? "Skip for now" : "Continue",
                           prominent: !model.practiceText.isEmpty) { step = .done }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkView(size: 40)
            title("You’re set").padding(.top, 22)
            lede("Redmic lives in the menu bar. Hold \(keyName) in any app and talk.").padding(.bottom, 22)
            VStack(spacing: 0) {
                shortcutLine(caps: MacSettings.shared.trigger.caps, prefix: nil, text: "Hold to talk, let go to write", first: true)
                if MacSettings.shared.handsFree {
                    shortcutLine(caps: MacSettings.shared.trigger.caps, prefix: "2×", text: "Double-tap for hands-free")
                }
                shortcutLine(caps: MacSettings.shared.trigger.caps + ["⌃"], prefix: nil, text: "Change selected text by voice")
                if MacSettings.shared.pasteLastShortcut {
                    shortcutLine(caps: ["⌃", "⌘", "V"], prefix: nil, text: "Paste your last dictation")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Mac.Palette.line, lineWidth: 1))
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                Button { finish(openMain: false) } label: { Text("Close").frame(maxWidth: .infinity) }
                    .buttonStyle(OutlineButtonStyle(height: 44))
                Button { finish(openMain: true) } label: { Text("Open Redmic").frame(maxWidth: .infinity) }
                    .buttonStyle(InkButtonStyle(height: 44))
            }
        }
    }

    // MARK: Parts

    private var keyName: String {
        MacSettings.shared.trigger == .function ? "fn" : MacSettings.shared.trigger.name
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 32, weight: .bold)).tracking(-0.8).padding(.bottom, 10)
    }

    private func lede(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).foregroundStyle(Mac.Palette.second).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func continueButton(enabled: Bool, title: String = "Continue", prominent: Bool = true,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled && prominent ? Mac.Palette.canvas : Mac.Palette.second)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule(style: .circular).fill(enabled && prominent ? Mac.Palette.ink : Mac.Palette.line))
                .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func permissionRow(symbol: String, title: String, detail: String, granted: Bool, action: String,
                               ink: Bool, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if granted {
                Label("Allowed", systemImage: "checkmark").font(Mac.Font.label)
            } else if ink {
                Button(action, action: perform).buttonStyle(InkButtonStyle(height: 30))
            } else {
                Button(action, action: perform).buttonStyle(OutlineButtonStyle(height: 30))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 72)
    }

    private func shortcutLine(caps: [String], prefix: String?, text: String, first: Bool = false) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                if let prefix { Text(prefix).font(.system(size: 11)).foregroundStyle(Mac.Palette.second) }
                Keycaps(keys: caps)
            }
            .frame(width: 112, alignment: .leading)
            Text(text).font(Mac.Font.small)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .overlay(alignment: .top) { if !first { Rectangle().fill(Mac.Palette.line).frame(height: 1) } }
    }

    private func finish(openMain: Bool) {
        model.onboardingComplete = true
        model.shortcutTestActive = false
        if openMain {
            openWindow(id: "main")
            NSApp.activate()
        }
        dismissWindow(id: "onboarding")
    }
}

/// The push-to-talk keys as chips; the chosen one is filled.
struct FlowChips: View {
    @Binding var selection: MacSettings.TriggerKey

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MacSettings.TriggerKey.allCases) { key in
                let on = selection == key
                Button(key == .function ? "fn" : key.name.replacingOccurrences(of: "Right ", with: "Right \(symbol(key)) ")) {
                    selection = key
                }
                .buttonStyle(.plain)
                .font(Mac.Font.label)
                .foregroundStyle(on ? Mac.Palette.canvas : Mac.Palette.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule(style: .circular).fill(on ? Mac.Palette.ink : .clear))
                .overlay(Capsule(style: .circular).strokeBorder(Mac.Palette.ink, lineWidth: 1.5))
            }
        }
    }

    private func symbol(_ key: MacSettings.TriggerKey) -> String {
        switch key {
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        case .function: ""
        }
    }
}
