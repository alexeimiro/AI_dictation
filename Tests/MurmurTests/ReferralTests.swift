import Foundation
import MurmurCore
import Testing
@testable import Murmur

struct ReferralTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A friend's month replaces the 14-day trial, so the menu counts 30 days.
    @Test func inviteMonthCountsItsOwnLength() {
        let quota = AccountService.Quota(plan: "pro", onTrial: true, trialEndsAt: now.addingTimeInterval(20 * 86_400 - 60),
                                         wordsThisWeek: 0, weeklyLimit: nil, remaining: nil,
                                         trialStartedAt: now.addingTimeInterval(-10 * 86_400))
        #expect(quota.trialLength == 30)
        #expect(quota.usageLine(now: now) == "10 of 30 days used in trial")
        #expect(quota.usageFraction(now: now) == 10.0 / 30.0)
    }

    /// `verify-purchase` answers without trial_started_at: the trial is taken as 14 days.
    @Test func trialWithoutStartIsFourteenDays() {
        let quota = AccountService.Quota(plan: "pro", onTrial: true, trialEndsAt: now.addingTimeInterval(7 * 86_400 - 60),
                                         wordsThisWeek: 0, weeklyLimit: nil, remaining: nil)
        #expect(quota.trialLength == 14)
        #expect(quota.usageLine(now: now) == "7 of 14 days used in trial")
    }

    @Test func decodesTrialStart() throws {
        let json = #"[{"plan":"pro","on_trial":true,"trial_ends_at":"2026-12-09T10:00:00+00:00","words_this_week":0,"weekly_limit":null,"remaining":null,"trial_started_at":"2026-11-09T10:00:00+00:00"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let quota = try #require(try decoder.decode([AccountService.Quota].self, from: Data(json.utf8)).first)
        #expect(quota.trialLength == 30)
    }

    @Test func decodesMyReferrals() throws {
        let json = #"[{"code":"a1b2c3d4","friends_joined":3,"months_earned":2,"redeemed":false,"can_redeem":true}]"#
        let referrals = try #require(try JSONDecoder().decode([AccountService.Referrals].self, from: Data(json.utf8)).first)
        #expect(referrals == .init(code: "a1b2c3d4", friendsJoined: 3, monthsEarned: 2, redeemed: false, canRedeem: true))
        #expect(referrals.summary == "3 friends joined · 2 months of Pro earned")
    }

    @Test func summaryCountsOneOfEach() {
        let one = AccountService.Referrals(code: "x", friendsJoined: 1, monthsEarned: 1, redeemed: false, canRedeem: false)
        #expect(one.summary == "1 friend joined · 1 month of Pro earned")
        let none = AccountService.Referrals(code: "x", friendsJoined: 0, monthsEarned: 0, redeemed: false, canRedeem: false)
        #expect(none.summary == nil)
    }

    /// Codes are shown in capitals and may be typed with spaces or dashes.
    @Test func normalizesTypedCodes() {
        #expect(AccountService.normalizedCode(" A1B2 C3D4 ") == "a1b2c3d4")
        #expect(AccountService.normalizedCode("a1b2-c3d4") == "a1b2c3d4")
        #expect(AccountService.normalizedCode(" - ") == nil)
        #expect(AccountService.normalizedCode(String(repeating: "a", count: 33)) == nil)
    }

    @Test func mapsEveryServerAnswer() {
        let answers = ["ok", "invalid", "own_code", "already_redeemed", "too_late", "sign_in_required",
                       "device_used", "device_check_required"]
        #expect(answers.compactMap(AccountService.RedeemOutcome.init(rawValue:)).count == answers.count)
        #expect(AccountService.RedeemOutcome.ok.message.contains("a month of Murmur Pro"))
        // The month is the iPhone's free trial, one per iPhone.
        #expect(AccountService.RedeemOutcome.deviceUsed.message.contains("already had its free trial"))
    }

    /// Open in Murmur on the invite page.
    @Test func parsesInviteLinks() {
        #expect(DeepLink(url: Brand.inviteDeepLink(code: "a1b2c3d4")) == .invite(code: "a1b2c3d4"))
        #expect(DeepLink(url: URL(string: "murmur://invite/?code=A1B2")!) == .invite(code: "A1B2"))
        #expect(DeepLink(url: URL(string: "murmur://invite")!) == nil)
        #expect(LaunchRoute(rawValue: "referral") == .referral)
    }

    /// The link Share invite sends opens the website's invite page with the code.
    @Test func inviteLinkOpensTheInvitePage() throws {
        let url = try #require(Brand.inviteURL(code: "a1b2c3d4"))
        #expect(url.absoluteString == "https://simplymurmur.com/invite/?code=a1b2c3d4")
        #expect(Brand.supportURL?.absoluteString == "https://simplymurmur.com/support/")
        #expect(ReferralView.shareMessage(code: "a1b2c3d4").contains("A1B2C3D4"))
    }
}
