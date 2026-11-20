import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The rules by which the released app brings the on-device speech models: which languages, when,
/// on which network, and how often after a failure.
@MainActor
struct OnDeviceModelKeeperTests {
    /// What the keeper asks, answered by the test.
    @MainActor
    private final class World {
        var states: [String: OnDeviceModelKeeper.ModelState] = [:]
        var unsupported: Set<String> = []
        var mayDownload = true
        var isIdle = true
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var fails: Set<String> = []
        private(set) var ensured: [String] = []
        /// How many `ensure` calls ran at the same time, at most.
        private(set) var mostAtOnce = 0
        private var running = 0

        struct DownloadFailed: Error {}

        var environment: OnDeviceModelKeeper.Environment {
            .init(
                supportedTag: { [self] tag in unsupported.contains(tag) ? nil : tag },
                state: { [self] tag in states[tag] ?? .missing },
                ensure: { [self] tag in
                    running += 1
                    mostAtOnce = max(mostAtOnce, running)
                    defer { running -= 1 }
                    ensured.append(tag)
                    await Task.yield()
                    if fails.contains(tag) { throw DownloadFailed() }
                    states[tag] = .ready
                    return ResolvedLanguage(tag: tag, locale: Locale(identifier: tag), engine: .speech)
                },
                mayDownload: { [self] in mayDownload },
                isIdle: { [self] in isIdle },
                now: { [self] in now })
        }
    }

    private func kept(_ keeper: OnDeviceModelKeeper, _ tags: [String]) async -> [String] {
        var ready: [String] = []
        await keeper.keep(tags) { ready.append($0.tag) }
        return ready
    }

    @Test func thePrimaryTheSecondaryAndThePickedLanguagesAreKept() {
        #expect(OnDeviceModelKeeper.wanted(primary: "en-US", secondary: "ru-RU", picked: ["de-DE", "fr-FR"])
            == ["en-US", "ru-RU", "de-DE"])
        // One model per language, and never one for Auto-detect.
        #expect(OnDeviceModelKeeper.wanted(primary: "en-GB", secondary: nil, picked: ["en-US", "ru-RU", "und"])
            == ["en-GB", "ru-RU"])
        #expect(OnDeviceModelKeeper.wanted(primary: nil, secondary: nil, picked: []).isEmpty)
    }

    /// A model that isn't on the iPhone is downloaded, one that is there unchecked is checked, and
    /// the session hears of each as it becomes ready. What is in order is left alone.
    @Test func missingAndUncheckedModelsAreBroughtOneAtATime() async {
        let world = World()
        world.states = ["en-US": .ready, "ru-RU": .unchecked, "de-DE": .missing]
        let keeper = OnDeviceModelKeeper(environment: world.environment)

        #expect(await kept(keeper, ["en-US", "ru-RU", "de-DE"]) == ["ru-RU", "de-DE"])
        #expect(world.ensured == ["ru-RU", "de-DE"])
        #expect(world.mostAtOnce == 1)
    }

    /// A download waits for Wi-Fi; a model that is already there is checked on any network.
    @Test func aDownloadWaitsForWiFi() async {
        let world = World()
        world.states = ["ru-RU": .unchecked, "de-DE": .missing]
        world.mayDownload = false
        let keeper = OnDeviceModelKeeper(environment: world.environment)

        #expect(await kept(keeper, ["ru-RU", "de-DE"]) == ["ru-RU"])
        #expect(world.ensured == ["ru-RU"])

        // On Wi-Fi again, the very next time.
        world.mayDownload = true
        #expect(await kept(keeper, ["ru-RU", "de-DE"]) == ["de-DE"])
    }

    /// Nothing is begun while a dictation runs: the model would load beside it.
    @Test func nothingIsBegunDuringADictation() async {
        let world = World()
        world.states = ["de-DE": .missing]
        world.isIdle = false
        let keeper = OnDeviceModelKeeper(environment: world.environment)

        #expect(await kept(keeper, ["de-DE"]).isEmpty)
        #expect(world.ensured.isEmpty)

        world.isIdle = true
        #expect(await kept(keeper, ["de-DE"]) == ["de-DE"])
    }

    /// After a failure the language is left alone for an hour, then tried again.
    @Test func aFailedLanguageIsLeftAloneForAnHour() async {
        let world = World()
        world.states = ["de-DE": .missing, "ru-RU": .missing]
        world.fails = ["de-DE"]
        let keeper = OnDeviceModelKeeper(environment: world.environment)

        // The failure of one doesn't keep the next from coming.
        #expect(await kept(keeper, ["de-DE", "ru-RU"]) == ["ru-RU"])
        world.fails = []
        world.now += 600
        #expect(await kept(keeper, ["de-DE", "ru-RU"]).isEmpty)
        #expect(world.ensured == ["de-DE", "ru-RU"])

        world.now += OnDeviceModelKeeper.failurePause
        #expect(await kept(keeper, ["de-DE", "ru-RU"]) == ["de-DE"])
    }

    /// A language no engine knows, or one found in order, isn't asked about after every dictation.
    @Test func aSettledLanguageIsNotAskedAboutAgainAtOnce() async {
        let world = World()
        world.states = ["en-US": .ready]
        world.unsupported = ["kk-KZ"]
        let keeper = OnDeviceModelKeeper(environment: world.environment)
        #expect(await kept(keeper, ["en-US", "kk-KZ"]).isEmpty)

        // The system took the model away a minute later: found out at the next look, not before.
        world.states["en-US"] = .missing
        world.now += 60
        #expect(await kept(keeper, ["en-US", "kk-KZ"]).isEmpty)
        world.now += OnDeviceModelKeeper.lookPause
        #expect(await kept(keeper, ["en-US", "kk-KZ"]) == ["en-US"])
    }
}
