import Foundation
import Testing
@testable import Murmur

/// Whether the account signed in has the App Store's subscription, and when it is sent to the
/// server again.
@MainActor
struct ProSubscriptionTests {
    private func quota(plan: String, onTrial: Bool) -> AccountService.Quota {
        AccountService.Quota(plan: plan, onTrial: onTrial, trialEndsAt: nil, wordsThisWeek: 0,
                             weeklyLimit: plan == "pro" ? nil : 1000, remaining: plan == "pro" ? nil : 1000)
    }

    /// The review's case: bought Pro, deleted the account, signed in again. StoreKit still says
    /// subscribed, the server says Basic: the menu, Home and Settings offer Pro again, and the
    /// paywall offers Restore purchase instead of "You're on Murmur Pro".
    @Test func aSubscriptionTheAccountDoesntHaveDoesntCount() {
        #expect(AppModel.hasProSubscription(storeKit: true, quota: quota(plan: "pro", onTrial: false)))
        #expect(!AppModel.hasProSubscription(storeKit: true, quota: quota(plan: "basic", onTrial: false)),
                "after an account change")
        #expect(!AppModel.hasProSubscription(storeKit: true, quota: quota(plan: "pro", onTrial: true)),
                "Pro from the trial, not from the subscription")
        #expect(AppModel.hasProSubscription(storeKit: true, quota: nil), "before the server's first answer")
        #expect(!AppModel.hasProSubscription(storeKit: false, quota: quota(plan: "pro", onTrial: false)),
                "Pro paid by another Apple Account: nothing to manage here")
        #expect(!AppModel.hasProSubscription(storeKit: false, quota: nil))
    }

    /// Sent for one account says nothing about the next: after an account change the subscription
    /// goes to the server again, even within the hours a resend normally waits.
    @Test func aTransactionSentForAnotherAccountIsSentAgain() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.murmur.pro.\(UUID().uuidString)"))
        var account: UUID? = UUID()
        let store = ProStore(functions: nil, accountToken: { account }, defaults: defaults)
        let sent = Date()
        let later = sent.addingTimeInterval(60)
        store.markSent(42, now: sent)
        #expect(store.recentlySent(42, now: later))
        #expect(!store.recentlySent(43, now: later), "another transaction")
        #expect(!store.recentlySent(42, now: sent.addingTimeInterval(ProStore.resendAfter + 1)))
        account = UUID()
        #expect(!store.recentlySent(42, now: later), "another account signed in")
        account = nil
        #expect(store.recentlySent(42, now: later), "no session: nothing to tell apart")
    }
}
