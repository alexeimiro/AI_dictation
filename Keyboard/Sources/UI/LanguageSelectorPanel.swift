import MurmurCore
import SwiftUI

/// A keyboard-sized bottom sheet. Keeping it inside the extension avoids presenting a modal
/// controller over the host app and makes language changes feel immediate.
struct LanguageSelectorPanel: View {
    let model: KeyboardModel

    var body: some View {
        if model.showsLanguageSelector {
            ZStack {
                KeyboardChrome.backdrop.opacity(0.92)
                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 32, height: 4)
                        .padding(.top, 7)
                        .padding(.bottom, 3)
                    header
                    translationToggle
                    direction
                    if model.translationEnabled, !eligibleRecent.isEmpty {
                        recent
                    }
                    Spacer(minLength: 2)
                    Text(model.idleHint)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .padding(.bottom, 9)
                }
                .padding(.horizontal, 12)
                .background(KeyboardChrome.panel, in: .rect(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).stroke(KeyboardChrome.border, lineWidth: 0.7) }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack {
            Text("Languages")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Spacer()
            Button(action: model.actions.hideLanguageSelector) {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background { KeyboardSurface(shape: Capsule()) }
                    .frame(minHeight: 44)
            }
            .buttonStyle(.keyboardPress)
            .accessibilityLabel("Close language settings")
        }
        .frame(height: 44)
    }

    private var translationToggle: some View {
        Toggle(isOn: Binding(
            get: { model.translationEnabled },
            set: { enabled in model.actions.setTranslationEnabled(enabled) }
        )) {
            HStack(spacing: 10) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.translationEnabled ? KeyboardChrome.accent : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(model.translationEnabled ? KeyboardChrome.accentSoft : KeyboardChrome.surface,
                                in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Translate as you speak")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.translationEnabled ? "On · text inserts automatically" : "Off · keep spoken language")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel("Translate as you speak")
        .accessibilityValue(model.translationEnabled ? "On" : "Off")
        .disabled(model.locksSessionOptions)
        .tint(KeyboardChrome.accent)
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 13)) }
    }

    private var direction: some View {
        HStack(spacing: 10) {
            languageMenu(title: "Speak", selection: model.effectiveLanguage,
                         choices: model.languageChoices) { language in
                model.actions.setLanguage(language == model.primaryLanguage ? nil : language)
            }

            Button(action: model.actions.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background { KeyboardSurface(shape: Circle(), active: model.translationEnabled) }
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.keyboardPress)
            .disabled(model.locksSessionOptions || !model.translationEnabled || model.effectiveLanguage.isAutomatic)
            .opacity(model.locksSessionOptions || !model.translationEnabled || model.effectiveLanguage.isAutomatic ? 0.58 : 1)
            .accessibilityLabel("Swap languages")

            languageMenu(title: "Type", selection: model.targetLanguage,
                         choices: model.targetLanguageChoices,
                         disabled: !model.translationEnabled,
                         action: model.actions.setTargetLanguage)
        }
        .padding(.vertical, 6)
    }

    private func languageMenu(
        title: String,
        selection: DictationLanguage,
        choices: [DictationLanguage],
        disabled: Bool = false,
        action: @escaping (DictationLanguage) -> Void
    ) -> some View {
        Menu {
            ForEach(choices) { language in
                Button {
                    action(language)
                } label: {
                    if language.languageCode == selection.languageCode {
                        Label(language.localizedName, systemImage: "checkmark")
                    } else {
                        Text(language.localizedName)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(selection.shortCode)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(KeyboardChrome.accent)
                    Text(selection.localizedName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 13), active: !disabled) }
        }
        .buttonStyle(.keyboardPress)
        .disabled(disabled || model.locksSessionOptions)
        .opacity(disabled || model.locksSessionOptions ? 0.58 : 1)
    }

    private var recent: some View {
        HStack(spacing: 6) {
            Text("Recent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(eligibleRecent.prefix(4)) { language in
                Button { model.actions.setTargetLanguage(language) } label: {
                    Text(language.shortCode)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background { KeyboardSurface(shape: Capsule()) }
                        .frame(minHeight: 44)
                }
                .buttonStyle(.keyboardPress)
                .disabled(model.locksSessionOptions)
                .accessibilityLabel("Type in \(language.localizedName)")
            }
            Spacer(minLength: 0)
        }
    }

    private var eligibleRecent: [DictationLanguage] {
        model.recentLanguages.filter { $0.languageCode != model.effectiveLanguage.languageCode }
    }
}
