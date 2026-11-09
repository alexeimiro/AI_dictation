import MurmurCore
import SwiftUI

/// The voice keyboard under the toolbar, Anton's big talk button in Wispr Flow's style: a flat
/// white disc with the hint under it. While a dictation runs the row of keys below gives way to
/// Wispr's listening view (dots and two lines), and the disc stays put as ✓, so one spot starts and
/// finishes. A notice or the last dictation that couldn't be inserted sits above the disc. Dragging
/// in the empty space moves the cursor, like holding the space bar.
struct VoicePad: View {
    let model: KeyboardModel
    /// Trackpad distance already turned into cursor moves.
    @State private var consumed: CGFloat = 0

    /// Points of drag per character.
    private static let cursorStep: CGFloat = 9

    /// Sizes for the 278 pt keyboard, and for landscape.
    private struct Metrics {
        /// From the toolbar to the disc, with no card above it.
        var top: CGFloat
        var mic: CGFloat
        /// The disc under a card.
        var smallMic: CGFloat
        var gap: CGFloat
        var dots: CGFloat

        static let regular = Metrics(top: 24, mic: 76, smallMic: 56, gap: 12, dots: 28)
        static let compact = Metrics(top: 12, mic: 60, smallMic: 46, gap: 8, dots: 20)
    }

    var body: some View {
        let metrics = model.compactHeight ? Metrics.compact : .regular
        let card = showsCard
        VStack(spacing: 0) {
            if card {
                topSlot
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
            VStack(spacing: metrics.gap) {
                MicButton(model: model, size: card ? metrics.smallMic : metrics.mic)
                if model.isCapturing {
                    DotsWaveform(model: model, height: metrics.dots)
                    ListeningCaption(model: model)
                } else {
                    PadHint(model: model)
                }
            }
            .padding(.top, card ? 8 : metrics.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(.rect)
            .gesture(trackpad)
        }
        .foregroundStyle(.primary)
    }

    /// Cards wait while a dictation runs, so its view stays Wispr's.
    private var showsCard: Bool {
        guard !model.isCapturing else { return false }
        if model.pendingResult != nil { return true }
        switch model.phase {
        case .needsFullAccess, .notice: return true
        default: return false
        }
    }

    /// A notice, or the last dictation that couldn't be inserted.
    @ViewBuilder
    private var topSlot: some View {
        if let pending = model.pendingResult {
            NoticeCard(symbol: "arrow.uturn.down", primary: true, title: "Insert last dictation",
                       detail: pending.text, action: model.actions.insertPending,
                       dismiss: model.actions.dismissPending)
        } else if case .notice(let message) = model.phase, message == Brand.limitReachedMessage {
            NoticeCard(symbol: "sparkles", primary: true, title: "Get unlimited words",
                       detail: "You've used this week's free words. Tap to see Murmur Pro.",
                       action: model.actions.openPro, dismiss: model.actions.dismissNotice)
        } else if case .notice(let message) = model.phase {
            NoticeCard(symbol: "exclamationmark.bubble", title: nil, detail: message,
                       dismiss: model.actions.dismissNotice)
        } else {
            NoticeCard(symbol: "lock", title: "Almost there!",
                       detail: "Turn on Allow Full Access in Settings › Murmur › Keyboards",
                       dismiss: model.actions.dismissNotice)
        }
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

/// A flat card above the talk button for a notice: a tile, the message, and ✕. With an `action`
/// the whole card is the button (Insert last dictation), and its tile is white like the disc.
private struct NoticeCard: View {
    let symbol: String
    var primary = false
    let title: String?
    let detail: String
    var action: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let action {
                Button(action: action) { message }
                    .buttonStyle(.keyboardPress)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title ?? detail)
                    .accessibilityHint(detail)
            } else {
                message
                    .accessibilityElement(children: .combine)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background { KeyboardSurface(shape: Circle()) }
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.keyboardPress)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 7)
        .padding(.trailing, 3)
        .padding(.vertical, 4)
        .frame(minHeight: 54)
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                      fill: KeyboardChrome.card) }
    }

    private var message: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primary ? KeyboardChrome.primaryGlyph : Color.primary)
                .frame(width: 36, height: 36)
                .background(primary ? KeyboardChrome.primary : KeyboardChrome.key,
                            in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(KeyboardChrome.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
