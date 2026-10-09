import ActivityKit
import Foundation
import os

/// Shows the session in the Lock Screen / Dynamic Island while the hot mic is on, which is also
/// the clear recording indicator App Review expects (guideline 2.5.14).
@MainActor
final class LiveActivityController {
    private var activityID: String?
    private let logger = Logger(subsystem: "Murmur", category: "LiveActivity")

    /// Only works while the app is in the foreground, which is when sessions start.
    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        Task { await Self.endAll() }
        do {
            let activity = try Activity.request(
                attributes: SessionActivityAttributes(),
                content: ActivityContent(state: .init(phase: .ready, recordingStartedAt: nil), staleDate: nil),
                pushType: nil)
            activityID = activity.id
        } catch {
            logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ phase: SessionActivityAttributes.ContentState.Phase, since startedAt: Date?) {
        guard let activityID else { return }
        let state = SessionActivityAttributes.ContentState(phase: phase, recordingStartedAt: startedAt)
        Task { await Self.update(id: activityID, state: state) }
    }

    func end() {
        activityID = nil
        Task { await Self.endAll() }
    }

    // `Activity` isn't Sendable, so it is looked up inside these nonisolated functions instead of
    // being passed across actors.
    nonisolated private static func update(id: String, state: SessionActivityAttributes.ContentState) async {
        for activity in Activity<SessionActivityAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    nonisolated private static func endAll() async {
        for activity in Activity<SessionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// App-side handlers for the Live Activity intents (the widget target has no-op stubs).
enum LiveActivityActions {
    @MainActor static weak var session: SessionController?

    static func stopDictation() async {
        await MainActor.run { session?.endDictation(commit: true) }
    }

    static func endSession() async {
        await MainActor.run { session?.stop() }
    }
}
