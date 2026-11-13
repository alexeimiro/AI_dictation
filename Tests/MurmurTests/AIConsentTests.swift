import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// Stands in for "Before Murmur listens": answers as told, and counts how often it was shown.
@MainActor
private final class Question {
    var answer: Bool
    /// The question stays on screen until `release()`, like someone reading it.
    var stays = false
    private(set) var asked = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(answer: Bool) {
        self.answer = answer
    }

    func ask() async -> Bool {
        asked += 1
        if stays { await withCheckedContinuation { waiting.append($0) } }
        return answer
    }

    func release() {
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

@MainActor
struct AIConsentTests {
    private func settings() -> SharedSettings {
        SharedSettings(defaults: UserDefaults(suiteName: "test.murmur.consent.\(UUID().uuidString)"))
    }

    /// Asked once; "Allow" is kept, also for the next launch.
    @Test func allowingIsKeptAndNotAskedAgain() async {
        let settings = settings()
        let question = Question(answer: true)
        let consent = AIConsent(settings: settings, ask: question.ask)
        #expect(!consent.isGranted)

        #expect(await consent.ensure())
        #expect(await consent.ensure())

        #expect(question.asked == 1)
        #expect(consent.isGranted)
        #expect(settings.aiConsentVersion == AIConsent.currentVersion)
        let nextLaunch = Question(answer: false)
        #expect(await AIConsent(settings: settings, ask: nextLaunch.ask).ensure())
        #expect(nextLaunch.asked == 0)
    }

    /// "Not now" keeps nothing, so the next start asks again.
    @Test func notNowIsAskedAgainNextTime() async {
        let settings = settings()
        let question = Question(answer: false)
        let consent = AIConsent(settings: settings, ask: question.ask)

        #expect(await !consent.ensure())
        #expect(!consent.isGranted)
        #expect(settings.aiConsentVersion == 0)

        question.answer = true
        #expect(await consent.ensure())
        #expect(question.asked == 2)
    }

    /// Settings' switch off, a sign-out or a deleted account take the OK back.
    @Test func takingItBackAsksAgain() async {
        let settings = settings()
        let question = Question(answer: true)
        let consent = AIConsent(settings: settings, ask: question.ask)
        consent.grant()
        #expect(consent.isGranted)

        consent.withdraw()

        #expect(!consent.isGranted)
        #expect(settings.aiConsentVersion == 0)
        #expect(await consent.ensure())
        #expect(question.asked == 1)
    }

    /// An OK given to an older wording doesn't cover the current one.
    @Test func anOlderWordingIsAskedAgain() {
        let settings = settings()
        settings.aiConsentVersion = AIConsent.currentVersion - 1
        #expect(!AIConsent(settings: settings, ask: { true }).isGranted)
        settings.aiConsentVersion = AIConsent.currentVersion
        #expect(AIConsent(settings: settings, ask: { true }).isGranted)
    }

    /// The session and a screen can ask at the same moment: one question, one answer for both.
    @Test func everythingThatAsksMeanwhileSharesOneQuestion() async {
        let question = Question(answer: true)
        question.stays = true
        let consent = AIConsent(settings: settings(), ask: question.ask)

        async let first = consent.ensure()
        async let second = consent.ensure()
        while question.asked == 0 { await Task.yield() }
        // Both are waiting on the one question by now.
        for _ in 0..<10 { await Task.yield() }
        question.release()

        #expect(await first)
        #expect(await second)
        #expect(question.asked == 1)
        #expect(consent.isGranted)
    }

    /// Screenshot runs and UI tests on fake services never stop to ask, and keep nothing.
    @Test func fixtureRunsAreAllowedWithoutAsking() async {
        let consent = AIConsent.allowedForFixtures()
        #expect(consent.isGranted)
        #expect(await consent.ensure())
    }
}
