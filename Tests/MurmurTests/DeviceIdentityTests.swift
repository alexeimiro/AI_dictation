import Foundation
import Supabase
import Testing
@testable import Murmur

/// A store in memory, which can be told to be unreadable or to refuse what it's handed.
private final class MemoryDeviceStore: DeviceIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var readable = true
    private var writable = true
    private var written = 0

    init(_ stored: String? = nil) {
        self.stored = stored
    }

    var value: String? { lock.withLock { stored } }
    var writes: Int { lock.withLock { written } }
    func set(readable: Bool? = nil, writable: Bool? = nil) {
        lock.withLock {
            if let readable { self.readable = readable }
            if let writable { self.writable = writable }
        }
    }

    func read() -> DeviceIdentityRead {
        lock.withLock { !readable ? .unavailable : stored.map(DeviceIdentityRead.found) ?? .missing }
    }

    func write(_ id: String) -> Bool {
        lock.withLock {
            guard writable, stored == nil else { return false }
            stored = id
            written += 1
            return true
        }
    }

    func remove() {
        lock.withLock { stored = nil }
    }
}

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

/// One weekly allowance per iPhone: the id the iPhone keeps, and where it is sent.
@MainActor
struct DeviceIdentityTests {
    private let phone = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
    private var phoneID: String { phone.uuidString.lowercased() }

    // MARK: The id

    @Test func anIPhoneMakesOneIDAndKeepsIt() {
        let store = MemoryDeviceStore()
        var made = 0
        let identity = DeviceIdentity(store: store) {
            made += 1
            return phone
        }
        #expect(identity.id == phoneID)
        #expect(identity.id == phoneID)
        #expect(store.value == phoneID)
        #expect(made == 1)

        // Murmur deleted and installed again, or just started again: the Keychain still has it.
        let reinstalled = DeviceIdentity(store: store) { UUID() }
        #expect(reinstalled.id == phoneID)
        #expect(store.writes == 1)
    }

    @Test func nothingIsSentWhileTheKeychainCantBeRead() {
        // Started behind the lock screen after a restart: the Keychain isn't readable yet.
        let store = MemoryDeviceStore(phoneID)
        store.set(readable: false)
        let identity = DeviceIdentity(store: store) { UUID() }
        #expect(identity.id == nil)
        // Not a reason to make a new id: the one that is there is read once the iPhone is unlocked.
        store.set(readable: true)
        #expect(identity.id == phoneID)
        #expect(store.writes == 0)
    }

    @Test func anIDThatCouldntBeKeptIsntUsed() {
        // Sent once and forgotten, it would be a new iPhone to the server at every launch.
        let store = MemoryDeviceStore()
        store.set(writable: false)
        let identity = DeviceIdentity(store: store) { phone }
        #expect(identity.id == nil)
        store.set(writable: true)
        #expect(identity.id == phoneID)
    }

    @Test func whatIsStoredIsSentAsTheServerTakesIt() {
        #expect(DeviceIdentity(store: MemoryDeviceStore(phone.uuidString)).id == phoneID)
        #expect(DeviceIdentity.normalized("  \(phone.uuidString)\n") == phoneID)
        #expect(DeviceIdentity.normalized("my-iphone") == nil)
        #expect(DeviceIdentity.normalized("") == nil)

        // Something that isn't an id is replaced by one.
        let store = MemoryDeviceStore("my-iphone")
        #expect(DeviceIdentity(store: store) { phone }.id == phoneID)
        #expect(store.value == phoneID)
    }

    #if !os(macOS)
    /// The real Keychain, under a service of this test's own.
    @Test func theKeychainKeepsWhatItIsHanded() {
        let store = KeychainDeviceStore(service: "test.murmur.device.\(UUID().uuidString)")
        defer { store.remove() }
        #expect(store.read() == .missing)
        #expect(store.write(phoneID))
        #expect(store.read() == .found(phoneID))
        // One id per iPhone: a second one isn't written over the first.
        #expect(!store.write(UUID().uuidString.lowercased()))
        #expect(store.read() == .found(phoneID))
        #expect(DeviceIdentity(store: store) { UUID() }.id == phoneID)
        store.remove()
        #expect(store.read() == .missing)
    }
    #endif

    // MARK: Where it goes

    private let functionsHost = "functions-\(UUID().uuidString.lowercased()).test"
    private let databaseHost = "database-\(UUID().uuidString.lowercased()).test"

    private func functions(device: @escaping @MainActor () -> String?) -> EdgeFunctionClient {
        EdgeFunctionClient(baseURL: URL(string: "https://\(functionsHost)")!, headers: ["Apikey": "sb_publishable_test"],
                           session: StubURLProtocol.session(), device: device, accessToken: { "user-jwt" })
    }

    @Test func everyCallToTheFunctionsNamesTheIPhone() async throws {
        let identity = DeviceIdentity(store: MemoryDeviceStore()) { phone }
        let client = functions { identity.id }
        _ = try await client.post("claim-trial", body: ["deviceToken": "token"], timeout: 5)
        _ = try await client.send("dictate", extraHeaders: ["x-murmur-warm": "1"], timeout: 5)

        let sent = StubURLProtocol.sent(to: functionsHost)
        #expect(sent.count == 2)
        #expect(sent.map { $0.request.value(forHTTPHeaderField: "x-murmur-device") } == [phoneID, phoneID])
        #expect(sent[1].request.value(forHTTPHeaderField: "x-murmur-warm") == "1")
        #expect(sent[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
    }

    @Test func withoutAnIDNothingIsSentInItsPlace() async throws {
        _ = try await functions { nil }.send("dictate", timeout: 5)
        let sent = try #require(StubURLProtocol.sent(to: functionsHost).first)
        #expect(sent.request.value(forHTTPHeaderField: "x-murmur-device") == nil)
    }

    private func service(device: @escaping @MainActor () -> String?) throws -> AccountService {
        let options = SupabaseClientOptions(
            auth: .init(storage: try SignedInStorage(key: "murmur-tests"), storageKey: "murmur-tests", autoRefreshToken: false),
            global: .init(session: StubURLProtocol.session()))
        let backend = Backend(url: URL(string: "https://\(databaseHost)")!, anonKey: "sb_publishable_test",
                              options: options, defaults: UserDefaults(suiteName: "device-\(UUID().uuidString)")!)
        return AccountService(backend: backend, functions: nil, device: device)
    }

    private static let quotaReply = Data(#"""
        [{"plan":"basic","on_trial":false,"trial_ends_at":null,"words_this_week":1000,"weekly_limit":1000,
          "remaining":0,"trial_started_at":null}]
        """#.utf8)

    /// The plan is asked about for this iPhone, so "words left" is what the server will enforce.
    @Test func thePlanIsAskedAboutForThisIPhone() async throws {
        StubURLProtocol.answer(databaseHost, with: .init(body: Self.quotaReply))
        let quota = try #require(try await service { phoneID }.quota())
        #expect(quota.remaining == 0)
        #expect(quota.wordsThisWeek == 1000)

        let sent = try #require(StubURLProtocol.sent(to: databaseHost).first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path() == "/rest/v1/rpc/my_quota")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: String])
        #expect(body == ["p_device": phoneID])
    }

    @Test func withoutAnIDThePlanIsAskedAboutAsBefore() async throws {
        StubURLProtocol.answer(databaseHost, with: .init(body: Self.quotaReply))
        _ = try await service { nil }.quota()
        let sent = try #require(StubURLProtocol.sent(to: databaseHost).first)
        #expect(sent.request.url?.path() == "/rest/v1/rpc/my_quota")
        #expect(sent.body.isEmpty || sent.body == Data("{}".utf8))
    }

    /// A server that doesn't know the question with an iPhone in it is asked the old one.
    @Test func aServerFromBeforeTheCountIsAskedTheOldQuestion() async throws {
        StubURLProtocol.answer(databaseHost, with: .init(status: 404, body: Data(#"""
            {"code":"PGRST202","details":null,"hint":null,
             "message":"Could not find the function public.my_quota(p_device) in the schema cache"}
            """#.utf8)))
        await #expect(throws: (any Error).self) { try await service { phoneID }.quota() }
        let sent = StubURLProtocol.sent(to: databaseHost)
        #expect(sent.count == 2)
        #expect(String(data: sent[0].body, encoding: .utf8)?.contains("p_device") == true)
        #expect(String(data: sent[1].body, encoding: .utf8)?.contains("p_device") != true)
        #expect(AccountService.isUnknownFunction(PostgrestError(code: "42883", message: "x")))
        #expect(!AccountService.isUnknownFunction(PostgrestError(code: "42501", message: "x")))
    }
}
