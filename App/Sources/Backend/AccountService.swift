import Foundation
import os
import Supabase
import UIKit

/// The account screens' server calls: the plan and this week's words (`my_quota`), support
/// messages (`issue_reports`) and deleting the account (`delete-account`). Without a backend the
/// reads return nil and the writes throw, so builds without one still show the screens.
@MainActor
final class AccountService {
    /// `my_quota()`: what the menu and the Account screen show about the plan.
    struct Quota: Decodable, Equatable, Sendable {
        /// "pro" while a trial or a subscription lasts, else "basic".
        let plan: String
        let onTrial: Bool
        let trialEndsAt: Date?
        let wordsThisWeek: Int
        /// Nil on Pro: no weekly limit.
        let weeklyLimit: Int?
        let remaining: Int?

        enum CodingKeys: String, CodingKey {
            case plan
            case onTrial = "on_trial"
            case trialEndsAt = "trial_ends_at"
            case wordsThisWeek = "words_this_week"
            case weeklyLimit = "weekly_limit"
            case remaining
        }

        /// The trial the signup trigger grants (`handle_new_user`).
        static let trialDays = 14

        var isPro: Bool { plan == "pro" }

        /// "Pro Trial", "Pro" or "Basic", for the badge next to the logo.
        var badge: String {
            onTrial ? "Pro Trial" : isPro ? "Pro" : "Basic"
        }

        /// Whole days left in the trial, rounded up; nil when not on one.
        func trialDaysLeft(now: Date = Date()) -> Int? {
            guard onTrial, let trialEndsAt else { return nil }
            return max(0, Int((trialEndsAt.timeIntervalSince(now) / 86_400).rounded(.up)))
        }

        /// "7 of 14 days used in trial", or "640 of 1,000 words used this week" on Basic; nil on a
        /// paid plan, which has nothing to count.
        func usageLine(now: Date = Date()) -> String? {
            if let left = trialDaysLeft(now: now) {
                let used = min(Self.trialDays, max(0, Self.trialDays - left))
                return "\(used) of \(Self.trialDays) days used in trial"
            }
            guard let weeklyLimit else { return nil }
            return "\(wordsThisWeek.formatted()) of \(weeklyLimit.formatted()) words used this week"
        }

        /// How full the bar under `usageLine` is, 0…1.
        func usageFraction(now: Date = Date()) -> Double? {
            if let left = trialDaysLeft(now: now) {
                return Double(Self.trialDays - min(Self.trialDays, left)) / Double(Self.trialDays)
            }
            guard let weeklyLimit, weeklyLimit > 0 else { return nil }
            return min(1, Double(wordsThisWeek) / Double(weeklyLimit))
        }
    }

    /// What the support sheet sends.
    struct SupportMessage: Equatable, Sendable {
        enum Kind: String, Sendable, CaseIterable, Identifiable {
            case issue, feedback
            var id: String { rawValue }
            var title: String {
                switch self {
                case .issue: "Report an issue"
                case .feedback: "Share feedback"
                }
            }
        }

        var kind: Kind
        /// "Dictation", "Keyboard", … for an issue; nil for feedback.
        var topic: String?
        var message: String
    }

    enum Failure: LocalizedError {
        case notConfigured
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "This build has no account server"
            case .unavailable(let reason): reason
            }
        }
    }

    private let backend: Backend?
    private let functions: EdgeFunctionClient?
    private let logger = Logger(subsystem: "Murmur", category: "Account")

    init(backend: Backend?, functions: EdgeFunctionClient?) {
        self.backend = backend
        self.functions = functions
    }

    /// The plan and this week's words; nil without a backend or a stored session. It never starts
    /// one: opening the app sends nothing until the cloud is used.
    func quota() async throws -> Quota? {
        guard let backend, backend.client.auth.currentSession != nil else { return nil }
        try await backend.ensureSession()
        let rows: [Quota] = try await backend.client.rpc("my_quota").execute().value
        return rows.first
    }

    /// Writes a support message to `issue_reports`, with what's needed to look into it.
    func send(_ message: SupportMessage) async throws {
        struct Insert: Encodable {
            let message: String
            let diagnostics: [String: String]
        }
        guard let backend else { throw Failure.notConfigured }
        try await backend.ensureSession()
        var diagnostics = Self.diagnostics()
        diagnostics["kind"] = message.kind.rawValue
        if let topic = message.topic { diagnostics["topic"] = topic }
        let text = String(message.message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(5000))
        try await backend.client.from("issue_reports")
            .insert(Insert(message: text, diagnostics: diagnostics))
            .execute()
    }

    /// 👍 or 👎 on a dictation, to `feedback`. Its text goes along only when the user agreed to
    /// share dictations ("Improve Murmur for everyone") and left "Include the text" on.
    struct DictationFeedback: Encodable, Equatable, Sendable {
        let dictationId: UUID
        /// 1 or -1.
        let rating: Int
        let comment: String?
        let rawText: String?
        let cleanedText: String?

        enum CodingKeys: String, CodingKey {
            case rating, comment
            case dictationId = "dictation_id"
            case rawText = "raw_text"
            case cleanedText = "cleaned_text"
        }
    }

    func send(_ feedback: DictationFeedback) async throws {
        guard let backend else { throw Failure.notConfigured }
        guard backend.client.auth.currentSession != nil else { throw Failure.unavailable("Sign in to send feedback.") }
        do {
            try await backend.ensureSession()
            try await backend.client.from("feedback").insert(feedback).execute()
        } catch {
            logger.error("Feedback failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.unavailable("Couldn't send that. Check your connection and try again.")
        }
    }

    /// "Improve Murmur for everyone" in Settings: the consent onboarding records (`DataChoiceView`),
    /// with the policy it was given under and when. Needs a stored session: never starts one.
    func setDataSharing(_ on: Bool, at date: Date = Date()) async throws {
        guard let backend else { throw Failure.notConfigured }
        guard backend.client.auth.currentSession != nil, let userID = backend.client.auth.currentUser?.id else {
            throw Failure.unavailable("Sign in to change this.")
        }
        try await backend.ensureSession()
        let update: [String: AnyJSON] = [
            "data_sharing": .bool(on),
            "data_sharing_policy_version": .integer(DataChoiceDecision.currentPolicyVersion),
            "data_sharing_decided_at": .string(date.ISO8601Format()),
        ]
        do {
            try await backend.client.from("profiles").update(update).eq("id", value: userID).execute()
        } catch {
            logger.error("Data sharing update failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.unavailable("Couldn't save that. Check your connection and try again.")
        }
    }

    /// Deletes the account on the server; its rows cascade. Signing out locally is the caller's.
    /// `appleAuthorizationCode`: for an account that signed in with Apple, a fresh code the
    /// server uses to revoke the sign-in, as Apple requires.
    func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        guard let functions else { throw Failure.notConfigured }
        var body: [String: String] = [:]
        if let appleAuthorizationCode { body["appleAuthorizationCode"] = appleAuthorizationCode }
        do {
            _ = try await functions.post("delete-account", body: body, timeout: 25)
        } catch {
            logger.error("Account deletion failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.unavailable("Couldn't delete your account. Check your connection and try again.")
        }
    }

    /// Ends the session on this iPhone (`Backend.signOut`).
    func signOut() async {
        await backend?.signOut()
    }

    /// App and system versions, so a report can be matched to a build.
    static func diagnostics(bundle: Bundle = .main) -> [String: String] {
        let info = bundle.infoDictionary
        return [
            "app": "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "os": "iOS \(UIDevice.current.systemVersion)",
            "device": UIDevice.current.model,
            "locale": Locale.preferredLanguages.first ?? "?",
        ]
    }
}
