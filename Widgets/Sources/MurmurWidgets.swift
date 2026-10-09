import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MurmurWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}

/// Intents run in the app process; the extension only needs the types to build buttons.
enum LiveActivityActions {
    static func stopDictation() async {}
    static func endSession() async {}
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenSessionView(state: context.state)
                .activityBackgroundTint(Color(red: 0.18, green: 0.165, blue: 0.204))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MarkView()
                        .frame(width: 26, height: 22)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    StatusText(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionButtons(state: context.state, compact: true)
                }
            } compactLeading: {
                MarkView().frame(width: 18, height: 15)
            } compactTrailing: {
                StatusDot(phase: context.state.phase)
            } minimal: {
                MarkView().frame(width: 16, height: 13)
            }
        }
    }
}

private struct LockScreenSessionView: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            MarkView()
                .frame(width: 30, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Murmur")
                    .font(.headline)
                    .foregroundStyle(.white)
                StatusText(state: state)
            }
            Spacer()
            SessionButtons(state: state, compact: false)
        }
        .padding(16)
    }
}

private struct StatusText: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .ready:
            Text("on").foregroundStyle(.white.opacity(0.75))
        case .recording:
            if let start = state.recordingStartedAt {
                HStack(spacing: 4) {
                    Text("recording")
                    Text(start, style: .timer).monospacedDigit()
                }
                .foregroundStyle(.red)
            } else {
                Text("recording").foregroundStyle(.red)
            }
        case .processing:
            Text("processing…").foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct SessionButtons: View {
    let state: SessionActivityAttributes.ContentState
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            if state.phase == .recording {
                Button(intent: StopDictationIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 34, height: 34)
                }
                .tint(.red)
            }
            Button(intent: EndSessionIntent()) {
                Label("Turn off", systemImage: "power")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 34)
            }
            .tint(.white.opacity(0.25))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
    }
}

private struct StatusDot: View {
    let phase: SessionActivityAttributes.ContentState.Phase

    var body: some View {
        Circle()
            .fill(phase == .recording ? Color.red : Color.green)
            .frame(width: 8, height: 8)
    }
}

/// Same geometry as `LogoMarkShape` in MurmurUI (kept local so the extension stays small).
private struct MarkView: View {
    var body: some View {
        Canvas { context, size in
            let heights: [CGFloat] = [0.48, 1.0, 0.7]
            let unit = size.width / 8.2
            let barWidth = unit * 1.3
            let gap = unit * 0.9
            for (index, height) in heights.enumerated() {
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap),
                                  y: size.height * (1 - height) / 2,
                                  width: barWidth, height: size.height * height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.white))
            }
            let dot = barWidth * 1.15
            context.fill(Path(ellipseIn: CGRect(x: 3 * (barWidth + gap) + unit * 0.1,
                                                y: size.height / 2 - dot / 2, width: dot, height: dot)),
                         with: .color(.white))
        }
    }
}
