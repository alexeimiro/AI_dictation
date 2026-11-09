import MurmurCore
import SwiftUI

/// The talk button, after Wispr Flow's: a flat white (light: ink) disc with a mic, a ✓ that
/// finishes the dictation while it listens, and a spinner while starting or transcribing. The voice
/// pad shows it large; the key layouts' toolbar small. It never reads the mic level, so the 20 Hz
/// level updates redraw only `DotsWaveform`.
struct MicButton: View {
    let model: KeyboardModel
    var size: CGFloat

    var body: some View {
        let listening = model.listeningSince != nil
        Button(action: listening ? model.actions.stop : model.actions.mic) {
            Circle()
                .fill(KeyboardChrome.primary)
                .frame(width: size, height: size)
                .overlay { glyph }
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
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(KeyboardChrome.primaryGlyph)
                .transition(.scale.combined(with: .opacity))
        default:
            Image(systemName: "mic.fill")
                .font(.system(size: size * 0.38))
                .foregroundStyle(KeyboardChrome.primaryGlyph)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Wispr's listening dots: ten 5 pt dots that stretch with the voice. The level history is
/// mirrored, so the newest level is in the middle and older ones move outwards; at rest, and while
/// transcribing, they are round.
struct DotsWaveform: View {
    let model: KeyboardModel
    var height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let dots = 10

    var body: some View {
        let levels = model.levels
        HStack(alignment: .center, spacing: 8) {
            ForEach(0..<Self.dots, id: \.self) { index in
                Capsule()
                    .fill(.primary)
                    .frame(width: 5, height: dotHeight(index, levels: levels))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }

    private func dotHeight(_ index: Int, levels: [Double]) -> CGFloat {
        let middle = Self.dots / 2
        let distance = index < middle ? middle - 1 - index : index - middle
        let level = levels.isEmpty ? 0 : levels[max(0, levels.count - 1 - distance * 2)]
        let floor: CGFloat = 5
        // Levels rest at 0.06; quiet speech should still move the dots.
        return floor + (height - floor) * CGFloat(min(1, max(0, (level - 0.06) * 1.6)))
    }
}

/// Wispr's two lines under the dots: "Listening" (or what the dictation waits for), then what it
/// will do.
struct ListeningCaption: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 2) {
            Text(model.captionTitle)
            Text(model.captionDetail)
        }
        .font(.system(size: 17))
        .foregroundStyle(.primary)
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
                HStack(spacing: 10) {
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
            Text("Undo")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background { KeyboardSurface(shape: Capsule()) }
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.keyboardPress)
    }
}

/// ✕ in ☰'s place while a dictation runs, Wispr's grey circle: throws the dictation away.
struct CancelChip: View {
    let model: KeyboardModel
    var size: CGFloat = 46

    var body: some View {
        Button(action: model.actions.cancel) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.36, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(KeyboardChrome.secondary, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Cancel transcription")
        .transition(.opacity)
    }
}
