import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Sign-in is required: Murmur records, and its keyboard works, only while someone is signed in.
/// The rules here decide it; the keyboard hears them through `SharedSettings.signedOut`.
@MainActor
struct SignInGateTests {
    /// Without a backend there's no account to require. With one, only a signed-in account
    /// records: not a guest, a lost session or nobody. Screenshot and fixture runs act signed in
    /// unless `-account-state` fakes a signed-out or guest account.
    @Test func onlyASignedInAccountRecords() {
        func may(backend: Bool = true, signedIn: Bool = false, fixtures: Bool = false, faked: Bool = false) -> Bool {
            AppModel.maySignedInDictate(hasBackend: backend, accountSignedIn: signedIn, fixtureRun: fixtures,
                                        fakedAccount: faked)
        }
        #expect(may(backend: false))
        #expect(may(backend: false, fixtures: true, faked: true))
        #expect(may(signedIn: true))
        #expect(!may())
        #expect(may(fixtures: true))
        #expect(!may(fixtures: true, faked: true))
    }

    @Test func fixtureRunsAreTheScreenshotAndUITestLaunches() {
        #expect(!LaunchOptions(arguments: ["Murmur"]).isFixtureRun)
        #expect(LaunchOptions(arguments: ["Murmur", "-fixtures"]).isFixtureRun)
        #expect(LaunchOptions(arguments: ["Murmur", "-route", "home"]).isFixtureRun)
        #expect(LaunchOptions(arguments: ["Murmur", "-onboarding-fixtures"]).isFixtureRun)
        #expect(LaunchOptions(arguments: ["Murmur", "-onboarding-step", "welcome"]).isFixtureRun)
    }

    /// Log in, and every dictation refused while signed out, lead to onboarding's own sign-in
    /// page until onboarding is past it, and to the "Sign in again" sheet after that.
    @Test func signingInHappensInOnboardingUntilItIsPastSignIn() {
        for step: OnboardingStep in [.welcome, .useCases, .personalizedExplainer, .signIn, .signInOptions, .emailSignIn] {
            #expect(AppModel.signInDestination(onboardingStep: step) == .onboarding, "at \(step)")
        }
        for step: OnboardingStep in [.setupIntro, .keyboardInstructions, .basicPractice, .trialOffer] {
            #expect(AppModel.signInDestination(onboardingStep: step) == .sheet, "at \(step)")
        }
        #expect(AppModel.signInDestination(onboardingStep: nil) == .sheet)
    }

    /// The app tells the keyboard and stops the session on each real change of the account, and
    /// only then: Auth's launch events often repeat what is already known.
    @Test func theAccountSaysWhenItChanges() throws {
        let suite = "test.murmur.account.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AccountModel(defaults: defaults)
        var changes = 0
        model.onChange = { changes += 1 }
        let account = AccountModel.Account(userID: UUID(), email: "olga@example.com")

        model.signedIn(account)
        model.signedIn(account)
        #expect(changes == 1)
        #expect(model.isSignedIn)

        model.sessionEnded()
        model.sessionEnded()
        #expect(changes == 2)
        #expect(model.isSignedOut)

        model.forget()
        model.forget()
        #expect(changes == 3)
        #expect(model.state == nil)
    }
}
