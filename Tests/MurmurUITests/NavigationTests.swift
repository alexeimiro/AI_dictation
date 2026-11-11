import XCTest

/// The menu is the only way between the app's places: no screen shows a tab bar, every row of the
/// menu opens its screen, and every `-route` name still lands where it should. Runs on sample
/// data (`-fixtures`), so nothing leaves the app.
final class NavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(route: String = "home", extra: [String] = []) {
        app.launchArguments = ["-route", route, "-fixtures"] + extra
        app.launch()
        // A simulator that has only just booted takes its time over the first launch: wait for
        // the first screen (each has a button) before any test starts counting.
        _ = app.buttons.firstMatch.waitForExistence(timeout: 45)
    }

    // MARK: Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "no “\(identifier)”", file: file, line: line)
        target.tap()
    }

    private func openMenu(file: StaticString = #filePath, line: UInt = #line) {
        tap(AccessibilityID.menuButton, file: file, line: line)
        if !element(AccessibilityID.menuClose).waitForExistence(timeout: 5) {
            print("HIERARCHY\n\(app.debugDescription)")
            XCTFail("the menu didn't open", file: file, line: line)
        }
    }

    private func expectNoTabBar(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.tabBars.firstMatch.exists, "\(screen) shows a tab bar", file: file, line: line)
    }

    /// The screen named `name` (`AccessibilityID.screen`) is showing, without a tab bar.
    private func expectScreen(_ name: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertTrue(element(AccessibilityID.screen(name)).waitForExistence(timeout: timeout), "not on “\(name)”",
                      file: file, line: line)
        expectNoTabBar(name, file: file, line: line)
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: Tests

    func testTheMenuOpensEachPlaceAndNoneShowsATabBar() {
        launch()
        expectScreen("home", timeout: 10)

        // Each place other than Home, by the menu row's name and the screen's.
        for (place, screen) in [("scratchpad", "notes"), ("dictionary", "dictionary"), ("snippets", "snippets"),
                                ("style", "style")] {
            openMenu()
            tap(AccessibilityID.menuPlace(place))
            expectScreen(screen)
            // The menu marks the place on screen.
            openMenu()
            XCTAssertTrue(element(AccessibilityID.menuPlace(place)).isSelected, "\(place) isn't marked")
            XCTAssertFalse(element(AccessibilityID.menuPlace("home")).isSelected)
            tap(AccessibilityID.menuClose)
        }

        openMenu()
        tap(AccessibilityID.menuPlace("home"))
        expectScreen("home")
    }

    func testTheMenusOtherRowsOpenTheirScreens() {
        launch()
        openMenu()
        tap(AccessibilityID.menuSettings)
        expectScreen("settings")
        back()

        openMenu()
        tap(AccessibilityID.menuAccount)
        expectScreen("account")
        back()

        openMenu()
        tap(AccessibilityID.menuInvite)
        expectScreen("invite")
        back()

        openMenu()
        tap(AccessibilityID.menuSupport)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "the support sheet")
        app.buttons["Cancel"].tap()

        openMenu()
        tap(AccessibilityID.menuUpgrade)
        expectScreen("paywall")
    }

    /// Every `-route` name, old and new, opens its screen, and none of them shows a tab bar.
    func testEveryRouteOpensItsScreen() {
        let routes: [(route: String, screen: String, extra: [String])] = [
            ("home", "home", []),
            ("settings", "settings", []),
            ("account", "account", []),
            ("paywall", "paywall", []),
            ("referral", "invite", []),
            ("invite", "invite", []),
            ("dictionary", "dictionary", []),
            ("snippets", "snippets", []),
            ("style", "style", []),
            ("scratchpad", "notes", []),
            ("notes", "notes", []),
            ("swipeBack", "swipeBack", ["-session-fixture", "on"]),
        ]
        for (route, screen, extra) in routes {
            launch(route: route, extra: extra)
            expectScreen(screen, timeout: 10)
            app.terminate()
        }

        // Screens named by their top bar.
        for (route, title) in [("languages", "Languages"), ("debug", "Debug")] {
            launch(route: route)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "-route \(route)")
            expectNoTabBar(route)
            app.terminate()
        }

        launch(route: "menu")
        XCTAssertTrue(element(AccessibilityID.menuClose).waitForExistence(timeout: 10), "-route menu")
        app.terminate()

        launch(route: "note")
        let rename = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rename")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 10), "-route note")
        expectNoTabBar("note")
        app.terminate()

        // The transcript prepares its recording first, which takes a while on a simulator.
        launch(route: "transcript")
        expectScreen("transcript", timeout: 40)
    }

    /// A pushed screen has no menu button; Back and a swipe from the left edge both return.
    func testPushedScreensGoBackByButtonAndBySwipe() {
        launch(route: "settings")
        expectScreen("settings", timeout: 10)
        XCTAssertFalse(element(AccessibilityID.menuButton).exists)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(element(AccessibilityID.sessionControl).waitForExistence(timeout: 5), "the swipe didn't go back")

        openMenu()
        tap(AccessibilityID.menuSettings)
        expectScreen("settings")
        back()
        XCTAssertTrue(element(AccessibilityID.sessionControl).waitForExistence(timeout: 5), "Back didn't go back")
    }

    /// The menu closes by its ✕ and by a tap outside it.
    func testTheMenuCloses() {
        launch()
        openMenu()
        tap(AccessibilityID.menuClose)
        XCTAssertTrue(waitUntilGone(element(AccessibilityID.menuClose)), "✕ didn't close the menu")

        openMenu()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitUntilGone(element(AccessibilityID.menuClose)), "a tap outside didn't close the menu")
    }

    /// Home's session control is one switch for VoiceOver, named as it always was.
    func testTheSessionControlIsOneSwitch() {
        launch()
        let control = element(AccessibilityID.sessionControl)
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        XCTAssertEqual(control.label, "Murmur is on")
        XCTAssertEqual(control.value as? String, "Off")

        app.terminate()
        launch(extra: ["-session-fixture", "on"])
        let live = element(AccessibilityID.sessionControl)
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        XCTAssertEqual(live.label, "Murmur is on")
        XCTAssertEqual(live.value as? String, "On")
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}
