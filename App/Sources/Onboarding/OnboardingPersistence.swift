import Foundation
import MurmurCore

/// Where the onboarding checkpoint is kept between launches.
@MainActor
protocol OnboardingPersisting: AnyObject {
    func load() -> OnboardingRecord?
    func save(_ record: OnboardingRecord)
    func clear()
}

/// App Group defaults, next to `SharedSettings`, so a Settings round trip or a termination
/// (turning on Full Access can kill the app) resumes on the same screen.
@MainActor
final class DefaultsOnboardingPersistence: OnboardingPersisting {
    static let key = "onboarding.record"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: Brand.appGroupID)) {
        self.defaults = defaults ?? .standard
    }

    func load() -> OnboardingRecord? {
        defaults.data(forKey: Self.key).flatMap(OnboardingMigration.decode)
    }

    func save(_ record: OnboardingRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Screenshot routes and tests: nothing outlives the process.
@MainActor
final class InMemoryOnboardingPersistence: OnboardingPersisting {
    private(set) var stored: OnboardingRecord?

    init(_ record: OnboardingRecord? = nil) {
        stored = record
    }

    func load() -> OnboardingRecord? { stored }
    func save(_ record: OnboardingRecord) { stored = record }
    func clear() { stored = nil }
}

/// Reads checkpoints written by any build. Unknown steps and options are mapped or dropped
/// instead of failing, so an app update never strands someone mid-onboarding.
enum OnboardingMigration {
    /// Step names used by earlier builds and plans.
    static let renamedSteps: [String: OnboardingStep] = [
        "welcome1": .welcome,
        "welcome2": .welcome,
        "welcome3": .welcome,
        "keyboardSettingsRoundTrip": .keyboardInstructions,
    ]

    static func decode(_ data: Data) -> OnboardingRecord? {
        try? JSONDecoder().decode(OnboardingRecord.self, from: data)
    }

    /// A stored step name → the step to resume on.
    static func step(forStoredValue value: String?, fallback: OnboardingStep) -> OnboardingStep {
        guard let value else { return fallback }
        return OnboardingStep(rawValue: value) ?? renamedSteps[value] ?? fallback
    }

    /// The safest place to resume when the stored step no longer exists: the start of the phase
    /// the user had reached.
    static func checkpoint(for record: OnboardingRecord) -> OnboardingStep {
        if record.completedAt != nil { return .complete }
        if record.practiceCommittedAt != nil { return .wrapUpIntro }
        if record.answers.authMethod != nil { return .setupIntro }
        return .welcome
    }
}
