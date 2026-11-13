import Foundation

/// Answers the requests to one host with a canned reply and keeps what was sent. Each test uses
/// its own host, so the tests can run in parallel.
final class StubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body = Data(#"{"text":"Hello."}"#.utf8)
        var failure: URLError?
        /// Never answers: the request stays out until it is cancelled or times out.
        var hangs = false
    }

    struct Sent: Sendable {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var sent: [String: [Sent]] = [:]

    static func answer(_ host: String, with reply: Reply) {
        lock.withLock { replies[host] = reply }
    }

    static func sent(to host: String) -> [Sent] {
        lock.withLock { sent[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        // An upload task hands its body over as a stream.
        let body = request.httpBodyStream.map(Self.read) ?? request.httpBody ?? Data()
        let reply = Self.lock.withLock { () -> Reply in
            Self.sent[host, default: []].append(Sent(request: request, body: body))
            return Self.replies[host] ?? Reply()
        }
        if reply.hangs { return }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension StubURLProtocol {
    /// A session whose requests all go to the stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
