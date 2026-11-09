import MurmurCore
import SwiftUI

/// The voice keyboard from Anton's mock, under the toolbar: the translate row (or a notice in its
/// place), then the talk button with what it is doing under it. Space and return are the UIKit row
/// below. Dragging in the empty space moves the cursor, like holding the space bar.
struct VoicePad: View {
    let model: KeyboardModel
    /// Trackpad distance already turned into cursor moves.
    @State private var consumed: CGFloat = 0

    /// Points of drag per character.
    private static let cursorStep: CGFloat = 9

    /// Sizes for the 320 pt keyboard, and for landscape, where it is 272 pt.
    private struct Metrics {
        var top: CGFloat
        var mic: CGFloat
        var gap: CGFloat
        var wave: CGFloat
        var waveGap: CGFloat
        /// The hint, the waveform with the status line, or the status line alone.
        var block: CGFloat

        // The soft ring reaches 8 pt (regular) or 6 pt (compact) past the disc; `top` clears it.
        static let regular = Metrics(top: 12, mic: 74, gap: 12, wave: 26, waveGap: 6, block: 48)
        static let compact = Metrics(top: 8, mic: 54, gap: 8, wave: 16, waveGap: 4, block: 34)
    }

    var body: some View {
        let metrics = model.compactHeight ? Metrics.compact : .regular
        VStack(spacing: 0) {
            topSlot
                .padding(.horizontal, 12)
                .padding(.top, 6)
                // Above the talk button's pulses, so they seem to come from behind it.
                .zIndex(1)
            centre(metrics)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(.rect)
                .gesture(trackpad)
        }
        .foregroundStyle(.primary)
    }

    /// The translate row, or in its place a notice or the last dictation that couldn't be inserted.
    @ViewBuilder
    private var topSlot: some View {
        if let pending = model.pendingResult {
            NoticeCard(symbol: "arrow.uturn.down", accent: true, title: "Insert last dictation",
                       detail: pending.text, action: model.actions.insertPending,
                       dismiss: model.actions.dismissPending)
        } else {
            switch model.phase {
            case .needsFullAccess:
                NoticeCard(symbol: "lock", title: "Almost there!",
                           detail: "Turn on Allow Full Access in Settings › Murmur › Keyboards",
                           dismiss: model.actions.dismissNotice)
            case .notice(let message):
                NoticeCard(symbol: "exclamationmark.bubble", title: nil, detail: message,
                           dismiss: model.actions.dismissNotice)
            default:
                TranslateRow(model: model)
            }
        }
    }

    private func centre(_ metrics: Metrics) -> some View {
        VStack(spacing: metrics.gap) {
            MicButton(model: model, size: metrics.mic)
                .overlay {
                    if model.isCapturing {
                        CancelChip(model: model)
                            .offset(x: -(metrics.mic / 2 + 28 + 22))
                    }
                }
            Group {
                if case .listening = model.phase {
                    VStack(spacing: metrics.waveGap) {
                        Waveform(model: model, height: metrics.wave)
                        StatusLine(model: model)
                    }
                } else {
                    StatusLine(model: model)
                }
            }
            .frame(height: metrics.block)
        }
        .padding(.top, metrics.top)
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

/// A card the size of the translate row that takes its place for a notice: a tile, the message,
/// and ✕. With an `action` the whole card is the button (Insert last dictation).
private struct NoticeCard: View {
    let symbol: String
    var accent = false
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
                    .background(KeyboardChrome.backdrop, in: .circle)
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
        .background { KeyboardSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    private var message: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent ? KeyboardChrome.accentGlyph : KeyboardChrome.tileGlyph)
                .frame(width: 36, height: 36)
                .background(accent ? KeyboardChrome.accent : KeyboardChrome.tile,
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
