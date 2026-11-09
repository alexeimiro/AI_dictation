import MurmurCore
import SwiftUI

/// The key layouts' language sheet: the translate row, recent targets and what the next dictation
/// will do. The voice keyboard shows the row itself. Kept inside the extension, so language
/// changes feel immediate and no modal opens over the host app.
struct LanguageSelectorPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TranslateRow(model: model)
            if model.translationEnabled, !eligibleRecent.isEmpty {
                recent
            }
            Spacer(minLength: 0)
            Text(model.idleHint)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(KeyboardChrome.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .background(KeyboardChrome.panel, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(KeyboardChrome.border, lineWidth: 1)
        }
        .shadow(color: KeyboardChrome.shadow.opacity(0.18), radius: 20, y: 18)
        .shadow(color: KeyboardChrome.shadow.opacity(0.08), radius: 3, y: 2)
    }

    private var header: some View {
        HStack {
            Text("Languages")
                .font(.system(size: 17, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: model.actions.hideOverlay) {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background { KeyboardSurface(shape: Capsule()) }
                    .frame(minHeight: 44)
            }
            .buttonStyle(.keyboardPress)
            .accessibilityLabel("Close language settings")
        }
        .padding(.leading, 10)
        .frame(height: 48)
    }

    private var recent: some View {
        HStack(spacing: 6) {
            Text("Recent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KeyboardChrome.muted)
            ForEach(eligibleRecent.prefix(4)) { language in
                Button { model.actions.setTargetLanguage(language) } label: {
                    Text(language.shortCode)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background {
                            KeyboardSurface(shape: Capsule(),
                                            active: language.languageCode == model.targetLanguage.languageCode)
                        }
                        .frame(minHeight: 44)
                }
                .buttonStyle(.keyboardPress)
                .disabled(model.locksSessionOptions)
                .accessibilityLabel("Type in \(language.localizedName)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private var eligibleRecent: [DictationLanguage] {
        model.recentLanguages.filter { $0.languageCode != model.effectiveLanguage.languageCode }
    }
}
