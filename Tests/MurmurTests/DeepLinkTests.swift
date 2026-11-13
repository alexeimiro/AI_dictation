import Foundation
import MurmurCore
import Testing
@testable import Murmur

struct DeepLinkTests {
    @Test func parsesSessionStartWithToken() {
        let url = URL(string: "murmur://session/start?t=abc123")!
        #expect(DeepLink(url: url) == .startSession(token: "abc123"))
    }

    @Test func parsesSettings() {
        #expect(DeepLink(url: URL(string: "murmur://settings")!) == .openSettings)
        #expect(DeepLink(url: URL(string: "murmur://settings/")!) == .openSettings)
    }

    /// The keyboard's limit message opens Murmur Pro's page.
    @Test func parsesPro() {
        #expect(DeepLink(url: Brand.proURL) == .pro)
        #expect(DeepLink(url: URL(string: "murmur://pro/")!) == .pro)
        #expect(LaunchRoute(rawValue: "paywall") == .paywall)
    }

    /// The keyboard's "You are logged out" page opens Murmur's sign-in.
    @Test func parsesSignIn() {
        #expect(DeepLink(url: Brand.signInURL) == .signIn)
        #expect(DeepLink(url: URL(string: "murmur://sign-in/")!) == .signIn)
        #expect(DeepLink(url: URL(string: "murmur://sign-in/later")!) == nil)
        #expect(LaunchOptions(arguments: ["Murmur", "-keyboard-demo", "loggedOut"]).keyboardDemo
                == KeyboardDemo(state: .loggedOut))
    }

    @Test func ignoresOtherSchemesAndPaths() {
        #expect(DeepLink(url: URL(string: "https://session/start?t=x")!) == nil)
        #expect(DeepLink(url: URL(string: "murmur://session/stop")!) == nil)
    }

    @Test func parsesLaunchRoutes() {
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "languages"]) == .languages)
        #expect(LaunchRoute(arguments: ["Murmur"]) == nil)
        for name in ["home", "settings", "languages", "debug", "transcript", "dictionary", "snippets",
                     "style", "scratchpad", "menu", "account", "paywall", "referral", "note"] {
            #expect(LaunchRoute(arguments: ["Murmur", "-route", name])?.rawValue == name)
        }
        // What two screens are called now; their old names above still open them.
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "notes"]) == .scratchpad)
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "invite"]) == .referral)
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "nope"]) == nil)
        // The "Murmur is on" page is gone, and its route with it.
        #expect(LaunchRoute(arguments: ["Murmur", "-route", "swipeBack"]) == nil)
    }

    /// Screenshot runs and UI tests put the line that says how to swipe back under Home's session
    /// bar (DEBUG builds only).
    @Test func parsesTheReturnHint() {
        #expect(LaunchOptions(arguments: ["Murmur", "-return-hint", "Safari"]).returnHint
                == ReturnHint(appName: "Safari"))
        #expect(LaunchOptions(arguments: ["Murmur", "-return-hint"]).returnHint == ReturnHint(appName: nil))
        #expect(LaunchOptions(arguments: ["Murmur", "-return-hint", "-fixtures"]).returnHint
                == ReturnHint(appName: nil))
        #expect(LaunchOptions(arguments: ["Murmur"]).returnHint == nil)
    }

    /// The keyboard's link came from another app unless Murmur was already on screen at the tap.
    @Test func aLinkFromMurmursOwnFieldsIsToldApart() {
        let tap = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppModel.cameFromAnotherApp(activeSince: nil, tappedAt: tap), "still coming to the front")
        #expect(AppModel.cameFromAnotherApp(activeSince: tap.addingTimeInterval(0.4), tappedAt: tap),
                "the link brought Murmur to the front")
        #expect(AppModel.cameFromAnotherApp(activeSince: tap.addingTimeInterval(2.5), tappedAt: tap),
                "a slow launch")
        #expect(!AppModel.cameFromAnotherApp(activeSince: tap.addingTimeInterval(-0.5), tappedAt: tap),
                "on screen just before the tap")
        #expect(!AppModel.cameFromAnotherApp(activeSince: tap.addingTimeInterval(-600), tappedAt: tap))
    }

    /// Someone left to swipe back by hand may take longer than the 10 s the session keeps their
    /// recording. The dictation then starts again, for 45 s after Home said how to swipe back, and
    /// only once the Murmur keyboard is back and UIKit says a keyboard is showing in the app Home
    /// named. Opened anywhere else, nothing listens.
    @Test func aDictationOwedAfterALateSwipeStartsOnlyInTheAppHomeNamed() {
        let armed = Date(timeIntervalSince1970: 1_800_000_000)
        let safari = "com.apple.mobilesafari"
        let notes = "com.apple.mobilenotes"
        func owed(back: Bool = true, report: String? = safari, onScreen: Bool? = true) -> AppModel.OwedDictation {
            var owed = AppModel.OwedDictation(linkAt: armed.addingTimeInterval(-1), armedAt: armed, host: safari,
                                              generation: 3)
            if back { owed.keyboardBackAt = armed.addingTimeInterval(16) }
            owed.awayReport = report.map {
                KeyboardHostLog.Report(bundleID: $0, seenAt: armed.addingTimeInterval(16), onScreen: onScreen)
            }
            return owed
        }
        func step(_ owed: AppModel.OwedDictation, after seconds: TimeInterval = 17,
                  phase: SessionController.Phase = .ready, generation: Int = 3,
                  murmurActive: Bool = false) -> AppModel.OwedDictationStep {
            AppModel.owedDictationStep(owed, now: armed.addingTimeInterval(seconds), phase: phase,
                                       generation: generation, murmurActive: murmurActive)
        }
        #expect(AppModel.owedDictationWindow == 45)
        #expect(step(owed()) == .start, "the recording was dropped at 10 s; the swipe back to Safari came at 17 s")
        #expect(step(owed(), after: 45) == .start)
        #expect(step(owed(report: "COM.APPLE.MOBILESAFARI")) == .start)
        #expect(step(owed(onScreen: nil)) == .start, "UIKit didn't say, but named Safari")

        // The review's case: Home said Safari, and the user opened Notes instead.
        #expect(step(owed(report: notes)) == .elsewhere)
        #expect(step(owed(back: false, report: notes)) == .elsewhere)

        // Not known yet: wait for the other word.
        #expect(step(owed(report: nil)) == .keep, "the keyboard is back, but UIKit hasn't said where")
        #expect(step(owed(back: false)) == .keep, "UIKit says Safari has a keyboard, but Murmur's hasn't said it's back")
        #expect(step(owed(onScreen: false)) == .keep, "the keyboard went away in Safari")
        // Murmur still in front: the keyboard is hiding as Murmur opens, or is in one of Murmur's
        // own fields. The user hasn't gone back yet.
        #expect(step(owed(), after: 1.2, phase: .recording(UUID()), murmurActive: true) == .keep)
        #expect(step(owed(), murmurActive: true) == .keep)

        // Nothing is owed any more.
        #expect(step(owed(), after: 45.1) == .drop, "too long after the tap to start listening unasked")
        #expect(step(owed(), after: 45.1, murmurActive: true) == .drop)
        #expect(step(owed(), after: 6, phase: .recording(UUID())) == .drop,
                "back in time: the keyboard joins the recording itself")
        #expect(step(owed(), phase: .off) == .drop, "Murmur was turned off meanwhile")
        #expect(step(owed(), phase: .needsReconnect) == .drop)
        #expect(step(owed(), generation: 4) == .drop, "the session stopped since")
        #expect(step(owed(), generation: 5) == .drop, "the session stopped and started again since")
        #expect(step(owed(), generation: 5, murmurActive: true) == .drop, "Home's stop clears it at once")
    }

    @Test func parsesLaunchOptions() {
        let options = LaunchOptions(arguments: ["Murmur", "-route", "debug", "-fixtures"])
        #expect(options.route == .debug)
        #expect(options.useFixtures)
        #expect(!LaunchOptions(arguments: ["Murmur"]).useFixtures)
    }

    /// Screenshot runs fake the account and open the sign-in sheet (DEBUG builds only).
    @Test func parsesAccountLaunchOptions() {
        let options = LaunchOptions(arguments: [
            "Murmur", "-route", "home", "-account-state", "signedOut", "-account-email", "olga@example.com",
            "-account-sheet", "-fixtures",
        ])
        guard case .signedOut(let account) = options.accountState else {
            Issue.record("Expected a signed-out account, got \(String(describing: options.accountState))")
            return
        }
        #expect(account.email == "olga@example.com")
        #expect(options.accountSheet == .options)
        #expect(options.useFixtures)
        #expect(LaunchOptions(arguments: ["Murmur", "-account-sheet", "email"]).accountSheet == .email)
        // The sheet no longer asks about going on as a guest: its old name opens it plainly.
        #expect(LaunchOptions(arguments: ["Murmur", "-account-sheet", "guest"]).accountSheet == .options)
        #expect(LaunchOptions(arguments: ["Murmur", "-account-state", "guest"]).accountState?.account.email == nil)
        let apple = LaunchOptions(arguments: ["Murmur", "-account-state", "guest", "-account-provider", "apple"])
        #expect(apple.accountState?.account.provider == "apple")
        #expect(LaunchOptions(arguments: ["Murmur", "-account-state", "nope"]).accountState == nil)
        // A signed-in account can't be faked without a session, which Auth would end at launch.
        #expect(LaunchOptions(arguments: ["Murmur", "-account-state", "signedIn"]).accountState == nil)
        #expect(LaunchOptions(arguments: ["Murmur"]).accountSheet == nil)
    }

    /// Screenshot runs pin the session's phase, so Home shows each state without a microphone
    /// (DEBUG builds only).
    @Test func parsesSessionFixtures() {
        func fixture(_ name: String) -> SessionController.Phase? {
            LaunchOptions(arguments: ["Murmur", "-route", "home", "-session-fixture", name]).sessionFixture
        }
        #expect(fixture("off") == .off)
        #expect(fixture("starting") == .starting)
        #expect(fixture("on") == .ready)
        #expect(fixture("reconnect") == .needsReconnect)
        if case .recording = fixture("listening") {} else { Issue.record("listening should pin a recording") }
        if case .processing = fixture("writing") {} else { Issue.record("writing should pin processing") }
        if case .failed(let message) = fixture("failed") {
            #expect(!message.isEmpty)
        } else {
            Issue.record("failed should pin a failure")
        }
        #expect(fixture("nope") == nil)
        #expect(LaunchOptions(arguments: ["Murmur"]).sessionFixture == nil)
    }

    /// Screenshot runs pick the plan and can leave the history empty (DEBUG builds only).
    @Test func parsesQuotaAndHistoryFixtures() {
        func quota(_ name: String) -> AccountService.Quota? {
            LaunchOptions(arguments: ["Murmur", "-fixtures", "-quota-fixture", name]).quotaFixture
        }
        #expect(quota("trial")?.onTrial == true)
        #expect(quota("basic")?.remaining == 360)
        #expect(quota("limit")?.remaining == 0)
        #expect(quota("pro")?.chip() == "Pro")
        #expect(quota("nope") == nil)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures"]).quotaFixture == nil)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures", "-history-fixture", "empty"]).emptyHistory)
        #expect(!LaunchOptions(arguments: ["Murmur", "-fixtures"]).emptyHistory)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures", "-history-fixture", "showcase"]).showcaseHistory)
        #expect(!LaunchOptions(arguments: ["Murmur", "-fixtures", "-history-fixture", "showcase"]).emptyHistory)
        #expect(!LaunchOptions(arguments: ["Murmur", "-fixtures"]).showcaseHistory)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures", "-library-fixture", "empty"]).emptyLibrary)
        #expect(!LaunchOptions(arguments: ["Murmur", "-fixtures"]).emptyLibrary)
    }

    @Test @MainActor func initialPathOpensNestedScreens() {
        #expect(Router.initialPath(for: .languages) == [.settings, .debug, .languages])
        #expect(Router.initialPath(for: .debug) == [.settings, .debug])
        #expect(Router.initialPath(for: .home) == [])
        #expect(Router.initialPath(for: nil) == [])
        #expect(Router.initialPath(for: .account) == [.account])
        #expect(Router.initialTab(for: .snippets) == .snippets)
        #expect(Router.initialTab(for: .settings) == .home)
        #expect(Router.initialTab(for: .note) == .scratchpad)
    }

    @Test @MainActor func eachTabKeepsItsOwnStackAndTheMenuOpensOnHome() {
        let router = Router()
        let note = UUID()
        router.tab = .scratchpad
        router.open(.note(note))
        router.tab = .home
        #expect(router.path == [])
        router.isMenuOpen = true
        router.tab = .dictionary
        router.openFromMenu(.settings)
        #expect(!router.isMenuOpen)
        #expect(router.tab == .home)
        #expect(router.path == [.settings])
        #expect(router.paths[.scratchpad] == [.note(note)])
        router.popToRoot()
        #expect(router.path == [])
    }

    /// The keyboard's start shows Home's root, where the session bar is; the other places keep
    /// what was open in them.
    @Test @MainActor func showingHomeLeavesTheOtherPlacesAsTheyWere() {
        let router = Router()
        let note = UUID()
        router.tab = .scratchpad
        router.open(.note(note))
        router.tab = .home
        router.open(.settings)
        router.tab = .dictionary
        router.isMenuOpen = true
        router.showHome()
        #expect(!router.isMenuOpen)
        #expect(router.tab == .home)
        #expect(router.path == [])
        #expect(router.paths[.scratchpad] == [.note(note)])
    }

    /// The menu lists the five places. Choosing one closes the menu and shows the place with
    /// whatever was open in it; choosing the place already on screen returns it to its root.
    @Test @MainActor func theMenuChoosesAPlace() {
        #expect(MainTab.menuOrder == [.home, .scratchpad, .dictionary, .snippets, .style])
        #expect(Set(MainTab.menuOrder) == Set(MainTab.allCases))
        #expect(MainTab.scratchpad.title == "Notes")
        let router = Router()
        let note = UUID()
        router.tab = .scratchpad
        router.open(.note(note))
        router.tab = .home
        router.isMenuOpen = true
        router.select(.scratchpad)
        #expect(!router.isMenuOpen)
        #expect(router.tab == .scratchpad)
        #expect(router.path == [.note(note)])
        router.isMenuOpen = true
        router.select(.scratchpad)
        #expect(!router.isMenuOpen)
        #expect(router.tab == .scratchpad)
        #expect(router.path == [])
    }
}
