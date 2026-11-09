import MurmurCore
import SwiftUI

/// The translate row on the ☰ page: the translate tile, From and To, swap, and the switch. From is
/// also the dictation language (Auto or a pinned one), so it stays usable with translation off;
/// To and swap follow the switch. While a dictation runs its options are locked, but the row stays
/// readable.
struct TranslateRow: View {
    let model: KeyboardModel

    var body: some View {
        let on = model.translationEnabled
        let canSwap = on && !model.effectiveLanguage.isAutomatic
        HStack(spacing: 8) {
            Image(systemName: "translate")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(on ? KeyboardChrome.primaryGlyph : Color.primary)
                .frame(width: 36, height: 36)
                .background(on ? KeyboardChrome.primary : KeyboardChrome.key,
                            in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                LanguageMenu(title: "From", accessibilityTitle: "Translate from",
                             selection: model.effectiveLanguage, choices: model.languageChoices) { language in
                    model.actions.setLanguage(language == model.primaryLanguage ? nil : language)
                }

                Button(action: model.actions.swapLanguages) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background { KeyboardSurface(shape: Circle()) }
                        .frame(width: 36, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.keyboardPress)
                .disabled(!canSwap)
                .opacity(canSwap ? 1 : 0.4)
                .accessibilityLabel("Swap languages")

                LanguageMenu(title: "To", accessibilityTitle: "Translate to",
                             selection: model.targetLanguage, choices: model.targetLanguageChoices,
                             action: model.actions.setTargetLanguage)
                    .disabled(!on)
                    .opacity(on ? 1 : 0.4)
            }

            Spacer(minLength: 0)

            Toggle("Translate", isOn: Binding(
                get: { model.translationEnabled },
                set: { model.actions.setTranslationEnabled($0) }))
                .labelsHidden()
                .tint(KeyboardChrome.switchTint)
                .accessibilityLabel("Translate")
                .padding(.trailing, 2)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                      fill: KeyboardChrome.card) }
        .disabled(model.locksSessionOptions)
    }
}

/// A From or To button that opens the language list, with a check on the current language.
struct LanguageMenu: View {
    let title: String
    let accessibilityTitle: String
    let selection: DictationLanguage
    let choices: [DictationLanguage]
    let action: (DictationLanguage) -> Void

    var body: some View {
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
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KeyboardChrome.muted)
                Text(selection.shortCode)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 62, minHeight: 40, alignment: .leading)
            .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("\(accessibilityTitle) \(selection.localizedName)")
    }
}

/// The toolbar's sign that translation is on, "AUTO → RU" ("→ RU" where that doesn't fit). Wispr's
/// keyboard has no translation, so this is the one grey capsule in its bar; it opens the ☰ page.
struct TranslateChip: View {
    let model: KeyboardModel
    var height: CGFloat = 46

    var body: some View {
        Button { model.actions.showOverlay(.menu) } label: {
            ViewThatFits(in: .horizontal) {
                chip("\(model.effectiveLanguage.shortCode) → \(model.targetLanguage.shortCode)")
                chip("→ \(model.targetLanguage.shortCode)")
            }
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel(model.effectiveLanguage.isAutomatic
            ? "Translating into \(model.targetLanguage.localizedName)"
            : "Translating \(model.effectiveLanguage.localizedName) to \(model.targetLanguage.localizedName)")
        .accessibilityHint("Opens the menu")
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: height)
            .background { KeyboardSurface(shape: Capsule()) }
            .contentShape(.capsule)
    }
}
