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
            // Solid while translation is on, outlined while it is off.
            Image(systemName: "translate")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(on ? KeyboardChrome.primaryGlyph : KeyboardChrome.primary)
                .frame(width: 36, height: 36)
                .background(on ? KeyboardChrome.primary : .clear, in: .rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    if !on {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(KeyboardChrome.primary, lineWidth: 1.5)
                    }
                }
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                LanguageMenu(title: "From", accessibilityTitle: "Translate from",
                             selection: model.effectiveLanguage, choices: model.languageChoices) { language in
                    model.actions.setLanguage(language == model.primaryLanguage ? nil : language)
                }

                Button(action: model.actions.swapLanguages) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(KeyboardChrome.primary)
                        .frame(width: 40, height: 44)
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

            KeyboardSwitch(label: "Translate", isOn: Binding(
                get: { model.translationEnabled },
                set: { model.actions.setTranslationEnabled($0) }))
        }
        .foregroundStyle(KeyboardChrome.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                    .foregroundStyle(KeyboardChrome.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .frame(minWidth: 48, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("\(accessibilityTitle) \(selection.localizedName)")
    }
}

/// The toolbar's sign that translation is on, "Auto → RU" ("→ RU" where that doesn't fit): an
/// outlined chip that opens the menu page.
struct TranslateChip: View {
    let model: KeyboardModel
    var height: CGFloat = 46

    var body: some View {
        Button { model.actions.showOverlay(.menu) } label: {
            ViewThatFits(in: .horizontal) {
                chip("\(model.effectiveLanguage.isAutomatic ? "Auto" : model.effectiveLanguage.shortCode) → \(model.targetLanguage.shortCode)")
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
        OutlineChip { Text(text) }
            .frame(height: height)
            .padding(.horizontal, 2)
            .contentShape(.rect)
    }
}
