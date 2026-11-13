import Foundation
import Testing
@testable import MurmurCore

/// Whole milliseconds, so dates survive the timings log's millisecond encoding exactly.
private let stop = Date(timeIntervalSince1970: 1_762_600_000.25)

/// `claimedAfter`: seconds from the result to the keyboard's claim.
private func entry(_ kind: DictationTimings.Kind, status: String = "cleaned", insertable: Bool = true,
                   stopToResultMs: Int? = 2_000, requests: [RequestTiming] = [], cloudTranscript: Bool? = nil,
                   claimedAfter: TimeInterval? = nil) -> DictationTimings {
    let createdAt = stop.addingTimeInterval(2)
    return DictationTimings(requestId: UUID(), createdAt: createdAt, kind: kind, audioSeconds: 6,
                            stopRequestedAt: stop, tapToStopMs: 20, stopToResultMs: stopToResultMs,
                            requests: requests, status: status, insertable: insertable,
                            cloudTranscript: cloudTranscript,
                            claimedAt: claimedAfter.map { createdAt.addingTimeInterval($0) })
}

private func request(_ function: String, uploadMs: Int? = nil, reused: Bool? = nil, region: String? = nil,
                     server: ServerTiming? = nil) -> RequestTiming {
    RequestTiming(function: function, status: 200, totalMs: 900, reused: reused, uploadMs: uploadMs, region: region,
                  server: server)
}

private func coder() -> (JSONEncoder, JSONDecoder) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return (encoder, decoder)
}

struct DictationTimingsCodingTests {
    @Test func roundTripsEveryField() throws {
        let server = ServerTiming(region: "eu-central-1", cold: true, workerAgeMs: 41_210, executionId: "e1",
                                  authMs: 2, bodyMs: 30, preflightMs: 12, readyMs: 33, transcribeMs: 640,
                                  modelMs: 690, totalMs: 1_395)
        let timings = DictationTimings(
            requestId: UUID(), createdAt: stop.addingTimeInterval(2.5), kind: .translation, audioSeconds: 6.4,
            stopRequestedAt: stop, tapToStopMs: 18, encodeMs: 40, audioBytes: 25_600, tokenMs: 3,
            stopToResultMs: 2_480,
            requests: [RequestTiming(function: "transcribe", status: 200, tokenMs: 3, totalMs: 1_500, reused: false,
                                     protocolName: "h2", connectMs: 250, tlsMs: 170, uploadMs: 60, waitMs: 1_150,
                                     bytesSent: 34_000, region: "eu-central-1", server: server)],
            warmup: RequestTiming(function: "dictate", status: 200, tokenMs: 0, totalMs: 480, reused: true,
                                  server: ServerTiming(cold: true, executionId: "e1", authMs: 40, totalMs: 300)),
            cleanupModel: "gpt-6.1-terra", status: "cleaned", insertable: true, cloudTranscript: true,
            claimedAt: stop.addingTimeInterval(2.8), style: "concise")
        let (encoder, decoder) = coder()
        let decoded = try decoder.decode(DictationTimings.self, from: encoder.encode(timings))
        #expect(decoded == timings)
        #expect(decoded.style == "concise")
    }

    @Test func olderJSONWithoutTheNewKeysStillDecodes() throws {
        let json = #"""
        {"requestId":"6F1C3A52-7E1B-4C1D-9C0B-2B9E1A1D0F11","createdAt":1762600002250,"kind":"dictation",
         "audioSeconds":3.5,"requests":[{"function":"transcribe","totalMs":800}]}
        """#
        let timings = try coder().1.decode(DictationTimings.self, from: Data(json.utf8))
        #expect(timings.kind == .dictation)
        #expect(timings.createdAt == stop.addingTimeInterval(2))
        #expect(timings.stopRequestedAt == nil && timings.tapToStopMs == nil && timings.encodeMs == nil)
        #expect(timings.status == nil && timings.cleanupModel == nil && timings.insertable == nil)
        #expect(timings.cloudTranscript == nil && timings.claimedAt == nil && timings.style == nil)
        #expect(timings.requests == [RequestTiming(function: "transcribe", totalMs: 800)])
    }

    /// The function measures with `performance.now()`, so its milliseconds can be fractional, and
    /// a bad value must never fail the reply it came in.
    @Test func serverTimingsRoundFractionsAndDropBadValues() throws {
        let json = #"{"authMs":12.6,"cold":"yes","region":"eu-central-1","totalMs":700,"workerAgeMs":null,"modelMs":"x"}"#
        let server = try JSONDecoder().decode(ServerTiming.self, from: Data(json.utf8))
        #expect(server == ServerTiming(region: "eu-central-1", authMs: 13, totalMs: 700))

        struct Reply: Decodable { let text: String; let timings: ServerTiming? }
        let malformed = try JSONDecoder().decode(Reply.self, from: Data(#"{"text":"Hi.","timings":"soon"}"#.utf8))
        #expect(malformed.text == "Hi.")
        #expect(malformed.timings == ServerTiming())
        let older = try JSONDecoder().decode(Reply.self, from: Data(#"{"text":"Hi."}"#.utf8))
        #expect(older.timings == nil)
    }
}

struct TimingsSummaryTests {
    @Test func phasesAddUpOverADictationsRequests() {
        let translations = [100, 200, 300].map { upload in
            entry(.translation, requests: [
                request("transcribe", uploadMs: upload, server: ServerTiming(authMs: 10, transcribeMs: 600)),
                request("cleanup", uploadMs: 5, server: ServerTiming(authMs: 20, modelMs: 700)),
            ])
        }
        let dictation = entry(.dictation, stopToResultMs: 9_000, requests: [request("transcribe", uploadMs: 999)])
        let summary = TimingsSummary.summarize(translations + [dictation], kind: .translation)

        #expect(summary.count == 3)
        #expect(summary.upload == MetricsSummary(count: 3, median: 205, p95: 305))
        #expect(summary.serverAuth.median == 30)
        #expect(summary.serverTranscribe.median == 600)
        #expect(summary.serverModel.median == 700)
        #expect(summary.stopToResult == MetricsSummary(count: 3, median: 2_000, p95: 2_000))
        #expect(summary.tapToStop.median == 20)
        // Not measured at all: no samples rather than zeros.
        #expect(summary.wait.count == 0 && summary.wait.median == nil)
        #expect(summary.serverPreflight.count == 0)
    }

    @Test func sharesCountOnlyRequestsThatReportedThem() {
        let entries = [
            entry(.dictation, requests: [
                request("transcribe", reused: true, region: "eu-central-1", server: ServerTiming(cold: false)),
                request("cleanup", reused: false, server: ServerTiming(region: "eu-central-1", cold: true)),
            ]),
            entry(.dictation, requests: [
                request("transcribe", reused: true, region: "us-east-1"),
                request("cleanup"),
            ]),
        ]
        let summary = TimingsSummary.summarize(entries, kind: .dictation)
        #expect(summary.reused == .init(count: 2, total: 3))
        #expect(summary.cold == .init(count: 1, total: 2))
        #expect(summary.cold.fraction == 0.5)
        #expect(summary.regions == ["eu-central-1": 2, "us-east-1": 1])
        #expect(TimingsSummary.summarize(entries, kind: .translation).reused.fraction == nil)
    }

    /// Only a warm-up and a request that both name their worker say whether it was the same one.
    @Test func warmedWorkerComparesTheWarmUpsWorkerWithTheRequests() {
        func translation(warmedOn warmed: String?, reached: String?) -> DictationTimings {
            var timings = entry(.translation, requests: [request("dictate", server: ServerTiming(executionId: reached))])
            timings.warmup = RequestTiming(function: "dictate", totalMs: 400, server: ServerTiming(executionId: warmed))
            return timings
        }
        let entries = [
            translation(warmedOn: "w1", reached: "w1"),
            translation(warmedOn: "w2", reached: "w3"),
            translation(warmedOn: nil, reached: "w4"),
            translation(warmedOn: "w5", reached: nil),
            entry(.translation, requests: [request("dictate", server: ServerTiming(executionId: "w6"))]),
        ]
        let summary = TimingsSummary.summarize(entries, kind: .translation)
        #expect(summary.warmedWorker == .init(count: 1, total: 2))
    }

    /// Late claims are "Insert last dictation" taps, even one soon after the stop, and a failed
    /// result is claimed only to dismiss its notice: none of them is the automatic insert.
    @Test func insertTimesCountOnlyPromptInsertsOfText() {
        let quick = entry(.dictation, claimedAfter: 0.3)
        let manual = entry(.dictation, claimedAfter: 40)
        // 13 s after the tap, but 11 s after the result.
        let soonManual = entry(.dictation, claimedAfter: 11)
        let failed = entry(.dictation, status: "failed", insertable: false, claimedAfter: 0.1)
        let unclaimed = entry(.dictation)
        let summary = TimingsSummary.summarize([quick, manual, soonManual, failed, unclaimed], kind: .dictation)
        #expect(summary.resultToInsert == MetricsSummary(count: 1, median: 300, p95: 300))
        // From the stop command: 2 s to the result, then 0.3 s.
        #expect(summary.tapToInsert == MetricsSummary(count: 1, median: 2_300, p95: 2_300))
    }

    /// X while the keyboard waits claims the request before the result is written. The app still
    /// finishes the dictation, but nothing was inserted.
    @Test func aClaimFromBeforeTheResultIsNoInsert() {
        let cancelled = entry(.dictation, claimedAfter: -0.5)
        let summary = TimingsSummary.summarize([cancelled], kind: .dictation)
        #expect(summary.resultToInsert.count == 0)
        #expect(summary.tapToInsert.count == 0)
    }

    /// The slowest dictations are the point of the p95: an automatic insert counts from the tap
    /// however long the result took.
    @Test func aSlowAutomaticInsertStillCountsFromTheTap() {
        var slow = entry(.translation, stopToResultMs: 18_000)
        slow.createdAt = stop.addingTimeInterval(18)
        slow.claimedAt = slow.createdAt.addingTimeInterval(0.2)
        let summary = TimingsSummary.summarize([slow], kind: .translation)
        #expect(summary.resultToInsert == MetricsSummary(count: 1, median: 200, p95: 200))
        #expect(summary.tapToInsert == MetricsSummary(count: 1, median: 18_200, p95: 18_200))
    }

    /// The free plan's limit keeps a dictation's local text, which the keyboard inserts, but a
    /// transcription or translation it stopped has none: that claim only dismisses the notice.
    @Test func aLimitReachedResultIsAnInsertOnlyWithText() {
        let kept = entry(.dictation, status: "limitReached", claimedAfter: 0.3)
        let stopped = entry(.dictation, status: "limitReached", insertable: false, claimedAfter: 0.1)
        let summary = TimingsSummary.summarize([kept, stopped], kind: .dictation)
        #expect(summary.resultToInsert == MetricsSummary(count: 1, median: 300, p95: 300))
        #expect(summary.tapToInsert == MetricsSummary(count: 1, median: 2_300, p95: 2_300))
    }

    /// An on-device transcript (the fallback after a failed request, or during the cloud pause)
    /// and a failure took other paths: they count in the share, not in the rows.
    @Test func theRowsCountOnlyCloudTranscripts() {
        let entries = [
            entry(.translation, stopToResultMs: 2_000, requests: [request("transcribe", uploadMs: 50)],
                  cloudTranscript: true, claimedAfter: 0.3),
            entry(.translation, stopToResultMs: 26_000, cloudTranscript: false, claimedAfter: 0.3),
            entry(.translation, status: "failed", insertable: false, stopToResultMs: 25_000, cloudTranscript: false),
            // Logged before the field existed.
            entry(.translation, stopToResultMs: 3_000),
        ]
        let summary = TimingsSummary.summarize(entries, kind: .translation)
        #expect(summary.count == 2)
        #expect(summary.cloudTranscripts == .init(count: 2, total: 4))
        #expect(summary.stopToResult == MetricsSummary(count: 2, median: 2_000, p95: 3_000))
        #expect(summary.upload.count == 1)
        #expect(summary.resultToInsert.count == 1)
    }
}

struct MillisecondsTests {
    /// A `Date` difference is a `Double` and rounds to the nearest millisecond; a clock instant
    /// counts whole milliseconds, as the pipeline always has.
    @Test func datesRoundAndInstantsRoundDown() {
        #expect(stop.addingTimeInterval(0.3).milliseconds(since: stop) == 300)
        #expect(stop.addingTimeInterval(0.0004).milliseconds(since: stop) == 0)
        #expect(stop.milliseconds(since: stop.addingTimeInterval(1.5)) == -1_500)
        let elapsed = ContinuousClock.now.advanced(by: .milliseconds(-1_500)).elapsedMilliseconds
        #expect((1_500..<2_500).contains(elapsed))
    }
}
