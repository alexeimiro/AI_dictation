import SwiftUI

/// Key colors matching `KeyButton`'s character keys.
private let keyFill = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
private let keyPressedFill = Color(UIColor {
    $0.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : UIColor(red: 0.69, green: 0.71, blue: 0.75, alpha: 1)
})

/// The voice layout's main area: a big talk button between delete and return, with a hint below.
/// Dragging anywhere off the buttons moves the cursor, like holding the space bar.
struct VoicePad: View {
    let model: KeyboardModel
    /// Trackpad distance already turned into cursor moves.
    @State private var consumed: CGFloat = 0

    /// Points of drag per character.
    private static let cursorStep: CGFloat = 9

    var body: some View {
        VStack(spacing: 14) {
            // Fixed side slots, so the talk button stays put when a slot empties (while transcribing).
            HStack {
                Color.clear.frame(width: 72, height: 56).overlay { leading }
                Spacer()
                TalkButton(model: model)
                Spacer()
                Color.clear.frame(width: 72, height: 56).overlay { trailing }
            }
            hint.frame(height: 30)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
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
                    .frame(width: 56, height: 56)
                    .background { KeyFace(shape: Circle()) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel transcription")
        } else {
            DeleteKey(model: model)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let since = model.listeningSince {
            Text(since, style: .timer)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if !model.isCapturing {
            Button(action: model.actions.returnKey) {
                Group {
                    if model.returnTitle == "return" {
                        Image(systemName: "return.left").font(.system(size: 19))
                    } else {
                        Text(model.returnTitle)
                            .font(.system(size: 16))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 72, height: 56)
                .background { KeyFace(shape: Capsule()) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.returnTitle)
        }
    }

    @ViewBuilder
    private var hint: some View {
        switch model.phase {
        case .listening:
            caption("Tap ✓ when you're done")
        case .processing:
            caption(model.announcesReady ? "Transcribing… you'll feel it when it's in" : "Transcribing…")
        default:
            if let words = model.undoableWords {
                HStack(spacing: 10) {
                    Text("Inserted \(words) \(words == 1 ? "word" : "words")")
                        .foregroundStyle(.secondary)
                    Button("Undo", action: model.actions.undo)
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(.thinMaterial, in: .capsule)
                }
                .font(.system(size: 15, weight: .medium))
            } else {
                caption(model.idleHint)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
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

    var body: some View {
        let listening = model.listeningSince != nil
        Button(action: listening ? model.actions.stop : model.actions.mic) {
            ZStack {
                Circle().fill(actionFill)
                glyph
            }
            .frame(width: 88, height: 88)
            .background {
                Circle()
                    .fill(actionFill.opacity(0.14))
                    .scaleEffect(listening ? 1 + 0.45 * level : 1)
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? "Stop transcribing" : model.isProcessing ? "Transcribing" : "Start Murmur")
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
            .fill(pressed ? keyPressedFill : keyFill)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.25), radius: 0, y: 1)
    }
}
