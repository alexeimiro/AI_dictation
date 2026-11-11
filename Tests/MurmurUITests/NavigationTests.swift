import XCTest

/// The menu is the only way between the app's places: no screen shows a tab bar, and every row of
/// the menu opens its screen. Runs on sample data (`-fixtures`), so nothing leaves the app.
final class NavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(route: String = "home", extra: [String] = []) {
        app.launchArguments = ["-route", route, "-fixtures"] + extra
        app.launch()
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

    private func expectTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "not on “\(title)”", file: file, line: line)
        expectNoTabBar(title, file: file, line: line)
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: Tests

    func testTheMenuOpensEachPlaceAndNoneShowsATabBar() {
        launch()
        XCTAssertTrue(element(AccessibilityID.sessionControl).waitForExistence(timeout: 10), "Home")
        expectNoTabBar("Home")

        // The places other than Home, by the title each shows in its top bar.
        for (place, title) in [("scratchpad", "Scratchpad"), ("dictionary", "Dictionary"), ("snippets", "Snippets"),
                               ("style", "Style")] {
            openMenu()
            tap(AccessibilityID.menuPlace(place))
            expectTitle(title)
            // The menu marks the place on screen.
            openMenu()
            XCTAssertTrue(element(AccessibilityID.menuPlace(place)).isSelected, "\(place) isn't marked")
            XCTAssertFalse(element(AccessibilityID.menuPlace("home")).isSelected)
            tap(AccessibilityID.menuClose)
        }

        openMenu()
        tap(AccessibilityID.menuPlace("home"))
        XCTAssertTrue(element(AccessibilityID.sessionControl).waitForExistence(timeout: 5), "back on Home")
    }

    func testTheMenusOtherRowsOpenTheirScreens() {
        launch()
        openMenu()
        tap(AccessibilityID.menuSettings)
        expectTitle("Settings")
        back()

        openMenu()
        tap(AccessibilityID.menuAccount)
        expectTitle("Account")
        back()

        openMenu()
        tap(AccessibilityID.menuInvite)
        expectTitle("Referrals")
        back()

        openMenu()
        tap(AccessibilityID.menuSupport)
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "the support sheet")
        app.buttons["Cancel"].tap()

        openMenu()
        tap(AccessibilityID.menuUpgrade)
        XCTAssertTrue(app.buttons["Restore purchase"].waitForExistence(timeout: 5), "the plans")
    }

    /// A pushed screen has no menu button; Back and a swipe from the left edge both return.
    func testPushedScreensGoBackByButtonAndBySwipe() {
        launch(route: "settings")
        expectTitle("Settings")
        XCTAssertFalse(element(AccessibilityID.menuButton).exists)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(element(AccessibilityID.sessionControl).waitForExistence(timeout: 5), "the swipe didn't go back")

        openMenu()
        tap(AccessibilityID.menuSettings)
        expectTitle("Settings")
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
