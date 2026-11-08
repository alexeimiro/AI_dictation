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

/// Calls our edge functions in place of supabase-swift's `functions.invoke`, for the timings:
/// only a per-task delegate gets `URLSessionTaskMetrics` (reused connection, TLS, upload, wait),
/// and `invoke` can't take one. On the wire it sends what `invoke` sent: a JSON POST to
/// `<project>/functions/v1/<name>` with the client's headers, the session's access token and the
/// same timeout, on `URLSession.shared`, whose connections supabase-swift's auth calls share.
@MainActor
final class EdgeFunctionClient {
    struct Reply: Sendable {
        let data: Data
        let timing: RequestTiming
    }

    private struct Envelope: Decodable {
        let timings: ServerTiming?
    }

    private let functionsURL: URL
    private let headers: [String: String]
    private let session: URLSession
    private let accessToken: @MainActor () async throws -> String

    /// `headers` go out with every request except an Authorization, which carries the token
    /// from `accessToken` instead.
    init(baseURL: URL, headers: [String: String], session: URLSession = .shared,
         accessToken: @escaping @MainActor () async throws -> String) {
        functionsURL = baseURL.appendingPathComponent("/functions/v1")
        self.headers = headers.filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
        self.session = session
        self.accessToken = accessToken
    }

    /// The project's `apikey` and `X-Client-Info`, and the user's session as `invoke` had it. The
    /// client's own Authorization holds the API key, not the user.
    convenience init(backend: Backend) {
        self.init(baseURL: backend.url, headers: backend.client.headers) {
            try await backend.ensureSession()
            return try await backend.client.auth.session.accessToken
        }
    }

    /// POSTs `body` as JSON and returns a 2xx reply undecoded, with its timing.
    func post(_ function: String, body: some Encodable, timeout: TimeInterval) async throws(EdgeFunctionError) -> Reply {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(body)
        } catch {
            throw .transport(error)
        }
        return try await send(function, payload: payload, contentType: "application/json", timeout: timeout)
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
        let tokenMs = started.elapsedMilliseconds
        var request = URLRequest(url: functionsURL.appendingPathComponent(function), timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (name, value) in headers.merging(extraHeaders, uniquingKeysWith: { $1 }) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let metrics = TaskMetricsCollector()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: payload, delegate: metrics)
        } catch {
            throw .transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw .transport(URLError(.badServerResponse)) }
        if http.value(forHTTPHeaderField: "x-relay-error") == "true" { throw .transport(FunctionsError.relayError) }
        guard 200..<300 ~= http.statusCode else { throw .httpError(code: http.statusCode) }

        var timing = RequestTiming(
            function: function, status: http.statusCode, tokenMs: tokenMs,
            totalMs: started.elapsedMilliseconds,
            region: http.value(forHTTPHeaderField: "x-sb-edge-region"),
            server: (try? JSONDecoder().decode(Envelope.self, from: data))?.timings)
        if let transaction = metrics.lastTransaction { timing.apply(transaction) }
        return Reply(data: data, timing: timing)
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
