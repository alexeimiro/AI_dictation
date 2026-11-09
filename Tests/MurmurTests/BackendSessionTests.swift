import Foundation
import Supabase
import Testing
@testable import Murmur

/// Plays the project's Auth server for one host and counts the requests to each endpoint: a
/// refresh is answered as the test says, an anonymous sign-in with a new anonymous session, and
/// the emailed code with the session `signIn` gave. Each test uses its own host, so the tests can
/// run in parallel.
private final class AuthStub: URLProtocol {
    enum Refresh: Sendable {
        /// What Auth answers a refresh token it no longer has: revoked, or already rotated.
        case rejected
        /// No connection.
        case offline
        /// A new session.
        case refreshed
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var refreshes: [String: Refresh] = [:]
    nonisolated(unsafe) private static var meanwhile: [String: @Sendable () -> Void] = [:]
    nonisolated(unsafe) private static var counts: [String: [String: Int]] = [:]
    nonisolated(unsafe) private static var signIns: [String: Session] = [:]

    /// `meanwhile` runs just before the refresh is answered, as something the app does while
    /// that reply is on its way.
    static func answer(_ host: String, refresh: Refresh, meanwhile: (@Sendable () -> Void)? = nil) {
        lock.withLock {
            refreshes[host] = refresh
            Self.meanwhile[host] = meanwhile
        }
    }

    /// What a correct emailed code signs in to.
    static func signIn(_ host: String, as session: Session) {
        lock.withLock { signIns[host] = session }
    }

    static func requests(to path: String, on host: String) -> Int {
        lock.withLock { counts[host]?[path] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let path = request.url?.path() ?? ""
        let (refresh, meanwhile) = Self.lock.withLock { () -> (Refresh, (@Sendable () -> Void)?) in
            Self.counts[host, default: [:]][path, default: 0] += 1
            return (Self.refreshes[host] ?? .rejected, Self.meanwhile[host])
        }
        switch path {
        case "/auth/v1/token":
            // Longer than the client takes to start: a refresh it begins on its own for the
            // expired session overlaps the test's, and supabase-swift sends one request for both.
            Thread.sleep(forTimeInterval: 0.1)
            meanwhile?()
            switch refresh {
            case .rejected:
                // The 2024-01-01 API version, which supabase-swift asks for, puts the code in `code`.
                reply(400, headers: ["X-Supabase-Api-Version": "2024-01-01"], body: Data(#"""
                    {"code":"refresh_token_not_found","message":"Invalid Refresh Token: Refresh Token Not Found"}
                    """#.utf8))
            case .offline:
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            case .refreshed:
                let session = storedSession(anonymous: true, expired: false)
                reply(200, body: (try? AuthClient.Configuration.jsonEncoder.encode(session)) ?? Data())
            }
        case "/auth/v1/signup":
            let session = storedSession(anonymous: true, expired: false)
            reply(200, body: (try? AuthClient.Configuration.jsonEncoder.encode(session)) ?? Data())
        case "/auth/v1/verify":
            let session = Self.lock.withLock { Self.signIns[host] } ?? storedSession(anonymous: false, expired: false)
            reply(200, body: (try? AuthClient.Configuration.jsonEncoder.encode(session)) ?? Data())
        case "/rest/v1/entitlements":
            // What the signup trigger grants every new user, a guest included: a 14-day trial.
            let ends = ISO8601DateFormatter().string(from: Date().addingTimeInterval(14 * 86_400))
            reply(200, body: Data(#"[{"plan":"basic","source":"trial","trial_ends_at":"\#(ends)","expires_at":null}]"#.utf8))
        default:
            reply(404, body: Data("{}".utf8))
        }
    }

    override func stopLoading() {}

    private func reply(_ status: Int, headers: [String: String] = [:], body: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "application/json"]) { mine, _ in mine })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Auth's storage in memory, in place of the Keychain.
private final class MemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
}

/// A session as Auth keeps it; `expired` when its access token needs a refresh. `user`: whose it
/// is, when not a new user's.
private func storedSession(anonymous: Bool, expired: Bool, user: User? = nil) -> Session {
    let now = Date()
    return Session(
        accessToken: "access-\(UUID().uuidString)", tokenType: "bearer", expiresIn: 3600,
        expiresAt: now.addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970,
        refreshToken: "refresh-\(UUID().uuidString)",
        user: user ?? User(id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated",
                           email: anonymous ? nil : "olga@example.com", createdAt: now, updatedAt: now,
                           isAnonymous: anonymous))
}

/// A defaults suite of one test's own, for the remembered account; removed when the test ends.
private final class ScratchDefaults {
    private let name = "test.murmur.account.\(UUID().uuidString)"
    let suite: UserDefaults

    init() {
        suite = UserDefaults(suiteName: name)!
    }

    deinit {
        suite.removePersistentDomain(forName: name)
    }
}

/// The session rule: a signed-in user is never swapped for an anonymous one.
@MainActor
struct BackendSessionTests {
    private let host = "auth-\(UUID().uuidString.lowercased()).test"
    private let storageKey = "murmur-tests"
    private let defaults = ScratchDefaults()

    private var refreshes: Int { AuthStub.requests(to: "/auth/v1/token", on: host) }
    private var anonymousSignIns: Int { AuthStub.requests(to: "/auth/v1/signup", on: host) }

    /// A backend on the stub that kept `stored` from the last launch. Auth refreshes only when
    /// asked (`ensureSession`), apart from the refresh it starts for an expired session at once.
    /// `emitsLocalSession: false` is the app's own setting: at launch Auth refreshes an expired
    /// session before it reports the initial one.
    private func backend(storing stored: Session?, in storage: MemoryStorage = MemoryStorage(),
                         emitsLocalSession: Bool = true) throws -> Backend {
        if let stored { try storage.store(key: storageKey, value: JSONEncoder().encode(stored)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthStub.self]
        let options = SupabaseClientOptions(
            auth: .init(storage: storage, storageKey: storageKey, autoRefreshToken: false,
                        emitLocalSessionAsInitialSession: emitsLocalSession),
            global: .init(session: URLSession(configuration: configuration)))
        return Backend(url: URL(string: "https://\(host)")!, anonKey: "sb_publishable_test", options: options,
                       defaults: defaults.suite)
    }

    /// A launch as the app makes it: Auth's initial session as in production, so its own refresh
    /// of an expired session runs at once, before any call.
    private func launching(_ stored: Session?, in storage: MemoryStorage = MemoryStorage()) throws -> Backend {
        try backend(storing: stored, in: storage, emitsLocalSession: false)
    }

    /// What Auth and the backend's listener do on their own takes a moment; this waits up to two
    /// seconds for it.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Long enough for the listener to have handled what Auth just reported, when the check is
    /// that nothing changed.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Why the rule exists. With rotation, a refresh cut short by the app being killed is enough
    /// for the server to reject the token; the call that finds out doesn't make the user a new
    /// anonymous one without their plan.
    @Test func aSignedInUserWhoseSessionWasRejectedIsSignedOutNotReplaced() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let backend = try backend(storing: storedSession(anonymous: false, expired: true))
        await #expect(throws: BackendError.signedOut) { try await backend.ensureSession() }
        #expect(refreshes >= 1)
        #expect(anonymousSignIns == 0)
        // supabase-swift deleted it, which is why the user is read before the refresh.
        #expect(backend.client.auth.currentSession == nil)
    }

    /// Offline, timed out or a 5xx: the session is still there for the next attempt.
    @Test func aSignedInUserOfflineKeepsTheirSession() async throws {
        AuthStub.answer(host, refresh: .offline)
        let stored = storedSession(anonymous: false, expired: true)
        let backend = try backend(storing: stored)
        let error = await #expect(throws: URLError.self) { try await backend.ensureSession() }
        #expect(error?.code == .notConnectedToInternet)
        #expect(anonymousSignIns == 0)
        #expect(backend.client.auth.currentUser?.id == stored.user.id)
    }

    /// As before: an anonymous user whose session was rejected gets a new anonymous one.
    @Test func anAnonymousUserWhoseSessionWasRejectedSignsInAgain() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let backend = try backend(storing: storedSession(anonymous: true, expired: true))
        try await backend.ensureSession()
        #expect(refreshes >= 1)
        #expect(anonymousSignIns == 1)
    }

    /// A sign-in that finishes while an anonymous session is being refreshed is kept, whether
    /// that refresh then succeeds (supabase-swift drops it) or is rejected: the refresh's failure
    /// doesn't lead to an anonymous sign-in over the user who just signed in.
    @Test func aSignInDuringTheRefreshIsKept() async throws {
        for refresh in [AuthStub.Refresh.refreshed, .rejected] {
            let storage = MemoryStorage()
            let signedIn = storedSession(anonymous: false, expired: false)
            AuthStub.answer(host, refresh: refresh) { [storageKey] in
                try? storage.store(key: storageKey, value: JSONEncoder().encode(signedIn))
            }
            let backend = try backend(storing: storedSession(anonymous: true, expired: true), in: storage)
            try await backend.ensureSession()
            #expect(backend.client.auth.currentUser?.id == signedIn.user.id)
        }
        #expect(refreshes >= 2)
        #expect(anonymousSignIns == 0)
    }

    @Test func withoutASessionItSignsInAnonymously() async throws {
        let backend = try backend(storing: nil)
        try await backend.ensureSession()
        #expect(refreshes == 0)
        #expect(anonymousSignIns == 1)
        #expect(backend.client.auth.currentUser?.isAnonymous == true)
    }

    /// A session that would run out within a dictation is refreshed while the user speaks
    /// (`BackendWarmup`), not when the request at stop needs it.
    @Test func aSessionExpiringSoonIsRefreshedEarly() async throws {
        AuthStub.answer(host, refresh: .refreshed)
        var stored = storedSession(anonymous: true, expired: false)
        stored.expiresAt = Date().addingTimeInterval(120).timeIntervalSince1970
        let backend = try backend(storing: stored)

        try await backend.ensureSession()
        #expect(refreshes == 0)

        try await backend.ensureSession(validFor: 360)
        #expect(refreshes == 1)
        #expect(anonymousSignIns == 0)
        #expect(backend.client.auth.currentSession?.refreshToken != stored.refreshToken)
    }

    /// Offline, the session it had still works for a while: it's kept, and nobody new signs in.
    @Test(arguments: [false, true])
    func aFailedEarlyRefreshKeepsTheSession(anonymous: Bool) async throws {
        AuthStub.answer(host, refresh: .offline)
        var stored = storedSession(anonymous: anonymous, expired: false)
        stored.expiresAt = Date().addingTimeInterval(120).timeIntervalSince1970
        let backend = try backend(storing: stored)

        try await backend.ensureSession(validFor: 360)
        #expect(backend.client.auth.currentSession?.refreshToken == stored.refreshToken)
        #expect(backend.account.isSignedOut == false)
        // Auth's client tries a request that couldn't connect once more.
        #expect(refreshes >= 1)
        #expect(anonymousSignIns == 0)
    }

    /// Rejected early is rejected all the same: the account is signed out, not replaced.
    @Test func aRejectedEarlyRefreshSignsTheAccountOut() async throws {
        AuthStub.answer(host, refresh: .rejected)
        var stored = storedSession(anonymous: false, expired: false)
        stored.expiresAt = Date().addingTimeInterval(120).timeIntervalSince1970
        let backend = try backend(storing: stored)

        await #expect(throws: BackendError.signedOut) { try await backend.ensureSession(validFor: 360) }
        #expect(anonymousSignIns == 0)
    }

    /// The ways into `ensureSession` end a rejected signed-in session as a failure, with no
    /// anonymous sign-in: the offer, the desktop link, and the edge functions' token, which
    /// transcription and cleanup report as their own case, so the cloud isn't paused and the
    /// keyboard says why.
    @Test func itsCallersTreatTheSignOutAsAFailure() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let offers = SupabaseOfferProvider(backend: try backend(storing: storedSession(anonymous: false, expired: true)))
        await #expect(throws: BackendError.signedOut) { try await offers.currentOffer() }

        let profile = SupabaseProfileSync(backend: try backend(storing: storedSession(anonymous: false, expired: true)))
        await #expect(throws: BackendError.signedOut) { try await profile.requestDesktopLink(email: "olga@example.com") }

        let functions = EdgeFunctionClient(backend: try backend(storing: storedSession(anonymous: false, expired: true)))
        await #expect(throws: CloudTranscriptionError.signedOut) {
            try await TranscriptionClient(functions: functions).transcribe(
                audio: Data("audio".utf8), format: .m4a, language: nil, languageHints: [], keywords: [])
        }

        // `CleanupClient.Failure` isn't Equatable.
        let cleanup = CleanupClient(functions: functions)
        do {
            _ = try await cleanup.clean(dictationId: UUID(), transcript: "привет всем", language: "ru-RU",
                                        targetLanguage: "en-US", style: .verbatim, dictionary: [], snippets: [])
            Issue.record("The cleanup went through while signed out")
        } catch {
            guard case .signedOut = error else {
                Issue.record("Expected signedOut, got \(error)")
                return
            }
        }
        #expect(anonymousSignIns == 0)
    }

    // MARK: The signed-out state

    /// Auth's own refresh at launch (or in the foreground) finds the session rejected before any
    /// call does, and deletes it. The account is signed out and stays so: calls fail at once, with
    /// no refresh and no anonymous user.
    @Test func aSessionRejectedAtLaunchKeepsTheAccountSignedOut() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let backend = try launching(storedSession(anonymous: false, expired: true))
        #expect(await eventually { backend.account.isSignedOut })
        #expect(backend.account.email == "olga@example.com")
        #expect(backend.client.auth.currentSession == nil)

        let launchRefreshes = refreshes
        for _ in 0..<2 {
            await #expect(throws: BackendError.signedOut) { try await backend.ensureSession() }
        }
        #expect(refreshes == launchRefreshes)
        #expect(anonymousSignIns == 0)
    }

    /// The call that finds out signs the account out at once, so the next one is signed out too
    /// rather than a first launch's anonymous sign-in.
    @Test func theCallAfterTheOneThatFindsOutIsSignedOutToo() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let backend = try launching(storedSession(anonymous: false, expired: true))
        await #expect(throws: BackendError.signedOut) { try await backend.ensureSession() }
        #expect(backend.account.isSignedOut)
        await #expect(throws: BackendError.signedOut) { try await backend.ensureSession() }
        #expect(anonymousSignIns == 0)
    }

    /// The account is remembered as signed in, but its session is already gone at launch (the
    /// last run was killed before it could say so): Auth's initial session alone signs it out.
    @Test func aRememberedAccountWithoutASessionIsSignedOutAtLaunch() async throws {
        AccountModel(defaults: defaults.suite).signedIn(.init(userID: UUID(), email: "olga@example.com"))
        let backend = try launching(nil)
        #expect(await eventually { backend.account.isSignedOut })
        #expect(refreshes == 0)
        #expect(anonymousSignIns == 0)
    }

    /// The same, with a call before the listener has heard anything: it's signed out too, not a
    /// first launch's anonymous sign-in.
    @Test func aCallBeforeTheListenerHearsIsSignedOutToo() async throws {
        AccountModel(defaults: defaults.suite).signedIn(.init(userID: UUID(), email: "olga@example.com"))
        let backend = try launching(nil)
        await #expect(throws: BackendError.signedOut) { try await backend.ensureSession() }
        #expect(backend.account.isSignedOut)
        #expect(anonymousSignIns == 0)
    }

    /// Offline at launch, Auth reports no initial session but keeps the stored one: that's no
    /// sign-out.
    @Test func offlineAtLaunchIsNotASignOut() async throws {
        AuthStub.answer(host, refresh: .offline)
        let backend = try launching(storedSession(anonymous: false, expired: true))
        await #expect(throws: URLError.self) { try await backend.ensureSession() }
        await settle()
        #expect(backend.account.isSignedIn)
        #expect(anonymousSignIns == 0)
    }

    /// "Continue without an account": anonymous sessions are allowed again from the next call
    /// on, and the account stays remembered for a later sign-in.
    @Test func continuingAsAGuestSignsInAnonymouslyOnce() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let backend = try launching(storedSession(anonymous: false, expired: true))
        #expect(await eventually { backend.account.isSignedOut })

        backend.continueAsGuest()
        #expect(backend.account.isGuest)
        try await backend.ensureSession()
        try await backend.ensureSession()
        #expect(anonymousSignIns == 1)
        #expect(backend.client.auth.currentUser?.isAnonymous == true)
        await settle()
        #expect(backend.account.isGuest)
        #expect(backend.account.email == "olga@example.com")
    }

    /// Signing in again (here with the emailed code, through the app's own sign-in) ends the
    /// sign-out as soon as it returns, without waiting for the listener, and the cloud opens again.
    @Test func signingInAgainEndsTheSignOut() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let lost = storedSession(anonymous: false, expired: true)
        let backend = try launching(lost)
        #expect(await eventually { backend.account.isSignedOut })

        AuthStub.signIn(host, as: storedSession(anonymous: false, expired: false, user: lost.user))
        try await SupabaseOnboardingAuth(backend: backend).verifyEmailCode("123456", email: "olga@example.com")
        #expect(backend.account.state == .signedIn(.init(userID: lost.user.id, email: "olga@example.com")))
        let refreshesBefore = refreshes
        try await backend.ensureSession()
        #expect(refreshes == refreshesBefore)
        #expect(anonymousSignIns == 0)
        // The listener's own word on the sign-in, arriving after, agrees.
        await settle()
        #expect(backend.account.isSignedIn)
    }

    /// The sign-in itself has the account signed in (`didSignIn`), before Auth's event about it
    /// arrives, so the sheet can close at once.
    @Test func aSignInCountsBeforeItsEventArrives() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let storage = MemoryStorage()
        let lost = storedSession(anonymous: false, expired: true)
        let backend = try launching(lost, in: storage)
        #expect(await eventually { backend.account.isSignedOut })

        // Stored as a sign-in stores it, but without any event.
        let again = storedSession(anonymous: false, expired: false, user: lost.user)
        try storage.store(key: storageKey, value: JSONEncoder().encode(again))
        #expect(backend.account.isSignedOut)
        backend.didSignIn()
        #expect(backend.account.isSignedIn)
    }

    /// Nothing remembered: an anonymous user whose session was rejected at launch gets a new
    /// anonymous one on the next call, as before.
    @Test func withoutARememberedAccountARejectedSessionIsReplaced() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let backend = try launching(storedSession(anonymous: true, expired: true))
        #expect(await eventually { backend.client.auth.currentSession == nil })
        try await backend.ensureSession()
        #expect(anonymousSignIns == 1)
        #expect(backend.client.auth.currentUser?.isAnonymous == true)
        #expect(backend.account.state == nil)
    }

    /// The way out of onboarding's offer page after a sign-out: while signed out the offer fails
    /// at once with nothing sent, and once they go on as a guest it loads, for a new anonymous
    /// user.
    @Test func theOfferLoadsOnceTheyGoOnAsAGuest() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let backend = try launching(storedSession(anonymous: false, expired: true))
        #expect(await eventually { backend.account.isSignedOut })
        let offers = SupabaseOfferProvider(backend: backend)
        let launchRefreshes = refreshes
        await #expect(throws: BackendError.signedOut) { try await offers.currentOffer() }
        #expect(refreshes == launchRefreshes)
        #expect(AuthStub.requests(to: "/rest/v1/entitlements", on: host) == 0)

        backend.continueAsGuest()
        #expect(try await offers.currentOffer() == .trial(days: 14))
        #expect(anonymousSignIns == 1)
    }

    /// The account is remembered with what it was created with, so the copy can say "with Apple"
    /// instead of showing a relay address nobody recognizes.
    @Test func theAccountIsRememberedWithItsProvider() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let now = Date()
        let user = User(id: UUID(), appMetadata: ["provider": .string("apple")], userMetadata: [:], aud: "authenticated",
                        email: "x7k2q9@privaterelay.appleid.com", createdAt: now, updatedAt: now, isAnonymous: false)
        let backend = try launching(storedSession(anonymous: false, expired: true, user: user))
        #expect(await eventually { backend.account.isSignedOut })
        #expect(backend.account.state?.account.provider == "apple")
        #expect(backend.account.phrase == "with Apple")
    }

    /// The signed-out and guest states outlive the app: the next launch, with no session left,
    /// starts where the last one ended.
    @Test func theStateSurvivesARelaunch() async throws {
        AuthStub.answer(host, refresh: .rejected)
        let storage = MemoryStorage()
        let first = try launching(storedSession(anonymous: false, expired: true), in: storage)
        #expect(await eventually { first.account.isSignedOut })

        let second = try launching(nil, in: storage)
        #expect(second.account.isSignedOut)
        #expect(second.account.email == "olga@example.com")
        await #expect(throws: BackendError.signedOut) { try await second.ensureSession() }
        #expect(anonymousSignIns == 0)

        second.continueAsGuest()
        let third = try launching(nil, in: storage)
        #expect(third.account.isGuest)
        #expect(third.account.email == "olga@example.com")
    }
}
