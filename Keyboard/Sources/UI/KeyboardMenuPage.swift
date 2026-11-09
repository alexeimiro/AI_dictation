import MurmurCore
import SwiftUI

/// The ☰ page, in place of the pad or the keys as Wispr Flow's menu is: translation with recent
/// targets, then the keyboard's own settings. Its toolbar holds ✕, ABC and ⚙ (Murmur's Settings).
/// Without Full Access the keyboard can neither write the settings nor open the app, so it says so
/// and leaves them read-only.
struct KeyboardMenuPage: View {
    let model: KeyboardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.hasFullAccess {
                    Text("Turn on Allow Full Access in Settings › Murmur › Keyboards to change these.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(KeyboardChrome.muted)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }
                section("Translate")
                TranslateRow(model: model)
                if model.translationEnabled, !eligibleRecent.isEmpty {
                    recent
                }
                section("Feedback")
                VStack(spacing: 0) {
                    toggle("Haptic feedback", isOn: model.keyboardFeedback, set: model.actions.setKeyboardFeedback)
                    divider
                    toggle("Vibrate when text is ready", isOn: model.readyHaptic, set: model.actions.setReadyHaptic)
                    divider
                    toggle("Start and stop sounds", isOn: model.interactionSounds,
                           set: model.actions.setInteractionSounds)
                }
                .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                              fill: KeyboardChrome.card) }
                section("Appearance")
                appearancePicker
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(KeyboardChrome.muted)
            .padding(.horizontal, 4)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private var divider: some View {
        Rectangle()
            .fill(KeyboardChrome.border)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    private func toggle(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
        }
        .tint(KeyboardChrome.switchTint)
        .disabled(!model.hasFullAccess)
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }

    private var recent: some View {
        HStack(spacing: 6) {
            Text("Recent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KeyboardChrome.muted)
            ForEach(eligibleRecent.prefix(4)) { language in
                let selected = language.languageCode == model.targetLanguage.languageCode
                Button { model.actions.setTargetLanguage(language) } label: {
                    Text(language.shortCode)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selected ? KeyboardChrome.primaryGlyph : Color.primary)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background {
                            KeyboardSurface(shape: Capsule(), fill: selected ? KeyboardChrome.primary : KeyboardChrome.key)
                        }
                        .frame(minHeight: 44)
                }
                .buttonStyle(.keyboardPress)
                .disabled(model.locksSessionOptions)
                .accessibilityLabel("Type in \(language.localizedName)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var eligibleRecent: [DictationLanguage] {
        model.recentLanguages.filter { $0.languageCode != model.effectiveLanguage.languageCode }
    }

    /// Light / Dark / Auto as a segmented control.
    private var appearancePicker: some View {
        HStack(spacing: 4) {
            ForEach([KeyboardAppearancePreference.light, .dark, .automatic]) { option in
                let selected = model.appearance == option
                Button {
                    model.actions.setAppearance(option)
                } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? KeyboardChrome.primaryGlyph : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(KeyboardChrome.primary)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.keyboardPress)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                      fill: KeyboardChrome.card) }
        .disabled(!model.hasFullAccess)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }
}
