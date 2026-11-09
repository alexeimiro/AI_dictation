import MurmurCore
import MurmurUI
import SwiftUI

/// "Refer a friend", after Wispr Flow's "Gift Flow to a friend": the gift card, how invites work,
/// the invite link with Copy and Share, what invites have earned, and, while the account is new,
/// a field for a friend's code.
struct ReferralView: View {
    @Environment(AppModel.self) private var model
    @State private var referrals: AccountService.Referrals?
    @State private var failed = false
    @State private var copied = false
    @State private var friendCode = ""
    @State private var redeeming = false
    @State private var redeemMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SerifTitle("Gift \(Brand.name) to a friend", size: 38, color: Palette.ink)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                GiftCard()
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                steps
                    .padding(.horizontal, 28)
                    .padding(.top, 30)
                invite
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                if referrals?.canRedeem == true {
                    redeem
                        .padding(.horizontal, 24)
                        .padding(.top, 34)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Palette.paper.ignoresSafeArea())
        .navigationTitle("Referrals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How it works")
                .font(.ui(16))
                .foregroundStyle(Palette.textSecondary)
            step("arrowshape.turn.up.right", "Share your invite")
            step("link", "They enter your code in \(Brand.name)")
            step("gift", "They get a month of Pro, and you get one when they first dictate")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.ui(17))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(Palette.ink)
                .frame(width: 28)
        }
    }

    @ViewBuilder
    private var invite: some View {
        if model.account?.isSignedIn != true && !model.launchOptions.useFixtures {
            VStack(spacing: 12) {
                Text("Sign in to get your invite.")
                    .font(.ui(16))
                    .foregroundStyle(Palette.textSecondary)
                Button("Sign in") { model.signInSheet = .options }
                    .buttonStyle(.pill(.ink))
            }
        } else if let referrals, let url = Brand.inviteURL(code: referrals.code) {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Label {
                        Text(url.absoluteString)
                            .font(.ui(16))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "link").foregroundStyle(Palette.muted)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.cardBorder))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Your invite link")
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.url = url
                        copied = true
                    }
                    .font(.ui(16, .medium))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .background(Palette.canvas, in: .rect(cornerRadius: 12))
                }
                ShareLink(item: url, message: Text(Self.shareMessage(code: referrals.code))) {
                    Text("Share invite")
                }
                .buttonStyle(.pill(.ink))
                if let summary = referrals.summary {
                    Text(summary)
                        .font(.ui(15))
                        .foregroundStyle(Palette.textSecondary)
                    if referrals.monthsEarned >= AccountService.Referrals.maxMonths {
                        Text("That's the most invites can earn. Thank you for spreading the word.")
                            .font(.ui(14))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        } else if failed {
            VStack(spacing: 10) {
                Text("Your invite didn't load. Check your connection and try again.")
                    .font(.ui(16))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }
                    .font(.ui(16, .medium))
            }
        } else {
            ProgressView().padding(.vertical, 20)
        }
    }

    private var redeem: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Got a code from a friend?")
                .font(.ui(18, .semibold))
                .foregroundStyle(Palette.text)
            Text("Enter it within 14 days of creating your account for a month of \(Brand.name) Pro.")
                .font(.ui(15))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("Invite code", text: $friendCode)
                    .font(.ui(17))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(redeemCode)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.cardBorder))
                Button(action: redeemCode) {
                    if redeeming { ProgressView() } else { Text("Use code") }
                }
                .font(.ui(16, .medium))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(Palette.canvas, in: .rect(cornerRadius: 12))
                .disabled(redeeming || AccountService.normalizedCode(friendCode) == nil)
            }
            if let redeemMessage {
                Text(redeemMessage)
                    .font(.ui(15))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What Share invite sends along with the link.
    nonisolated static func shareMessage(code: String) -> String {
        "I use \(Brand.name) to type with my voice. Here's a month of \(Brand.name) Pro: "
            + "get the app and enter my code \(code.uppercased())."
    }

    private func load() async {
        if model.launchOptions.useFixtures {
            referrals = .init(code: "a1b2c3d4", friendsJoined: 2, monthsEarned: 1, redeemed: false, canRedeem: true)
            return
        }
        failed = false
        do {
            referrals = try await model.accountService.referrals()
            failed = referrals == nil && model.account?.isSignedIn == true
        } catch {
            failed = true
        }
    }

    private func redeemCode() {
        guard !redeeming, AccountService.normalizedCode(friendCode) != nil else { return }
        redeeming = true
        redeemMessage = nil
        Task {
            do {
                let outcome = try await model.accountService.redeem(code: friendCode)
                redeemMessage = outcome.message
                if outcome == .ok {
                    friendCode = ""
                    model.refreshQuota()
                    await load()
                }
            } catch {
                redeemMessage = error.localizedDescription
            }
            redeeming = false
        }
    }
}

/// The ink card on Refer a friend: the wordmark with a Pro badge and what an invite gives.
private struct GiftCard: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Wordmark(height: 30, color: Palette.cream)
                PlanBadge(text: "Pro")
            }
            Text("UNLIMITED WORDS FOR A MONTH")
                .font(.ui(13, .medium))
                .tracking(1.6)
                .foregroundStyle(Palette.cream.opacity(0.85))
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(Palette.ink, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Brand.name) Pro: unlimited words for a month")
    }
}
