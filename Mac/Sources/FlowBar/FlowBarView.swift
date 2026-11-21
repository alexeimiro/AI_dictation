import MurmurBrand
import SwiftUI

/// The floating bar, as the approved mock draws it: a small white capsule with the mark at rest
/// ("Hold fn to dictate" on hover), a black pill while listening (red only for the live dot),
/// three dots while writing, "✓ 13 words" once typed, and dark notice cards above it.
struct FlowBarView: View {
    let engine: DictationEngine
    let onTap: () -> Void
    let onSize: (CGSize) -> Void
    var onNoticeAction: (DictationEngine.Notice) -> Void = { _ in }
    /// Screenshot runs: show the hover state without a pointer.
    var previewHover = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            if let notice = engine.notice {
                NoticeCard(notice: notice, action: { onNoticeAction(notice) }, dismiss: engine.dismissNotice)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if engine.commanding, engine.isListening {
                CommandHint().transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            bar
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .fixedSize()
        .animation(.snappy(duration: 0.22), value: engine.phase)
        .animation(.snappy(duration: 0.22), value: engine.notice)
        .animation(.snappy(duration: 0.22), value: engine.commanding)
        .animation(.snappy(duration: 0.22), value: engine.justInserted)
        .animation(.snappy(duration: 0.18), value: hovering)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    @ViewBuilder private var bar: some View {
        switch engine.phase {
        case .idle where engine.justInserted:
            pill(width: 160) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    Text("\(engine.insertedWords) \(engine.insertedWords == 1 ? "word" : "words")")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .accessibilityLabel("Inserted, \(engine.insertedWords) words")
        case .idle:
            Group {
                if hovering || previewHover {
                    HStack(spacing: 8) {
                        MarkView(size: 14)
                        Text("Hold").font(.system(size: 13, weight: .semibold))
                        Keycaps(keys: MacSettings.shared.trigger.caps)
                        Text("to dictate").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Mac.Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Capsule(style: .circular).fill(.white))
                    .overlay(Capsule(style: .circular).strokeBorder(Mac.Palette.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.14), radius: 9, y: 6)
                } else {
                    IdleCapsule()
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
            .help("Click to dictate hands-free")
        case .listening(let handsFree):
            if handsFree {
                pill(width: 288, height: 44, padding: 8) {
                    HStack(spacing: 12) {
                        RoundIcon(symbol: "xmark", label: "Throw it away") { engine.end(commit: false) }
                        LiveDot()
                        LevelBars(level: engine.level)
                        Elapsed(since: engine.listeningSince)
                        RoundIcon(symbol: "stop.fill", label: "Finish", filled: true) { engine.end(commit: true) }
                    }
                }
            } else {
                pill(width: 228) {
                    HStack(spacing: 12) {
                        LiveDot()
                        LevelBars(level: engine.level)
                        Elapsed(since: engine.listeningSince)
                    }
                    .padding(.leading, 6).padding(.trailing, 4)
                }
                .accessibilityLabel("Redmic is listening")
            }
        case .processing:
            pill(width: 100) { WritingDots() }
                .accessibilityLabel("Redmic is writing your text")
        }
    }

    private func pill<Content: View>(width: CGFloat, height: CGFloat = 40, padding: CGFloat = 12,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, padding)
            .frame(width: width, height: height)
            .background(Capsule(style: .circular).fill(Mac.Palette.ink))
            .shadow(color: .black.opacity(0.22), radius: 9, y: 6)
    }
}

/// The live dot: red, with a ring that swells out of it.
private struct LiveDot: View {
    var body: some View {
        ZStack {
            PulseDot()
            Circle().fill(Mac.Palette.liveOnDark).frame(width: 10, height: 10)
        }
        .frame(width: 10, height: 10)
    }
}

/// White bars that follow the microphone, tallest in the middle.
private struct LevelBars: View {
    let level: Float
    private static let shape: [CGFloat] = [0.25, 0.35, 0.55, 0.8, 1, 0.7, 0.5, 0.85, 0.6, 0.4, 0.3, 0.2]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.shape.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 3, height: max(4, 26 * Self.shape[index] * CGFloat(max(level, 0.08))))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct Elapsed: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: since ?? .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since ?? context.date)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct WritingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * (2 * .pi / 1.1)
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin(phase - Double(index) * 0.85)))
                }
            }
        }
    }
}

private struct RoundIcon: View {
    let symbol: String
    let label: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(filled ? Mac.Palette.ink : .white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(filled ? .white : .white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Command mode's card while it listens: what to say, with three examples.
private struct CommandHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Say how to change the selection").font(.system(size: 13, weight: .semibold))
                Text("For example:").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 6) {
                ForEach(["Make it shorter", "More formal", "Translate to Russian"], id: \.self) { example in
                    Text(example).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .overlay(Capsule(style: .circular).strokeBorder(.white.opacity(0.35), lineWidth: 1))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 368, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Mac.Palette.ink))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 10)
    }
}

/// A dark card above the bar: what happened, what to do, an optional action and ✕.
private struct NoticeCard: View {
    let notice: DictationEngine.Notice
    let action: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if let detail = notice.detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let title = actionTitle {
                Button(title, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Mac.Palette.ink)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule(style: .circular).fill(.white))
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 12)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Mac.Palette.ink))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 10)
    }

    private var symbol: String {
        switch notice.kind {
        case .copied: "doc.on.clipboard"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .microphone: "mic.slash"
        case .accessibility: "hand.raised"
        case .consent: "hand.raised"
        case .nothingHeard: "waveform"
        case .failed: "exclamationmark.circle"
        case .limitReached: "gauge.with.dots.needle.100percent"
        case .nothingSelected: "text.cursor"
        case .proRequired: "star"
        case .unchanged: "equal.circle"
        }
    }

    private var actionTitle: String? {
        switch notice.kind {
        case .signedOut: "Sign in"
        case .limitReached, .proRequired: "Upgrade"
        case .microphone, .accessibility: "Open Settings"
        default: nil
        }
    }
}
