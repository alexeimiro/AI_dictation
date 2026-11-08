import Foundation
import os
import Supabase

enum BackendError: LocalizedError {
    /// The server rejected a signed-in user's session (revoked, or its refresh token already
    /// rotated), and supabase-swift deleted it. Only signing in again brings the account back.
    case signedOut

    var errorDescription: String? {
        switch self {
        case .signedOut: "The account was signed out."
        }
    }
}

/// The Supabase project the app talks to, configured from `SUPABASE_HOST` / `SUPABASE_ANON_KEY`
/// (Config/Local.xcconfig → Info.plist). Nil when not configured, in which case dictation still
/// works with on-device formatting only.
@MainActor
final class Backend: SessionRenewing {
    /// The project's base URL; the edge functions live under it (`EdgeFunctionClient`).
    let url: URL
    let client: SupabaseClient
    /// The account this install signs in with. While its session is gone, `ensureSession` keeps
    /// the cloud closed until the user signs in again or continues as a guest.
    let account: AccountModel
    private let logger = Logger(subsystem: "Murmur", category: "Backend")
    /// Keeps `account` in step with Auth for as long as the backend lives.
    private let authEvents: Task<Void, Never>

    /// `options`: tests pass in-memory auth storage and a stubbed URLSession; the default is
    /// what `SupabaseClient(supabaseURL:supabaseKey:)` uses, with its Keychain storage cached.
    /// `defaults`: where the account is remembered; tests pass a suite of their own.
    init(url: URL, anonKey: String, options: SupabaseClientOptions = Backend.defaultOptions(),
         defaults: UserDefaults = .standard) {
        self.url = url
        let client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey, options: options)
        self.client = client
        let account = AccountModel(defaults: defaults)
        self.account = account
        // Read before Auth's launch refresh can delete it: a signed-in session kept by a build
        // that didn't remember accounts is remembered now, so losing it at this launch signs the
        // user out instead of replacing them.
        Self.adopt(client.auth.currentSession, into: account)
        // Asked for here, so Auth attaches it before its launch refresh can answer.
        authEvents = Task { [changes = client.auth.authStateChanges] in
            for await (event, _) in changes {
                Self.update(account, after: event, stored: client.auth.currentSession)
            }
        }
    }

    deinit {
        authEvents.cancel()
    }

    static func fromInfoPlist(_ bundle: Bundle = .main, options: SupabaseClientOptions = Backend.defaultOptions(),
                              defaults: UserDefaults = .standard) -> Backend? {
        guard let host = infoString("MurmurSupabaseHost", bundle),
              let key = infoString("MurmurSupabaseAnonKey", bundle),
              let url = baseURL(forHost: host) else { return nil }
        return Backend(url: url, anonKey: key, options: options, defaults: defaults)
    }

    /// supabase-swift's defaults, with the session read from the Keychain once rather than on
    /// every request (`CachedAuthStorage`).
    nonisolated static func defaultOptions() -> SupabaseClientOptions {
        SupabaseClientOptions(auth: .init(storage: CachedAuthStorage(AuthClient.Configuration.defaultLocalStorage)))
    }

    /// `abcd.supabase.co` → https; a local stack (`127.0.0.1:54321`, LAN IPs, `*.local`) → http.
    static func baseURL(forHost host: String) -> URL? {
        if host.hasPrefix("http://") || host.hasPrefix("https://") { return URL(string: host) }
        let isLocal = host.hasPrefix("127.") || host.hasPrefix("localhost") || host.hasPrefix("192.168.")
            || host.hasPrefix("10.") || host.contains(".local")
        return URL(string: "\(isLocal ? "http" : "https")://\(host)")
    }

    // MARK: Account

    /// Auth's events can be stale by the time they're handled here, so this goes by the session
    /// stored now; the event only says whether a missing one means the account's was lost.
    ///
    /// Nothing in the app signs out on purpose, so every `.signedOut` is one the user didn't ask
    /// for: the server rejected the session, at Auth's own refresh (launch, foreground) or at
    /// `ensureSession`'s. A Sign out button would have to forget the account first, and again once
    /// Auth has dropped the session (an event queued before it would bring the account back), or
    /// the user would see "You're signed out". That, and the sign-out's scope, is left to it.
    static func update(_ account: AccountModel, after event: AuthChangeEvent, stored: Session?) {
        if adopt(stored, into: account) { return }
        switch event {
        case .signedOut, .initialSession:
            // No signed-in session is stored, so the account's is gone. Offline, Auth keeps it
            // stored (and reports no initial session): that one was adopted above.
            account.sessionEnded()
        default:
            // An anonymous user's sign-in or refresh never changes the remembered account.
            break
        }
    }

    /// Remembers a stored non-anonymous user as the signed-in account; false when there's none.
    @discardableResult
    private static func adopt(_ stored: Session?, into account: AccountModel) -> Bool {
        guard let user = stored?.user, !user.isAnonymous else { return false }
        account.signedIn(AccountModel.Account(
            userID: user.id, email: user.email, provider: user.appMetadata["provider"]?.stringValue))
        return true
    }

    /// A sign-in just finished (`SupabaseOnboardingAuth`): its account is taken now rather than
    /// when the listener's event arrives, so the sign-in sheet closes on a state that's already
    /// signed in. It's the listener's own rule, so whichever comes first, the result is the same.
    func didSignIn() {
        Self.adopt(client.auth.currentSession, into: account)
    }

    /// "Continue without an account" after a sign-out. The anonymous sign-in is left to the next
    /// `ensureSession`: nothing goes out until the cloud is used, and its rule refreshes a session
    /// the user signed in with meanwhile instead of replacing it.
    func continueAsGuest() {
        account.continueAsGuest()
    }

    // MARK: Session

    /// Makes sure requests carry a user JWT: the signed-in user's, or else an anonymous user's,
    /// which still gets per-user quota and rate limits. A signed-in user is never swapped for an
    /// anonymous one, which would lose their plan: once the server has rejected their session
    /// (here, or at Auth's own refresh) this throws `BackendError.signedOut`, at once and with no
    /// request, until they sign in again or continue as a guest (`account`). Other refresh
    /// failures (offline, a timeout, a 5xx) are thrown as they are, and the session stays stored
    /// for the next attempt.
    ///
    /// `validFor`: a session that expires sooner is refreshed now, ahead of the requests that will
    /// need it (`BackendWarmup`). If that early refresh fails, the session still works and is kept.
    func ensureSession(validFor minimum: TimeInterval = 0) async throws {
        let stored = client.auth.currentSession
        if account.isSignedOut {
            // Only a session the user signed in with again gets through: no refresh, no anonymous
            // sign-in, and never a stored anonymous session.
            guard let stored, !stored.user.isAnonymous, !stored.isExpired else { throw BackendError.signedOut }
        }
        Self.adopt(stored, into: account)
        if account.isSignedIn, stored?.user.isAnonymous != false {
            // The account's session is gone and the listener hasn't said so yet, or an anonymous
            // one took its place: the plan stays with the account.
            account.sessionEnded()
            throw BackendError.signedOut
        }
        // From here on as before: the account's own session, a guest's, or no account's.
        let early = stored.map { !$0.isExpired } ?? false
        if let stored, early, stored.expiresAt - Date().timeIntervalSince1970 >= minimum { return }
        // Read before the refresh: when the server rejects the refresh token, supabase-swift
        // deletes the stored session itself, and the user with it.
        let signedIn = stored?.user.isAnonymous == false
        do {
            // `session` refreshes only an expired one.
            _ = try await early ? client.auth.refreshSession() : client.auth.session
        } catch {
            // Read again: a sign-in can finish while the refresh is out.
            let current = client.auth.currentSession
            if let current, current.refreshToken != stored?.refreshToken {
                // That session replaced the one being refreshed (supabase-swift drops the refresh):
                // it's the one to use, and an anonymous sign-in would replace it.
                guard current.isExpired else { return }
                throw error
            }
            if early, let current, !current.isExpired {
                // Refreshed early, and still stored (offline, a timeout, a 5xx): it works for now,
                // and the next call tries again.
                logger.notice("Couldn't refresh the session early: \(error.localizedDescription, privacy: .public)")
                return
            }
            if signedIn || current?.user.isAnonymous == false {
                // Still stored: offline, a timeout or a 5xx, and the next attempt can refresh it.
                guard current == nil else { throw error }
                logger.notice("The server rejected the signed-in session")
                // The listener hears it too; either one is enough.
                account.sessionEnded()
                throw BackendError.signedOut
            }
            logger.info("No session; signing in anonymously")
            _ = try await client.auth.signInAnonymously()
        }
    }

    /// How the current access token is signed, for the Debug screen: with an asymmetric key
    /// ("ES256 (kid …)") the functions verify it locally, while "HS256" costs them an Auth call
    /// per request. Nil without a session.
    var tokenSigning: String? {
        client.auth.currentSession.flatMap { Self.signing(ofToken: $0.accessToken) }
    }

    /// The `alg` and `kid` in a JWT's header; nil when the header doesn't parse.
    static func signing(ofToken token: String) -> String? {
        struct Header: Decodable {
            let alg: String
            let kid: String?
        }
        guard let encoded = token.split(separator: ".").first else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        guard let kid = header.kid, !kid.isEmpty else { return header.alg }
        return "\(header.alg) (kid \(kid.count > 8 ? String(kid.prefix(8)) + "…" : kid))"
    }

    private static func infoString(_ key: String, _ bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}

/// Auth's storage with what it holds kept in memory. supabase-swift reads the stored session at
/// every `currentSession` and `session`, a Keychain read and a decode each time: several per
/// dictation, some on the main thread. Only this app's process writes the item, and every write
/// goes through here, so the copy is never stale.
final class CachedAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let base: any AuthLocalStorage
    private let lock = NSLock()
    /// By key: the stored value, or `.some(nil)` once it's known there is none.
    private var values: [String: Data?] = [:]

    init(_ base: any AuthLocalStorage) {
        self.base = base
    }

    // The Keychain calls stay under the lock, so a read can't put back a value a write replaced.
    func store(key: String, value: Data) throws {
        try lock.withLock {
            try base.store(key: key, value: value)
            values[key] = .some(value)
        }
    }

    func retrieve(key: String) throws -> Data? {
        try lock.withLock {
            if let known = values[key] { return known }
            // Not kept when the read fails (a locked device): the next read tries the Keychain again.
            let value = try base.retrieve(key: key)
            values[key] = .some(value)
            return value
        }
    }

    func remove(key: String) throws {
        try lock.withLock {
            try base.remove(key: key)
            values[key] = .some(nil)
        }
    }
}

#if DEBUG
extension Backend {
    /// Screenshot runs and UI tests (`-account-state`): the configured project, or one that can't
    /// be reached, with `state` faked. It lives in a defaults suite of its own over sessions kept
    /// in memory, so neither the Keychain nor the network changes it, and the app's own defaults
    /// never see it. With no session stored, only a signed-out or guest state holds: Auth's
    /// initial session would sign a signed-in one out at once.
    static func faking(_ state: AccountModel.State) -> Backend? {
        let name = "murmur.fixtures.account"
        guard let defaults = UserDefaults(suiteName: name) else { return nil }
        defaults.removePersistentDomain(forName: name)
        AccountModel.store(state, in: defaults)
        let options = SupabaseClientOptions(auth: .init(storage: FixtureSessionStorage()))
        return fromInfoPlist(options: options, defaults: defaults)
            ?? Backend(url: URL(string: "https://fixtures.invalid")!, anonKey: "fixtures", options: options,
                       defaults: defaults)
    }
}

/// Auth's storage in memory, for `Backend.faking`.
private final class FixtureSessionStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
}
#endif
