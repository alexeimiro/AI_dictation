import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// A transaction's values, as `URLSessionTaskTransactionMetrics` reports them.
private struct Transaction: TransactionMetrics {
    var isReusedConnection = false
    var networkProtocolName: String? = "h2"
    var connectStartDate: Date?
    var connectEndDate: Date?
    var secureConnectionStartDate: Date?
    var secureConnectionEndDate: Date?
    var requestStartDate: Date?
    var requestEndDate: Date?
    var responseStartDate: Date?
    var countOfRequestBodyBytesSent: Int64 = 0
}

@MainActor
struct EdgeFunctionClientTests {
    private let host = "stub-\(UUID().uuidString.lowercased()).test"

    /// On the stub, with the headers supabase-swift builds for a publishable key: its
    /// Authorization carries the key itself.
    private func functions(token: @escaping @MainActor () async throws -> String = { "user-jwt" })
        -> EdgeFunctionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return EdgeFunctionClient(
            baseURL: URL(string: "https://\(host)")!,
            headers: ["X-Client-Info": "supabase-swift/2.55.3", "Apikey": "sb_publishable_test",
                      "Authorization": "Bearer sb_publishable_test"],
            session: URLSession(configuration: configuration), accessToken: token)
    }

    private func transcribe(with functions: EdgeFunctionClient) async throws(CloudTranscriptionError) -> CloudTranscript {
        try await TranscriptionClient(functions: functions).transcribe(
            audio: Data("audio".utf8), format: .m4a, language: "ru-RU", keywords: ["Окафор"])
    }

    private func clean(with functions: EdgeFunctionClient) async throws(CleanupClient.Failure) -> CleanupClient.Response {
        try await CleanupClient(functions: functions).clean(
            dictationId: UUID(), transcript: "привет всем", language: "ru-RU", targetLanguage: "en-US",
            style: .verbatim, dictionary: [], snippets: [])
    }

    /// `CleanupClient.Failure` isn't Equatable; its description is enough to tell the cases apart.
    private func cleanupFailure(status: Int) async -> String? {
        StubURLProtocol.answer(host, with: .init(status: status, body: Data(#"{"error":"x"}"#.utf8)))
        do {
            _ = try await clean(with: functions())
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// What `functions.invoke` sent: the project's headers with the user's token in place of the
    /// key's Authorization, the same JSON body, endpoint and timeout.
    @Test func sendsWhatInvokeSent() async throws {
        let transcript = try await transcribe(with: functions())
        #expect(transcript.text == "Hello.")

        let sent = try #require(StubURLProtocol.sent(to: host).first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path() == "/functions/v1/transcribe")
        #expect(sent.request.timeoutInterval == 25)
        #expect(sent.request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test")
        #expect(sent.request.value(forHTTPHeaderField: "x-client-info") == "supabase-swift/2.55.3")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["audio"] as? String == Data("audio".utf8).base64EncodedString())
        #expect(body["format"] as? String == "m4a")
        #expect(body["language"] as? String == "ru-RU")
        #expect(body["keywords"] as? [String] == ["Окафор"])
        #expect((body["dictationId"] as? String).flatMap(UUID.init(uuidString:)) != nil)
    }

    @Test func statusesMapAsBefore() async {
        for (status, expected) in [(402, CloudTranscriptionError.limitReached), (429, .rateLimited),
                                   (401, .unavailable("HTTP 401")), (500, .unavailable("HTTP 500"))] {
            StubURLProtocol.answer(host, with: .init(status: status, body: Data(#"{"error":"x"}"#.utf8)))
            await #expect(throws: expected) { try await transcribe(with: functions()) }
        }
        #expect(await cleanupFailure(status: 402) == "limitReached")
        #expect(await cleanupFailure(status: 429) == "rateLimited")
        #expect(await cleanupFailure(status: 503) == #"unavailable("HTTP 503")"#)
    }

    /// A relay error comes with a 2xx status. It was supabase-swift's `FunctionsError.relayError`.
    @Test func aRelayErrorIsUnavailable() async {
        StubURLProtocol.answer(host, with: .init(headers: ["x-relay-error": "true"]))
        await #expect(throws: CloudTranscriptionError.unavailable("Relay Error invoking the Edge Function")) {
            try await transcribe(with: functions())
        }
    }

    @Test func noConnectionIsUnavailable() async {
        StubURLProtocol.answer(host, with: .init(failure: URLError(.notConnectedToInternet)))
        await #expect(throws: CloudTranscriptionError.unavailable(URLError(.notConnectedToInternet).localizedDescription)) {
            try await transcribe(with: functions())
        }
    }

    /// A cancelled request is its own case, whichever layer noticed: URLSession, the token, or
    /// only the task itself.
    @Test func aCancelledRequestIsCancelled() async {
        StubURLProtocol.answer(host, with: .init(failure: URLError(.cancelled)))
        await #expect(throws: CloudTranscriptionError.cancelled) { try await transcribe(with: functions()) }

        await #expect(throws: CloudTranscriptionError.cancelled) {
            try await transcribe(with: functions(token: { throw CancellationError() }))
        }

        struct SignedOut: Error {}
        let cancelled = Task {
            try await transcribe(with: functions(token: {
                try? await Task.sleep(for: .seconds(10))
                throw SignedOut()
            }))
        }
        cancelled.cancel()
        await #expect(throws: CloudTranscriptionError.cancelled) { try await cancelled.value }
    }

    @Test func withoutATokenNothingIsSent() async {
        struct SignedOut: Error {}
        await #expect(throws: CloudTranscriptionError.self) {
            try await transcribe(with: functions(token: { throw SignedOut() }))
        }
        #expect(StubURLProtocol.sent(to: host).isEmpty)
    }

    @Test func capturesTheRegionAndTheServerTimings() async throws {
        StubURLProtocol.answer(host, with: .init(
            headers: ["Content-Type": "application/json", "x-sb-edge-region": "eu-central-1"],
            body: Data(#"""
            {"text":"Hello.","timings":{"region":"eu-central-1","cold":true,"authMs":2.4,"transcribeMs":640,"totalMs":700}}
            """#.utf8)))
        let timing = try #require(try await transcribe(with: functions()).timing)
        #expect(timing.function == "transcribe")
        #expect(timing.status == 200)
        #expect(timing.region == "eu-central-1")
        #expect(timing.server == ServerTiming(region: "eu-central-1", cold: true, authMs: 2, transcribeMs: 640, totalMs: 700))
        #expect(timing.tokenMs != nil)
        #expect(timing.totalMs >= (timing.tokenMs ?? 0))
        // The stub's one transaction opened no connection of its own.
        #expect(timing.reused == false)
    }

    @Test func cleanupRepliesKeepTheirTimings() async throws {
        StubURLProtocol.answer(host, with: .init(
            headers: ["x-sb-edge-region": "eu-central-1"],
            body: Data(#"""
            {"text":"Hi everyone.","status":"cleaned","reason":null,"targetLanguage":"en-US","words":2,
             "model":"gpt-6.1-terra","ttftMs":null,"totalMs":690,"remaining":null,
             "timings":{"authMs":3,"preflightMs":12,"modelMs":690}}
            """#.utf8)))
        let response = try await clean(with: functions())
        #expect(response.text == "Hi everyone.")
        #expect(response.targetLanguage == "en-US")
        #expect(response.timings == ServerTiming(authMs: 3, preflightMs: 12, modelMs: 690))
        #expect(response.request?.function == "cleanup")
        #expect(response.request?.region == "eu-central-1")
        #expect(response.request?.server == response.timings)
        let sent = try #require(StubURLProtocol.sent(to: host).first)
        #expect(sent.request.url?.path() == "/functions/v1/cleanup")
        #expect(sent.request.timeoutInterval == 11)
    }

    /// `request` is the client's own, which is why `Response` lists its keys: a reply that
    /// carries one, in any shape, decodes as before and keeps the client's timing.
    @Test func aRequestKeyInACleanupReplyIsIgnored() async throws {
        for request in [#"{"function":"x","totalMs":1}"#, #""x""#] {
            StubURLProtocol.answer(host, with: .init(body: Data(#"""
                {"text":"Hi everyone.","status":"cleaned","targetLanguage":"en-US","words":2,"model":"gpt-6.1-terra",
                 "ttftMs":null,"totalMs":690,"remaining":null,"request":\#(request)}
                """#.utf8)))
            let response = try await clean(with: functions())
            #expect(response.text == "Hi everyone.", "\(request)")
            #expect(response.request?.function == "cleanup", "\(request)")
        }
    }

    /// The connection rows. Connect and TLS count only for a new connection; upload is request
    /// start → end, and wait is request end → the reply's first byte.
    @Test func transactionsMapOntoTheTiming() {
        func at(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: 1_762_600_000 + milliseconds / 1000) }
        let cases: [(String, Transaction, RequestTiming)] = [
            ("a new TLS connection",
             Transaction(connectStartDate: at(0), connectEndDate: at(250), secureConnectionStartDate: at(80),
                         secureConnectionEndDate: at(250), requestStartDate: at(251), requestEndDate: at(311),
                         responseStartDate: at(1_461), countOfRequestBodyBytesSent: 34_000),
             RequestTiming(function: "transcribe", totalMs: 1_500, reused: false, protocolName: "h2", connectMs: 250,
                           tlsMs: 170, uploadMs: 60, waitMs: 1_150, bytesSent: 34_000)),
            ("a reused connection that still reports connect dates",
             Transaction(isReusedConnection: true, connectStartDate: at(0), connectEndDate: at(250),
                         secureConnectionStartDate: at(80), secureConnectionEndDate: at(250), requestStartDate: at(400),
                         requestEndDate: at(402), responseStartDate: at(800), countOfRequestBodyBytesSent: 900),
             RequestTiming(function: "transcribe", totalMs: 1_500, reused: true, protocolName: "h2", uploadMs: 2,
                           waitMs: 398, bytesSent: 900)),
            ("plain HTTP, as on the local stack",
             Transaction(networkProtocolName: "http/1.1", connectStartDate: at(0), connectEndDate: at(3),
                         requestStartDate: at(3), requestEndDate: at(5), responseStartDate: at(40),
                         countOfRequestBodyBytesSent: 120),
             RequestTiming(function: "transcribe", totalMs: 1_500, reused: false, protocolName: "http/1.1",
                           connectMs: 3, uploadMs: 2, waitMs: 35, bytesSent: 120)),
            ("nothing reported",
             Transaction(networkProtocolName: nil),
             RequestTiming(function: "transcribe", totalMs: 1_500, reused: false, bytesSent: 0)),
        ]
        for (name, transaction, expected) in cases {
            var timing = RequestTiming(function: "transcribe", totalMs: 1_500)
            timing.apply(transaction)
            #expect(timing == expected, "\(name)")
        }
    }

    /// A function deployed before timings, or a malformed `timings`, still gives a usable reply.
    @Test func repliesWithoutUsableTimingsStillDecode() async throws {
        for body in [#"{"text":"Hello."}"#, #"{"text":"Hello.","timings":"soon"}"#] {
            StubURLProtocol.answer(host, with: .init(body: Data(body.utf8)))
            #expect(try await transcribe(with: functions()).text == "Hello.")
        }
    }

    @Test func tokenSigningReadsTheJWTHeader() {
        func token(header: String) -> String {
            let encoded = Data(header.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return encoded + ".eyJzdWIiOiIxIn0.signature"
        }
        #expect(Backend.signing(ofToken: token(header: #"{"alg":"ES256","kid":"3f9a1c2e-77aa-4b0e","typ":"JWT"}"#))
            == "ES256 (kid 3f9a1c2e…)")
        #expect(Backend.signing(ofToken: token(header: #"{"alg":"HS256","typ":"JWT"}"#)) == "HS256")
        #expect(Backend.signing(ofToken: "not a token") == nil)
    }
}
