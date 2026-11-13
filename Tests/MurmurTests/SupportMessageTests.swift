import Foundation
import Supabase
import Testing
@testable import Murmur

/// Auth's storage in memory, holding a signed-in session that needs no refresh.
private final class SignedInStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    init(key: String) throws {
        let now = Date()
        let session = Session(
            accessToken: "access", tokenType: "bearer", expiresIn: 3600, expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "refresh",
            user: User(id: UUID(), appMetadata: [:], userMetadata: [:], aud: "authenticated", email: "olga@example.com",
                       createdAt: now, updatedAt: now, isAnonymous: false))
        values[key] = try JSONEncoder().encode(session)
    }

    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { values[key] = nil } }
}

/// Support messages go to `support`, which saves and emails them; a server without it gets them
/// written to `issue_reports` as before.
@MainActor
struct SupportMessageTests {
    /// The functions and the database answer on hosts of their own, so each can answer differently.
    private let functionsHost = "functions-\(UUID().uuidString.lowercased()).test"
    private let databaseHost = "database-\(UUID().uuidString.lowercased()).test"
    private let defaults = UserDefaults(suiteName: "support-\(UUID().uuidString)")!
    private let message = AccountService.SupportMessage(kind: .issue, topic: "Keyboard", message: "  The mic stops.  ")

    private func service() throws -> AccountService {
        let options = SupabaseClientOptions(
            auth: .init(storage: try SignedInStorage(key: "murmur-tests"), storageKey: "murmur-tests", autoRefreshToken: false),
            global: .init(session: StubURLProtocol.session()))
        let backend = Backend(url: URL(string: "https://\(databaseHost)")!, anonKey: "sb_publishable_test",
                              options: options, defaults: defaults)
        let functions = EdgeFunctionClient(baseURL: URL(string: "https://\(functionsHost)")!, headers: [:],
                                           session: StubURLProtocol.session(), accessToken: { "user-jwt" })
        return AccountService(backend: backend, functions: functions)
    }

    private func body(of sent: StubURLProtocol.Sent?) throws -> [String: Any] {
        let sent = try #require(sent)
        return try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
    }

    @Test func thePayloadCarriesTheKindTopicAndTrimmedText() {
        let payload = AccountService.payload(message, diagnostics: ["app": "1.0 (1)"])
        #expect(payload.message == "The mic stops.")
        #expect(payload.diagnostics == ["app": "1.0 (1)", "kind": "issue", "topic": "Keyboard"])
        let feedback = AccountService.payload(.init(kind: .feedback, topic: nil, message: String(repeating: "a", count: 6000)),
                                              diagnostics: [:])
        #expect(feedback.message.count == 5000)
        #expect(feedback.diagnostics == ["kind": "feedback"])
    }

    @Test func aMessageGoesToTheSupportFunction() async throws {
        StubURLProtocol.answer(functionsHost, with: .init(status: 200, body: Data(#"{"saved":true}"#.utf8)))
        try await service().send(message)
        let sent = StubURLProtocol.sent(to: functionsHost)
        #expect(sent.count == 1)
        #expect(sent.first?.request.url?.path() == "/functions/v1/support")
        let body = try body(of: sent.first)
        #expect(body["message"] as? String == "The mic stops.")
        #expect((body["diagnostics"] as? [String: String])?["topic"] == "Keyboard")
        #expect(StubURLProtocol.sent(to: databaseHost).isEmpty)
    }

    @Test func aServerWithoutTheFunctionGetsItInTheTable() async throws {
        StubURLProtocol.answer(functionsHost, with: .init(status: 404, body: Data(#"{"error":"not found"}"#.utf8)))
        StubURLProtocol.answer(databaseHost, with: .init(status: 201, body: Data()))
        try await service().send(message)
        let saved = StubURLProtocol.sent(to: databaseHost)
        #expect(saved.count == 1)
        #expect(saved.first?.request.url?.path() == "/rest/v1/issue_reports")
        #expect(try body(of: saved.first)["message"] as? String == "The mic stops.")
    }

    @Test func tooManyMessagesSaySoAndSaveNothing() async throws {
        StubURLProtocol.answer(functionsHost, with: .init(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8)))
        let service = try service()
        await #expect(throws: AccountService.Failure.self) { try await service.send(message) }
        do {
            try await service.send(message)
        } catch {
            #expect(error.localizedDescription.contains("several messages in the last hour"))
        }
        #expect(StubURLProtocol.sent(to: databaseHost).isEmpty)
    }
}
