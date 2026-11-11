import XCTest

/// The onboarding journey end to end on fake services (`-onboarding-fixtures`): sign-in, Settings,
/// permission prompts and dictation are simulated, so nothing leaves the app. Its checkpoint lives
/// in its own defaults suite, which lets these tests terminate and relaunch mid-journey.
///
/// The words come from `OnboardingCopy`, which the app's pages read too.
final class OnboardingJourneyTests: XCTestCase {
    private typealias Copy = OnboardingCopy

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(reset: Bool = true, extra: [String] = []) {
        launch(arguments: ["-onboarding-fixtures"] + (reset ? ["-onboarding-reset"] : []) + extra)
    }

    private func launch(arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
        // A simulator that has only just booted takes its time over the first launch: wait for
        // the first page (each has a button) before any test starts counting.
        _ = app.buttons.firstMatch.waitForExistence(timeout: 45)
    }

    // MARK: Helpers

    /// The button labeled `text`, else the first whose label starts with it ("Word for word, Your exact …").
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
        tap(Copy.Practice.simulate)
        tap(Copy.next, timeout: 6)
    }

    // Steps, each ending on the next screen.
    private func throughSurvey() {
        tap(Copy.Welcome.button)
        XCTAssertFalse(button(Copy.next).isEnabled, "Next needs an answer")
        tap(Copy.Survey.typeFaster)
        tap(Copy.next)
        expectText(Copy.Explainer.ending)
        tap(Copy.next)
    }

    private func throughSignIn() {
        tap(Copy.SignIn.apple)
        expectText(Copy.SetupIntro.line)
    }

    private func throughKeyboardSetup() {
        tap(Copy.SetupIntro.button)
        tap(Copy.Keyboard.button)
        expectText(Copy.PracticeIntro.line)
        tap(Copy.PracticeIntro.button)
        // The microphone page; the fake prompt grants it.
        tap(Copy.continue)
    }

    private func throughPractice() {
        expectText(Copy.Practice.basicLine)
        dictate()
        expectText(Copy.Practice.emailLine)
        dictate()
        // "You can whisper, too."
        tap(Copy.continue)
        expectText(Copy.Practice.whisperLine)
        dictate()
        expectText(Copy.PracticeDone.title)
        tap(Copy.continue)
    }

    private func throughWrapUp() {
        tap(Copy.next)
        expectText(Copy.DataChoice.line)
        XCTAssertFalse(button(Copy.next).isEnabled, "no consent is preselected")
        tap(Copy.DataChoice.privateTitle)
        tap(Copy.next)
        expectText(Copy.Languages.title)
        tap(Copy.next)
        // A style's name, from MurmurCore.
        tap("Word for word")
        tap(Copy.next)
        tap(Copy.Notifications.later)
        tap(Copy.Desktop.decline)
        tap(Copy.Referral.searchEngine)
        tap(Copy.next)
        tap("Google")
        tap(Copy.next)
        tap(Copy.Ready.button)
    }

    /// The offer the fake server grants: a two-week trial.
    private var trialTitle: String { Copy.Offer.trialTitle(days: 14) }

    // MARK: Journeys

    func testFreshInstallReachesHomeAndStaysThere() {
        launch()
        throughSurvey()
        throughSignIn()
        throughKeyboardSetup()
        throughPractice()
        throughWrapUp()
        expectText(trialTitle)
        tap(Copy.Offer.button)
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 5), "Home after the offer")

        // The next launch opens Home directly.
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(button(Copy.Welcome.button).exists)
    }

    func testBackKeepsAnswersAndReturnsToTheRightScreen() {
        launch()
        tap(Copy.Welcome.button)
        tap(Copy.Survey.typeFaster)
        tap(Copy.next)
        expectText(Copy.Explainer.ending)
        tap(Copy.back)
        let choice = button(Copy.Survey.typeFaster)
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(choice.isSelected, "the answer survives going back")
        XCTAssertTrue(button(Copy.next).isEnabled)
        tap(Copy.back)
        XCTAssertTrue(button(Copy.Welcome.button).waitForExistence(timeout: 5))
    }

    /// The welcome's three pages turn with a swipe (a screenshot route, where they don't turn by
    /// themselves).
    func testTheWelcomePagesTurnWithASwipe() {
        launch(arguments: ["-onboarding-step", "welcome"])
        expectText(Copy.Welcome.talk)
        app.swipeLeft()
        expectText(Copy.Welcome.languages)
        app.swipeLeft()
        expectText(Copy.Welcome.dictionary)
        app.swipeRight()
        expectText(Copy.Welcome.languages)
        XCTAssertTrue(button(Copy.Welcome.button).isEnabled)
    }

    func testMoreOptionsOffersEmailWhichNeedsAValidAddress() {
        launch()
        throughSurvey()
        tap(Copy.SignIn.more)
        XCTAssertTrue(button(Copy.SignIn.email).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Continue with Microsoft")).firstMatch.exists,
                       "providers that don't work aren't shown")
        tap(Copy.SignIn.email)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("not-an-email")
        XCTAssertFalse(button(Copy.continue).isEnabled)
        field.typeText("@example.com")
        tap(Copy.continue)
        expectText(Copy.Email.sentLineStart)
        let code = app.textFields.firstMatch
        code.tap()
        code.typeText("123456")
        tap(Copy.continue)
        expectText(Copy.SetupIntro.line)
    }

    func testTerminationResumesAtKeyboardSetupEachExerciseAndTheOffer() {
        launch()
        throughSurvey()
        throughSignIn()
        tap(Copy.SetupIntro.button)
        relaunch()
        expectText(Copy.Keyboard.title)

        tap(Copy.Keyboard.button)
        tap(Copy.PracticeIntro.button)
        tap(Copy.continue)
        relaunch()
        expectText(Copy.Practice.basicLine)
        dictate()
        relaunch()
        expectText(Copy.Practice.emailLine)
        dictate()
        tap(Copy.continue)
        relaunch()
        expectText(Copy.Practice.whisperLine)
        dictate()
        tap(Copy.continue)
        throughWrapUp()
        expectText(trialTitle)
        relaunch()
        expectText(trialTitle)
        tap(Copy.Offer.button)
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 5))
    }

    private func relaunch() {
        app.terminate()
        launch(reset: false)
    }

    // MARK: Offer variants (screenshot routes)

    func testOfferVariantsComeFromTheServerAnswer() {
        for (variant, text) in [("trial", trialTitle), ("subscriber", Copy.Offer.subscriberTitle),
                                ("free", Copy.Offer.freeTitle)] {
            launch(arguments: ["-onboarding-step", "trialOffer", "-onboarding-variant", variant])
            expectText(text)
            XCTAssertTrue(button(Copy.Offer.button).isEnabled)
            app.terminate()
        }
        launch(arguments: ["-onboarding-step", "trialOffer", "-onboarding-variant", "offline"])
        expectText(Copy.Offer.failedTitle)
        XCTAssertTrue(button(Copy.Offer.retry).waitForExistence(timeout: 5))
    }

    /// The server rejected the session after sign-in, so the offer can't load and this page has
    /// no way back. It opens the sign-in sheet instead of a retry that can't work, and going on
    /// as a guest there finishes onboarding.
    func testASignOutBeforeTheOfferStillLetsOnboardingFinish() {
        launch(arguments: ["-onboarding-step", "trialOffer", "-account-state", "signedOut",
                           "-account-email", "olga@example.com"])
        expectText(Copy.Offer.signedOutTitle)
        XCTAssertFalse(button(Copy.Offer.retry).exists)
        tap(Copy.Offer.signInAgain)
        // The sign-in sheet's own words.
        expectText("You were signed in as olga@example.com")
        tap("Continue without an account")
        tap("Continue as a guest")
        expectText(trialTitle)
        tap(Copy.Offer.button)
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 5), "Home after the offer")
    }
}
