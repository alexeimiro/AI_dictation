import MurmurCore
import SwiftUI

/// The translate row from Anton's mock: the A/文 tile, From and To, swap, and the switch. From is
/// also the dictation language (Auto or a pinned one), so it stays usable with translation off;
/// To and swap follow the switch. While a dictation runs its options are locked, but the row stays
/// readable.
struct TranslateRow: View {
    let model: KeyboardModel

    var body: some View {
        let on = model.translationEnabled
        let canSwap = on && !model.effectiveLanguage.isAutomatic
        HStack(spacing: 8) {
            TranslateGlyph(tile: on ? KeyboardChrome.translateTile : KeyboardChrome.offTrack)
                .frame(width: 26, height: 26)
                .frame(width: 36, height: 36)
                .background(on ? KeyboardChrome.translateTile : KeyboardChrome.offTrack,
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
                .tint(KeyboardChrome.accent)
                .accessibilityLabel("Translate")
                .padding(.trailing, 2)
        }
        .foregroundStyle(.primary)
        .padding(.leading, 7)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
        .disabled(model.locksSessionOptions)
    }
}

/// A From or To button that opens the language list, with a check on the current language.
/// Shared by the translate row and the languages sheet.
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
            .background(KeyboardChrome.backdrop, in: .rect(cornerRadius: 12, style: .continuous))
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("\(accessibilityTitle) \(selection.localizedName)")
    }
}

/// The mock's translate glyph on a 24 pt grid: a white speech bubble with "A" and a dark one with
/// "文", ringed in the colour of the tile behind it.
struct TranslateGlyph: View {
    var tile: Color

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 24
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: x * unit, y: y * unit, width: width * unit, height: height * unit)
            }
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            let ink = Color(uiColor: UIColor(hex: 0x14161C))

            var light = Path(roundedRect: rect(1.5, 2.5, 12, 10), cornerRadius: 2.5 * unit)
            light.addLines([point(4.5, 12), point(4.5, 15.2), point(7.7, 12)])
            light.closeSubpath()
            context.fill(light, with: .color(.white))
            context.draw(Text("A").font(.system(size: 8 * unit, weight: .bold)).foregroundStyle(ink),
                         at: point(7.5, 7.7))

            let bubble = Path(roundedRect: rect(10, 9, 12.5, 10), cornerRadius: 2.5 * unit)
            var dark = bubble
            dark.addLines([point(19.5, 18.6), point(19.5, 22), point(16.1, 18.6)])
            dark.closeSubpath()
            context.fill(dark, with: .color(ink))
            context.stroke(bubble, with: .color(tile), lineWidth: 1.2 * unit)
            context.draw(Text("文").font(.system(size: 7.5 * unit, weight: .semibold)).foregroundStyle(.white),
                         at: point(16.25, 14.1))
        }
    }
}
