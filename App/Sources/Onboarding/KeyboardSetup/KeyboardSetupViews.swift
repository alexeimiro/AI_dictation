import MurmurUI
import SwiftUI

/// Opens the second part: adding the keyboard.
struct SetupIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IntroPage(part: 2, title: OnboardingCopy.SetupIntro.title, line: OnboardingCopy.SetupIntro.line,
                  button: OnboardingCopy.SetupIntro.button) { model.onboarding.send(.next) }
    }
}

/// Opens the third part: the exercises.
struct PracticeIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IntroPage(part: 3, title: OnboardingCopy.PracticeIntro.title, line: OnboardingCopy.PracticeIntro.line,
                  button: OnboardingCopy.PracticeIntro.button) { model.onboarding.send(.next) }
    }
}

/// Opens the last part: the choices.
struct WrapUpIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IntroPage(part: 4, title: OnboardingCopy.WrapUpIntro.title, line: OnboardingCopy.WrapUpIntro.line,
                  button: OnboardingCopy.next) { model.onboarding.send(.next) }
    }
}

/// What to turn on in Settings, and the way there. The switches themselves are in the Settings
/// app; coming back with the keyboard added moves the journey on.
struct KeyboardInstructionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let added = store.permissions.keyboardAdded
        OnboardingPage {
            OnboardingTitle(OnboardingCopy.Keyboard.title, line: OnboardingCopy.Keyboard.line)
                .padding(.top, 14)
            SettingsStepsPicture()
                .padding(.top, 22)
            HStack(spacing: 10) {
                CheckCircle(isOn: added)
                Text(verbatim: OnboardingCopy.Keyboard.added)
                    .font(.murmur(.subhead, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
            .accessibilityValue(added ? OnboardingCopy.Keyboard.done : OnboardingCopy.Keyboard.notDone)
            // What Full Access is for, in the user's terms.
            Text(verbatim: OnboardingCopy.Keyboard.note)
                .font(.murmur(.footnote))
                .foregroundStyle(Theme.third)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        } actions: {
            Button(added ? OnboardingCopy.continue : OnboardingCopy.Keyboard.button) {
                if added {
                    store.send(.next)
                } else {
                    model.openKeyboardSettings()
                }
            }
            .buttonStyle(.murmur(.primary))
        }
    }
}

/// Why the microphone, before the system asks. Denied or restricted access gets a way to
/// Settings, and onboarding can go on without the exercises.
struct MicrophonePrimerView: View {
    @Environment(AppModel.self) private var model
    @State private var requesting = false

    var body: some View {
        let store = model.onboarding
        let state = store.permissions.microphone
        let isOff = state == .denied || state == .restricted
        OnboardingPage {
            Spacer(minLength: 16)
            VStack(spacing: 12) {
                OpenMicPicture()
                Text(verbatim: OnboardingCopy.Microphone.caption)
                    .font(.murmur(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.second)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 16)
            OnboardingTitle(isOff ? OnboardingCopy.Microphone.offTitle : OnboardingCopy.Microphone.title,
                            line: message(for: state))
        } actions: {
            Button {
                act(on: state)
            } label: {
                // Disabled, and so grey, while the system asks.
                if requesting {
                    ProgressView().tint(Theme.ink)
                } else {
                    Text(isOff ? OnboardingCopy.openSettings : OnboardingCopy.continue)
                }
            }
            .buttonStyle(.murmur(.primary))
            .disabled(requesting)
            if isOff {
                Button(OnboardingCopy.Microphone.skip) { store.send(.skipOptional) }
                    .buttonStyle(.textOnly)
                    .padding(.top, 4)
            }
        }
    }

    private func message(for state: PermissionState) -> String {
        switch state {
        case .denied: OnboardingCopy.Microphone.deniedLine
        case .restricted: OnboardingCopy.Microphone.restrictedLine
        default: OnboardingCopy.Microphone.line
        }
    }

    private func act(on state: PermissionState) {
        switch state {
        case .undetermined:
            requesting = true
            Task {
                defer { requesting = false }
                // Where a recording goes comes before the system's question about the microphone.
                guard await model.aiConsent.ensure() else { return }
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
