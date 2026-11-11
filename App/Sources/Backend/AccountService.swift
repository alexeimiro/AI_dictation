import Foundation
import MurmurCore
import os
import Supabase
import UIKit

/// The account screens' server calls: the plan and this week's words (`my_quota`), invites
/// (`my_referrals`, `redeem_referral`), support messages (`issue_reports`), the default style
/// (`profiles`) and deleting the account (`delete-account`). Without a backend the reads return nil
/// and the writes throw, so builds without one still show the screens.
@MainActor
final class AccountService: StyleRemote {
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
        /// When the current free stretch started: the trial, or months from invites. Nil from
        /// `verify-purchase`, which answers with `quota_status`.
        var trialStartedAt: Date?

        enum CodingKeys: String, CodingKey {
            case plan
            case onTrial = "on_trial"
            case trialEndsAt = "trial_ends_at"
            case wordsThisWeek = "words_this_week"
            case weeklyLimit = "weekly_limit"
            case remaining
            case trialStartedAt = "trial_started_at"
        }

        /// The trial the signup trigger grants (`handle_new_user`).
        static let trialDays = 14

        /// Days in the current free stretch: 14 for the trial, more with a month from an invite.
        var trialLength: Int {
            guard let trialStartedAt, let trialEndsAt else { return Self.trialDays }
            return max(1, Int((trialEndsAt.timeIntervalSince(trialStartedAt) / 86_400).rounded()))
        }

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
                let used = min(trialLength, max(0, trialLength - left))
                return "\(used) of \(trialLength) days used in trial"
            }
            guard let weeklyLimit else { return nil }
            return "\(wordsThisWeek.formatted()) of \(weeklyLimit.formatted()) words used this week"
        }

        /// How full the bar under `usageLine` is, 0…1.
        func usageFraction(now: Date = Date()) -> Double? {
            if let left = trialDaysLeft(now: now) {
                return Double(trialLength - min(trialLength, left)) / Double(trialLength)
            }
            guard let weeklyLimit, weeklyLimit > 0 else { return nil }
            return min(1, Double(wordsThisWeek) / Double(weeklyLimit))
        }

        /// "Trial", "Pro" or "Basic": the plan in a word.
        var planName: String {
            onTrial ? "Trial" : isPro ? "Pro" : "Basic"
        }

        /// The chip beside the wordmark: "Trial · 6 days", "Pro" or "Basic".
        func chip(now: Date = Date()) -> String {
            guard let left = trialDaysLeft(now: now) else { return planName }
            return switch left {
            case ...0: planName
            case 1: "\(planName) · 1 day"
            default: "\(planName) · \(left) days"
            }
        }

        /// What the menu's meter counts.
        struct Usage: Equatable {
            /// "Trial" or "This week".
            let title: String
            /// "8 of 14 days used", "250 of 1,000 words used".
            let detail: String
            /// The meter: `filled` of `total` segments.
            let filled: Int
            let total: Int
        }

        /// The trial's days, or this week's words on Basic; nil on a paid plan, which has nothing
        /// to count. A two-week trial gets a segment a day; anything longer is drawn in proportion.
        func usage(now: Date = Date()) -> Usage? {
            if let left = trialDaysLeft(now: now) {
                let used = min(trialLength, max(0, trialLength - left))
                let total = min(trialLength, Self.trialDays)
                return Usage(title: "Trial", detail: "\(used) of \(trialLength) days used",
                             filled: Self.segments(Double(used) / Double(trialLength), of: total), total: total)
            }
            guard let weeklyLimit, weeklyLimit > 0 else { return nil }
            return Usage(title: "This week",
                         detail: "\(wordsThisWeek.formatted()) of \(weeklyLimit.formatted()) words used",
                         filled: Self.segments(min(1, Double(wordsThisWeek) / Double(weeklyLimit)), of: 10),
                         total: 10)
        }

        /// `fraction` of `total` segments: never empty once something is used, never full before
        /// everything is.
        private static func segments(_ fraction: Double, of total: Int) -> Int {
            let filled = Int((fraction * Double(total)).rounded())
            if fraction > 0, filled == 0 { return 1 }
            if fraction < 1, filled == total { return total - 1 }
            return filled
        }
    }

    /// `my_referrals()`: the code and counts Invite a friend shows.
    struct Referrals: Decodable, Equatable, Sendable {
        let code: String
        let friendsJoined: Int
        /// Friends whose first dictation earned the caller a month.
        let monthsEarned: Int
        /// The caller entered a friend's code.
        let redeemed: Bool
        /// The caller can still enter one: a new account (14 days) that hasn't.
        let canRedeem: Bool

        enum CodingKeys: String, CodingKey {
            case code, redeemed
            case friendsJoined = "friends_joined"
            case monthsEarned = "months_earned"
            case canRedeem = "can_redeem"
        }

        /// The most months invites earn (`reward_referrer`).
        static let maxMonths = 12

        /// "2 friends joined · 1 month of Pro earned"; nil before anyone joins.
        var summary: String? {
            guard friendsJoined > 0 else { return nil }
            let friends = friendsJoined == 1 ? "1 friend joined" : "\(friendsJoined) friends joined"
            let months = monthsEarned == 1 ? "1 month of Pro earned" : "\(monthsEarned) months of Pro earned"
            return "\(friends) · \(months)"
        }
    }

    /// What entering a friend's code did (`redeem_referral`).
    enum RedeemOutcome: String, Equatable, Sendable {
        case ok, invalid
        case ownCode = "own_code"
        case alreadyRedeemed = "already_redeemed"
        case tooLate = "too_late"
        case signInRequired = "sign_in_required"

        var message: String {
            switch self {
            case .ok: "You've got a month of \(Brand.name) Pro, thanks to your friend."
            case .invalid: "That code doesn't match an invite. Check it and try again."
            case .ownCode: "That's your own code. Share it with a friend instead."
            case .alreadyRedeemed: "You've already used an invite code."
            case .tooLate: "Invite codes work within 14 days of creating your account."
            case .signInRequired: "Sign in to use an invite code."
            }
        }
    }

    /// A code as people type or paste it: "A1B2 C3D4" → "a1b2c3d4"; nil when nothing's left.
    nonisolated static func normalizedCode(_ text: String) -> String? {
        let code = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return code.isEmpty || code.count > 32 ? nil : code
    }

    /// What the support sheet sends.
    struct SupportMessage: Equatable, Sendable {
        enum Kind: String, Sendable, CaseIterable, Identifiable {
            case issue, feedback
            var id: String { rawValue }
            var title: String {
                switch self {
                case .issue: "Report an issue"
                case .feedback: "Leave feedback"
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

    /// The caller's invite code and counts; nil without a backend or a signed-in account.
    func referrals() async throws -> Referrals? {
        guard let backend, backend.client.auth.currentSession != nil else { return nil }
        try await backend.ensureSession()
        let rows: [Referrals] = try await backend.client.rpc("my_referrals").execute().value
        return rows.first
    }

    /// Enters a friend's invite code: a month of Pro for the caller, and one for the friend once
    /// the caller first dictates.
    func redeem(code: String) async throws -> RedeemOutcome {
        guard let backend else { throw Failure.notConfigured }
        guard let code = Self.normalizedCode(code) else { return .invalid }
        guard backend.client.auth.currentSession != nil else { return .signInRequired }
        do {
            try await backend.ensureSession()
            let answer: String = try await backend.client.rpc("redeem_referral", params: ["p_code": code])
                .execute().value
            return RedeemOutcome(rawValue: answer) ?? .invalid
        } catch {
            logger.error("Redeeming an invite failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.unavailable("Couldn't use that code. Check your connection and try again.")
        }
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

    /// The account's default style (`StyleSync`); nil without a stored session: never starts one.
    func defaultStyle() async throws -> StylePreset? {
        struct Row: Decodable {
            let defaultStyle: String
            enum CodingKeys: String, CodingKey { case defaultStyle = "default_style" }
        }
        guard let backend, backend.client.auth.currentSession != nil,
              let userID = backend.client.auth.currentUser?.id else { return nil }
        try await backend.ensureSession()
        let rows: [Row] = try await backend.client.from("profiles").select("default_style")
            .eq("id", value: userID).limit(1).execute().value
        return rows.first.map { StylePreset(stored: $0.defaultStyle) }
    }

    /// Saves the default style to the account (`StyleSync`). Needs a stored session: never starts one.
    func saveDefaultStyle(_ style: StylePreset) async throws {
        guard let backend else { throw Failure.notConfigured }
        guard backend.client.auth.currentSession != nil, let userID = backend.client.auth.currentUser?.id else {
            throw Failure.unavailable("Sign in to change this.")
        }
        try await backend.ensureSession()
        let update: [String: AnyJSON] = ["default_style": .string(style.rawValue)]
        try await backend.client.from("profiles").update(update).eq("id", value: userID).execute()
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
