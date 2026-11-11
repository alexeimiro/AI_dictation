import MurmurCore
import MurmurUI
import SwiftUI

/// Invite a friend: what an invite gives, how invites work, the invite link with Copy and Share,
/// what invites have earned, and, while the account is new, a field for a friend's code.
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
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("Give a friend a month of Pro")
                    .accessibilityIdentifier(AccessibilityID.screen("invite"))
                GiftCard()
                    .padding(.top, 18)
                steps
                    .padding(.top, 24)
                invite
                    .padding(.top, 20)
                if referrals?.canRedeem == true {
                    Hairline()
                        .padding(.top, 24)
                    redeem
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .tint(Theme.ink)
        .navigationTitle("Invite a friend")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works")
                .font(.murmur(.headline))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            step(1, "Share your invite")
            step(2, "They enter your code in \(Brand.name)")
            step(3, "They get a month of Pro, and you get one when they first dictate")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StepNumber(number)
            Text(text)
                .font(.murmur(.callout))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(number). \(text)")
    }

    @ViewBuilder
    private var invite: some View {
        if model.account?.isSignedIn != true && !model.launchOptions.useFixtures {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sign in to get your invite.")
                    .font(.murmur(.callout))
                    .foregroundStyle(Theme.second)
                Button("Sign in") { model.signInSheet = .options }
                    .buttonStyle(.murmur(.primary))
            }
        } else if let referrals, let url = Brand.inviteURL(code: referrals.code) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(Self.display(url))
                        .font(.murmur(.subhead))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Your invite link")
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.url = url
                        copied = true
                    }
                    .buttonStyle(.murmur(.primary, size: .compact))
                }
                .padding(.leading, 18)
                .padding(.trailing, 4)
                .frame(minHeight: 52)
                .background(Theme.fill, in: .roundCapsule)
                ShareLink(item: url, message: Text(Self.shareMessage(code: referrals.code))) {
                    Text("Share invite")
                }
                .buttonStyle(.murmur(.primary))
                if let summary = referrals.summary {
                    Text(summary)
                        .font(.murmur(.subhead))
                        .foregroundStyle(Theme.second)
                        .padding(.top, 2)
                    if referrals.monthsEarned >= AccountService.Referrals.maxMonths {
                        Text("That’s the most invites can earn. Thank you for spreading the word.")
                            .font(.murmur(.footnote))
                            .foregroundStyle(Theme.third)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        } else if failed {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your invite didn’t load. Check your connection and try again.")
                    .font(.murmur(.callout))
                    .foregroundStyle(Theme.second)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.murmur(.secondary, size: .compact))
            }
        } else {
            ProgressView()
                .tint(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        }
    }

    private var redeem: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Got a code from a friend?")
                .font(.murmur(.headline))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Enter it within 14 days of creating your account for a month of \(Brand.name) Pro.")
                .font(.murmur(.subhead))
                .foregroundStyle(Theme.second)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("Invite code", text: $friendCode, prompt: Text("Invite code").foregroundStyle(Theme.third))
                    .font(.murmur(.body))
                    .foregroundStyle(Theme.ink)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(redeemCode)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .background(Theme.fill, in: .rect(cornerRadius: 16))
                Button(action: redeemCode) {
                    if redeeming { ProgressView().tint(Theme.ink) } else { Text("Use code") }
                }
                .buttonStyle(.murmur(.secondary, size: .compact))
                .disabled(redeeming || AccountService.normalizedCode(friendCode) == nil)
            }
            .padding(.top, 6)
            if let redeemMessage {
                Text(redeemMessage)
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.second)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    /// The link as the field shows it: without the scheme.
    static func display(_ url: URL) -> String {
        let text = url.absoluteString
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            return String(text.dropFirst(scheme.count))
        }
        return text
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

/// The ink card on Invite a friend: the wordmark and what an invite gives.
private struct GiftCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(height: 22, color: Theme.onInk)
            Spacer(minLength: 28)
            Text("One month of Pro")
                .font(.murmur(.title2))
                .tracking(-0.5)
                .foregroundStyle(Theme.onInk)
            Text("Unlimited words")
                .font(.murmur(.subhead))
                .foregroundStyle(Theme.onInk.opacity(0.8))
                .padding(.top, 2)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(Theme.ink, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Brand.name) Pro: unlimited words for a month")
    }
}
