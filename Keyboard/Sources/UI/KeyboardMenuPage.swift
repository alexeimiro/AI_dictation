import MurmurCore
import SwiftUI

/// The menu page, in place of the pad or the keys: translation with recent targets, adding a
/// word to the dictionary, then the keyboard's own settings. Its toolbar holds ✕, ABC and the way
/// to Murmur's Settings.
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
                section("Dictionary")
                dictionaryRow
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
        Text(title)
            .font(.system(size: 12, weight: .semibold))
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
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(KeyboardChrome.primary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            KeyboardSwitch(label: title, isOn: Binding(get: { isOn }, set: set))
        }
        .disabled(!model.hasFullAccess)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minHeight: 46)
    }

    /// "Add “Mironenko” to dictionary": the selection, or the word before the cursor, so a name
    /// the keyboard got wrong and the user fixed is spelled right from the next dictation on.
    private var dictionaryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: model.addedToDictionary == nil ? "character.book.closed" : "checkmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KeyboardChrome.primary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Group {
                if let added = model.addedToDictionary {
                    Text("Added \u{201C}\(added)\u{201D} to your dictionary")
                } else if let word = model.dictionaryCandidate {
                    Text("Add \u{201C}\(word)\u{201D} to dictionary")
                } else {
                    Text("Select a word to add it to your dictionary")
                        .foregroundStyle(KeyboardChrome.muted)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(KeyboardChrome.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
            if model.addedToDictionary == nil, let word = model.dictionaryCandidate {
                Button { model.actions.addToDictionary(word) } label: {
                    Text("Add")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KeyboardChrome.primaryGlyph)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(KeyboardChrome.primary, in: Capsule(style: .circular))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.keyboardPress)
                .disabled(!model.hasFullAccess)
                .accessibilityLabel("Add \(word) to dictionary")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                      fill: KeyboardChrome.card) }
        .accessibilityElement(children: .combine)
    }

    private var recent: some View {
        HStack(spacing: 6) {
            Text("Recent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KeyboardChrome.muted)
            ForEach(eligibleRecent.prefix(4)) { language in
                let selected = language.languageCode == model.targetLanguage.languageCode
                Button { model.actions.setTargetLanguage(language) } label: {
                    OutlineChip(height: 28, filled: selected) {
                        Text(language.shortCode).font(.system(size: 12, weight: .bold))
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
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

    /// Light / Dark / Auto as one capsule of three, the chosen one in ink.
    private var appearancePicker: some View {
        HStack(spacing: 3) {
            ForEach([KeyboardAppearancePreference.light, .dark, .automatic]) { option in
                let selected = model.appearance == option
                Button {
                    model.actions.setAppearance(option)
                } label: {
                    Text(option.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? KeyboardChrome.primaryGlyph : KeyboardChrome.primary)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if selected {
                                Capsule(style: .circular).fill(KeyboardChrome.primary)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.keyboardPress)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background { KeyboardSurface(shape: Capsule(style: .circular), fill: KeyboardChrome.card) }
        .disabled(!model.hasFullAccess)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Appearance")
    }
}
