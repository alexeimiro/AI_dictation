import DeviceCheck
import Foundation
import os

/// One free trial per iPhone. A new account has no trial until the server decides it
/// (`claim-trial`): Apple's DeviceCheck tells it whether this iPhone has had a Murmur trial, from a
/// token only DCDevice can make, and Apple learns nothing about the account. Claimed right after a
/// sign-in, when a guest's session starts, when Murmur comes to the front, and before onboarding's
/// last page and an invite code read the plan, until the server has decided for the account. Then
/// never again for that account.
@MainActor
final class TrialClaim {
    /// The server's decision for an account.
    enum Outcome: String, Codable, Sendable {
        /// This iPhone's first trial.
        case granted
        /// This iPhone has had its trial: the account starts on Basic.
        case deviceUsed = "device_used"
        /// Granted without Apple's answer (no key on the server, or Apple was down).
        case unchecked
        /// An account from before the check, with the trial it got at sign-up.
        case legacy
    }

    private struct Request: Encodable {
        let deviceToken: String?
    }

    private struct Reply: Decodable {
        let trial: Outcome
    }

    static let decisionsKey = "trialDecisions"

    private let functions: EdgeFunctionClient?
    private let currentUser: @MainActor () -> UUID?
    private let deviceToken: @Sendable () async -> String?
    private let defaults: UserDefaults
    private var inFlight: (user: UUID, task: Task<Outcome?, Never>)?
    private let logger = Logger(subsystem: "Murmur", category: "Trial")
    /// Called after a trial is granted, so the plan on screen catches up.
    var onGranted: (() -> Void)?

    /// `functions`: nil without a backend, or on fake services, where nothing is claimed.
    /// `currentUser`: the stored session's user; nil without one, and a claim never starts one.
    init(functions: EdgeFunctionClient?, currentUser: @escaping @MainActor () -> UUID?,
         deviceToken: @escaping @Sendable () async -> String? = TrialClaim.systemDeviceToken,
         defaults: UserDefaults = .standard) {
        self.functions = functions
        self.currentUser = currentUser
        self.deviceToken = deviceToken
        self.defaults = defaults
    }

    /// What the server decided for `user`, once it has.
    func decision(for user: UUID) -> Outcome? {
        (defaults.dictionary(forKey: Self.decisionsKey)?[user.uuidString.lowercased()] as? String)
            .flatMap(Outcome.init(rawValue:))
    }

    /// Asks the server to decide the current account's trial, unless it already has. Returns the
    /// decision, or nil while there's none: no session, offline, no token, or the server's error.
    /// Concurrent calls for one account share one request.
    @discardableResult
    func claimIfNeeded() async -> Outcome? {
        guard let functions, let user = currentUser() else { return nil }
        if let known = decision(for: user) { return known }
        if let inFlight, inFlight.user == user { return await inFlight.task.value }
        let task = Task { [deviceToken, logger] () -> Outcome? in
            let token = await deviceToken()
            do {
                let reply = try await functions.post("claim-trial", body: Request(deviceToken: token), timeout: 20)
                return try JSONDecoder().decode(Reply.self, from: reply.data).trial
            } catch {
                logger.notice("Trial claim: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        inFlight = (user, task)
        let outcome = await task.value
        if inFlight?.user == user { inFlight = nil }
        // A session that changed meanwhile (signed out, another account) got someone else's answer.
        guard let outcome, currentUser() == user else { return outcome }
        remember(outcome, for: user)
        if outcome == .granted || outcome == .unchecked { onGranted?() }
        return outcome
    }

    private func remember(_ outcome: Outcome, for user: UUID) {
        var decisions = defaults.dictionary(forKey: Self.decisionsKey) ?? [:]
        // A handful of accounts at most ever sign in on one iPhone; keep it from growing anyway.
        if decisions.count >= 20 { decisions.removeAll() }
        decisions[user.uuidString.lowercased()] = outcome.rawValue
        defaults.set(decisions, forKey: Self.decisionsKey)
    }

    /// DCDevice's token in base64; nil where DeviceCheck isn't available (the simulator) or fails.
    nonisolated static func systemDeviceToken() async -> String? {
        guard DCDevice.current.isSupported else { return nil }
        do {
            return try await DCDevice.current.generateToken().base64EncodedString()
        } catch {
            Logger(subsystem: "Murmur", category: "Trial")
                .notice("No DeviceCheck token: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
