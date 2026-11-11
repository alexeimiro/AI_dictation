import MurmurBrand
import MurmurCore
import SwiftUI

/// The talk button: an ink disc with a mic, red with ✓ while it listens (✓ finishes the
/// dictation), and a spinner while starting or writing. The voice pad shows it large, with a ring
/// around it at rest and the echo rings while it listens; the key layouts' toolbar shows it small.
/// It never reads the mic level, so the 20 Hz level updates redraw only `LevelRings`.
struct MicButton: View {
    let model: KeyboardModel
    var size: CGFloat
    /// The voice pad's disc carries the rings; the toolbar's small one doesn't.
    var showsRings = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let listening = model.listeningSince != nil
        Button(action: listening ? model.actions.stop : model.actions.mic) {
            Circle()
                // Red only while the microphone is open for this dictation.
                .fill(listening ? KeyboardChrome.live : KeyboardChrome.primary)
                .frame(width: size, height: size)
                .overlay { glyph }
                .background {
                    if showsRings {
                        if listening {
                            LevelRings(model: model, diameter: size)
                        } else if !model.isTransitioning {
                            Circle()
                                .strokeBorder(KeyboardChrome.primary.opacity(contrast == .increased ? 0.6 : 0.28),
                                              lineWidth: 1.5)
                                .frame(width: size + 18, height: size + 18)
                        }
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.keyboardPress)
        .disabled(model.isTransitioning)
        .accessibilityLabel(listening ? "Finish dictation" : model.isTransitioning ? "Working" : "Start dictation")
        .accessibilityAddTraits(.startsMediaSession)
    }

    @ViewBuilder
    private var glyph: some View {
        switch model.phase {
        case .starting, .openingApp, .processing:
            ProgressView()
                .tint(KeyboardChrome.primaryGlyph)
                .controlSize(size > 50 ? .large : .regular)
        case .listening:
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(KeyboardChrome.liveGlyph)
                .transition(.scale.combined(with: .opacity))
        default:
            Image(systemName: "mic")
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(KeyboardChrome.primaryGlyph)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// The echo rings around the talk button, swelling with the voice. The only view that reads the
/// mic level, and on screen only while a dictation listens. `EchoRingsView` keeps them still under
/// Reduce Motion and makes them heavier under Increase Contrast.
struct LevelRings: View {
    let model: KeyboardModel
    var diameter: CGFloat

    var body: some View {
        EchoRingsView(levels: model.levels, diameter: diameter, color: KeyboardChrome.live)
    }
}

/// The two lines while a dictation runs: "Listening" with the time (or what the dictation waits
/// for), then what it will do.
struct ListeningCaption: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.captionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.primary)
                if let since = model.listeningSince {
                    Text(since, style: .timer)
                        .font(.system(size: 15))
                        .monospacedDigit()
                        .foregroundStyle(KeyboardChrome.muted)
                }
            }
            Text(model.captionDetail)
                .font(.system(size: 13))
                .foregroundStyle(KeyboardChrome.muted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// The line under the voice pad's talk button while nothing records: what a tap will do, what is
/// happening, or the last dictation with Undo.
struct PadHint: View {
    let model: KeyboardModel

    var body: some View {
        content
            .font(.system(size: 15))
            .foregroundStyle(KeyboardChrome.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .starting:
            Text("Starting…")
        case .openingApp:
            Text("Opening Murmur…")
        case .needsReconnect:
            Text("Tap to reconnect")
        default:
            if let words = model.undoableWords {
                HStack(spacing: 6) {
                    Text("Inserted \(words) \(words == 1 ? "word" : "words")")
                    UndoButton(model: model)
                }
            } else {
                Text(model.isSessionLive ? "Tap to speak" : "Tap to start Murmur")
            }
        }
    }
}

/// Takes the last dictation back out, while the text before the cursor still ends with it.
struct UndoButton: View {
    let model: KeyboardModel

    var body: some View {
        Button(action: model.actions.undo) {
            OutlineChip(height: 30) { Text("Undo") }
                .frame(minHeight: 44)
                .padding(.horizontal, 2)
                .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
    }
}

/// ✕ in the menu's place while a dictation runs: throws the dictation away.
struct CancelChip: View {
    let model: KeyboardModel
    var size: CGFloat = 46

    var body: some View {
        BarGlyphButton(size: size, label: "Cancel transcription", action: model.actions.cancel) {
            Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
        }
        .transition(.opacity)
    }
}
