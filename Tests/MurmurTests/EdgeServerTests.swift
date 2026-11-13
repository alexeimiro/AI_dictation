import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The dictation server beside the project's own functions: it is asked first for what it serves,
/// and the project's function answers whatever it can't, or is too slow on.
@MainActor
struct EdgeServerTests {
    private let project = "project-\(UUID().uuidString.lowercased()).test"
    private let edge = "edge-\(UUID().uuidString.lowercased()).test"

    /// A client with both homes on the stub. `patience`: how long the server gets before the
    /// project's function is asked beside it.
    private func functions(patience: Duration = .seconds(30)) -> EdgeFunctionClient {
        EdgeFunctionClient(
            baseURL: URL(string: "https://\(project)")!, edgeURL: URL(string: "https://\(edge)")!,
            headers: ["Apikey": "sb_publishable_test"], session: StubURLProtocol.session(),
            patience: { _ in patience }, accessToken: { "user-jwt" })
    }

    private func transcribe(with functions: EdgeFunctionClient) async throws(CloudTranscriptionError) -> CloudTranscript {
        try await TranscriptionClient(functions: functions).transcribe(
            audio: Data("audio".utf8), format: .m4a, language: "ru-RU", languageHints: [], keywords: [],
            dictationId: UUID())
    }

    private func reply(_ text: String, host: String? = nil) -> StubURLProtocol.Reply {
        var headers = ["Content-Type": "application/json"]
        if let host { headers["x-murmur-host"] = host }
        return .init(headers: headers, body: Data(#"{"text":"\#(text)"}"#.utf8))
    }

    private func paths(_ host: String) -> [String] {
        StubURLProtocol.sent(to: host).compactMap { $0.request.url?.path() }
    }

    @Test func aDictationGoesToTheServerFirstUnderTheSamePath() async throws {
        StubURLProtocol.answer(edge, with: reply("From the server.", host: "edge-fi"))
        let client = functions()
        let transcript = try await transcribe(with: client)
        #expect(transcript.text == "From the server.")
        // Where it ran: the server's own name, as the project's region is for its functions.
        #expect(transcript.timing?.region == "edge-fi")

        let sent = try #require(StubURLProtocol.sent(to: edge).first)
        #expect(sent.request.url?.path() == "/functions/v1/transcribe")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer user-jwt")
        #expect(sent.request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test")
        #expect(sent.request.timeoutInterval == 25)
        #expect(paths(project).isEmpty)
        #expect(!client.edgePause.isPaused(at: .now))
    }

    @Test func whatTheServerDoesNotServeGoesToTheProjectAlone() async throws {
        let client = functions()
        for function in ["verify-purchase", "claim-trial", "support", "delete-account", "live"] {
            _ = try await client.post(function, body: ["key": "value"], timeout: 20)
        }
        #expect(paths(edge).isEmpty)
        #expect(paths(project).count == 5)
        #expect(EdgeFunctionClient.edgeFunctions == ["dictate", "transcribe", "cleanup"])
    }

    @Test func aFailureOnTheServerIsAnsweredByTheProjectAndTheServerIsLeftAlone() async throws {
        StubURLProtocol.answer(project, with: reply("From the project."))
        let failures: [StubURLProtocol.Reply] = [
            .init(failure: URLError(.cannotConnectToHost)), .init(failure: URLError(.timedOut)),
            .init(status: 500), .init(status: 502), .init(status: 503),
            // What a server that can't reach the project answers: the project's function knows better.
            .init(status: 401), .init(status: 404),
        ]
        for failure in failures {
            StubURLProtocol.answer(edge, with: failure)
            let client = functions()
            let transcript = try await transcribe(with: client)
            #expect(transcript.text == "From the project.", "\(failure.status) \(String(describing: failure.failure))")
            #expect(client.edgePause.isPaused(at: .now))

            // While it is left alone, a dictation doesn't try it at all.
            let before = paths(edge).count
            _ = try await transcribe(with: client)
            #expect(paths(edge).count == before)
        }
        #expect(paths(edge).count == failures.count)
        #expect(paths(project).count == failures.count * 2)
    }

    @Test func refusalsTheProjectWouldRepeatStandAsTheServerGaveThem() async {
        for (status, expected) in [(402, CloudTranscriptionError.limitReached), (429, .rateLimited),
                                   (400, .unavailable("HTTP 400"))] {
            StubURLProtocol.answer(edge, with: .init(status: status, body: Data(#"{"error":"x"}"#.utf8)))
            let client = functions()
            await #expect(throws: expected) { try await transcribe(with: client) }
            #expect(!client.edgePause.isPaused(at: .now), "a refusal is an answer")
        }
        #expect(paths(project).isEmpty)
    }

    @Test func aServerThatIsTooSlowIsHedgedWithTheProject() async throws {
        StubURLProtocol.answer(edge, with: .init(hangs: true))
        StubURLProtocol.answer(project, with: reply("From the project."))
        let client = functions(patience: .milliseconds(40))
        let started = ContinuousClock.now
        let transcript = try await transcribe(with: client)
        #expect(transcript.text == "From the project.")
        #expect(started.duration(to: .now) < .seconds(5), "it didn't wait for the server's timeout")
        // The same request went to both, and the server is left alone after losing.
        #expect(paths(edge) == ["/functions/v1/transcribe"])
        #expect(paths(project) == ["/functions/v1/transcribe"])
        #expect(StubURLProtocol.sent(to: edge).first?.body == StubURLProtocol.sent(to: project).first?.body)
        #expect(client.edgePause.isPaused(at: .now))
    }

    @Test func whenBothFailTheProjectsAnswerIsTheError() async {
        StubURLProtocol.answer(edge, with: .init(failure: URLError(.cannotConnectToHost)))
        StubURLProtocol.answer(project, with: .init(status: 402, body: Data(#"{"error":"limit_reached"}"#.utf8)))
        await #expect(throws: CloudTranscriptionError.limitReached) { try await transcribe(with: functions()) }

        StubURLProtocol.answer(project, with: .init(failure: URLError(.notConnectedToInternet)))
        await #expect(throws: CloudTranscriptionError.unavailable(URLError(.notConnectedToInternet).localizedDescription)) {
            try await transcribe(with: functions())
        }
    }

    @Test func aCancelledCallIsCancelledAndSaysNothingAboutTheServer() async {
        StubURLProtocol.answer(edge, with: .init(hangs: true))
        let client = functions()
        let call = Task { try await transcribe(with: client) }
        try? await Task.sleep(for: .milliseconds(50))
        call.cancel()
        await #expect(throws: CloudTranscriptionError.cancelled) { try await call.value }
        #expect(paths(project).isEmpty, "nothing new is started for a call that was given up")
        #expect(!client.edgePause.isPaused(at: .now))
    }

    @Test func withoutAServerEveryCallIsTheProjects() async throws {
        let client = EdgeFunctionClient(
            baseURL: URL(string: "https://\(project)")!, headers: [:], session: StubURLProtocol.session(),
            accessToken: { "user-jwt" })
        #expect(try await transcribe(with: client).text == "Hello.")
        #expect(paths(project) == ["/functions/v1/transcribe"])
    }

    @Test func aWarmUpGetsLessPatienceThanADictation() {
        #expect(EdgeFunctionClient.defaultPatience(forTimeout: 5) == .milliseconds(2500))
        #expect(EdgeFunctionClient.defaultPatience(forTimeout: 11) == .seconds(6))
        #expect(EdgeFunctionClient.defaultPatience(forTimeout: 30) == .seconds(6))
    }

    @Test func theServerIsLeftAloneLongerEachTimeInARowAndOneAnswerClearsIt() {
        let now = ContinuousClock.now
        var pause = EdgePause()
        #expect(!pause.isPaused(at: now))
        var lengths: [Int] = []
        for _ in 0..<7 {
            pause.failed(at: now)
            let until = pause.until ?? now
            lengths.append(Int(now.duration(to: until).components.seconds))
        }
        #expect(lengths == [60, 120, 240, 480, 900, 900, 900])
        #expect(pause.isPaused(at: now + .seconds(899)))
        #expect(!pause.isPaused(at: now + .seconds(900)))

        pause.succeeded()
        #expect(!pause.isPaused(at: now))
        pause.failed(at: now)
        #expect(pause.until == now + .seconds(60))
    }
}

/// `hedged` on its own: which of two ways answers, and when the second is started.
struct HedgedTests {
    /// A way that answers `value` after `delay`, and counts its starts.
    private final class Way: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var starts: Int { lock.withLock { count } }

        func answer(_ value: String, after delay: Duration = .zero) -> @Sendable () async -> String {
            { [self] in
                lock.withLock { count += 1 }
                if delay > .zero { try? await Task.sleep(for: delay) }
                return value
            }
        }
    }

    private let isFinal: @Sendable (String) -> Bool = { !$0.hasPrefix("failed") }

    @Test func aFinalAnswerInTimeIsTheWholeCall() async {
        let primary = Way(), fallback = Way()
        let answer = await hedged(patience: .seconds(30), primary: primary.answer("edge"),
                                  fallback: fallback.answer("project"), isFinal: isFinal)
        #expect(answer.value == "edge")
        #expect(answer.source == .primary)
        #expect(!answer.hedged)
        #expect(fallback.starts == 0)
    }

    @Test func aFailureStartsTheFallbackAtOnce() async {
        let primary = Way(), fallback = Way()
        let started = ContinuousClock.now
        let answer = await hedged(patience: .seconds(30), primary: primary.answer("failed: no connection"),
                                  fallback: fallback.answer("project"), isFinal: isFinal)
        #expect(answer.value == "project")
        #expect(answer.source == .fallback)
        #expect(started.duration(to: .now) < .seconds(5), "it didn't wait out the patience")
        #expect(primary.starts == 1)
        #expect(fallback.starts == 1)
    }

    @Test func aSlowPrimaryIsRacedAndTheFirstFinalAnswerWins() async {
        // The fallback wins.
        let slow = Way(), quick = Way()
        let lost = await hedged(patience: .milliseconds(20), primary: slow.answer("edge", after: .seconds(20)),
                                fallback: quick.answer("project"), isFinal: isFinal)
        #expect(lost.value == "project")
        #expect(lost.source == .fallback)
        #expect(lost.hedged)

        // The primary answers while the fallback is still out: its answer is used, and it says it was hedged.
        let late = Way(), slower = Way()
        let won = await hedged(patience: .milliseconds(20), primary: late.answer("edge", after: .milliseconds(120)),
                               fallback: slower.answer("project", after: .seconds(20)), isFinal: isFinal)
        #expect(won.value == "edge")
        #expect(won.source == .primary)
        #expect(won.hedged)
        #expect(slower.starts == 1)
    }

    @Test func withNoFinalAnswerTheFallbacksStands() async {
        let primary = Way(), fallback = Way()
        let both = await hedged(patience: .seconds(30), primary: primary.answer("failed: edge"),
                                fallback: fallback.answer("failed: project"), isFinal: isFinal)
        #expect(both.value == "failed: project")
        #expect(both.source == .fallback)

        // The fallback fails first while the slow primary is still out: the primary may yet answer.
        let slow = Way(), failing = Way()
        let rescued = await hedged(patience: .milliseconds(20), primary: slow.answer("edge", after: .milliseconds(150)),
                                   fallback: failing.answer("failed: project"), isFinal: isFinal)
        #expect(rescued.value == "edge")
        #expect(rescued.source == .primary)

        // And when it fails too, the fallback's failure is the one reported.
        let slowFailure = Way(), quickFailure = Way()
        let neither = await hedged(patience: .milliseconds(20), primary: slowFailure.answer("failed: edge", after: .milliseconds(150)),
                                   fallback: quickFailure.answer("failed: project"), isFinal: isFinal)
        #expect(neither.value == "failed: project")
        #expect(neither.source == .fallback)
    }
}
