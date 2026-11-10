import Foundation
import MurmurCore
import Testing
@testable import Murmur

@MainActor
private final class FakeStyleRemote: StyleRemote {
    var account: StylePreset? = .verbatim
    var saved: [StylePreset] = []
    var offline = false

    func defaultStyle() async throws -> StylePreset? {
        if offline { throw URLError(.notConnectedToInternet) }
        return account
    }

    func saveDefaultStyle(_ style: StylePreset) async throws {
        if offline { throw URLError(.notConnectedToInternet) }
        saved.append(style)
        account = style
    }
}

/// Holds the read of the account's style until the test lets it answer.
@MainActor
private final class GatedStyleRemote: StyleRemote {
    var account: StylePreset? = .verbatim
    var saved: [StylePreset] = []
    var gate: CheckedContinuation<Void, Never>?

    func defaultStyle() async throws -> StylePreset? {
        await withCheckedContinuation { gate = $0 }
        return account
    }

    func saveDefaultStyle(_ style: StylePreset) async throws {
        saved.append(style)
        account = style
    }
}

/// This iPhone's style, as `SharedSettings` would hold it.
@MainActor
private final class LocalStyle {
    var value: StylePreset
    init(_ value: StylePreset) { self.value = value }
}

@MainActor
struct StyleSyncTests {
    private let remote = FakeStyleRemote()
    private let defaults = UserDefaults(suiteName: "StyleSyncTests.\(UUID().uuidString)")!

    private func makeSync(_ local: LocalStyle, signedIn: Bool = true) -> StyleSync {
        StyleSync(remote: remote, defaults: defaults, local: { local.value }, apply: { local.value = $0 },
                  isEnabled: { signedIn })
    }

    /// A reinstall: signing in during onboarding brings back the account's style.
    @Test func aNewInstallTakesTheAccountsStyle() async {
        remote.account = .grammar
        let local = LocalStyle(.verbatim)
        await makeSync(local).sync(onboardingComplete: false)
        #expect(local.value == .grammar)
        #expect(remote.saved.isEmpty)
    }

    /// An iPhone set up before styles were synced keeps the style chosen on it.
    @Test func anIPhoneAlreadySetUpSendsItsStyleFirst() async {
        remote.account = .verbatim
        let local = LocalStyle(.grammar)
        await makeSync(local).sync(onboardingComplete: true)
        #expect(remote.saved == [.grammar])
        #expect(local.value == .grammar)
    }

    @Test func aChangeMadeHereIsSent() async {
        let local = LocalStyle(.verbatim)
        let sync = makeSync(local)
        await sync.sync(onboardingComplete: true)
        local.value = .grammar // the Style tab or the keyboard's pill
        await sync.sync(onboardingComplete: true)
        #expect(remote.saved == [.verbatim, .grammar])
    }

    @Test func aChangeMadeOnAnotherDeviceArrives() async {
        let local = LocalStyle(.verbatim)
        let sync = makeSync(local)
        await sync.sync(onboardingComplete: true)
        remote.account = .grammar
        await sync.sync(onboardingComplete: true)
        #expect(local.value == .grammar)
        #expect(remote.saved == [.verbatim])
    }

    /// Offline, nothing is taken as agreed: the change is sent once the server answers.
    @Test func aChangeMadeOfflineIsSentLater() async {
        let local = LocalStyle(.verbatim)
        let sync = makeSync(local)
        await sync.sync(onboardingComplete: true)
        local.value = .grammar
        remote.offline = true
        await sync.sync(onboardingComplete: true)
        remote.offline = false
        await sync.sync(onboardingComplete: true)
        #expect(remote.saved == [.verbatim, .grammar])
        #expect(local.value == .grammar)
    }

    /// Picked in the Style tab while the account's style was being read: sent right after.
    @Test func aChangeMadeWhileSyncingIsSentRightAfter() async {
        let gated = GatedStyleRemote()
        let local = LocalStyle(.verbatim)
        let sync = StyleSync(remote: gated, defaults: defaults, local: { local.value }, apply: { local.value = $0 },
                             isEnabled: { true })
        await sync.sync(onboardingComplete: true)
        let running = Task { await sync.sync(onboardingComplete: true) }
        while gated.gate == nil { await Task.yield() }
        local.value = .grammar
        await sync.sync(onboardingComplete: true)
        gated.gate?.resume()
        await running.value
        #expect(gated.saved == [.verbatim, .grammar])
        #expect(local.value == .grammar)
    }

    @Test func nothingIsSentOrTakenWhileSignedOut() async {
        remote.account = .grammar
        let local = LocalStyle(.verbatim)
        await makeSync(local, signedIn: false).sync(onboardingComplete: false)
        #expect(local.value == .verbatim)
        #expect(remote.saved.isEmpty)
    }

    /// After a sign-out, onboarding starts again and the next account's style is taken.
    @Test func resetTakesTheNextAccountsStyle() async {
        let local = LocalStyle(.grammar)
        let sync = makeSync(local)
        await sync.sync(onboardingComplete: true)
        sync.reset()
        remote.account = .verbatim
        await sync.sync(onboardingComplete: false)
        #expect(local.value == .verbatim)
    }
}
