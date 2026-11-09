import MurmurCore
import SwiftUI

/// The keyboard's own settings, from Anton's mock with only the settings that exist: feedback,
/// appearance, and the way to Murmur's full Settings. Without Full Access the keyboard can neither
/// write them nor open the app, so it says so and leaves them read-only.
struct KeyboardSettingsPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 17, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: model.actions.hideOverlay) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(KeyboardChrome.backdrop, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.keyboardPress)
                .accessibilityLabel("Close settings")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                Rectangle().fill(KeyboardChrome.border).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.hasFullAccess {
                        Text("Turn on Allow Full Access in Settings › Murmur › Keyboards to change these.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(KeyboardChrome.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                    }
                    section("Feedback")
                    toggle("Haptic feedback", isOn: model.keyboardFeedback, set: model.actions.setKeyboardFeedback)
                    toggle("Vibrate when text is ready", isOn: model.readyHaptic, set: model.actions.setReadyHaptic)
                    toggle("Start and stop sounds", isOn: model.interactionSounds,
                           set: model.actions.setInteractionSounds)
                    section("Appearance")
                    appearancePicker
                    moreSettings
                        .padding(.top, 14)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(KeyboardChrome.panel, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(KeyboardChrome.border, lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .shadow(color: KeyboardChrome.shadow.opacity(0.20), radius: 20, y: 18)
        .shadow(color: KeyboardChrome.shadow.opacity(0.08), radius: 3, y: 2)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(KeyboardChrome.muted)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func toggle(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
        }
        .tint(KeyboardChrome.accent)
        .disabled(!model.hasFullAccess)
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
    }

    /// Light / Dark / Auto, drawn like the mock's segmented control.
    private var appearancePicker: some View {
        HStack(spacing: 4) {
            ForEach([KeyboardAppearancePreference.light, .dark, .automatic]) { option in
                let selected = model.appearance == option
                Button {
                    model.actions.setAppearance(option)
                } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(KeyboardChrome.surface)
                                    .shadow(color: KeyboardChrome.shadow.opacity(0.15), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.keyboardPress)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(KeyboardChrome.backdrop, in: .rect(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10)
        .disabled(!model.hasFullAccess)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }

    private var moreSettings: some View {
        Button(action: model.actions.openApp) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("More settings in Murmur")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Languages, layout and your default style")
                        .font(.system(size: 12.5))
                        .foregroundStyle(KeyboardChrome.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.muted)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
            .overlay(alignment: .top) {
                Rectangle().fill(KeyboardChrome.border).frame(height: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .disabled(!model.hasFullAccess)
        .opacity(model.hasFullAccess ? 1 : 0.5)
    }
}
