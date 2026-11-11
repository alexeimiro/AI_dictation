import MurmurUI
import SwiftUI

// The pictures on onboarding's pages, drawn from the same parts as the app itself: the talk
// button, soft cards, the mark. None of them is a control. Each is one image for VoiceOver, and
// what moves in them stands still under Reduce Motion and in screenshot runs.

/// The keyboard's talk button: ink with a ring around it at rest, red with rings leaving it while
/// it listens.
struct TalkButtonPicture: View {
    enum Mode {
        case resting
        /// `reach`: how far the rings travel, in button sizes. A whisper's stay close.
        case listening(reach: CGFloat)
    }

    var size: CGFloat = 96
    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Circle()
            .fill(isListening ? Theme.live : Theme.ink)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "mic")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(isListening ? Theme.onLive : Theme.onInk)
            }
            .background {
                switch mode {
                case .resting:
                    Circle()
                        .strokeBorder(Theme.ink.opacity(contrast == .increased ? 0.6 : 0.28), lineWidth: 1.5)
                        .frame(width: size * 1.25, height: size * 1.25)
                case .listening(let reach):
                    PulseRings(reach: reach, isStill: model.launchOptions.isOnboardingScreenshot)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(isListening ? OnboardingCopy.Welcome.picture : OnboardingCopy.Ready.picture)
            .accessibilityAddTraits(.isImage)
    }

    private var isListening: Bool {
        if case .listening = mode { return true }
        return false
    }
}

/// The red dot on its own, with the rings an open microphone has.
struct OpenMicPicture: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Circle()
            .fill(Theme.live)
            .frame(width: 32, height: 32)
            .background {
                PulseRings(reach: 3.4, cycle: 2.2, lineWidth: 1.5,
                           isStill: model.launchOptions.isOnboardingScreenshot)
            }
            // Room for the rings, which the dot's own frame doesn't count.
            .frame(width: 112, height: 112)
            .accessibilityHidden(true)
    }
}

/// A number as the page's picture: very large, over a row of segments and a caption.
struct BigNumber: View {
    let number: String
    let caption: String
    var meter: (total: Int, filled: Int)?
    /// What VoiceOver says for the whole picture; the number and the caption when nil.
    var spoken: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: number)
                .font(.system(size: 132, weight: .bold))
                // Digits can sit closer together than letters ("Pro").
                .tracking(number.contains(where: \.isLetter) ? -3 : -5)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .foregroundStyle(Theme.ink)
                // The line box of a 132 pt font, cut back to its digits.
                .padding(.top, -22)
                .padding(.bottom, -20)
            if let meter {
                Meter(total: meter.total, filled: meter.filled, height: 8)
            }
            Text(verbatim: caption)
                .font(.murmur(.subhead, weight: .semibold))
                .foregroundStyle(Theme.second)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel(spoken ?? "\(number) \(caption)")
        .accessibilityAddTraits(.isImage)
    }
}

/// A text box in some app with what was just said in it: a small label for the place, then the
/// words.
struct TextBoxPicture: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: label)
                .font(.murmur(.footnote, weight: .semibold))
                .foregroundStyle(Theme.third)
            Text(verbatim: text)
                .font(.transcript(.body))
                .lineSpacing(3)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .softCard()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isImage)
    }
}

/// The three things to do in Settings, as its rows look: Keyboards, then the two switches.
struct SettingsStepsPicture: View {
    var body: some View {
        VStack(spacing: 0) {
            row(1, OnboardingCopy.Keyboard.keyboards) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.graphic)
            }
            Hairline()
            row(2, OnboardingCopy.Keyboard.murmur) { SwitchPicture() }
            Hairline()
            row(3, OnboardingCopy.Keyboard.fullAccess) { SwitchPicture() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(Theme.fill, in: .rect(cornerRadius: 20))
        .accessibilityElement()
        .accessibilityLabel(OnboardingCopy.Keyboard.picture)
        .accessibilityAddTraits(.isImage)
    }

    private func row(_ number: Int, _ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            StepNumber(number)
            Text(verbatim: title)
                .font(.murmur(.body))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 54)
    }
}

/// A switch that is on, in Murmur's ink.
private struct SwitchPicture: View {
    var body: some View {
        Capsule(style: .circular)
            .fill(Theme.ink)
            .frame(width: 51, height: 31)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(Theme.onInk)
                    .frame(width: 27, height: 27)
                    .padding(2)
            }
    }
}

/// How to switch keyboards: the list the globe key opens, with Murmur picked, over the key itself.
struct KeyboardPickerPicture: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                ForEach(OnboardingCopy.Practice.otherKeyboards, id: \.self) { name in
                    row(name, picked: false)
                    Hairline()
                }
                row(OnboardingCopy.Practice.murmurKeyboard, picked: true)
            }
            .padding(.horizontal, 16)
            .background(Theme.fill, in: .rect(cornerRadius: 20))
            Image(systemName: "globe")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .background {
                    Circle().strokeBorder(Theme.ink, lineWidth: 1.5)
                    PulseRings(color: Theme.ink, count: 2, reach: 1.7, cycle: 1.8, lineWidth: 1.5,
                               isStill: model.launchOptions.isOnboardingScreenshot)
                }
                .padding(.leading, 8)
                .padding(.bottom, 8)
        }
        .accessibilityElement()
        .accessibilityLabel(OnboardingCopy.Practice.guidePicture)
        .accessibilityAddTraits(.isImage)
    }

    private func row(_ name: String, picked: Bool) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: name)
                .font(.murmur(.body, weight: picked ? .semibold : .regular))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if picked {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
        }
        .frame(minHeight: 46)
    }
}

/// A notification from Murmur as the Lock Screen shows one.
struct NotificationPicture: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.ink)
                .frame(width: 40, height: 40)
                .overlay {
                    BrandMark(ring: Theme.onInk)
                        .frame(width: 26, height: 26)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: OnboardingCopy.Notifications.sampleSender)
                        .font(.murmur(.subhead, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(verbatim: OnboardingCopy.Notifications.sampleTime)
                        .font(.murmur(.footnote))
                        .foregroundStyle(Theme.second)
                }
                Text(verbatim: OnboardingCopy.Notifications.sampleText)
                    .font(.murmur(.subhead))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: .rect(cornerRadius: 22))
        .accessibilityElement()
        .accessibilityLabel(OnboardingCopy.Notifications.picture)
        .accessibilityAddTraits(.isImage)
    }
}

/// A window on a computer with a dictation arriving in it: the red dot, "Listening", the words.
struct DesktopPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Theme.track)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.bottom, 16)
            Text(verbatim: OnboardingCopy.Desktop.sample)
                .font(.transcript(.body))
                .lineSpacing(3)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 10, height: 10)
                Text(verbatim: OnboardingCopy.Desktop.listening)
                    .font(.murmur(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.top, 28)
        }
        .softCard()
        .accessibilityElement()
        .accessibilityLabel(OnboardingCopy.Desktop.picture)
        .accessibilityAddTraits(.isImage)
    }
}
