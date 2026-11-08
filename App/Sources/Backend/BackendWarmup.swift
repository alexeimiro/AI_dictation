import Foundation
import MurmurCore
import os

/// The account's session as `BackendWarmup` sees it (`Backend`, or a fake).
@MainActor
protocol SessionRenewing: AnyObject {
    /// `Backend.ensureSession(validFor:)`: a session that expires within `seconds` is refreshed now.
    func ensureSession(validFor seconds: TimeInterval) async throws
}

/// Gets the cloud ready while the user speaks, so the requests at stop wait for nothing but
/// their own work:
/// - The access token is refreshed if it would expire within `tokenLead`. A dictation lasts at
///   most 5 minutes, and in the background, where the hot mic waits, supabase-swift doesn't
///   refresh it on its own.
/// - A translation sends `dictate` a warm-up, which opens the connection and has a worker check
///   the token and open its own connections. Not when `dictate` answered within `debounce`, as
///   that worker is likely still up.
///
/// Plain dictations get the token only, until the timings show `transcribe`'s and `cleanup`'s
/// workers are cold often enough to be worth a ping.
@MainActor
final class BackendWarmup {
    private let session: any SessionRenewing
    private let dictate: (any Dictating)?
    private let tokenLead: TimeInterval
    private let debounce: Duration
    private let logger = Logger(subsystem: "Murmur", category: "Warmup")
    private var running: Task<Void, Never>?
    /// The last warm-up's dictation and request, until `takeTiming`.
    private var answered: (requestId: UUID, timing: RequestTiming)?

    init(session: any SessionRenewing, dictate: (any Dictating)?, tokenLead: TimeInterval = 360,
         debounce: Duration = .seconds(20)) {
        self.session = session
        self.dictate = dictate
        self.tokenLead = tokenLead
        self.debounce = debounce
    }

    /// `translating`: the dictation is translated with cloud transcription, so its request is
    /// `dictate`'s. Ignored while a warm-up is still out: one at a time is enough.
    func dictationDidStart(_ requestId: UUID, translating: Bool) {
        guard running == nil else { return }
        running = Task { [weak self] in
            await self?.warm(requestId, translating: translating)
            self?.running = nil
        }
    }

    /// The warm-up's request when it was `requestId`'s and has answered; once.
    func takeTiming(for requestId: UUID) -> RequestTiming? {
        guard let answered, answered.requestId == requestId else { return nil }
        self.answered = nil
        return answered.timing
    }

    /// Tests: until the warm-up under way, if any, is done.
    func waitUntilIdle() async {
        await running?.value
    }

    private func warm(_ requestId: UUID, translating: Bool) async {
        do {
            try await session.ensureSession(validFor: tokenLead)
        } catch {
            // Signed out, or offline: the dictation's own request finds out the same way.
            logger.notice("Warm-up skipped: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard translating, let dictate, dictate.isAvailable else { return }
        if let last = dictate.lastReplyAt, ContinuousClock.now - last < debounce { return }
        switch await dictate.warm() {
        case .warmed(let timing):
            answered = (requestId, timing)
        case .rejected:
            // The function didn't accept the token: a new one now, not when the dictation's
            // request needs it.
            try? await session.ensureSession(validFor: .infinity)
        case .skipped:
            break
        }
    }
}
