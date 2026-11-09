import AVFoundation
import Foundation
import MurmurCore

/// Deterministic onboarding states for `-onboarding-step` screenshot routes: the answers and setup
/// a user would have on that screen, plus the screen-specific `-onboarding-variant`.
///
/// Variants: `welcome` page1…page3 · `keyboardInstructions` partial · `microphonePrimer` denied ·
/// practice screens guide, ready, listening, result · `dataChoice` improve, doNotShare ·
/// `trialOffer` trial, subscriber, free, offline.
enum OnboardingFixtures {
    static func record(step: OnboardingStep, variant: String?, permissions: PermissionSnapshot?) -> OnboardingRecord {
        var record = OnboardingRecord()
        record.step = step
        let reached = { (other: OnboardingStep) in step.order > other.order }

        if reached(.useCases) { record.answers.useCases = [.typeFaster] }
        if reached(.emailSignIn) { record.answers.authMethod = .apple }
        if step.order >= OnboardingStep.practiceIntro.order {
            record.permissions.keyboardAdded = true
            record.permissions.fullAccessConfirmed = true
        }
        if step == .keyboardInstructions, variant == "partial" {
            record.permissions.keyboardAdded = true
        }
        if step.order > OnboardingStep.microphonePrimer.order { record.permissions.microphone = .granted }
        if step == .microphonePrimer, variant == "denied" { record.permissions.microphone = .denied }
        for exercise in PracticeExercise.allCases where reached(exercise.step) {
            record.practiceDone.append(exercise)
        }
        if let exercise = PracticeExercise.allCases.first(where: { $0.step == step }), variant == "result" {
            record.practiceDone.append(exercise)
        }
        if reached(.practiceComplete) { record.practiceCommittedAt = Date() }
        if reached(.dataChoice) {
            record.answers.dataChoice = DataChoiceDecision(choice: .doNotShare, policyVersion: 1, decidedAt: Date())
        } else if step == .dataChoice, let choice = variant.flatMap(dataChoice) {
            record.answers.dataChoice = DataChoiceDecision(choice: choice, policyVersion: 1, decidedAt: Date())
        }
        if step.order >= OnboardingStep.languages.order { record.answers.languages = ["en-US", "ru-RU"] }
        if reached(.defaultStyle) { record.answers.style = .verbatim }
        if reached(.notifications) { record.permissions.notifications = .granted }
        if reached(.desktopOffer) { record.answers.desktopLink = .declined }
        if reached(.referralSource) { record.answers.referralSource = .searchEngine }
        if reached(.referralDetail) { record.answers.referralDetail = "Google" }
        if step == .complete {
            record.completedAt = Date()
            record.historySeeded = true
        }
        if let permissions { record.permissions = permissions }
        return record
    }

    /// nil: the server can't be reached ("offline").
    static func offer(variant: String?) -> OfferVariant? {
        switch variant {
        case "subscriber": .subscriber
        case "free": .free
        case "offline": nil
        default: .trial(days: 14)
        }
    }

    /// Welcome carousel page: references 01, 02 and 03 show the dictionary, speed and languages pages.
    static func welcomePage(variant: String?) -> Int {
        switch variant {
        case "speed": WelcomePage.speed.rawValue
        case "languages": WelcomePage.languages.rawValue
        case "dictionary": WelcomePage.dictionary.rawValue
        default: 0
        }
    }

    static func practiceState(step: OnboardingStep?, variant: String?) -> PracticeDictationState {
        guard let exercise = PracticeExercise.allCases.first(where: { $0.step == step }) else { return .idle }
        switch variant {
        case "listening": return .listening
        case "result": return .completed(ScriptedPracticeClient.sampleText(for: exercise))
        default: return .idle
        }
    }

    /// Whether the Murmur keyboard is the one on screen (the "guide" variant shows the system one).
    static func murmurKeyboardActive(variant: String?) -> Bool {
        variant != "guide"
    }

    private static func dataChoice(_ variant: String) -> DataChoice? {
        switch variant {
        case "improve": .improveModel
        case "doNotShare": .doNotShare
        default: nil
        }
    }

    /// Home after onboarding (reference 42): the three practice takes, newest first.
    @MainActor
    static func seedCompletedHistory(_ history: HistoryStore, now: Date = Date()) {
        for (index, exercise) in PracticeExercise.allCases.enumerated() {
            let text = ScriptedPracticeClient.sampleText(for: exercise)
            history.record(Transcript(
                id: UUID(), createdAt: now.addingTimeInterval(Double(index - 3) * 60), language: "en-US",
                style: .verbatim, rawText: text, cleanedText: text, status: .cleaned,
                insertedAt: now.addingTimeInterval(Double(index - 3) * 60), source: .keyboard))
        }
    }
}

extension PermissionSnapshot {
    /// `-permission-fixtures keyboard,fullAccess,mic=granted,notifications=denied`; `none` for a
    /// fresh install.
    init(fixture: String) {
        self.init()
        for token in fixture.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count > 1 ? parts[1] : nil) {
            case ("keyboard", _): keyboardAdded = true
            case ("fullAccess", _): fullAccessConfirmed = true
            case ("mic", let value?): microphone = PermissionState(rawValue: value) ?? .undetermined
            case ("notifications", let value?): notifications = PermissionState(rawValue: value) ?? .undetermined
            default: break
            }
        }
    }
}

extension PermissionState {
    init(_ permission: AVAudioApplication.recordPermission) {
        switch permission {
        case .granted: self = .granted
        case .denied: self = .denied
        default: self = .undetermined
        }
    }
}
