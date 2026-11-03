import Foundation
import MurmurCore

/// Every onboarding screen, in journey order. The raw values are persisted and used by the
/// `-onboarding-step` launch argument, so renaming a case needs a migration (`OnboardingMigration`).
enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    /// The three-page carousel (references 01–03); the page is view state, not a step.
    case welcome
    case useCases, personalizedExplainer
    case signIn, signInOptions, emailSignIn
    case setupIntro, keyboardInstructions
    case practiceIntro, microphonePrimer, basicPractice
    case formattingPractice, whisperIntro, whisperPractice, practiceComplete
    case wrapUpIntro, dataChoice, languages, defaultStyle, notifications
    case desktopOffer, referralSource, referralDetail, ready, trialOffer
    case complete

    /// Position in the journey, used to compare checkpoints.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// "Which of these do you resonate with?" (reference 04). Multi-select.
enum UseCase: String, Codable, CaseIterable, Sendable, Identifiable {
    case messages, emails, chatWithAI, captureIdeas, onTheGo, typeFaster, typingIsHard

    var id: String { rawValue }
}

/// "Your data is safe" (reference 32). Nothing is preselected.
enum DataChoice: String, Codable, CaseIterable, Sendable {
    case improveModel
    case doNotShare
}

/// The recorded consent: which option, under which policy text, and when.
struct DataChoiceDecision: Codable, Equatable, Sendable {
    /// Bump when the wording on the data choice screen changes meaning.
    static let currentPolicyVersion = 1

    var choice: DataChoice
    var policyVersion: Int
    var decidedAt: Date
}

/// "Where did you hear about us?" (reference 38).
enum ReferralSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case xTwitter, searchEngine, tikTok, articleNews, newsletter, linkedIn, friendColleague
    case youTube, reddit, other

    var id: String { rawValue }

    /// The follow-up question's options (reference 39), or nil when there is none.
    var detailOptions: [String]? {
        switch self {
        case .searchEngine: ["Google", "Bing", "DuckDuckGo", "Brave Search", "Yahoo", "Other"]
        default: nil
        }
    }
}

enum PracticeExercise: String, Codable, CaseIterable, Sendable {
    case basic, formatting, whisper

    var step: OnboardingStep {
        switch self {
        case .basic: .basicPractice
        case .formatting: .formattingPractice
        case .whisper: .whisperPractice
        }
    }
}

/// A permission as onboarding sees it; mapped from AVAudioApplication / UNUserNotificationCenter.
enum PermissionState: String, Codable, Sendable {
    case undetermined, granted, denied, restricted

    var isDetermined: Bool { self != .undetermined }
}

enum OnboardingPermission: String, Codable, Sendable {
    case microphone, notifications
}

enum AuthMethod: String, Codable, Sendable {
    case apple, google, email, existingSession
    /// The build has no backend configured, so there is no account to sign in to.
    case localOnly
}

/// What the server granted, shown on the last screen (reference 41).
enum OfferVariant: Codable, Equatable, Sendable {
    case trial(days: Int)
    case subscriber
    case free
}

/// The answers the user gave. Authentication state lives in `Backend`, not here.
struct OnboardingAnswers: Codable, Equatable, Sendable {
    var useCases: [UseCase] = []
    var authMethod: AuthMethod?
    var dataChoice: DataChoiceDecision?
    /// BCP-47 tags, primary first.
    var languages: [String] = []
    var style: StylePreset?
    var desktopLink: DesktopLinkDecision?
    var referralSource: ReferralSource?
    var referralDetail: String?
    var offer: OfferVariant?
}

enum DesktopLinkDecision: Codable, Equatable, Sendable {
    case requested(Date)
    case declined
}

/// The last known setup and permission state. Each confirmed keyboard requirement is kept,
/// because turning on Full Access can terminate the app before it sees the change.
struct PermissionSnapshot: Codable, Equatable, Sendable {
    var keyboardAdded = false
    var fullAccessConfirmed = false
    var microphone: PermissionState = .undetermined
    var notifications: PermissionState = .undetermined
}

/// The persisted onboarding checkpoint.
struct OnboardingRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    var step: OnboardingStep = .welcome
    var answers = OnboardingAnswers()
    var permissions = PermissionSnapshot()
    /// Exercises finished in this run (typed or dictated text, or a dictation for the later ones).
    var practiceDone: [PracticeExercise] = []
    /// Set by Continue on "Congrats!" (reference 30).
    var practiceCommittedAt: Date?
    var completedAt: Date?
    /// The practice dictations were copied into history (once, after completion).
    var historySeeded = false

    var isComplete: Bool { step == .complete }

    func isDone(_ exercise: PracticeExercise) -> Bool { practiceDone.contains(exercise) }
}

/// Everything that can happen on an onboarding screen. Views send these; only the reducer
/// decides which step comes next.
enum OnboardingEvent: Equatable, Sendable {
    /// The screen's primary action (Next, Continue, Get started…).
    case next
    case back
    /// "Skip", "Maybe later" and similar optional exits.
    case skipOptional
    case toggleUseCase(UseCase)
    case showSignInOptions
    case showEmailSignIn
    case authenticated(AuthMethod)
    case keyboardStatusChanged(added: Bool, fullAccess: Bool)
    case permissionChanged(OnboardingPermission, PermissionState)
    case practiceCompleted(PracticeExercise)
    case selectDataChoice(DataChoice, at: Date)
    case setLanguages([String])
    case selectStyle(StylePreset)
    case desktopLinkRequested(at: Date)
    case desktopLinkDeclined
    case selectReferral(ReferralSource)
    case selectReferralDetail(String)
    case offerResolved(OfferVariant)
    /// A keyboard session link arrived before onboarding finished.
    case sessionLinkOpened
}

// MARK: Lenient decoding

// Checkpoints written by other builds decode field by field; unknown steps and options are mapped
// or dropped (see `OnboardingMigration`) instead of failing the whole record.

extension OnboardingRecord {
    enum CodingKeys: String, CodingKey {
        case version, step, answers, permissions, practiceDone, practiceCommittedAt, completedAt, historySeeded
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        answers = (try? container.decodeIfPresent(OnboardingAnswers.self, forKey: .answers)) ?? OnboardingAnswers()
        permissions = (try? container.decodeIfPresent(PermissionSnapshot.self, forKey: .permissions)) ?? PermissionSnapshot()
        practiceDone = container.lenientArray(PracticeExercise.self, forKey: .practiceDone)
        practiceCommittedAt = try? container.decodeIfPresent(Date.self, forKey: .practiceCommittedAt)
        completedAt = try? container.decodeIfPresent(Date.self, forKey: .completedAt)
        historySeeded = (try? container.decodeIfPresent(Bool.self, forKey: .historySeeded)) ?? false
        let storedStep = try? container.decodeIfPresent(String.self, forKey: .step)
        step = OnboardingMigration.step(forStoredValue: storedStep, fallback: OnboardingMigration.checkpoint(for: self))
        if completedAt != nil { step = .complete }
        version = Self.currentVersion
    }
}

extension OnboardingAnswers {
    enum CodingKeys: String, CodingKey {
        case useCases, authMethod, dataChoice, languages, style, desktopLink, referralSource, referralDetail, offer
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        useCases = container.lenientArray(UseCase.self, forKey: .useCases)
        authMethod = try? container.decodeIfPresent(AuthMethod.self, forKey: .authMethod)
        dataChoice = try? container.decodeIfPresent(DataChoiceDecision.self, forKey: .dataChoice)
        languages = (try? container.decodeIfPresent([String].self, forKey: .languages)) ?? []
        style = try? container.decodeIfPresent(StylePreset.self, forKey: .style)
        desktopLink = try? container.decodeIfPresent(DesktopLinkDecision.self, forKey: .desktopLink)
        referralSource = try? container.decodeIfPresent(ReferralSource.self, forKey: .referralSource)
        referralDetail = try? container.decodeIfPresent(String.self, forKey: .referralDetail)
        offer = try? container.decodeIfPresent(OfferVariant.self, forKey: .offer)
    }
}

extension PermissionSnapshot {
    enum CodingKeys: String, CodingKey {
        case keyboardAdded, fullAccessConfirmed, microphone, notifications
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        keyboardAdded = (try? container.decodeIfPresent(Bool.self, forKey: .keyboardAdded)) ?? false
        fullAccessConfirmed = (try? container.decodeIfPresent(Bool.self, forKey: .fullAccessConfirmed)) ?? false
        microphone = (try? container.decodeIfPresent(PermissionState.self, forKey: .microphone)) ?? .undetermined
        notifications = (try? container.decodeIfPresent(PermissionState.self, forKey: .notifications)) ?? .undetermined
    }
}

private extension KeyedDecodingContainer {
    /// An array of string-backed enums, skipping values this build doesn't know.
    func lenientArray<T: RawRepresentable>(_ type: T.Type, forKey key: Key) -> [T] where T.RawValue == String {
        let raw = (try? decodeIfPresent([String].self, forKey: key)) ?? []
        return raw.compactMap(T.init(rawValue:))
    }
}
