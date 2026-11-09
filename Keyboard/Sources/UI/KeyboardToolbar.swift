import MurmurCore
import SwiftUI

/// The row above the keys. The voice keyboard's (Anton's mock): settings, the style pill and
/// Delete. The key layouts': settings, then the style and language pills (or a notice, a caption
/// or the last dictation in their place), then the mic.
struct KeyboardToolbar: View {
    let model: KeyboardModel

    var body: some View {
        Group {
            if model.showsVoicePad {
                voiceBar
            } else {
                keysBar
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(KeyboardChrome.border).frame(height: 1)
        }
    }

    private var voiceBar: some View {
        HStack(spacing: 8) {
            settingsButton
            StylePill(model: model)
            Spacer(minLength: 0)
            memoryReadout
            DeleteKey(model: model)
        }
        .padding(.horizontal, 12)
    }

    private var keysBar: some View {
        HStack(spacing: 6) {
            settingsButton
            keysCenter
                .frame(maxWidth: .infinity, alignment: .leading)
            memoryReadout
            if !model.isCapturing {
                MicButton(model: model, size: 40, ringed: false)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 6)
    }

    private var settingsButton: some View {
        let open = model.overlay == .settings
        let size: CGFloat = model.showsVoicePad ? 44 : 36
        return Button {
            open ? model.actions.hideOverlay() : model.actions.showOverlay(.settings)
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: model.showsVoicePad ? 17 : 15, weight: .semibold))
                .foregroundStyle(open ? KeyboardChrome.accentGlyph : Color.primary)
                .frame(width: size, height: size)
                .background {
                    if open {
                        Circle().fill(KeyboardChrome.accent)
                    } else {
                        KeyboardSurface(shape: Circle())
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Keyboard settings")
    }

    @ViewBuilder
    private var memoryReadout: some View {
        if let memory = model.debugMemory {
            Text(memory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(KeyboardChrome.muted)
        }
    }

    @ViewBuilder
    private var keysCenter: some View {
        if let pending = model.pendingResult {
            HStack(spacing: 6) {
                Button(action: model.actions.insertPending) {
                    Label("Insert last dictation", systemImage: "arrow.uturn.down")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background { KeyboardSurface(shape: Capsule(), active: true) }
                        .frame(minHeight: 44)
                }
                .buttonStyle(.keyboardPress)
                .accessibilityHint(pending.text)
                dismissButton(model.actions.dismissPending)
            }
        } else {
            switch model.phase {
            case .needsFullAccess:
                banner(title: "Almost there!",
                       detail: "Turn on Allow Full Access in Settings › Murmur › Keyboards",
                       dismiss: model.actions.dismissNotice)
            case .notice(let message):
                banner(title: nil, detail: message, dismiss: model.actions.dismissNotice)
            case .needsReconnect:
                caption("Tap the mic to reconnect")
            case .openingApp:
                caption("Opening Murmur…")
            case .starting:
                caption("Starting…")
            case .idle, .listening, .processing:
                ViewThatFits(in: .horizontal) {
                    pills(tiles: true)
                    pills(tiles: false)
                }
            }
        }
    }

    private func pills(tiles: Bool) -> some View {
        HStack(spacing: 6) {
            StylePill(model: model, compact: true, showsDisc: tiles)
            languagePill(tile: tiles)
        }
    }

    /// Opens the language sheet over the keys.
    private func languagePill(tile: Bool) -> some View {
        Button { model.actions.showOverlay(.languages) } label: {
            HStack(spacing: 6) {
                if tile, model.translationEnabled {
                    TranslateGlyph(tile: KeyboardChrome.translateTile)
                        .frame(width: 19, height: 19)
                        .frame(width: 26, height: 26)
                        .background(KeyboardChrome.translateTile, in: .rect(cornerRadius: 8, style: .continuous))
                }
                Text(model.languagePillTitle)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.leading, tile && model.translationEnabled ? 5 : 12)
            .padding(.trailing, 11)
            .frame(height: 36)
            .background { KeyboardSurface(shape: Capsule()) }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .disabled(model.locksSessionOptions)
        .accessibilityLabel(model.translationEnabled
            ? "Translate from \(model.effectiveLanguage.localizedName) to \(model.targetLanguage.localizedName)"
            : "Dictation language: \(model.effectiveLanguage.localizedName)")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(KeyboardChrome.muted)
            .lineLimit(1)
    }

    private func banner(title: String?, detail: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(KeyboardChrome.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            dismissButton(dismiss)
        }
    }

    private func dismissButton(_ dismiss: @escaping () -> Void) -> some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 30, height: 30)
                .background { KeyboardSurface(shape: Circle()) }
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Dismiss")
    }
}

/// Replaces the key layouts' keys while a dictation runs: the voice keyboard's talk button, ✕
/// beside it, and the waveform and status line under it.
struct ListeningPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 12) {
            MicButton(model: model, size: 64)
                .overlay {
                    CancelChip(model: model)
                        .offset(x: -(32 + 28 + 22))
                }
            Group {
                if case .listening = model.phase {
                    VStack(spacing: 6) {
                        Waveform(model: model, height: 24)
                        StatusLine(model: model)
                    }
                } else {
                    StatusLine(model: model)
                }
            }
            .frame(height: 48)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
