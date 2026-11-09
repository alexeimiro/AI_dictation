import AuthenticationServices
import CryptoKit
import Foundation
import MurmurCore
import os
import Supabase
import UIKit
import UserNotifications

/// Everything onboarding talks to outside its own state. Production uses Supabase and the real
/// permission APIs; screenshot routes and UI tests get `fixtures(…)`, which never prompt or hit
/// the network.
@MainActor
final class OnboardingServices {
    let auth: any OnboardingAuthenticating
    let offers: any OfferProviding
    let notifications: any NotificationAuthorizing
    let profile: any ProfileSyncing
    let languages: any KeyboardLanguageProviding

    init(auth: any OnboardingAuthenticating, offers: any OfferProviding,
         notifications: any NotificationAuthorizing, profile: any ProfileSyncing,
         languages: any KeyboardLanguageProviding) {
        self.auth = auth
        self.offers = offers
        self.notifications = notifications
        self.profile = profile
        self.languages = languages
    }

    static func production(backend: Backend?) -> OnboardingServices {
        OnboardingServices(
            auth: SupabaseOnboardingAuth(backend: backend),
            offers: SupabaseOfferProvider(backend: backend),
            notifications: SystemNotificationAuthorizer(),
            profile: SupabaseProfileSync(backend: backend),
            languages: SystemKeyboardLanguages())
    }

    /// `offer: nil` behaves like a server that can't be reached. `account`: a faked one
    /// (`-account-state`), which the offer follows.
    static func fixtures(offer: OfferVariant? = .trial(days: 14), account: AccountModel? = nil) -> OnboardingServices {
        OnboardingServices(
            auth: FixtureAuth(),
            offers: FixtureOffers(offer: offer, account: account),
            notifications: FixtureNotifications(),
            profile: FixtureProfileSync(),
            languages: FixtureLanguages())
    }
}

// MARK: - Authentication

enum OnboardingAuthError: Error, Equatable {
    /// The user closed the sheet; stay on the page without a message.
    case cancelled
    /// This build or backend can't do that method.
    case unavailable(String)
    case failed(String)

    var message: String? {
        switch self {
        case .cancelled: nil
        case .unavailable(let reason), .failed(let reason): reason
        }
    }
}

@MainActor
protocol OnboardingAuthenticating: AnyObject {
    /// False when the build has no backend; onboarding then continues without an account.
    var isAvailable: Bool { get }
    /// A real account (not the anonymous development session) is signed in.
    var hasAccount: Bool { get }
    var accountEmail: String? { get }
    func signInWithApple() async throws(OnboardingAuthError)
    func signInWithGoogle() async throws(OnboardingAuthError)
    /// Sends a six-digit code (and a sign-in link) to the address.
    func sendEmailCode(to email: String) async throws(OnboardingAuthError)
    func verifyEmailCode(_ code: String, email: String) async throws(OnboardingAuthError)
    /// `murmur://auth-callback?…` from the emailed link.
    func handleCallback(_ url: URL) async -> Bool
}

@MainActor
final class SupabaseOnboardingAuth: OnboardingAuthenticating {
    static let callbackURL = URL(string: "\(Brand.urlScheme)://auth-callback")!

    private let backend: Backend?
    private let logger = Logger(subsystem: "Murmur", category: "Auth")
    private var appleCoordinator: AppleSignInCoordinator?

    init(backend: Backend?) {
        self.backend = backend
    }

    var isAvailable: Bool { backend != nil }

    var hasAccount: Bool {
        guard let user = backend?.client.auth.currentUser else { return false }
        return !user.isAnonymous
    }

    var accountEmail: String? { backend?.client.auth.currentUser?.email }

    func signInWithApple() async throws(OnboardingAuthError) {
        let client = try requireClient()
        let nonce = Self.randomNonce()
        let coordinator = AppleSignInCoordinator()
        appleCoordinator = coordinator
        defer { appleCoordinator = nil }
        let credential = try await coordinator.signIn(hashedNonce: Self.sha256(nonce))
        guard let tokenData = credential.identityToken, let idToken = String(data: tokenData, encoding: .utf8) else {
            throw .failed("Apple didn't return an identity token. Please try again.")
        }
        do {
            try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
            backend?.didSignIn()
            if let name = credential.fullName.flatMap(Self.format), !name.isEmpty {
                // Apple sends the name only on the first sign-in.
                _ = try? await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
            }
        } catch {
            logger.error("Apple sign-in failed: \(error.localizedDescription, privacy: .public)")
            throw .failed("Couldn't sign in with Apple: \(error.localizedDescription)")
        }
    }

    func signInWithGoogle() async throws(OnboardingAuthError) {
        let client = try requireClient()
        do {
            try await client.auth.signInWithOAuth(provider: .google, redirectTo: Self.callbackURL) { session in
                session.prefersEphemeralWebBrowserSession = false
            }
            backend?.didSignIn()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw .cancelled
        } catch {
            logger.error("Google sign-in failed: \(error.localizedDescription, privacy: .public)")
            throw .failed("Couldn't sign in with Google: \(error.localizedDescription)")
        }
    }

    func sendEmailCode(to email: String) async throws(OnboardingAuthError) {
        let client = try requireClient()
        do {
            try await client.auth.signInWithOTP(email: email, redirectTo: Self.callbackURL)
        } catch {
            throw .failed("Couldn't send the code: \(error.localizedDescription)")
        }
    }

    func verifyEmailCode(_ code: String, email: String) async throws(OnboardingAuthError) {
        let client = try requireClient()
        do {
            try await client.auth.verifyOTP(email: email, token: code, type: .email)
        } catch {
            throw .failed("That code didn't work. Check it, or send a new one.")
        }
        backend?.didSignIn()
    }

    func handleCallback(_ url: URL) async -> Bool {
        guard let client = backend?.client else { return false }
        do {
            try await client.auth.session(from: url)
            backend?.didSignIn()
            return true
        } catch {
            logger.error("Auth callback failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func requireClient() throws(OnboardingAuthError) -> SupabaseClient {
        guard let backend else { throw .unavailable("Sign-in isn't configured in this build.") }
        return backend.client
    }

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func format(_ name: PersonNameComponents) -> String? {
        PersonNameComponentsFormatter.localizedString(from: name, style: .default)
    }
}

/// Bridges `ASAuthorizationController` to async/await. Also confirms a deletion with Apple
/// (`AppModel.deleteAccount`), for the code the server revokes.
@MainActor
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, any Error>?

    func signIn(hashedNonce: String) async throws(OnboardingAuthError) -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce
        do {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw .cancelled
        } catch let error as ASAuthorizationError where error.code == .unknown || error.code == .notHandled {
            // Error 1000: usually the Sign in with Apple capability is missing from the build.
            throw .unavailable("Sign in with Apple isn't available in this build.")
        } catch {
            throw .failed("Couldn't sign in with Apple: \(error.localizedDescription)")
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            continuation?.resume(returning: credential)
        } else {
            continuation?.resume(throwing: ASAuthorizationError(.invalidResponse))
        }
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

// MARK: - Offer

@MainActor
protocol OfferProviding: AnyObject {
    /// What the server granted this account. Throws when it couldn't be reached; the offer
    /// screen then offers a retry rather than guessing.
    func currentOffer() async throws -> OfferVariant
}

@MainActor
final class SupabaseOfferProvider: OfferProviding {
    private struct Entitlement: Decodable {
        let plan: String
        let source: String
        let trialEndsAt: Date?
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case plan, source
            case trialEndsAt = "trial_ends_at"
            case expiresAt = "expires_at"
        }
    }

    private let backend: Backend?

    init(backend: Backend?) {
        self.backend = backend
    }

    func currentOffer() async throws -> OfferVariant {
        // A build without a backend has no server-granted trial: show the free plan.
        guard let backend else { return .free }
        try await backend.ensureSession()
        guard let userID = backend.client.auth.currentUser?.id else { return .free }
        let rows: [Entitlement] = try await backend.client.from("entitlements")
            .select("plan,source,trial_ends_at,expires_at")
            .eq("user_id", value: userID)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return .free }
        return Self.variant(plan: row.plan, source: row.source, trialEndsAt: row.trialEndsAt,
                            expiresAt: row.expiresAt, now: Date())
    }

    /// The trial is the `entitlements.trial_ends_at` the signup trigger grants; a paid plan is
    /// `pro` until `expires_at`.
    nonisolated static func variant(plan: String, source: String, trialEndsAt: Date?, expiresAt: Date?,
                                    now: Date) -> OfferVariant {
        if plan == "pro", source != "trial", expiresAt.map({ $0 > now }) ?? true {
            return .subscriber
        }
        if let trialEndsAt, trialEndsAt > now {
            let days = Int((trialEndsAt.timeIntervalSince(now) / 86_400).rounded(.up))
            return .trial(days: max(1, days))
        }
        return .free
    }
}

// MARK: - Notifications

@MainActor
protocol NotificationAuthorizing: AnyObject {
    func status() async -> PermissionState
    /// Shows the system prompt (once; later calls just report the decision).
    func request() async -> PermissionState
}

@MainActor
final class SystemNotificationAuthorizer: NotificationAuthorizing {
    func status() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.state(settings.authorizationStatus)
    }

    func request() async -> PermissionState {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return await status()
    }

    nonisolated static func state(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: .undetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .granted
        @unknown default: .denied
        }
    }
}

// MARK: - Profile

@MainActor
protocol ProfileSyncing: AnyObject {
    /// Copies the answers to the account's profile. Best effort: failures never block onboarding.
    func sync(_ answers: OnboardingAnswers) async
    /// "Email me a link for later": records the request with the address to send it to.
    func requestDesktopLink(email: String) async throws
}

@MainActor
final class SupabaseProfileSync: ProfileSyncing {
    private struct ProfileUpdate: Encodable {
        var languages: [String]?
        var defaultStyle: String?
        var dataSharing: Bool?
        var dataSharingPolicyVersion: Int?
        var dataSharingDecidedAt: Date?
        var referredBy: String?
        var survey: [String: AnyJSON]

        enum CodingKeys: String, CodingKey {
            case languages, survey
            case defaultStyle = "default_style"
            case dataSharing = "data_sharing"
            case dataSharingPolicyVersion = "data_sharing_policy_version"
            case dataSharingDecidedAt = "data_sharing_decided_at"
            case referredBy = "referred_by"
        }
    }

    private let backend: Backend?
    private let logger = Logger(subsystem: "Murmur", category: "Profile")

    init(backend: Backend?) {
        self.backend = backend
    }

    func sync(_ answers: OnboardingAnswers) async {
        guard let backend, let userID = backend.client.auth.currentUser?.id else { return }
        var survey: [String: AnyJSON] = ["useCases": .array(answers.useCases.map { .string($0.rawValue) })]
        if let detail = answers.referralDetail { survey["referralDetail"] = .string(detail) }
        let update = ProfileUpdate(
            languages: answers.languages.isEmpty ? nil : answers.languages,
            defaultStyle: answers.style?.rawValue,
            dataSharing: answers.dataChoice.map { $0.choice == .improveModel },
            dataSharingPolicyVersion: answers.dataChoice?.policyVersion,
            dataSharingDecidedAt: answers.dataChoice?.decidedAt,
            referredBy: answers.referralSource?.rawValue,
            survey: survey)
        do {
            try await backend.client.from("profiles").update(update).eq("id", value: userID).execute()
        } catch {
            logger.notice("Profile sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestDesktopLink(email: String) async throws {
        guard let backend else { throw OnboardingAuthError.unavailable("This build has no account to send it to.") }
        try await backend.ensureSession()
        guard let userID = backend.client.auth.currentUser?.id else {
            throw OnboardingAuthError.failed("Sign in to get the link.")
        }
        let request: [String: AnyJSON] = [
            "desktop_link_email": .string(email),
            "desktop_link_requested_at": .string(Date().ISO8601Format()),
        ]
        try await backend.client.from("profiles").update(request).eq("id", value: userID).execute()
    }
}

// MARK: - Languages

@MainActor
protocol KeyboardLanguageProviding: AnyObject {
    /// The iPhone's enabled keyboard languages that on-device recognition supports, as BCP-47
    /// tags; at most two, because Murmur dictates in a primary and a secondary language.
    func detectedLanguages() async -> [String]
    /// Every language the recognizers support, for Edit.
    func availableLanguages() async -> [DictationLanguage]
}

@MainActor
final class SystemKeyboardLanguages: KeyboardLanguageProviding {
    func detectedLanguages() async -> [String] {
        var tags: [String] = []
        let keyboards = UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
        for identifier in keyboards + Locale.preferredLanguages {
            guard !["emoji", "dictation", "mul"].contains(identifier),
                  let tag = await LanguageResolver.supportedTag(equivalentTo: identifier),
                  !tags.contains(where: { DictationLanguage(tag: $0).languageCode == DictationLanguage(tag: tag).languageCode })
            else { continue }
            tags.append(tag)
            if tags.count == 2 { break }
        }
        return tags.isEmpty ? [DictationLanguage.englishUS.tag] : tags
    }

    func availableLanguages() async -> [DictationLanguage] {
        await LanguageResolver.availableLanguages()
    }
}

// MARK: - Fixtures (screenshots, UI tests)

@MainActor
final class FixtureAuth: OnboardingAuthenticating {
    var isAvailable = true
    var hasAccount = false
    var accountEmail: String? = "you@example.com"

    func signInWithApple() async throws(OnboardingAuthError) { hasAccount = true }
    func signInWithGoogle() async throws(OnboardingAuthError) { hasAccount = true }
    func sendEmailCode(to email: String) async throws(OnboardingAuthError) { accountEmail = email }

    func verifyEmailCode(_ code: String, email: String) async throws(OnboardingAuthError) {
        guard code == "123456" else { throw .failed("That code didn't work. Check it, or send a new one.") }
        hasAccount = true
    }

    func handleCallback(_ url: URL) async -> Bool { false }
}

@MainActor
final class FixtureOffers: OfferProviding {
    let offer: OfferVariant?
    private let account: AccountModel?

    init(offer: OfferVariant?, account: AccountModel? = nil) {
        self.offer = offer
        self.account = account
    }

    func currentOffer() async throws -> OfferVariant {
        // As `ensureSession` refuses the real one.
        if account?.isSignedOut == true { throw BackendError.signedOut }
        guard let offer else { throw URLError(.notConnectedToInternet) }
        return offer
    }
}

@MainActor
final class FixtureNotifications: NotificationAuthorizing {
    private var state: PermissionState = .undetermined

    func status() async -> PermissionState { state }

    func request() async -> PermissionState {
        state = .granted
        return state
    }
}

@MainActor
final class FixtureProfileSync: ProfileSyncing {
    func sync(_ answers: OnboardingAnswers) async {}
    func requestDesktopLink(email: String) async throws {}
}

@MainActor
final class FixtureLanguages: KeyboardLanguageProviding {
    func detectedLanguages() async -> [String] { ["en-US", "ru-RU"] }

    func availableLanguages() async -> [DictationLanguage] {
        ["de-DE", "en-GB", "en-US", "es-ES", "fr-FR", "it-IT", "ja-JP", "ru-RU"].map(DictationLanguage.init(tag:))
    }
}
