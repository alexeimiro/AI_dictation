import MurmurBrand
import MurmurCore
import SwiftUI

/// The row above the keys: the menu on the left and the main controls on the right, 46 pt tall
/// and 12 pt from the top, with no divider. The voice keyboard keeps Delete there; the key layouts
/// have the mic, or Start while no session runs. While a dictation runs ✕ takes the menu's place
/// and the style pill fades; while a page is open ✕ closes it.
struct KeyboardToolbar: View {
    let model: KeyboardModel

    var body: some View {
        let metrics = BarMetrics.of(model)
        HStack(spacing: 4) {
            leading(metrics)
            // The spacer keeps the right-hand controls at the edge when the centre is empty.
            HStack(spacing: 0) {
                centre(metrics)
                Spacer(minLength: 0)
            }
            memoryReadout
            trailing(metrics)
        }
        .padding(.horizontal, 8)
        .padding(.top, metrics.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(KeyboardChrome.primary)
    }

    @ViewBuilder
    private func leading(_ metrics: BarMetrics) -> some View {
        if let overlay = model.overlay {
            BarGlyphButton(size: metrics.control, label: overlay == .menu ? "Close menu" : "Close styles",
                           action: model.actions.hideOverlay) {
                Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
            }
        } else if model.isCapturing {
            CancelChip(model: model, size: metrics.control)
        } else {
            BarGlyphButton(size: metrics.control, label: "Menu", action: { model.actions.showOverlay(.menu) }) {
                MenuGlyph()
                    .stroke(KeyboardChrome.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 24, height: 24)
            }
        }
    }

    @ViewBuilder
    private func centre(_ metrics: BarMetrics) -> some View {
        if model.overlay != nil || model.isCapturing {
            EmptyView()
        } else if model.showsVoicePad {
            // The voice pad shows its notices over the talk button.
            if model.translationEnabled {
                TranslateChip(model: model, height: metrics.control)
            }
        } else if let pending = model.pendingResult {
            HStack(spacing: 0) {
                Button(action: model.actions.insertPending) {
                    ViewThatFits(in: .horizontal) {
                        insertLabel("Insert last dictation", metrics: metrics)
                        insertLabel("Insert", metrics: metrics)
                    }
                }
                .buttonStyle(.keyboardPress)
                .accessibilityLabel("Insert last dictation")
                .accessibilityHint(pending.text)
                dismissButton(model.actions.dismissPending)
            }
        } else {
            switch model.phase {
            case .needsFullAccess:
                banner(title: "One switch left",
                       detail: "Turn on Allow Full Access in Settings › Murmur › Keyboards",
                       dismiss: model.actions.dismissNotice)
            case .notice(let message):
                // Whole, on two lines: beside the pill and the mic a title would be cut short.
                banner(title: nil, detail: message, dismiss: model.actions.dismissNotice)
            case .needsReconnect:
                caption("Tap Start to reconnect")
            case .openingApp:
                caption("Opening Murmur…")
            case .starting:
                caption("Starting…")
            case .idle, .listening, .processing:
                if model.translationEnabled {
                    TranslateChip(model: model, height: metrics.control)
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(_ metrics: BarMetrics) -> some View {
        switch model.overlay {
        case .menu:
            HStack(spacing: 0) {
                OutlinedDisc(size: metrics.disc, target: metrics.control, label: "Letters",
                             action: model.actions.showLetters) {
                    Text("ABC").font(.system(size: 12, weight: .bold))
                }
                OutlinedDisc(size: metrics.disc, target: metrics.control, label: "Murmur settings",
                             action: model.actions.openApp) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 16, weight: .medium))
                }
                .disabled(!model.hasFullAccess)
                .opacity(model.hasFullAccess ? 1 : 0.4)
            }
        case .style:
            StylePill(model: model, height: metrics.control)
        case nil:
            if model.showsVoicePad {
                HStack(spacing: 0) {
                    StylePill(model: model, height: metrics.control)
                    if !model.isCapturing {
                        DeleteKey(model: model, size: metrics.control)
                    }
                }
            } else if model.isSessionLive || model.isCapturing || model.isTransitioning {
                HStack(spacing: 0) {
                    StylePill(model: model, height: metrics.control)
                    MicButton(model: model, size: metrics.disc)
                        .frame(width: metrics.control, height: metrics.control)
                }
            } else {
                StartPill(model: model, height: metrics.disc)
                    .frame(height: metrics.control)
            }
        }
    }

    @ViewBuilder
    private var memoryReadout: some View {
        if let memory = model.debugMemory {
            Text(memory)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(KeyboardChrome.muted)
        }
    }

    /// The waiting dictation on the key layouts: a key-coloured capsule in the bar.
    private func insertLabel(_ title: String, metrics: BarMetrics) -> some View {
        Label(title, systemImage: "arrow.uturn.down")
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: metrics.disc)
            .background { KeyboardSurface(shape: Capsule(style: .circular)) }
            .frame(height: metrics.control)
            .padding(.horizontal, 2)
            .contentShape(.rect)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(KeyboardChrome.muted)
            .lineLimit(1)
            .padding(.leading, 4)
    }

    private func banner(title: String?, detail: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
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
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            dismissButton(dismiss)
        }
    }

    private func dismissButton(_ dismiss: @escaping () -> Void) -> some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Dismiss")
    }
}

/// A bare glyph in the bar: the menu, ✕.
struct BarGlyphButton<Content: View>: View {
    let size: CGFloat
    let label: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(KeyboardChrome.primary)
                .frame(width: size, height: size)
                .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel(label)
    }
}

/// An outlined disc in the menu page's bar: ABC and Murmur's Settings.
private struct OutlinedDisc<Content: View>: View {
    let size: CGFloat
    /// The touch target around the disc.
    let target: CGFloat
    let label: String
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(KeyboardChrome.primary)
                .frame(width: size, height: size)
                .overlay { Circle().strokeBorder(KeyboardChrome.primary, lineWidth: 1.5) }
                .frame(width: target, height: target)
                .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel(label)
    }
}

/// "Start" on the key layouts while no session runs: it opens Murmur, which starts one and listens
/// straight away.
private struct StartPill: View {
    let model: KeyboardModel
    var height: CGFloat

    var body: some View {
        Button(action: model.actions.mic) {
            HStack(spacing: 8) {
                BrandMark(ring: KeyboardChrome.primaryGlyph)
                    .frame(width: 18, height: 18)
                Text("Start")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(KeyboardChrome.primaryGlyph)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: height)
            .background(KeyboardChrome.primary, in: Capsule(style: .circular))
            .padding(.horizontal, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Start Murmur")
        .accessibilityHint("Opens Murmur to start listening")
        .accessibilityAddTraits(.startsMediaSession)
    }
}

/// Replaces the key layouts' keys while a dictation runs: the red dot with its rings while it
/// listens, and two lines. The toolbar holds ✕ and ✓.
struct ListeningPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 30) {
            if model.listeningSince != nil {
                Circle()
                    .fill(KeyboardChrome.live)
                    .frame(width: 24, height: 24)
                    .background { LevelRings(model: model, diameter: 24) }
                    .accessibilityHidden(true)
            }
            ListeningCaption(model: model)
        }
        .foregroundStyle(KeyboardChrome.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
