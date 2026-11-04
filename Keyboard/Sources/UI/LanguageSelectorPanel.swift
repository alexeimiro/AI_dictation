import MurmurCore
import SwiftUI

/// A keyboard-sized bottom sheet. Keeping it inside the extension avoids presenting a modal
/// controller over the host app and makes language changes feel immediate.
struct LanguageSelectorPanel: View {
    let model: KeyboardModel

    var body: some View {
        if model.showsLanguageSelector {
            VStack(spacing: 0) {
                header
                Divider()
                translationToggle
                direction
                if model.translationEnabled, !eligibleRecent.isEmpty {
                    recent
                }
                Spacer(minLength: 4)
                Text(model.idleHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 14)
            .background(.regularMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack {
            Text("Languages")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button(action: model.actions.hideLanguageSelector) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Close language settings")
        }
        .frame(height: 40)
    }

    private var translationToggle: some View {
        Toggle(isOn: Binding(
            get: { model.translationEnabled },
            set: { enabled in model.actions.setTranslationEnabled(enabled) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Translation")
                    .font(.system(size: 14, weight: .semibold))
                Text(model.translationEnabled ? "On · inserted automatically" : "Off · type what you say")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .frame(height: 48)
    }

    private var direction: some View {
        HStack(spacing: 10) {
            languageMenu(title: "Speak", selection: model.effectiveLanguage,
                         choices: model.languageChoices) { language in
                model.actions.setLanguage(language == model.primaryLanguage ? nil : language)
            }

            Button(action: model.actions.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.thinMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!model.translationEnabled || model.effectiveLanguage.isAutomatic)
            .opacity(!model.translationEnabled || model.effectiveLanguage.isAutomatic ? 0.35 : 1)
            .accessibilityLabel("Swap languages")

            languageMenu(title: "Type", selection: model.targetLanguage,
                         choices: model.targetLanguageChoices,
                         disabled: !model.translationEnabled,
                         action: model.actions.setTargetLanguage)
        }
        .padding(.vertical, 8)
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
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text(selection.localizedName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(.thinMaterial, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var recent: some View {
        HStack(spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(eligibleRecent.prefix(4)) { language in
                Button(language.shortCode) { model.actions.setTargetLanguage(language) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.thinMaterial, in: .capsule)
            }
            Spacer(minLength: 0)
        }
    }

    private var eligibleRecent: [DictationLanguage] {
        model.recentLanguages.filter { $0.languageCode != model.effectiveLanguage.languageCode }
    }
}
