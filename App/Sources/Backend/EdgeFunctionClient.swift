import Foundation
import MurmurCore
import Supabase

/// An edge function call without a usable 2xx reply. It keeps supabase-swift's descriptions
/// (`FunctionsError`, `URLError`), so the clients map errors exactly as they did with `invoke`.
enum EdgeFunctionError: LocalizedError {
    /// No reply to use: offline, a timeout, a relay error, or no access token.
    case transport(any Error)
    /// The function answered with a status outside 2xx.
    case httpError(code: Int)

    var errorDescription: String? {
        switch self {
        case .transport(let error): error.localizedDescription
        case .httpError(let code): FunctionsError.httpError(code: code, data: Data()).localizedDescription
        }
    }
}

/// When the dictation server is left alone after it failed or was too slow: a minute, then twice
/// as long each time in a row, up to fifteen. One answer from it clears the count.
struct EdgePause: Sendable {
    private(set) var until: ContinuousClock.Instant?
    private var strikes = 0

    func isPaused(at now: ContinuousClock.Instant) -> Bool {
        until.map { now < $0 } ?? false
    }

    mutating func failed(at now: ContinuousClock.Instant) {
        strikes += 1
        let seconds = min(60 * (1 << min(strikes - 1, 4)), 900)
        until = now + .seconds(seconds)
    }

    mutating func succeeded() {
        strikes = 0
        until = nil
    }
}

/// Which of two ways answered a hedged call.
enum HedgeSource: Sendable {
    case primary, fallback
}

/// What a hedged call's group hears: one of the two ways answered, or the patience ran out.
private enum HedgeEvent<Value: Sendable>: Sendable {
    case primary(Value), fallback(Value), patienceOver
}

/// Runs `primary`. If it gives no answer within `patience`, `fallback` runs beside it, and an
/// answer of `primary`'s that isn't `isFinal` (a failure another way may not share) starts
/// `fallback` at once. The first final answer wins and the other is cancelled; with none, the
/// fallback's answer stands: it is the way that worked before there were two. A cancelled caller
/// starts nothing new.
func hedged<Value: Sendable>(
    patience: Duration,
    primary: @escaping @Sendable () async -> Value,
    fallback: @escaping @Sendable () async -> Value,
    isFinal: @escaping @Sendable (Value) -> Bool
) async -> (value: Value, source: HedgeSource, hedged: Bool) {
    await withTaskGroup(of: HedgeEvent<Value>.self, returning: (value: Value, source: HedgeSource, hedged: Bool).self) { group in
        group.addTask { .primary(await primary()) }
        group.addTask {
            try? await Task.sleep(for: patience)
            return .patienceOver
        }
        var fallbackStarted = false
        var primaryAnswer: Value?
        var fallbackAnswer: Value?
        for await event in group {
            switch event {
            case .patienceOver:
                if primaryAnswer == nil, !fallbackStarted, !Task.isCancelled {
                    fallbackStarted = true
                    group.addTask { .fallback(await fallback()) }
                }
            case .primary(let value):
                if isFinal(value) || Task.isCancelled {
                    group.cancelAll()
                    return (value, .primary, fallbackStarted)
                }
                if let fallbackAnswer {
                    group.cancelAll()
                    return (fallbackAnswer, .fallback, true)
                }
                primaryAnswer = value
                if !fallbackStarted {
                    fallbackStarted = true
                    group.addTask { .fallback(await fallback()) }
                }
            case .fallback(let value):
                if isFinal(value) || primaryAnswer != nil {
                    group.cancelAll()
                    return (value, .fallback, true)
                }
                // Not final, and the primary is still out: its answer may be.
                fallbackAnswer = value
            }
        }
        // Not reached: the primary always answers, and the loop returns on its answer or the
        // fallback's. A value is still owed.
        if let fallbackAnswer { return (fallbackAnswer, .fallback, true) }
        return (primaryAnswer!, .primary, fallbackStarted)
    }
}

/// Calls our edge functions in place of supabase-swift's `functions.invoke`, for the timings:
/// only a per-task delegate gets `URLSessionTaskMetrics` (reused connection, TLS, upload, wait),
/// and `invoke` can't take one. On the wire it sends what `invoke` sent: a JSON POST to
/// `<project>/functions/v1/<name>` with the client's headers, the session's access token and the
/// same timeout, on `URLSession.shared`, whose connections supabase-swift's auth calls share.
///
/// With a dictation server configured (`edgeURL`), the functions it serves go there first, under
/// the same path and with the same request. It is a faster way, never the only one: whatever it
/// can't answer for good goes to the project's own function, and so does a call it is too slow on.
@MainActor
final class EdgeFunctionClient {
    struct Reply: Sendable {
        let data: Data
        let timing: RequestTiming
    }

    private struct Envelope: Decodable {
        let timings: ServerTiming?
    }

    /// One call, as either home gets it.
    private struct Call: Sendable {
        let function: String
        let payload: Data
        let contentType: String?
        let extraHeaders: [String: String]
        let timeout: TimeInterval
        let token: String
        let tokenMs: Int
        let started: ContinuousClock.Instant
    }

    /// The functions the dictation server serves. The rest exist only in the project.
    static let edgeFunctions: Set<String> = ["dictate", "transcribe", "cleanup"]

    /// How long the dictation server has for a call before the project's function is asked beside
    /// it: a warm-up (its timeout is 5 s) is its health check and gets 2.5 s; a dictation gets 6 s,
    /// several times what the server takes when the network to it is good.
    nonisolated static func defaultPatience(forTimeout timeout: TimeInterval) -> Duration {
        timeout <= 5 ? .milliseconds(2500) : .seconds(6)
    }

    private let functionsURL: URL
    private let edgeURL: URL?
    private let headers: [String: String]
    private let session: URLSession
    private let accessToken: @MainActor () async throws -> String
    private let patience: @Sendable (TimeInterval) -> Duration
    /// While set and not yet passed, calls skip the dictation server.
    private(set) var edgePause = EdgePause()

    /// `headers` go out with every request except an Authorization, which carries the token
    /// from `accessToken` instead. `edgeURL`: the dictation server, under which the functions it
    /// serves have the same path; nil without one. `patience`: tests pass short ones.
    init(baseURL: URL, edgeURL: URL? = nil, headers: [String: String], session: URLSession = .shared,
         patience: @escaping @Sendable (TimeInterval) -> Duration = EdgeFunctionClient.defaultPatience,
         accessToken: @escaping @MainActor () async throws -> String) {
        functionsURL = baseURL.appendingPathComponent("/functions/v1")
        self.edgeURL = edgeURL?.appendingPathComponent("/functions/v1")
        self.headers = headers.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        self.session = session
        self.patience = patience
        self.accessToken = accessToken
    }

    /// The project's `apikey` and `X-Client-Info`, and the user's session as `invoke` had it. The
    /// client's own Authorization holds the API key, not the user.
    convenience init(backend: Backend) {
        self.init(baseURL: backend.url, edgeURL: backend.edgeURL, headers: backend.client.headers) {
            try await backend.ensureSession()
            return try await backend.client.auth.session.accessToken
        }
    }

    /// POSTs `body` as JSON, with `extraHeaders`, and returns a 2xx reply undecoded, with its timing.
    func post(_ function: String, body: some Encodable, extraHeaders: [String: String] = [:],
              timeout: TimeInterval) async throws(EdgeFunctionError) -> Reply {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw .transport(error)
        }
        return try await send(function, payload: payload, contentType: "application/json",
                              extraHeaders: extraHeaders, timeout: timeout)
    }

    /// POSTs `payload` (none for a warm-up) with `extraHeaders`, and returns a 2xx reply undecoded.
    /// `timeout` is URLRequest's: how long the request may go without sending or receiving data.
    func send(_ function: String, payload: Data = Data(), contentType: String? = nil,
              extraHeaders: [String: String] = [:], timeout: TimeInterval) async throws(EdgeFunctionError) -> Reply {
        let started = ContinuousClock.now
        let token: String
        do {
            token = try await accessToken()
        } catch {
            throw .transport(error)
        }
        let call = Call(function: function, payload: payload, contentType: contentType, extraHeaders: extraHeaders,
                        timeout: timeout, token: token, tokenMs: started.elapsedMilliseconds, started: started)
        let result: Result<Reply, EdgeFunctionError>
        if let edgeURL, Self.edgeFunctions.contains(function), !edgePause.isPaused(at: .now) {
            result = await viaEdge(call, edgeURL: edgeURL)
        } else {
            result = await perform(call, at: functionsURL)
        }
        return try result.get()
    }

    /// The dictation server first, and the project's function for whatever it can't answer for good
    /// or is too slow on. A server that failed, or lost to the project's function, is left alone
    /// for a while (`EdgePause`), so a broken one costs a dictation its patience once, not each time.
    private func viaEdge(_ call: Call, edgeURL: URL) async -> Result<Reply, EdgeFunctionError> {
        let functionsURL = functionsURL
        let answer = await hedged(
            patience: patience(call.timeout),
            primary: { await self.perform(call, at: edgeURL) },
            fallback: { await self.perform(call, at: functionsURL) },
            isFinal: Self.isFinal)
        // A cancelled call says nothing about the server.
        guard !Task.isCancelled else { return answer.value }
        switch answer.source {
        case .primary:
            if case .success = answer.value { edgePause.succeeded() }
        case .fallback:
            edgePause.failed(at: .now)
        }
        return answer.value
    }

    /// Whether the dictation server's answer stands. A reply does, and so do the refusals the
    /// project's function would repeat, from the same database or for the same request: 400, 402,
    /// 429. Anything else (no connection, a 5xx, a 401 or a 404, which a server that can't reach
    /// the project also gives) is for the project's function to answer.
    nonisolated private static func isFinal(_ result: Result<Reply, EdgeFunctionError>) -> Bool {
        switch result {
        case .success: true
        case .failure(.httpError(let code)): code == 400 || code == 402 || code == 429
        case .failure(.transport): false
        }
    }

    /// One request to one home. It never throws: a failure is its result.
    private func perform(_ call: Call, at base: URL) async -> Result<Reply, EdgeFunctionError> {
        var request = URLRequest(url: base.appendingPathComponent(call.function), timeoutInterval: call.timeout)
        request.httpMethod = "POST"
        for (name, value) in headers.merging(call.extraHeaders, uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let contentType = call.contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(call.token)", forHTTPHeaderField: "Authorization")

        let metrics = TaskMetricsCollector()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: call.payload, delegate: metrics)
        } catch {
            return .failure(.transport(error))
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.transport(URLError(.badServerResponse))) }
        if http.value(forHTTPHeaderField: "x-relay-error") == "true" { return .failure(.transport(FunctionsError.relayError)) }
        guard 200..<300 ~= http.statusCode else { return .failure(.httpError(code: http.statusCode)) }

        var timing = RequestTiming(
            function: call.function, status: http.statusCode, tokenMs: call.tokenMs,
            totalMs: call.started.elapsedMilliseconds,
            // Where the function ran: the project's region, or the dictation server's own name.
            region: http.value(forHTTPHeaderField: "x-sb-edge-region") ?? http.value(forHTTPHeaderField: "x-murmur-host"),
            server: (try? JSONDecoder().decode(Envelope.self, from: data))?.timings)
        if let transaction = metrics.lastTransaction { timing.apply(transaction) }
        return .success(Reply(data: data, timing: timing))
    }
}

/// Keeps the task's metrics, which `URLSession` reports on its own queue before it completes the
/// task, so they are there once the reply is.
private final class TaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    var lastTransaction: URLSessionTaskTransactionMetrics? {
        lock.withLock { metrics?.transactionMetrics.last }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { self.metrics = metrics }
    }
}

/// What `RequestTiming` reads from a transaction. `URLSessionTaskTransactionMetrics` has it all;
/// tests, which can't make one, pass plain values.
protocol TransactionMetrics {
    var isReusedConnection: Bool { get }
    var networkProtocolName: String? { get }
    var connectStartDate: Date? { get }
    var connectEndDate: Date? { get }
    var secureConnectionStartDate: Date? { get }
    var secureConnectionEndDate: Date? { get }
    var requestStartDate: Date? { get }
    var requestEndDate: Date? { get }
    var responseStartDate: Date? { get }
    var countOfRequestBodyBytesSent: Int64 { get }
}

extension URLSessionTaskTransactionMetrics: TransactionMetrics {}

extension RequestTiming {
    /// The connection and the request's phases, from the task's last transaction. A reused
    /// connection cost nothing to open, whatever connect dates it reports.
    mutating func apply(_ transaction: some TransactionMetrics) {
        func milliseconds(from start: Date?, to end: Date?) -> Int? {
            guard let start, let end else { return nil }
            return end.milliseconds(since: start)
        }
        reused = transaction.isReusedConnection
        protocolName = transaction.networkProtocolName
        if !transaction.isReusedConnection {
            connectMs = milliseconds(from: transaction.connectStartDate, to: transaction.connectEndDate)
            tlsMs = milliseconds(from: transaction.secureConnectionStartDate, to: transaction.secureConnectionEndDate)
        }
        uploadMs = milliseconds(from: transaction.requestStartDate, to: transaction.requestEndDate)
        waitMs = milliseconds(from: transaction.requestEndDate, to: transaction.responseStartDate)
        bytesSent = Int(transaction.countOfRequestBodyBytesSent)
    }
}
