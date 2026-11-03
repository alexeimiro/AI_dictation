import MurmurCore
import MurmurUI
import SwiftUI
import UIKit

/// Reference 09.
struct SetupIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IntroPage(title: "Let’s set up \(Brand.name)", accent: "set up", top: 232, subtitleGap: 24.3,
                  subtitle: "This only takes a moment",
                  button: "Set up") { model.onboarding.send(.next) }
    }
}

/// Reference 16.
struct PracticeIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IntroPage(title: "Now, let’s test the magic", sparkles: true, tracking: 0, top: 236, lineHeight: 71,
                  subtitleGap: 21,
                  subtitle: "Try a quick dictation to see\n\(Brand.name) in action",
                  button: "Try \(Brand.name)") { model.onboarding.send(.next) }
    }
}

/// Reference 31.
struct WrapUpIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IntroPage(title: "Wrap up the setup", top: 243, subtitle: "One more step, then you’re in",
                  button: "Next") { model.onboarding.send(.next) }
    }
}

/// Reference 10, and the state after coming back from Settings (11–15 happen in the Settings app).
struct KeyboardInstructionsView: View {
    @Environment(AppModel.self) private var model
    @State private var visitedSettings = false

    var body: some View {
        let store = model.onboarding
        let added = store.permissions.keyboardAdded
        OnboardingPage {
            VStack(spacing: 0) {
                SerifTitle("Set up your \(Brand.name) Keyboard in Settings", size: 33, color: Palette.ink,
                           tracking: -1.9, lineHeight: 40.5)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                SettingsRowIllustration(tapping: !added)
                    .padding(.horizontal, 30)
                    .padding(.top, 106.5)
                if visitedSettings || added {
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow("\(Brand.name) keyboard added", ok: added)
                        if !added {
                            Text("In Settings, tap Keyboards and turn on \(Brand.name) and Allow Full Access.")
                                .font(.ui(14))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.top, 20)
                }
                Spacer(minLength: 0)
                PrivacyNote()
                    .padding(.horizontal, 44)
                    .padding(.bottom, 13)
            }
        } actions: {
            Button(added ? "Continue" : "Go to Settings") {
                if added {
                    store.send(.next)
                } else {
                    visitedSettings = true
                    model.openKeyboardSettings()
                }
            }
            .buttonStyle(.pill(.ink))
        }
    }

    private func statusRow(_ title: String, ok: Bool) -> some View {
        Label {
            Text(title).font(.ui(15, .medium)).foregroundStyle(Palette.text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Palette.toggleGreen : Palette.lockGray)
        }
    }
}

/// What Full Access is for, in the user's terms.
private struct PrivacyNote: View {
    var body: some View {
        Text(attributed)
            .font(.ui(14))
            .foregroundStyle(Color(hex: 0x5F5C63))
            .multilineTextAlignment(.center)
    }

    private var attributed: AttributedString {
        var text = AttributedString("\(Brand.name) ")
        var bold = AttributedString("never sells")
        bold.font = .ui(14, .semibold)
        text += bold
        text += AttributedString(" what you say. Full Access just lets the keyboard work with the Murmur app.")
        return text
    }
}

/// The Keyboards row as it looks in Settings, with a tap hint (an illustration, not a control).
private struct SettingsRowIllustration: View {
    let tapping: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x8E8D93))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "keyboard.fill").font(.system(size: 17)).foregroundStyle(.white)
                }
            Text("Keyboards")
                .font(.system(size: 19))
                .foregroundStyle(.black)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(hex: 0xC4C4C7))
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .frame(height: 53)
        .background(Color(hex: 0xF2F2F2), in: .rect(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            if tapping {
                Circle()
                    .fill(Color(hex: 0xB9B9BC).opacity(pressed ? 0.75 : 0.45))
                    .frame(width: 40, height: 40)
                    .scaleEffect(pressed ? 0.85 : 1)
                    .offset(x: 244, y: 41)
            }
        }
        .onAppear {
            guard tapping, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pressed = true }
        }
        .accessibilityElement()
        .accessibilityLabel("In Settings, open Keyboards")
    }
}

/// Reference 17: why the microphone, before the system prompt (18). Denied or restricted
/// access gets a way to Settings, and onboarding can go on without the exercises.
struct MicrophonePrimerView: View {
    @Environment(AppModel.self) private var model
    @State private var requesting = false

    var body: some View {
        let store = model.onboarding
        let state = store.permissions.microphone
        ZStack(alignment: .top) {
            Palette.sheetBackdrop.ignoresSafeArea()
            OnboardingHeader()
            VStack(spacing: 0) {
                SerifTitle(title(for: state), size: 32.5, color: Palette.ink, tracking: -0.4, lineHeight: 42.1)
                    .padding(.horizontal, 24)
                    .padding(.top, 38)
                Text(message(for: state))
                    .font(.ui(16))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.7)
                    .padding(.horizontal, 26)
                    .padding(.top, 13)
                MicrophoneIllustration()
                    .scaleEffect(0.93)
                    .padding(.top, 66.7)
                Spacer(minLength: 0)
                Button {
                    act(on: state)
                } label: {
                    if requesting { ProgressView().tint(.white) } else { Text(buttonTitle(for: state)) }
                }
                .buttonStyle(.pill(.ink, height: 52))
                .disabled(requesting)
                .padding(.horizontal, 22)
                if state == .denied || state == .restricted {
                    Button("Skip the exercises") { store.send(.skipOptional) }
                        .buttonStyle(.quiet(size: 15, weight: .medium))
                        .padding(.top, 6)
                }
            }
            .padding(.bottom, 46.7)
            .frame(maxWidth: .infinity)
            .background(Palette.paper, in: .rect(cornerRadius: 42))
            .padding(.horizontal, 8)
            .padding(.top, 174)
            .padding(.bottom, -21)
        }
    }

    private func title(for state: PermissionState) -> String {
        state == .denied || state == .restricted
            ? "Turn on the microphone for \(Brand.name)"
            : "Allow \(Brand.name) to access your microphone"
    }

    private func message(for state: PermissionState) -> String {
        switch state {
        case .denied: "Microphone access is off. Turn it on in Settings › \(Brand.name) to dictate."
        case .restricted: "Microphone access is restricted on this iPhone, so dictation can’t start."
        default: "\(Brand.name) needs microphone access to capture and transcribe what you say."
        }
    }

    private func buttonTitle(for state: PermissionState) -> String {
        state == .denied ? "Open Settings" : "Continue"
    }

    private func act(on state: PermissionState) {
        switch state {
        case .undetermined:
            requesting = true
            Task {
                defer { requesting = false }
                // The reducer moves on when the answer is "granted".
                _ = await model.requestMicrophone()
            }
        case .granted:
            model.onboarding.send(.next)
        case .denied, .restricted:
            model.setup.openSettings()
        }
    }
}
