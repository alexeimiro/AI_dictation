import Foundation
import MurmurCore
import os

/// Keeps the default style (Word for word or Improve my grammar) the same on every device signed in
/// to the account, as `profiles.default_style`.
///
/// A style changed on this iPhone since the last sync is sent; otherwise the account's is taken, so
/// a change made on another device arrives here. The first sync of an iPhone that's already set up
/// keeps its own style, while a new install that signs in during onboarding takes the account's:
/// that's what brings the style back after a reinstall.
@MainActor
final class StyleSync {
    /// The style this iPhone and the account last agreed on.
    static let syncedKey = "styleSync.synced"

    private let remote: any StyleRemote
    private let defaults: UserDefaults
    private let local: () -> StylePreset
    private let apply: (StylePreset) -> Void
    /// Sync runs only for a signed-in account.
    private let isEnabled: () -> Bool
    private var isSyncing = false
    /// Asked for while one was running: the running one goes again, so a change isn't left waiting.
    private var syncAgain = false
    private let logger = Logger(subsystem: "Murmur", category: "Sync")

    /// `local` and `apply` read and change this iPhone's style; `defaults`: tests pass a suite.
    init(remote: any StyleRemote, defaults: UserDefaults = .standard, local: @escaping () -> StylePreset,
         apply: @escaping (StylePreset) -> Void, isEnabled: @escaping () -> Bool) {
        self.remote = remote
        self.defaults = defaults
        self.local = local
        self.apply = apply
        self.isEnabled = isEnabled
    }

    /// `onboardingComplete`: false while a new install is still being set up.
    func sync(onboardingComplete: Bool) async {
        guard isEnabled() else { return }
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            await syncOnce(onboardingComplete: onboardingComplete)
        } while syncAgain
    }

    private func syncOnce(onboardingComplete: Bool) async {
        let style = local()
        let synced = defaults.string(forKey: Self.syncedKey).map(StylePreset.init(stored:))
        let changedHere = synced.map { $0 != style } ?? onboardingComplete
        do {
            if changedHere {
                try await remote.saveDefaultStyle(style)
                defaults.set(style.rawValue, forKey: Self.syncedKey)
            } else if let account = try await remote.defaultStyle() {
                // Changed here while the account's was read: that change is sent next time.
                if local() == style, account != style { apply(account) }
                defaults.set(account.rawValue, forKey: Self.syncedKey)
            }
        } catch {
            logger.error("Style sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Signing out or deleting the account: the next account's style is taken afresh.
    func reset() {
        defaults.removeObject(forKey: Self.syncedKey)
    }
}

/// The account's style, as `StyleSync` sees it (`AccountService`, or a fake in tests).
@MainActor
protocol StyleRemote: AnyObject {
    /// The account's default style; nil without a signed-in session.
    func defaultStyle() async throws -> StylePreset?
    func saveDefaultStyle(_ style: StylePreset) async throws
}
