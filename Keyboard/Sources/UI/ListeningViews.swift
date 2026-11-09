import MurmurCore
import SwiftUI

/// The talk button from Anton's mock: an accent disc with a mic, red with a stop square while
/// listening, a spinner while starting or transcribing. Its own body never reads the mic level,
/// so the 20 Hz level updates redraw only `VoiceRing` and `Waveform`, not the button or its pulses.
struct MicButton: View {
    let model: KeyboardModel
    var size: CGFloat
    /// The soft ring around the disc; the toolbar's small mic goes without.
    var ringed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = model.listeningSince != nil
        let fill = listening ? KeyboardChrome.recording : KeyboardChrome.accent
        Button(action: listening ? model.actions.stop : model.actions.mic) {
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
                .shadow(color: fill.opacity(listening ? 0.40 : 0.35), radius: size * 0.13, y: size * 0.11)
                .background {
                    if ringed {
                        VoiceRing(model: model, diameter: size, listening: listening)
                    }
                }
                .background {
                    if listening, ringed {
                        PulseRings(diameter: size)
                    }
                }
                .overlay { glyph(listening: listening) }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: listening)
        }
        .buttonStyle(.keyboardPress)
        .disabled(model.isTransitioning)
        .accessibilityLabel(listening ? "Stop dictation" : model.isTransitioning ? "Working" : "Start dictation")
        .accessibilityAddTraits(.startsMediaSession)
    }

    @ViewBuilder
    private func glyph(listening: Bool) -> some View {
        switch model.phase {
        case .starting, .openingApp, .processing:
            ProgressView()
                .tint(KeyboardChrome.accentGlyph)
                .controlSize(size > 50 ? .large : .regular)
        case .listening:
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(KeyboardChrome.accentGlyph)
                .frame(width: size * 0.29, height: size * 0.29)
                .transition(.scale.combined(with: .opacity))
        default:
            Image(systemName: "mic")
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(KeyboardChrome.accentGlyph)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// The soft ring around the talk button: accent while idle; while listening red, and as wide as
/// the voice is loud.
private struct VoiceRing: View {
    let model: KeyboardModel
    let diameter: CGFloat
    let listening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let base = diameter * 0.105
        let level = listening && !reduceMotion ? model.levels.last ?? 0 : 0
        let width = listening ? base * (0.75 + level) : base
        Circle()
            .fill(listening ? KeyboardChrome.recordingSoft : KeyboardChrome.accentSoft)
            .padding(-width)
            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: width)
    }
}

/// Two red discs that grow and fade behind the talk button, 0.9 s apart, while it listens. They
/// take no input, so the level updates around them never restart the animation.
private struct PulseRings: View {
    let diameter: CGFloat
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 0.9)
        }
        .onAppear { if !reduceMotion { expanded = true } }
        .accessibilityHidden(true)
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .fill(KeyboardChrome.recording)
            .scaleEffect(expanded ? 1.6 : 1)
            .opacity(expanded ? 0 : 0.5)
            .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(delay), value: expanded)
    }
}

/// The level history as 30 bars, mirrored so the newest level is in the middle and older ones move
/// outwards, shaped by the mock's envelope: tall in the centre, short at the ends.
struct Waveform: View {
    let model: KeyboardModel
    var height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bars = 30

    var body: some View {
        let levels = model.levels
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(KeyboardChrome.accent.opacity(index % 3 == 0 ? 1 : 0.6))
                    .frame(width: 4, height: barHeight(index, levels: levels))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int, levels: [Double]) -> CGFloat {
        let middle = Self.bars / 2
        let distance = index < middle ? middle - 1 - index : index - middle
        let level = levels.isEmpty ? 0 : levels[max(0, levels.count - 1 - distance)]
        let envelope = sin(Double.pi * (Double(index) + 0.5) / Double(Self.bars))
        let jitter = 0.7 + 0.3 * abs(sin(Double(index) * 2.17))
        let floor: CGFloat = 4
        return floor + (height - floor) * CGFloat(min(1, level * 1.4) * (0.45 + 0.55 * envelope) * jitter)
    }
}

/// One line under the talk button: what to do, what is happening, or what just happened. It is
/// not a button; ✕ cancels.
struct StatusLine: View {
    let model: KeyboardModel

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(KeyboardChrome.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening(_, let since):
            HStack(spacing: 8) {
                LiveDot()
                Text("Listening")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(since, style: .timer)
                    .monospacedDigit()
                Text("· tap to stop")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.translationEnabled
                ? "Listening, \(model.effectiveLanguage.localizedName) to \(model.targetLanguage.localizedName)"
                : "Listening")
        case .processing:
            Text(model.stageText)
        case .starting:
            Text("Starting…")
        case .openingApp:
            Text("Opening Murmur…")
        case .needsReconnect:
            Text("Tap the mic to reconnect")
        default:
            if let words = model.undoableWords {
                HStack(spacing: 10) {
                    Text("Inserted \(words) \(words == 1 ? "word" : "words")")
                    Button("Undo", action: model.actions.undo)
                        .buttonStyle(.keyboardPress)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KeyboardChrome.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background { KeyboardSurface(shape: Capsule(), active: true) }
                        .frame(minHeight: 44)
                }
            } else {
                hint
            }
        }
    }

    /// "Tap to speak · Word for word · AUTO → RU", the mock's hint without "rewrites as": Word for
    /// word doesn't rewrite.
    private var hint: Text {
        let style = Text(model.style.shortTitle).fontWeight(.semibold).foregroundStyle(.primary)
        guard model.translationEnabled else { return Text("Tap to speak · ") + style }
        let direction = Text("\(model.effectiveLanguage.shortCode) → \(model.targetLanguage.shortCode)")
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
        return Text("Tap to speak · ") + style + Text(" · ") + direction
    }
}

/// The red "live" dot of the listening line, blinking once a second.
private struct LiveDot: View {
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(KeyboardChrome.recording)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// ✕ beside the talk button while a dictation runs: throws it away.
struct CancelChip: View {
    let model: KeyboardModel

    var body: some View {
        Button(action: model.actions.cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background { KeyboardSurface(shape: Circle()) }
        }
        .buttonStyle(.keyboardPress)
        .accessibilityLabel("Cancel transcription")
        .transition(.opacity)
    }
}
