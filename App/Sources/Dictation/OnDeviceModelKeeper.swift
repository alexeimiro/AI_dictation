import Foundation
import MurmurCore
import os

/// Keeps the on-device models of the languages the user dictates in on the iPhone, in the cloud
/// too. The keyboard's live words come from them, and so does the transcript when the cloud can't
/// be reached; yet a cloud session only ever used a model that was already there, and the
/// released app downloaded one in onboarding alone. This brings the missing ones afterwards, and
/// checks again the ones whose check has run out.
///
/// One language at a time, begun only while nothing is dictated, a download only on Wi-Fi (not on
/// mobile data or a hotspot, nor in Low Data Mode), and after a failure not again for an hour.
/// It knows nothing of Apple's framework: the session hands it the questions to ask
/// (`Environment`), so its rules are tested as they are.
@MainActor
final class OnDeviceModelKeeper {
    enum ModelState: Sendable, Equatable {
        /// No on-device engine knows the language.
        case unsupported
        /// On the iPhone, and checked recently enough.
        case ready
        /// On the iPhone, but never checked here or checked too long ago: nothing to download.
        case unchecked
        /// Not on the iPhone: it has to be downloaded first.
        case missing
    }

    struct Environment {
        /// The tag an on-device engine accepts for a language, or nil when none does.
        var supportedTag: @MainActor (String) async -> String?
        var state: @MainActor (String) async -> ModelState
        /// Downloads the model if need be, checks it and remembers the check.
        var ensure: @MainActor (String) async throws -> ResolvedLanguage
        /// The network is one to download a model on.
        var mayDownload: @MainActor () -> Bool
        /// Nothing is being dictated.
        var isIdle: @MainActor () -> Bool
        var now: @MainActor () -> Date
    }

    /// The most languages kept: the system gives an app only a few reserved ones.
    nonisolated static let limit = 3
    /// After a download or a check failed, the language is left alone for this long.
    nonisolated static let failurePause: TimeInterval = 3_600
    /// A language found in order isn't asked about again for this long: `keep` runs after every dictation.
    nonisolated static let lookPause: TimeInterval = 300

    private let environment: Environment
    private let logger = Logger(subsystem: "Murmur", category: "ASR")
    private var failedAt: [String: Date] = [:]
    private var settledAt: [String: Date] = [:]

    init(environment: Environment) {
        self.environment = environment
    }

    /// The languages to keep, the most wanted first: the primary, the secondary, then the ones
    /// picked in Settings. One per language, never Auto-detect, at most `limit`.
    nonisolated static func wanted(primary: String?, secondary: String?, picked: [String]) -> [String] {
        var tags: [String] = []
        for tag in [primary, secondary].compactMap({ $0 }) + picked {
            let language = DictationLanguage(tag: tag)
            guard !language.isAutomatic,
                  !tags.contains(where: { DictationLanguage(tag: $0).languageCode == language.languageCode })
            else { continue }
            tags.append(tag)
            if tags.count == limit { break }
        }
        return tags
    }

    /// Brings each of `tags` whose model isn't in order, in turn. `ready` hears of every language
    /// as it becomes ready. A language that has to wait (a dictation runs, the network isn't one
    /// to download on) is looked at again at the next call.
    func keep(_ tags: [String], ready: @MainActor (ResolvedLanguage) -> Void) async {
        for requested in tags {
            guard !Task.isCancelled else { return }
            let now = environment.now()
            if let failed = failedAt[requested], now.timeIntervalSince(failed) < Self.failurePause { continue }
            if let settled = settledAt[requested], now.timeIntervalSince(settled) < Self.lookPause { continue }
            guard let tag = await environment.supportedTag(requested) else {
                settledAt[requested] = now
                continue
            }
            switch await environment.state(tag) {
            case .unsupported, .ready:
                settledAt[requested] = now
                continue
            case .missing:
                guard environment.mayDownload() else {
                    logger.info("Speech model for \(tag, privacy: .public): waits for Wi-Fi")
                    continue
                }
            case .unchecked:
                break
            }
            // Begun only in a quiet moment: the check loads the model and runs it.
            guard environment.isIdle(), !Task.isCancelled else { continue }
            do {
                logger.info("Speech model for \(tag, privacy: .public): getting it ready")
                let language = try await environment.ensure(tag)
                settledAt[requested] = environment.now()
                failedAt[requested] = nil
                logger.info("Speech model for \(tag, privacy: .public): ready")
                ready(language)
            } catch is CancellationError {
                return
            } catch {
                failedAt[requested] = environment.now()
                logger.notice("Speech model for \(tag, privacy: .public): failed, \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
