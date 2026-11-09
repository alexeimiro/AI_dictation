import Foundation
import Observation

/// The account this iPhone signs in with, remembered so that losing its session (the server
/// rejected it: revoked, or a refresh token that had already rotated) stops the cloud instead of
/// quietly making the user a new anonymous one without their plan. `Backend` keeps it in step with
/// Auth; Home and Settings show the sign-in sheet from it.
///
/// Kept in the app's own defaults, not the App Group: the keyboard never talks to the backend.
@MainActor
@Observable
final class AccountModel {
    /// Who signed in, enough to name them on the sign-in sheet.
    struct Account: Codable, Equatable, Sendable {
        let userID: UUID
        let email: String?
        /// What the account was created with ("apple", "google", "email"), from Auth's
        /// `app_metadata`. Signing in with it always reaches the account again: identities added
        /// later are linked to it.
        var provider: String? = nil

        /// How the copy names the account: "as olga@example.com", "with Google as
        /// olga@gmail.com", or just "with Apple" when Apple hid the address, since nobody
        /// recognizes a relay address. Nil when there's nothing to name it by.
        var phrase: String? {
            let relay = email.map(Self.isAppleRelay) ?? false
            let method: String? = switch provider {
            case "apple": "Apple"
            case "google": "Google"
            // Only Apple hands out relay addresses.
            case nil where relay: "Apple"
            default: nil
            }
            let address = method == "Apple" && relay ? nil : email
            switch (method, address) {
            case let (method?, address?): return "with \(method) as \(address)"
            case let (method?, nil): return "with \(method)"
            case let (nil, address?): return "as \(address)"
            case (nil, nil): return nil
            }
        }

        private static func isAppleRelay(_ email: String) -> Bool {
            email.lowercased().hasSuffix("@privaterelay.appleid.com")
        }
    }

    enum State: Codable, Equatable, Sendable {
        /// A non-anonymous user is signed in.
        case signedIn(Account)
        /// That account's session disappeared without the user asking. The cloud waits until they
        /// sign in again or continue as a guest.
        case signedOut(Account)
        /// They chose "Continue without an account": anonymous sessions are allowed again, and the
        /// account stays remembered so they can sign back in from Settings.
        case guest(Account)

        var account: Account {
            switch self {
            case .signedIn(let account), .signedOut(let account), .guest(let account): account
            }
        }
    }

    /// Nil while no account is remembered (a fresh install, an anonymous user): everything then
    /// works as it did before accounts were remembered.
    private(set) var state: State?

    var isSignedIn: Bool {
        if case .signedIn = state { true } else { false }
    }

    var isSignedOut: Bool {
        if case .signedOut = state { true } else { false }
    }

    var isGuest: Bool {
        if case .guest = state { true } else { false }
    }

    /// The remembered account's email.
    var email: String? { state?.account.email }

    /// How the sign-in copy names the remembered account (`Account.phrase`).
    var phrase: String? { state?.account.phrase }

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "account.state"

    /// `defaults`: tests pass a suite of their own.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = Self.load(from: defaults)
    }

    /// A non-anonymous user's session is stored: theirs is the account, whatever the state was.
    /// Signing in again is what ends a sign-out or a guest's stay.
    func signedIn(_ account: Account) {
        move(to: .signedIn(account))
    }

    /// The signed-in account's session is gone and the user didn't ask. Calling it again changes
    /// nothing, and a guest stays a guest.
    func sessionEnded() {
        if case .signedIn(let account) = state { move(to: .signedOut(account)) }
    }

    /// "Continue without an account" after a sign-out.
    func continueAsGuest() {
        if case .signedOut(let account) = state { move(to: .guest(account)) }
    }

    /// The user signed out or deleted the account: nothing is remembered, so Auth dropping the
    /// session afterwards isn't taken for a lost one ("You're signed out").
    func forget() {
        guard state != nil else { return }
        state = nil
        defaults.removeObject(forKey: Self.key)
    }

    /// Only a real change is written, so a launch that changes nothing leaves the stored state alone.
    private func move(to next: State) {
        guard next != state else { return }
        state = next
        Self.store(next, in: defaults)
    }

    private static func load(from defaults: UserDefaults) -> State? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    static func store(_ state: State, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}
