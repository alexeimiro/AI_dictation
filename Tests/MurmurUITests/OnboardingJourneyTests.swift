import XCTest

/// The onboarding journey end to end on fake services (`-onboarding-fixtures`): sign-in, Settings,
/// permission prompts and dictation are simulated, so nothing leaves the app. Its checkpoint lives
/// in its own defaults suite, which lets these tests terminate and relaunch mid-journey.
final class OnboardingJourneyTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(reset: Bool = true, extra: [String] = []) {
        app.launchArguments = ["-onboarding-fixtures"] + (reset ? ["-onboarding-reset"] : []) + extra
        app.launch()
    }

    // MARK: Helpers

    /// The button labeled `text`, else the first whose label starts with it ("Casual, Caps + …").
    /// Keyboard keys are excluded: the globe key is "Next keyboard".
    private func button(_ text: String) -> XCUIElement {
        let exact = app.buttons.matching(NSPredicate(format: "label == %@", text)).firstMatch
        if exact.exists { return exact }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", text, ", \(text)"))
            .firstMatch
    }

    private func tap(_ text: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let element = button(text)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "no button “\(text)”", file: file, line: line)
        XCTAssertTrue(waitUntilHittable(element), "“\(text)” isn't tappable", file: file, line: line)
        element.tap()
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable && element.isEnabled { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func expectText(_ text: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if !element.waitForExistence(timeout: timeout) {
            add(XCTAttachment(string: app.debugDescription))
            print("HIERARCHY\n\(app.debugDescription)")
            XCTFail("missing “\(text)”", file: file, line: line)
        }
    }

    private func dictate() {
        tap("Simulate dictation")
        tap("Next", timeout: 6)
    }

    // Steps, each ending on the next screen.
    private func throughSurvey() {
        tap("Get started")
        XCTAssertFalse(button("Next").isEnabled, "Next needs an answer")
        tap("I want to type faster on my phone")
        tap("Next")
        expectText("in any app")
        tap("Next")
    }

    private func throughSignIn() {
        tap("Continue with Apple")
        expectText("This only takes a moment")
    }

    private func throughKeyboardSetup() {
        tap("Set up")
        tap("Go to Settings")
        expectText("Try a quick dictation")
        tap("Try Murmur")
        tap("Continue")
    }

    private func throughPractice() {
        expectText("appear like magic")
        dictate()
        expectText("formatting and fixes mistakes")
        dictate()
        tap("Continue")
        expectText("Bring your phone close to your face")
        dictate()
        tap("Continue")
    }

    private func throughWrapUp() {
        tap("Next")
        expectText("Choose how Murmur handles")
        XCTAssertFalse(button("Next").isEnabled, "no consent is preselected")
        tap("Don’t share data")
        tap("Next")
        expectText("Confirm your language")
        tap("Next")
        tap("Casual")
        tap("Next")
        tap("Maybe later")
        tap("Another time")
        tap("Search engine")
        tap("Next")
        tap("Google")
        tap("Next")
        tap("Start Murmuring")
    }

    // MARK: Journeys

    func testFreshInstallReachesHomeAndStaysThere() {
        launch()
        throughSurvey()
        throughSignIn()
        throughKeyboardSetup()
        throughPractice()
        throughWrapUp()
        expectText("unlimited access for 2 weeks")
        tap("Get started")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5), "Home after the offer")

        // The next launch opens Home directly.
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(button("Get started").exists)
    }

    func testBackKeepsAnswersAndReturnsToTheRightScreen() {
        launch()
        tap("Get started")
        tap("I want to type faster on my phone")
        tap("Next")
        expectText("in any app")
        tap("Back")
        let choice = button("I want to type faster on my phone")
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(choice.isSelected, "the answer survives going back")
        XCTAssertTrue(button("Next").isEnabled)
        tap("Back")
        XCTAssertTrue(button("Get started").waitForExistence(timeout: 5))
    }

    func testMoreOptionsMarksUnavailableProvidersAndEmailNeedsAValidAddress() {
        launch()
        throughSurvey()
        tap("More options")
        let microsoft = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Continue with Microsoft, not available yet")).firstMatch
        XCTAssertTrue(microsoft.waitForExistence(timeout: 5), "unavailable providers are marked")
        tap("Continue with Email")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("not-an-email")
        XCTAssertFalse(button("Continue").isEnabled)
        field.typeText("@example.com")
        tap("Continue")
        expectText("Enter the 6-digit code")
        let code = app.textFields.firstMatch
        code.tap()
        code.typeText("123456")
        tap("Continue")
        expectText("This only takes a moment")
    }

    func testTerminationResumesAtKeyboardSetupEachExerciseAndTheOffer() {
        launch()
        throughSurvey()
        throughSignIn()
        tap("Set up")
        relaunch()
        expectText("Keyboard in Settings")

        tap("Go to Settings")
        tap("Try Murmur")
        tap("Continue")
        relaunch()
        expectText("appear like magic")
        dictate()
        relaunch()
        expectText("formatting and fixes mistakes")
        dictate()
        tap("Continue")
        relaunch()
        expectText("Bring your phone close to your face")
        dictate()
        tap("Continue")
        throughWrapUp()
        expectText("unlimited access")
        relaunch()
        expectText("unlimited access")
        tap("Get started")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
    }

    private func relaunch() {
        app.terminate()
        launch(reset: false)
    }

    // MARK: Offer variants (screenshot routes)

    func testOfferVariantsComeFromTheServerAnswer() {
        for (variant, text) in [("trial", "unlimited access for 2 weeks"), ("subscriber", "subscription is active"),
                                ("free", "words of dictation every week")] {
            app.launchArguments = ["-onboarding-step", "trialOffer", "-onboarding-variant", variant]
            app.launch()
            expectText(text)
            XCTAssertTrue(button("Get started").isEnabled)
            app.terminate()
        }
        app.launchArguments = ["-onboarding-step", "trialOffer", "-onboarding-variant", "offline"]
        app.launch()
        expectText("Couldn’t load your plan")
        XCTAssertTrue(button("Try again").waitForExistence(timeout: 5))
    }
}
