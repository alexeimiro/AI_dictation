import SwiftUI

/// The voice layout's main area: a big talk button with cancel on the left while capturing and
/// delete in the familiar right-hand position. Return lives in the bottom key row.
/// Dragging anywhere off the buttons moves the cursor, like holding the space bar.
struct VoicePad: View {
    let model: KeyboardModel
    /// Trackpad distance already turned into cursor moves.
    @State private var consumed: CGFloat = 0

    /// Points of drag per character.
    private static let cursorStep: CGFloat = 9

    var body: some View {
        VStack(spacing: 4) {
            // Fixed side slots, so the talk button stays put when a slot empties (while transcribing).
            HStack {
                Color.clear.frame(width: 72, height: 58).overlay { leading }
                Spacer()
                TalkButton(model: model)
                Spacer()
                Color.clear.frame(width: 72, height: 58).overlay { trailing }
            }
            hint.frame(height: 44)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.primary)
        // On the whole pad: the buttons' own gestures still win where they are.
        .contentShape(.rect)
        .gesture(trackpad)
    }

    @ViewBuilder
    private var leading: some View {
        if model.isCapturing {
            Button(action: model.actions.cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .background { KeyFace(shape: Circle()) }
            }
            .buttonStyle(.keyboardPress)
            .accessibilityLabel("Cancel transcription")
        }
    }

    private var trailing: some View {
        DeleteKey(model: model)
    }

    @ViewBuilder
    private var hint: some View {
        switch model.phase {
        case .listening:
            VStack(spacing: 2) {
                RecognitionIndicator(direction: model.recognitionDirection,
                                     since: model.listeningSince)
                Text("Tap ✓ when you're done")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .processing:
            caption(model.announcesReady ? "Transcribing · we'll tap when it's ready" : "Transcribing…")
        default:
            if let words = model.undoableWords {
                HStack(spacing: 10) {
                    Text("Inserted \(words) \(words == 1 ? "word" : "words")")
                        .foregroundStyle(.secondary)
                    Button("Undo", action: model.actions.undo)
                        .buttonStyle(.keyboardPress)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background { KeyboardSurface(shape: Capsule(), active: true) }
                        .frame(minHeight: 44)
                }
                .font(.system(size: 15, weight: .medium))
            } else {
                caption(model.idleHint)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
    }

    private var trackpad: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let steps = Int((value.translation.width - consumed) / Self.cursorStep)
                guard steps != 0 else { return }
                consumed += CGFloat(steps) * Self.cursorStep
                model.actions.moveCursor(steps)
            }
            .onEnded { _ in consumed = 0 }
    }
}

/// Start, stop (✓) and progress in one big circle, ringed by the mic level while listening.
private struct TalkButton: View {
    let model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = model.listeningSince != nil
        Button(action: listening ? model.actions.stop : model.actions.mic) {
            ZStack {
                Circle()
                    .fill(KeyboardChrome.accentSoft)
                    .scaleEffect(listening ? 1 + 0.14 * level : 1)
                    .animation(reduceMotion ? nil : .linear(duration: 0.10), value: level)
                Circle()
                    .stroke(KeyboardChrome.accent.opacity(listening ? 0.34 : 0.16), lineWidth: 1)
                    .padding(5)
                Circle()
                    .fill(LinearGradient(colors: [actionFill, actionFill.opacity(0.88)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(8)
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 0.8)
                    .padding(8)
                glyph
            }
            .frame(width: 104, height: 104)
            .shadow(color: KeyboardChrome.accent.opacity(0.24), radius: listening ? 9 : 6, y: 3)
        }
        .buttonStyle(.keyboardPress)
        .disabled(model.isTransitioning)
        .accessibilityLabel(listening ? "Stop transcribing" : model.isTransitioning ? "Transcribing" : "Start Murmur")
    }

    private var level: Double { model.levels.last ?? 0 }

    @ViewBuilder
    private var glyph: some View {
        switch model.phase {
        case .starting, .openingApp, .processing:
            ProgressView().tint(actionGlyph).controlSize(.large)
        case .listening:
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(actionGlyph)
        default:
            Image(systemName: "mic.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(actionGlyph)
        }
    }
}

/// Delete: one character on touch, repeating while held (`KeyRepeater`); a swipe left takes the
/// whole word.
private struct DeleteKey: View {
    let model: KeyboardModel
    @State private var pressed = false
    @State private var swiped = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 20))
            .frame(width: 56, height: 56)
            .background { KeyFace(shape: Circle(), pressed: pressed) }
            .contentShape(.circle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            pressed = true
                            model.actions.deleteDown()
                        }
                        if !swiped, value.translation.width < -28 {
                            swiped = true
                            model.actions.deleteWord()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        swiped = false
                        model.actions.deleteUp()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.actions.deleteDown()
                model.actions.deleteUp()
            }
    }
}

/// A key's face: the key color with the system keys' hairline shadow (light mode only).
private struct KeyFace<S: Shape>: View {
    let shape: S
    var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape
            .fill(pressed ? KeyboardChrome.pressedKey : KeyboardChrome.key)
            .overlay { shape.stroke(KeyboardChrome.border, lineWidth: 0.6) }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.12), radius: 2, y: 1)
    }
}
