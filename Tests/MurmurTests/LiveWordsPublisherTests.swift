import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
struct LiveWordsPublisherTests {
    private static let interval = Duration.milliseconds(60)

    private let transport = InMemoryIPCTransport()
    private let publisher: LiveWordsPublisher

    init() {
        publisher = LiveWordsPublisher(transport: transport, interval: Self.interval)
    }

    private var file: LivePreview? { transport.payloads.readLivePreview() }
    /// How often the preview was written or removed: each is announced once.
    private var posts: Int { transport.postedEvents.filter { $0 == .livePreview }.count }

    /// Long enough for reported words to have reached the main queue and, had they been taken, the
    /// file: several intervals.
    private func waitForLateWords() async throws {
        try await Task.sleep(for: Self.interval * 4)
    }

    /// One turn of the main queue: words reported before it have been taken by then.
    private func arrived() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Keeps the main thread busy, as a long turn of the app's own work would.
    private nonisolated func holdTheMainThread(milliseconds: UInt32) {
        usleep(milliseconds * 1_000)
    }

    /// `requestId`'s dictation with its preview open, as the session begins one whose transcriber
    /// said words will come.
    private func begin(_ requestId: UUID) -> LiveWordsHandler {
        let handler = publisher.handler(for: requestId)
        publisher.open()
        return handler
    }

    /// The keyboard picks its listening layout from the preview being there, so it is published
    /// before any word: empty, and announced.
    @Test func openingPublishesAnEmptyPreview() {
        let id = UUID()
        _ = publisher.handler(for: id)
        #expect(file == nil && transport.postedEvents.isEmpty)

        publisher.open()

        #expect(file == LivePreview(requestId: id))
        #expect(transport.postedEvents == [.livePreview])
    }

    /// The recognizer's words reach the file as they were reported, and the keyboard is told.
    @Test func wordsAreWrittenAndAnnounced() async {
        let id = UUID()
        let say = begin(id)

        say("see you", " at five")

        let words = LivePreview(requestId: id, settled: "see you", unsettled: " at five")
        #expect(await waitUntil { file == words })
        #expect(transport.postedEvents == [.livePreview, .livePreview])

        say("see you at five", "")
        #expect(await waitUntil { file == LivePreview(requestId: id, settled: "see you at five") })
        #expect(posts == 3)
    }

    /// A recognizer repeats itself between words. The same words are neither written nor announced
    /// a second time.
    @Test func unchangedWordsAreNotWrittenAgain() async throws {
        let id = UUID()
        let say = begin(id)
        say("see you", " at five")
        #expect(await waitUntil { posts == 2 })

        say("see you", " at five")
        try await waitForLateWords()

        #expect(posts == 2)
        #expect(file == LivePreview(requestId: id, settled: "see you", unsettled: " at five"))
    }

    /// Results can come many times a second. The file is written at most once an interval: the
    /// first report at once, and the newest of the rest when the interval is up.
    @Test func aBurstIsWrittenAtMostOnceAnInterval() async {
        let id = UUID()
        let say = begin(id)

        for count in 1...20 { say("", "word \(count)") }

        // All twenty have arrived: the first is in the file, the rest wait for the interval.
        await arrived()
        #expect(file == LivePreview(requestId: id, unsettled: "word 1"))
        #expect(posts == 2)

        let last = LivePreview(requestId: id, unsettled: "word 20")
        #expect(await waitUntil { file == last })
        // The empty preview, the first report, the last one.
        #expect(posts <= 3)
        #expect(file == last)
    }

    /// The dictation ended: its preview is removed and the keyboard told, and words its recognizer
    /// reports afterwards are not written.
    @Test func closingRemovesThePreviewAndDropsLateWords() async throws {
        let id = UUID()
        let say = begin(id)
        say("see you", " at five")
        #expect(await waitUntil { posts == 2 })

        publisher.close()

        #expect(file == nil)
        #expect(!FileManager.default.fileExists(atPath: transport.payloads.container.directory("live").path))
        #expect(posts == 3)
        say("see you at five", " tomorrow")
        try await waitForLateWords()
        #expect(file == nil && posts == 3)

        // Closing again touches nothing and announces nothing.
        publisher.close()
        #expect(posts == 3)
    }

    /// Words that were waiting for the interval when the dictation ended are not written after it.
    @Test func wordsHeldBackWhenTheDictationEndsAreNotWrittenAfterIt() async throws {
        let id = UUID()
        let say = begin(id)
        say("see you", "")
        #expect(await waitUntil { posts == 2 })
        say("see you", " at five")
        // The report has arrived, and waits for the interval.
        try await Task.sleep(for: .milliseconds(10))

        publisher.close()
        #expect(file == nil)
        let closed = posts
        try await waitForLateWords()

        #expect(file == nil && posts == closed)
    }

    /// Nor under the next dictation, when that one begins before the interval is up (a start that
    /// replaces another begins in the same turn).
    @Test func wordsHeldBackAreNotWrittenUnderTheNextDictation() async throws {
        let first = UUID(), second = UUID()
        let say = begin(first)
        say("the first", "")
        await arrived()
        #expect(posts == 2)
        say("the first", " dictation's last words")
        // The report has arrived, and waits for the interval.
        await arrived()

        _ = begin(second)
        try await waitForLateWords()

        #expect(file == LivePreview(requestId: second))
    }

    /// A report that was held back is written when the interval is up. When the main thread was
    /// busy past that moment, the next report is written directly, and the write that was waiting
    /// must not follow it at once with the report after that.
    @Test func aWriteThatWasWaitingDoesNotFollowADirectOne() async throws {
        let transport = InMemoryIPCTransport()
        let publisher = LiveWordsPublisher(transport: transport, interval: .milliseconds(400))
        func posts() -> Int { transport.postedEvents.filter { $0 == .livePreview }.count }
        let id = UUID()
        let say = publisher.handler(for: id)
        publisher.open()
        say("one", "")
        await arrived()
        try #require(posts() == 2)
        say("one", " two")
        // Held back: a write is waiting for the interval.
        await arrived()
        try #require(posts() == 2)
        say("one two", " three")
        say("one two three", " four")
        // Past the interval, with both reports still on their way.
        holdTheMainThread(milliseconds: 450)

        await arrived()
        #expect(posts() == 3)
        #expect(transport.payloads.readLivePreview() == LivePreview(requestId: id, settled: "one two", unsettled: " three"))
        #expect(await waitUntil { transport.payloads.readLivePreview()?.text == "one two three four" })
        #expect(posts() == 4)
    }

    /// A dictation whose transcriber has no words for it is never opened: nothing is written,
    /// nothing is announced, and a keyboard keeps the listening screen it always had.
    @Test func withoutOpenNothingIsWrittenOrPosted() async throws {
        let say = publisher.handler(for: UUID())
        say("words nobody", " asked for")
        try await waitForLateWords()
        #expect(file == nil && transport.postedEvents.isEmpty)

        publisher.close()
        say("words nobody", " asked for")
        try await waitForLateWords()

        #expect(file == nil)
        #expect(transport.postedEvents.isEmpty)
        // Opening needs a dictation to open for.
        publisher.open()
        #expect(file == nil && transport.postedEvents.isEmpty)
    }

    /// The next dictation's begin ends the one before, were it still published. From then on only
    /// the new dictation's handler is heard, also when both are runs of the same request (a route
    /// change starts a dictation again under its id).
    @Test func aNewDictationsHandlerEndsTheOldOne() async throws {
        let first = UUID(), second = UUID()
        let sayFirst = begin(first)
        sayFirst("the first", " dictation")
        #expect(await waitUntil { posts == 2 })

        let saySecond = publisher.handler(for: second)

        #expect(file == nil && posts == 3)
        sayFirst("the first dictation", " goes on")
        try await waitForLateWords()
        #expect(file == nil && posts == 3)

        publisher.open()
        #expect(file == LivePreview(requestId: second))
        sayFirst("the first dictation", " goes on")
        try await waitForLateWords()
        #expect(file == LivePreview(requestId: second))
        saySecond("the second", "")
        #expect(await waitUntil { file == LivePreview(requestId: second, settled: "the second") })

        // The same request, begun again.
        let sayAgain = begin(second)
        #expect(file == LivePreview(requestId: second))
        saySecond("the second", " run before")
        try await waitForLateWords()
        #expect(file == LivePreview(requestId: second))
        sayAgain("", "this run")
        #expect(await waitUntil { file == LivePreview(requestId: second, unsettled: "this run") })
    }

    /// The shared container never holds more than the end of a dictation.
    @Test func onlyTheEndOfALongDictationIsWritten() async throws {
        let id = UUID()
        let say = begin(id)
        let words = (1...600).map { "word\($0 % 10)" }.joined(separator: " ")
        let settled = String(words.prefix(2_700)), unsettled = String(words.dropFirst(2_700).prefix(300))
        #expect((settled + unsettled).count == 3_000)

        say(settled, unsettled)

        #expect(await waitUntil { file?.isEmpty == false })
        let written = try #require(file)
        #expect(written.text.count <= LivePreview.tailLimit)
        #expect((settled + unsettled).hasSuffix(written.text))
        #expect(written == LivePreview.tail(requestId: id, settled: settled, unsettled: unsettled))
        let raw = try Data(contentsOf: transport.payloads.container.directory("live").appendingPathComponent("preview.json"))
        #expect(raw.count < 1_000)
    }

    /// A keyboard that thought the app had stopped answering removes the file. If the app is
    /// still recording, its next changed words are written again.
    @Test func wordsAreWrittenAgainAfterTheFileWasRemovedFromOutside() async throws {
        let id = UUID()
        let say = begin(id)
        say("see you", "")
        #expect(await waitUntil { file == LivePreview(requestId: id, settled: "see you") })

        transport.payloads.clearLivePreview()
        #expect(file == nil)

        say("see you", " at five")
        #expect(await waitUntil { file == LivePreview(requestId: id, settled: "see you", unsettled: " at five") })
    }
}
