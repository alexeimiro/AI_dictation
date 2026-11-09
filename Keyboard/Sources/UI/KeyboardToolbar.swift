import MurmurCore
import SwiftUI

/// The row above the keys, laid out like Wispr Flow's: ☰ on the left and the main controls on the
/// right, 46 pt tall and 12 pt in from the edges, with no divider. The voice keyboard keeps Delete
/// there; the key layouts have the mic, or Start while no session runs. While a dictation runs a
/// grey ✕ takes ☰'s place and the style pill dims; while a page is open a white ✕ closes it.
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
            .padding(.leading, 4)
            memoryReadout
            trailing(metrics)
        }
        .padding(.horizontal, 12)
        .padding(.top, metrics.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func leading(_ metrics: BarMetrics) -> some View {
        if let overlay = model.overlay {
            CircleButton(size: metrics.control, label: overlay == .menu ? "Close menu" : "Close styles",
                         action: model.actions.hideOverlay) {
                Image(systemName: "xmark")
                    .font(.system(size: metrics.control * 0.36, weight: .medium))
            }
        } else if model.isCapturing {
            CancelChip(model: model, size: metrics.control)
        } else {
            Button { model.actions.showOverlay(.menu) } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20))
                    .frame(width: metrics.control, height: metrics.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.keyboardPress)
            .accessibilityLabel("Menu")
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
            HStack(spacing: 4) {
                Button(action: model.actions.insertPending) {
                    ViewThatFits(in: .horizontal) {
                        insertLabel("Insert last dictation", height: metrics.control)
                        insertLabel("Insert", height: metrics.control)
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
                banner(title: "Almost there!",
                       detail: "Turn on Allow Full Access in Settings › Murmur › Keyboards",
                       dismiss: model.actions.dismissNotice)
            case .notice(let message):
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
            HStack(spacing: 4) {
                CircleButton(size: metrics.control, label: "Letters", action: model.actions.showLetters) {
                    Text("ABC")
                        .font(.system(size: 15, weight: .medium))
                }
                CircleButton(size: metrics.control, label: "Murmur settings", action: model.actions.openApp) {
                    Image(systemName: "gearshape")
                        .font(.system(size: metrics.control * 0.42))
                }
                .disabled(!model.hasFullAccess)
                .opacity(model.hasFullAccess ? 1 : 0.4)
            }
        case .style:
            StylePill(model: model, height: metrics.control)
        case nil:
            if model.showsVoicePad {
                HStack(spacing: 4) {
                    StylePill(model: model, height: metrics.control)
                    if !model.isCapturing {
                        DeleteKey(model: model, size: metrics.control)
                    }
                }
            } else if model.isSessionLive || model.isCapturing || model.isTransitioning {
                HStack(spacing: 4) {
                    StylePill(model: model, height: metrics.control)
                    MicButton(model: model, size: metrics.control)
                }
            } else {
                StartPill(model: model, height: metrics.control)
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

    private func insertLabel(_ title: String, height: CGFloat) -> some View {
        Label(title, systemImage: "arrow.uturn.down")
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: height)
            .background { KeyboardSurface(shape: Capsule()) }
            .contentShape(.capsule)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(KeyboardChrome.muted)
            .lineLimit(1)
    }

    private func banner(title: String?, detail: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
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
                .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Dismiss")
    }
}

/// A white (light: ink) circle in the toolbar, like Wispr's mic, ✕, ABC and ⚙.
private struct CircleButton<Content: View>: View {
    let size: CGFloat
    let label: String
    let action: () -> Void
    let content: Content

    init(size: CGFloat, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.size = size
        self.label = label
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(KeyboardChrome.primaryGlyph)
                .frame(width: size, height: size)
                .background(KeyboardChrome.primary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel(label)
    }
}

/// Wispr's "Start" capsule for the key layouts while no session runs: it opens Murmur, which starts
/// one and listens straight away.
private struct StartPill: View {
    let model: KeyboardModel
    var height: CGFloat

    var body: some View {
        Button(action: model.actions.mic) {
            HStack(spacing: 13) {
                Text("Start")
                    .font(.system(size: 17, weight: .medium))
                LogoMarkShape()
                    .fill(KeyboardChrome.primaryGlyph)
                    .frame(width: 20, height: 19)
            }
            .foregroundStyle(KeyboardChrome.primaryGlyph)
            .padding(.horizontal, 17)
            .frame(height: height)
            .background(KeyboardChrome.primary, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Start Murmur")
        .accessibilityHint("Opens Murmur to start listening")
        .accessibilityAddTraits(.startsMediaSession)
    }
}

/// Murmur's mark, three bars and a dot, as `LogoMarkShape` in MurmurUI draws it. The keyboard
/// links only MurmurCore, so it keeps its own copy for the Start capsule.
private struct LogoMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let barHeights: [CGFloat] = [0.48, 1.0, 0.7]
        let unit = rect.width / 8.2
        let barWidth = unit * 1.3
        let gap = unit * 0.9
        var path = Path()
        for (index, height) in barHeights.enumerated() {
            let barRect = CGRect(x: rect.minX + CGFloat(index) * (barWidth + gap),
                                 y: rect.midY - rect.height * height / 2,
                                 width: barWidth, height: rect.height * height)
            path.addRoundedRect(in: barRect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        let dotSize = barWidth * 1.15
        let dotX = rect.minX + 3 * (barWidth + gap) + unit * 0.1
        path.addEllipse(in: CGRect(x: dotX, y: rect.midY - dotSize / 2, width: dotSize, height: dotSize))
        return path
    }
}

/// Replaces the key layouts' keys while a dictation runs, Wispr's listening panel: the dots and two
/// lines. The toolbar holds ✕ and ✓.
struct ListeningPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 18) {
            DotsWaveform(model: model, height: 28)
            ListeningCaption(model: model)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
