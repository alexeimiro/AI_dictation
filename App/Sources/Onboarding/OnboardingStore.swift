import Foundation
import Observation

/// The onboarding checkpoint as the UI sees it. Every change goes through `OnboardingReducer` and is
/// saved before observers see it, so the app resumes on the same screen after any termination.
@MainActor
@Observable
final class OnboardingStore {
    private(set) var record: OnboardingRecord

    /// The last step change went backwards (page transitions slide the other way).
    @ObservationIgnored private(set) var movedBack = false
    @ObservationIgnored private let persistence: any OnboardingPersisting
    @ObservationIgnored private let now: () -> Date
    /// Runs once when the final screen is acknowledged, and again on a later launch if the app
    /// was terminated before `markHistorySeeded()` (so the work must be idempotent).
    @ObservationIgnored var onComplete: ((OnboardingRecord) -> Void)?

    /// `legacyInstall`: the app was in use before onboarding existed (it has history or a
    /// keyboard that already ran), so it opens on Home instead of starting over.
    init(persistence: any OnboardingPersisting, legacyInstall: Bool = false, now: @escaping () -> Date = Date.init) {
        self.persistence = persistence
        self.now = now
        if let stored = persistence.load() {
            record = stored
        } else if legacyInstall {
            var record = OnboardingRecord()
            record.step = .complete
            record.completedAt = now()
            record.historySeeded = true
            self.record = record
            persistence.save(record)
        } else {
            record = OnboardingRecord()
        }
    }

    var step: OnboardingStep { record.step }
    var answers: OnboardingAnswers { record.answers }
    var permissions: PermissionSnapshot { record.permissions }
    var isComplete: Bool { record.isComplete }

    /// Applies an event; returns false when the reducer rejected it.
    @discardableResult
    func send(_ event: OnboardingEvent) -> Bool {
        guard let next = OnboardingReducer.reduce(record, event, now: now()) else { return false }
        guard next != record else { return true }
        let finished = !record.isComplete && next.isComplete
        movedBack = next.step.order < record.step.order
        record = next
        persistence.save(next)
        if finished { onComplete?(next) }
        return true
    }

    /// Whether an event would be accepted, for enabling buttons.
    func allows(_ event: OnboardingEvent) -> Bool {
        OnboardingReducer.reduce(record, event, now: now()) != nil
    }

    /// Finishes the completion work left over from a terminated launch.
    func resumePendingCompletion() {
        if record.isComplete, !record.historySeeded { onComplete?(record) }
    }

    func markHistorySeeded() {
        guard !record.historySeeded else { return }
        record.historySeeded = true
        persistence.save(record)
    }

    /// Debug › Replay onboarding.
    func restart() {
        record = OnboardingRecord()
        persistence.save(record)
    }
}
