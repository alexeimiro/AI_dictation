import Foundation
import Testing
@testable import Murmur

/// The account a test's claim belongs to, which a test may switch while the request is out.
private final class SignedIn: @unchecked Sendable {
    var user: UUID?
    init(_ user: UUID?) { self.user = user }
}

@MainActor
struct TrialClaimTests {
    private let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let defaults = UserDefaults(suiteName: "trial-claim-\(UUID().uuidString)")!
    private let ann = UUID()

    private func functions() -> EdgeFunctionClient {
        EdgeFunctionClient(baseURL: URL(string: "https://\(host)")!, headers: ["Apikey": "sb_publishable_test"],
                           session: StubURLProtocol.session(), accessToken: { "user-jwt" })
    }

    private func claim(_ signedIn: SignedIn, token: String? = "dGVzdC1kZXZpY2UtdG9rZW4tYmFzZTY0",
                       onToken: (@Sendable () -> Void)? = nil) -> TrialClaim {
        TrialClaim(functions: functions(), currentUser: { signedIn.user },
                   deviceToken: {
                       onToken?()
                       return token
                   }, defaults: defaults)
    }

    private func answer(_ status: Int, _ body: String) {
        StubURLProtocol.answer(host, with: .init(status: status, body: Data(body.utf8)))
    }

    private func sentBodies() throws -> [[String: Any]] {
        try StubURLProtocol.sent(to: host).map {
            try #require(try JSONSerialization.jsonObject(with: $0.body) as? [String: Any])
        }
    }

    /// The first claim asks the server with the iPhone's token; the decision is kept, so later
    /// claims for that account send nothing.
    @Test func claimsOnceWithTheTokenAndRemembers() async throws {
        answer(200, #"{"trial":"granted","trialEndsAt":"2026-11-27T08:00:00Z"}"#)
        let trial = claim(SignedIn(ann))
        var granted = 0
        trial.onGranted = { granted += 1 }

        #expect(await trial.claimIfNeeded() == .granted)
        #expect(await trial.claimIfNeeded() == .granted)
        #expect(trial.decision(for: ann) == .granted)
        #expect(granted == 1)

        let sent = try #require(StubURLProtocol.sent(to: host).first)
        #expect(StubURLProtocol.sent(to: host).count == 1)
        #expect(sent.request.url?.path() == "/functions/v1/claim-trial")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        #expect(try sentBodies().first?["deviceToken"] as? String == "dGVzdC1kZXZpY2UtdG9rZW4tYmFzZTY0")
    }

    /// A used iPhone's account is decided too, and nothing is said about a grant.
    @Test func aUsedIPhoneIsADecisionToo() async {
        answer(200, #"{"trial":"device_used","trialEndsAt":null}"#)
        let trial = claim(SignedIn(ann))
        var granted = false
        trial.onGranted = { granted = true }
        #expect(await trial.claimIfNeeded() == .deviceUsed)
        #expect(trial.decision(for: ann) == .deviceUsed)
        #expect(!granted)
    }

    /// No session, no claim: it never starts one. No backend, no claim either.
    @Test func noSessionOrBackendSendsNothing() async {
        answer(200, #"{"trial":"granted","trialEndsAt":null}"#)
        #expect(await claim(SignedIn(nil)).claimIfNeeded() == nil)
        let offline = TrialClaim(functions: nil, currentUser: { UUID() }, defaults: defaults)
        #expect(await offline.claimIfNeeded() == nil)
        #expect(StubURLProtocol.sent(to: host).isEmpty)
    }

    /// No token (the simulator) or a server that can't decide: nothing is kept, and the next claim
    /// asks again.
    @Test func anUndecidedAnswerIsAskedAgain() async throws {
        answer(400, #"{"error":"device_token_required"}"#)
        let trial = claim(SignedIn(ann), token: nil)
        #expect(await trial.claimIfNeeded() == nil)
        #expect(trial.decision(for: ann) == nil)
        // No token: the field is left out, which the server reads as "device_token_required".
        #expect(try sentBodies().first.map { $0["deviceToken"] == nil } == true)

        answer(503, #"{"error":"unavailable"}"#)
        #expect(await trial.claimIfNeeded() == nil)
        answer(200, #"{"trial":"unchecked","trialEndsAt":"2026-11-27T08:00:00Z"}"#)
        #expect(await trial.claimIfNeeded() == .unchecked)
        #expect(StubURLProtocol.sent(to: host).count == 3)
    }

    /// Sign-in, coming to the front and the offer page can all ask at once: one request.
    @Test func concurrentClaimsShareOneRequest() async {
        answer(200, #"{"trial":"granted","trialEndsAt":null}"#)
        let trial = claim(SignedIn(ann))
        async let first = trial.claimIfNeeded()
        async let second = trial.claimIfNeeded()
        let answers = await [first, second]
        #expect(answers == [.granted, .granted])
        #expect(StubURLProtocol.sent(to: host).count == 1)
    }

    /// Signed out (or into another account) while the request was out: that answer isn't kept
    /// for anyone.
    @Test func anAnswerForAnAccountThatLeftIsNotKept() async {
        answer(200, #"{"trial":"granted","trialEndsAt":null}"#)
        let signedIn = SignedIn(ann)
        let trial = claim(signedIn, onToken: { signedIn.user = UUID() })
        var granted = false
        trial.onGranted = { granted = true }
        #expect(await trial.claimIfNeeded() == .granted)
        #expect(trial.decision(for: ann) == nil)
        #expect(!granted)
    }

    /// Decisions are per account: another account on this iPhone is asked about separately.
    @Test func eachAccountIsDecidedOnItsOwn() async {
        answer(200, #"{"trial":"legacy","trialEndsAt":null}"#)
        let signedIn = SignedIn(ann)
        let trial = claim(signedIn)
        #expect(await trial.claimIfNeeded() == .legacy)
        let bob = UUID()
        signedIn.user = bob
        answer(200, #"{"trial":"device_used","trialEndsAt":null}"#)
        #expect(await trial.claimIfNeeded() == .deviceUsed)
        #expect(trial.decision(for: ann) == .legacy)
        #expect(trial.decision(for: bob) == .deviceUsed)
        #expect(StubURLProtocol.sent(to: host).count == 2)
    }
}
