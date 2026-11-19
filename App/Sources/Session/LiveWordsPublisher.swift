import Foundation
import MurmurCore

/// Shows the keyboard the words of the dictation being recorded (`LivePreview`): at most four times
/// a second, only when they changed, and only their end. The file is removed when the dictation
/// ends, however the app ends it. A crash or a kill for memory mid-dictation gives the app no
/// chance to: a keyboard following that dictation removes the file when it stops following it
/// (`KeyboardSessionClient`), and otherwise `SessionController.init` does when the app next starts.
///
/// For one dictation: `handler(for:)` → the transcriber's `beginUtterance(liveWords:)` → `open()`
/// if it said words will come, otherwise `close()` → … → `close()`.
@MainActor
final class LiveWordsPublisher {
    private let transport: IPCTransport
    private let interval: Duration
    /// Moves on with every `handler(for:)` and `close()`: words reported for a dictation that has
    /// ended, or for an earlier run of the same request, are dropped.
    private var epoch: UInt64 = 0
    /// The dictation `handler(for:)` was last asked for, until `open()` or `close()`.
    private var armed: UUID?
    /// The dictation whose preview is published.
    private var published: UUID?
    private var latest: (settled: String, unsettled: String)?
    private var written: LivePreview?
    private var lastWrite: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?

    init(transport: IPCTransport, interval: Duration = .milliseconds(250)) {
        self.transport = transport
        self.interval = interval
    }

    /// The handler to begin `requestId` with. Ends whatever was published before. Nothing is
    /// written until `open()`.
    func handler(for requestId: UUID) -> LiveWordsHandler {
        close()
        armed = requestId
        let epoch = epoch
        return { [weak self] settled, unsettled in
            // The main queue keeps the reports in order.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.receive(settled: settled, unsettled: unsettled, epoch: epoch) }
            }
        }
    }

    /// Words will come for the dictation `handler(for:)` was made for: publishes its preview, empty,
    /// so the keyboard lays the listening screen out for words before the first one.
    func open() {
        guard let requestId = armed else { return }
        armed = nil
        let empty = LivePreview(requestId: requestId)
        do { try transport.payloads.write(livePreview: empty) } catch { return }
        published = requestId
        written = empty
        transport.post(.livePreview)
    }

    /// The dictation ended, or has no live words: later reports are dropped and the preview is
    /// removed. Without a published preview nothing is touched and nothing is posted.
    func close() {
        epoch &+= 1
        armed = nil
        latest = nil
        written = nil
        lastWrite = nil
        trailing?.cancel()
        trailing = nil
        guard published != nil else { return }
        published = nil
        transport.payloads.clearLivePreview()
        transport.post(.livePreview)
    }

    private func receive(settled: String, unsettled: String, epoch: UInt64) {
        guard epoch == self.epoch, published != nil else { return }
        latest = (settled, unsettled)
        let now = ContinuousClock.now
        guard let lastWrite, now - lastWrite < interval else {
            // This is the write a held-back report was waiting for: it must not follow at once.
            trailing?.cancel()
            trailing = nil
            return flush()
        }
        guard trailing == nil else { return }
        let wait = interval - (now - lastWrite)
        trailing = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.trailing = nil
            self.flush()
        }
    }

    private func flush() {
        guard let requestId = published, let latest else { return }
        let preview = LivePreview.tail(requestId: requestId, settled: latest.settled, unsettled: latest.unsettled)
        guard preview != written else { return }
        do { try transport.payloads.write(livePreview: preview) } catch { return }
        written = preview
        lastWrite = .now
        transport.post(.livePreview)
    }
}
