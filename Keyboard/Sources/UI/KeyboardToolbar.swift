import MurmurCore
import SwiftUI

private let ink = Color(red: 0.192, green: 0.176, blue: 0.220)

/// The row above the keys: app button, status / style pill / banners, and the mic.
struct KeyboardToolbar: View {
    let model: KeyboardModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.actions.openApp) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Settings")

            center
                .frame(maxWidth: .infinity, alignment: .leading)

            if let memory = model.debugMemory {
                Text(memory)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            micButton
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(height: 50)
    }

    @ViewBuilder
    private var center: some View {
        if let pending = model.pendingResult {
            HStack(spacing: 6) {
                Button(action: model.actions.insertPending) {
                    Label("Insert last dictation", systemImage: "arrow.uturn.down")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.thinMaterial, in: .capsule)
                }
                .accessibilityHint(pending.text)
                Button(action: model.actions.dismissPending) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("Dismiss")
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
                caption("Tap the mic to reconnect")
            case .openingApp:
                caption("Opening Murmur…")
            case .starting:
                caption("Starting…")
            case .idle, .listening, .processing:
                stylePill
            }
        }
    }

    private var stylePill: some View {
        Menu {
            ForEach(StylePreset.allCases) { style in
                Button {
                    model.actions.setStyle(style == model.defaultStyle ? nil : style)
                } label: {
                    if style == model.effectiveStyle {
                        Label(style.title, systemImage: "checkmark")
                    } else {
                        Text(style.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if model.sessionStatus.isLive {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
                Text(model.effectiveStyle.title)
                    .font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.thinMaterial, in: .capsule)
        }
        .accessibilityLabel("Style: \(model.effectiveStyle.title)")
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func banner(title: String?, detail: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .accessibilityLabel("Dismiss")
        }
    }

    private var micButton: some View {
        Button(action: model.actions.mic) {
            ZStack {
                Circle().fill(ink)
                switch model.phase {
                case .starting, .openingApp:
                    ProgressView().tint(.white)
                case .listening:
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                default:
                    Image(systemName: "waveform").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 40)
        }
        .accessibilityLabel(model.isCapturing ? "Stop transcribing" : "Start Murmur")
    }
}

/// Replaces the keys while listening / processing: X, waveform + timer, ✓.
struct ListeningPanel: View {
    let model: KeyboardModel

    var body: some View {
        HStack(spacing: 0) {
            Button(action: model.actions.cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .background(.thinMaterial, in: .circle)
            }
            .accessibilityLabel("Cancel transcription")
            .padding(.leading, 20)

            Spacer()
            VStack(spacing: 14) {
                Waveform(levels: model.levels)
                    .frame(height: 44)
                status
            }
            Spacer()

            Button(action: model.actions.stop) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(ink, in: .circle)
            }
            .accessibilityLabel("Stop transcribing")
            .padding(.trailing, 20)
            .opacity(model.listeningSince == nil ? 0.3 : 1)
            .disabled(model.listeningSince == nil)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var status: some View {
        if let since = model.listeningSince {
            HStack(spacing: 6) {
                Text("Listening")
                Text(since, style: .timer).monospacedDigit()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("Transcribing…")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .onTapGesture(perform: model.actions.cancel)
            .accessibilityHint("Tap to cancel")
        }
    }
}

private struct Waveform: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.primary.opacity(0.8))
                    .frame(width: 3, height: max(4, 44 * level))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}
