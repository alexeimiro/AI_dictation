import Foundation

/// What an edge function measured on its side: the reply's `timings`. A function deployed before
/// timings sends none, and every key is optional.
///
/// Decoding never fails. A value of the wrong type is dropped, so the reply it came in still
/// decodes, and fractional milliseconds (`performance.now()` differences) are rounded.
public struct ServerTiming: Codable, Sendable, Hashable {
    /// `SB_REGION`: where the function ran.
    public var region: String?
    /// The worker's first request.
    public var cold: Bool?
    /// How long the worker had been up.
    public var workerAgeMs: Int?
    /// `SB_EXECUTION_ID`: which worker (isolate) served the request.
    public var executionId: String?
    /// Verifying the caller's token.
    public var authMs: Int?
    /// Reading the body, which includes waiting for the rest of the upload unless the gateway
    /// buffers it.
    public var bodyMs: Int?
    /// The rate-limit and quota RPCs.
    public var preflightMs: Int?
    /// Handler start → OpenAI called: the overhead before the model.
    public var readyMs: Int?
    /// The OpenAI transcription call (`transcribe`).
    public var transcribeMs: Int?
    /// The OpenAI model call (`cleanup`).
    public var modelMs: Int?
    /// Handler start → reply.
    public var totalMs: Int?

    public init(region: String? = nil, cold: Bool? = nil, workerAgeMs: Int? = nil, executionId: String? = nil,
                authMs: Int? = nil, bodyMs: Int? = nil, preflightMs: Int? = nil, readyMs: Int? = nil,
                transcribeMs: Int? = nil, modelMs: Int? = nil, totalMs: Int? = nil) {
        self.region = region
        self.cold = cold
        self.workerAgeMs = workerAgeMs
        self.executionId = executionId
        self.authMs = authMs
        self.bodyMs = bodyMs
        self.preflightMs = preflightMs
        self.readyMs = readyMs
        self.transcribeMs = transcribeMs
        self.modelMs = modelMs
        self.totalMs = totalMs
    }

    private enum CodingKeys: String, CodingKey {
        case region, cold, workerAgeMs, executionId, authMs, bodyMs, preflightMs, readyMs, transcribeMs, modelMs
        case totalMs
    }

    public init(from decoder: any Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        region = try? values.decodeIfPresent(String.self, forKey: .region)
        cold = try? values.decodeIfPresent(Bool.self, forKey: .cold)
        workerAgeMs = Self.milliseconds(values, .workerAgeMs)
        executionId = try? values.decodeIfPresent(String.self, forKey: .executionId)
        authMs = Self.milliseconds(values, .authMs)
        bodyMs = Self.milliseconds(values, .bodyMs)
        preflightMs = Self.milliseconds(values, .preflightMs)
        readyMs = Self.milliseconds(values, .readyMs)
        transcribeMs = Self.milliseconds(values, .transcribeMs)
        modelMs = Self.milliseconds(values, .modelMs)
        totalMs = Self.milliseconds(values, .totalMs)
    }

    private static func milliseconds(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let whole = try? values.decodeIfPresent(Int.self, forKey: key) { return whole }
        guard let value = try? values.decodeIfPresent(Double.self, forKey: key),
              value.isFinite, value.magnitude < 1e12 else { return nil }
        return Int(value.rounded())
    }
}

/// One call to an edge function: what the app saw (`URLSessionTaskMetrics`, the last
/// transaction) and what the function reported (`server`).
public struct RequestTiming: Codable, Sendable, Hashable {
    /// The function's name, e.g. "transcribe".
    public var function: String
    /// The HTTP status.
    public var status: Int?
    /// Getting the access token before the request: near zero unless it had to be refreshed.
    public var tokenMs: Int?
    /// The whole call: the token, the request and the reply.
    public var totalMs: Int
    /// The request went out on a connection that was already open (`isReusedConnection`).
    public var reused: Bool?
    /// "h2", "http/1.1" or "h3".
    public var protocolName: String?
    /// Opening the connection, TLS included; nil when it was reused.
    public var connectMs: Int?
    /// The TLS handshake alone; nil when the connection was reused.
    public var tlsMs: Int?
    /// Sending the request, start → end: mostly the body.
    public var uploadMs: Int?
    /// Request sent → first byte of the reply: the function's time plus a round trip.
    public var waitMs: Int?
    public var bytesSent: Int?
    /// `x-sb-edge-region`: where the function ran.
    public var region: String?
    public var server: ServerTiming?

    public init(function: String, status: Int? = nil, tokenMs: Int? = nil, totalMs: Int, reused: Bool? = nil,
                protocolName: String? = nil, connectMs: Int? = nil, tlsMs: Int? = nil, uploadMs: Int? = nil,
                waitMs: Int? = nil, bytesSent: Int? = nil, region: String? = nil, server: ServerTiming? = nil) {
        self.function = function
        self.status = status
        self.tokenMs = tokenMs
        self.totalMs = totalMs
        self.reused = reused
        self.protocolName = protocolName
        self.connectMs = connectMs
        self.tlsMs = tlsMs
        self.uploadMs = uploadMs
        self.waitMs = waitMs
        self.bytesSent = bytesSent
        self.region = region
        self.server = server
    }
}

/// Where one dictation's time went, from the keyboard's stop to the text being ready, for the
/// app's timings log and the Debug screen. It never holds any text. A nil field wasn't measured.
public struct DictationTimings: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case translation, dictation
    }

    /// The dictation's `requestId`, which also names its claim marker.
    public var requestId: UUID
    /// When the result was written for the keyboard (the result's `createdAt`).
    public var createdAt: Date
    public var kind: Kind
    public var audioSeconds: Double
    /// The keyboard's stop command (`KeyboardCommand.createdAt`). Nil when the app ended the
    /// dictation itself: the time cap, a lost heartbeat, an interruption.
    public var stopRequestedAt: Date?
    /// Stop command → the app ending the dictation.
    public var tapToStopMs: Int?
    /// Compressing the audio after stop.
    public var encodeMs: Int?
    public var audioBytes: Int?
    /// Getting access tokens after stop, over all requests.
    public var tokenMs: Int?
    /// The app's stop → the result (`DictationMetrics.stopToResultMs`), or → the failure when
    /// there was no transcript.
    public var stopToResultMs: Int?
    /// In the order they were made: the one `dictate`, then `cleanup` when the app asked for one;
    /// `transcribe` in place of `dictate` where that couldn't take the audio.
    public var requests: [RequestTiming]
    /// The warm-up sent while the user spoke, when it answered before the result. Its
    /// `server.executionId` against the requests' says whether it warmed the worker they reached.
    public var warmup: RequestTiming?
    public var cleanupModel: String?
    /// The result's `ResultStatus`.
    public var status: String?
    /// The result had text to insert (`DictationResult.isInsertable`). A `limitReached` result
    /// may or may not, and the keyboard claims one without text too, only to dismiss its notice.
    public var insertable: Bool?
    /// The transcript came from the cloud (`transcribe`). False when the on-device transcriber
    /// made it (the fallback after a failed or paused request, or the on-device engine) or there
    /// was none. The latency rows leave those out.
    public var cloudTranscript: Bool?
    /// When the keyboard claimed the result: its claim marker's date, copied in by
    /// `TimingsLog.recordClaims` because the markers are pruned after a day.
    public var claimedAt: Date?
    /// The dictation's `StylePreset`, as stored ("verbatim" for Word for word). Word for word goes
    /// through `dictate` too now, so the requests no longer tell it from the styles the model
    /// writes. Nil in entries from builds before that.
    public var style: String?

    public init(requestId: UUID, createdAt: Date, kind: Kind, audioSeconds: Double, stopRequestedAt: Date? = nil,
                tapToStopMs: Int? = nil, encodeMs: Int? = nil, audioBytes: Int? = nil, tokenMs: Int? = nil,
                stopToResultMs: Int? = nil, requests: [RequestTiming] = [], warmup: RequestTiming? = nil,
                cleanupModel: String? = nil, status: String? = nil, insertable: Bool? = nil,
                cloudTranscript: Bool? = nil, claimedAt: Date? = nil, style: String? = nil) {
        self.requestId = requestId
        self.createdAt = createdAt
        self.kind = kind
        self.audioSeconds = audioSeconds
        self.stopRequestedAt = stopRequestedAt
        self.tapToStopMs = tapToStopMs
        self.encodeMs = encodeMs
        self.audioBytes = audioBytes
        self.tokenMs = tokenMs
        self.stopToResultMs = stopToResultMs
        self.requests = requests
        self.warmup = warmup
        self.cleanupModel = cleanupModel
        self.status = status
        self.insertable = insertable
        self.cloudTranscript = cloudTranscript
        self.claimedAt = claimedAt
        self.style = style
    }

    /// The sum of the values that were measured; nil when none was.
    public static func sum(_ values: [Int?]) -> Int? {
        let measured = values.compactMap { $0 }
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }
}

/// The Debug screen's latency rows for one kind of dictation: medians and 95th percentiles
/// (`MetricsSummary`) and the connection and worker shares. A phase that ran in several requests
/// (a translation calls `transcribe`, then `cleanup`) counts once per dictation, as their sum.
public struct TimingsSummary: Sendable, Hashable {
    /// `count` out of `total`.
    public struct Share: Sendable, Hashable {
        public let count: Int
        public let total: Int

        public init(count: Int, total: Int) {
            self.count = count
            self.total = total
        }

        public var fraction: Double? {
            total > 0 ? Double(count) / Double(total) : nil
        }
    }

    /// Dictations of this kind with a cloud transcript: the ones the rows summarize.
    public var count: Int
    /// Of this kind's dictations, those with a cloud transcript. The others (the on-device
    /// fallback, a failure) would mix other paths into the cloud's numbers.
    public var cloudTranscripts: Share
    public var stopToResult: MetricsSummary
    public var tapToStop: MetricsSummary
    public var encode: MetricsSummary
    public var token: MetricsSummary
    public var upload: MetricsSummary
    public var wait: MetricsSummary
    public var serverAuth: MetricsSummary
    public var serverPreflight: MetricsSummary
    public var serverTranscribe: MetricsSummary
    public var serverModel: MetricsSummary
    /// The result written → the keyboard's claim marker.
    public var resultToInsert: MetricsSummary
    /// The stop command → the claim marker: everything the user waits for.
    public var tapToInsert: MetricsSummary
    /// Requests sent on a connection that was already open.
    public var reused: Share
    /// Requests that were their worker's first.
    public var cold: Share
    /// Dictations with a warm-up whose worker is known, and of those, the ones whose request
    /// reached that worker: a warm-up that lands elsewhere warms nothing the dictation uses.
    public var warmedWorker: Share
    /// Requests per region: the reply's `x-sb-edge-region`, else the function's `SB_REGION`.
    public var regions: [String: Int]

    /// A claim later than this after the result is someone tapping "Insert last dictation", not
    /// the automatic insert.
    public static let automaticInsertLimitMs = 10_000

    /// Both insert rows count the automatic inserts only (`claimedAt`), however long the
    /// dictation took: a result with text, claimed within `automaticInsertLimitMs` of being
    /// written. An earlier claim is the keyboard's X while it waited, and it claims a result
    /// without text just to dismiss its notice. An entry from before `cloudTranscript` counts as
    /// a cloud one.
    public static func summarize(_ entries: [DictationTimings], kind: DictationTimings.Kind) -> TimingsSummary {
        let all = entries.filter { $0.kind == kind }
        let entries = all.filter { $0.cloudTranscript != false }
        let requests = entries.flatMap(\.requests)
        func perDictation(_ value: (RequestTiming) -> Int?) -> MetricsSummary {
            MetricsSummary.summarize(entries.compactMap { DictationTimings.sum($0.requests.map(value)) })
        }
        let inserts = entries.compactMap { entry -> (entry: DictationTimings, claimed: Date)? in
            guard entry.insertable == true, let claimed = entry.claimedAt,
                  (0...automaticInsertLimitMs).contains(claimed.milliseconds(since: entry.createdAt)) else { return nil }
            return (entry, claimed)
        }
        let warmed = entries.compactMap { entry -> Bool? in
            guard let worker = entry.warmup?.server?.executionId else { return nil }
            let reached = entry.requests.compactMap(\.server?.executionId)
            return reached.isEmpty ? nil : reached.contains(worker)
        }
        let reported = requests.compactMap(\.reused)
        let cold = requests.compactMap(\.server?.cold)
        var regions: [String: Int] = [:]
        for region in requests.compactMap({ $0.region ?? $0.server?.region }) { regions[region, default: 0] += 1 }
        return TimingsSummary(
            count: entries.count,
            cloudTranscripts: Share(count: entries.count, total: all.count),
            stopToResult: MetricsSummary.summarize(entries.compactMap(\.stopToResultMs)),
            tapToStop: MetricsSummary.summarize(entries.compactMap(\.tapToStopMs)),
            encode: MetricsSummary.summarize(entries.compactMap(\.encodeMs)),
            token: MetricsSummary.summarize(entries.compactMap(\.tokenMs)),
            upload: perDictation(\.uploadMs),
            wait: perDictation(\.waitMs),
            serverAuth: perDictation { $0.server?.authMs },
            serverPreflight: perDictation { $0.server?.preflightMs },
            serverTranscribe: perDictation { $0.server?.transcribeMs },
            serverModel: perDictation { $0.server?.modelMs },
            resultToInsert: MetricsSummary.summarize(inserts.map { $0.claimed.milliseconds(since: $0.entry.createdAt) }),
            tapToInsert: MetricsSummary.summarize(inserts.compactMap { insert in
                insert.entry.stopRequestedAt.map { insert.claimed.milliseconds(since: $0) }
            }),
            reused: Share(count: reported.filter { $0 }.count, total: reported.count),
            cold: Share(count: cold.filter { $0 }.count, total: cold.count),
            warmedWorker: Share(count: warmed.filter { $0 }.count, total: warmed.count),
            regions: regions)
    }
}

extension ContinuousClock.Instant {
    /// Whole milliseconds from this instant to now, rounded down.
    public var elapsedMilliseconds: Int {
        let elapsed = ContinuousClock.now - self
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

extension Date {
    /// Milliseconds from `start` to this date, to the nearest one: a `Date` difference is a
    /// `Double`, so 0.3 s may come out a hair short of 300 ms.
    public func milliseconds(since start: Date) -> Int {
        Int((timeIntervalSince(start) * 1000).rounded())
    }
}
