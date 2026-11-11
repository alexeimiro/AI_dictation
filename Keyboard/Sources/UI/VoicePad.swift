import MurmurCore
import SwiftUI

/// The voice keyboard under the toolbar: the big talk button with a hint under it. While a
/// dictation runs the row of keys below gives way to the listening view (the rings and two
/// lines), and the disc stays put as ✓, so one spot starts and finishes. A notice or the last
/// dictation that couldn't be inserted sits above the disc. Dragging in the empty space moves the
/// cursor, like holding the space bar.
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
        /// From the disc to the line under it; more while the rings need the room.
        var gap: CGFloat
        var listeningGap: CGFloat

        static let regular = Metrics(top: 18, mic: 76, smallMic: 56, gap: 12, listeningGap: 30)
        static let compact = Metrics(top: 10, mic: 60, smallMic: 46, gap: 8, listeningGap: 22)
    }

    var body: some View {
        let metrics = model.compactHeight ? Metrics.compact : .regular
        let card = showsCard
        let listening = model.listeningSince != nil
        VStack(spacing: 0) {
            if card {
                topSlot
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
            }
            VStack(spacing: listening ? metrics.listeningGap : metrics.gap) {
                MicButton(model: model, size: card ? metrics.smallMic : metrics.mic, showsRings: true)
                if model.isCapturing {
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
        .foregroundStyle(KeyboardChrome.primary)
    }

    /// Cards wait while a dictation runs, so nothing sits over its rings.
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
            NoticeCard(symbol: "arrow.uturn.down", title: "Insert last dictation",
                       detail: pending.text, action: model.actions.insertPending,
                       dismiss: model.actions.dismissPending)
        } else if case .notice(let message) = model.phase, message == Brand.limitReachedMessage {
            NoticeCard(symbol: "gauge.with.needle", title: "This week’s words are used up",
                       detail: "Tap to see Murmur Pro.",
                       action: model.actions.openPro, dismiss: model.actions.dismissNotice)
        } else if case .notice(let message) = model.phase {
            let parts = KeyboardNotice.parts(of: message)
            NoticeCard(symbol: "exclamationmark.triangle", title: parts.title, detail: parts.detail,
                       dismiss: model.actions.dismissNotice)
        } else {
            NoticeCard(symbol: "lock", title: "One switch left",
                       detail: "Turn on Allow Full Access in Settings › Murmur › Keyboards.",
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

/// A flat card above the talk button for a notice: an outlined tile, a title, a line, and ✕. With
/// an `action` the whole card is the button (Insert last dictation, the way to Pro).
private struct NoticeCard: View {
    let symbol: String
    let title: String
    let detail: String?
    var action: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if let action {
                Button(action: action) { message }
                    .buttonStyle(.keyboardPress)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityHint(detail ?? "")
            } else {
                message
                    .accessibilityElement(children: .combine)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.keyboardPress)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .frame(minHeight: 54)
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                      fill: KeyboardChrome.card) }
    }

    private var message: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(KeyboardChrome.primary)
                .frame(width: 36, height: 36)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(KeyboardChrome.primary, lineWidth: 1.5)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.primary)
                    .lineLimit(detail == nil ? 2 : 1)
                    .minimumScaleFactor(0.85)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(KeyboardChrome.muted)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
