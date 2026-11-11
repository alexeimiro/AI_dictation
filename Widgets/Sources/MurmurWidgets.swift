import ActivityKit
import AppIntents
import MurmurBrand
import SwiftUI
import WidgetKit

@main
struct MurmurWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
        DictateControl()
    }
}

/// Control Center, the Lock Screen and the Action Button's Controls: "Dictate with Murmur".
struct DictateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "MurmurDictateControl") {
            ControlWidgetButton(action: DictateIntent()) {
                Label("Dictate", systemImage: "waveform")
            }
        }
        .displayName("Dictate with Murmur")
        .description("Start or stop a dictation. With the Murmur keyboard open, the text is typed where you're writing.")
    }
}

/// Intents run in the app process; the extension only needs the types to build buttons.
enum LiveActivityActions {
    static func stopDictation() async {}
    static func endSession() async {}
    static func toggleDictation() async -> Bool { false }
    static func dictateIntoNewNote() async {}
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenSessionView(state: context.state)
                .activityBackgroundTint(ActivityColor.surface)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityMark()
                        .frame(width: 28, height: 28)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    StatusText(state: context.state, stacked: true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionButtons(state: context.state)
                }
            } compactLeading: {
                ActivityMark().frame(width: 18, height: 18)
            } compactTrailing: {
                CompactStatus(state: context.state)
            } minimal: {
                ActivityMark().frame(width: 16, height: 16)
            }
        }
    }
}

/// The Live Activity's surface is dark in light and dark mode alike, so its colours are fixed
/// values of the brand tokens, not ones that follow the appearance.
private enum ActivityColor {
    static let surface = Color(rgb: BrandToken.activity.light)
    static let label = Color.white
    static let status = Color(rgb: BrandRGB(0xC9C9C9))
    /// The microphone is open for as long as the activity shows.
    static let live = Color(rgb: BrandToken.live.dark)
    static let onLive = Color(rgb: BrandToken.onLive.dark)
}

/// Murmur's mark with a red dot: the microphone is open for as long as the activity shows.
private struct ActivityMark: View {
    var body: some View {
        BrandMark(ring: ActivityColor.label, dot: ActivityColor.live)
            .accessibilityHidden(true)
    }
}

private struct LockScreenSessionView: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ActivityMark()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Murmur")
                    .font(.headline)
                    .foregroundStyle(ActivityColor.label)
                StatusText(state: state, stacked: false)
            }
            Spacer(minLength: 8)
            SessionButtons(state: state)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 16)
    }
}

/// What the session is doing, always in words: "Ready", "Listening" with the time in red, or
/// "Writing…". The timer is the only thing that moves.
private struct StatusText: View {
    let state: SessionActivityAttributes.ContentState
    /// The expanded island puts the time under the word, the Lock Screen beside it.
    let stacked: Bool

    var body: some View {
        switch state.phase {
        case .ready:
            Text("Ready").font(font).foregroundStyle(ActivityColor.status)
        case .recording:
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                 : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Text("Listening")
                    .font(font)
                    .foregroundStyle(stacked ? ActivityColor.label : ActivityColor.status)
                if let start = state.recordingStartedAt {
                    Text(start, style: .timer)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(ActivityColor.live)
                }
            }
        case .processing:
            Text("Writing…").font(font).foregroundStyle(ActivityColor.status)
        }
    }

    private var font: Font {
        stacked ? .callout.weight(.semibold) : .subheadline
    }
}

/// The compact island's right side: the state in a word, or the time while it listens.
private struct CompactStatus: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .ready:
                Text("Ready").foregroundStyle(ActivityColor.label)
            case .recording:
                if let start = state.recordingStartedAt {
                    Text(start, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(ActivityColor.live)
                        // A timer otherwise takes the island's whole width.
                        .frame(maxWidth: 44)
                        .accessibilityLabel("Listening")
                } else {
                    Text("Listening").foregroundStyle(ActivityColor.live)
                }
            case .processing:
                Text("Writing…").foregroundStyle(ActivityColor.label)
            }
        }
        .font(.footnote.weight(.semibold))
    }
}

/// Stop while a dictation is heard (red: the microphone is listening to it), and Turn off.
private struct SessionButtons: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if state.phase == .recording {
                Button(intent: StopDictationIntent()) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ActivityColor.onLive)
                        .frame(width: 13, height: 13)
                        .frame(width: 44, height: 44)
                        .background(ActivityColor.live, in: .circle)
                }
                .accessibilityLabel("Stop")
            }
            Button(intent: EndSessionIntent()) {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ActivityColor.label)
                    .frame(width: 44, height: 44)
                    .overlay { Circle().strokeBorder(ActivityColor.label, lineWidth: 1.5) }
            }
            .accessibilityLabel("Turn off")
        }
        .buttonStyle(.plain)
    }
}
