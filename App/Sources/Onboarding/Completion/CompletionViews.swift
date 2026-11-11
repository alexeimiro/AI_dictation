import MurmurUI
import SwiftUI

/// "You're set.": the talk button at rest, as it waits on the keyboard.
struct ReadyView: View {
    @Environment(AppModel.self) private var model
    /// The statement's size, which grows with the text size like the titles do.
    @ScaledMetric(relativeTo: .largeTitle) private var statementSize: CGFloat = 48

    var body: some View {
        OnboardingPage(top: .wordmark) {
            Spacer(minLength: 24)
            VStack(spacing: 26) {
                TalkButtonPicture(mode: .resting)
                    .padding(.vertical, 12)
                Text(verbatim: OnboardingCopy.Ready.caption)
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.second)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 24)
            Text(verbatim: OnboardingCopy.Ready.title)
                .font(.system(size: statementSize, weight: .bold))
                .tracking(-1.4)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: OnboardingCopy.Ready.line)
                .font(.murmur(.body))
                .lineSpacing(2)
                .foregroundStyle(Theme.second)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        } actions: {
            Button(OnboardingCopy.Ready.button) { model.onboarding.send(.next) }
                .buttonStyle(.murmur(.primary))
        }
        .task { await TrialOfferView.prefetch(model) }
    }
}

/// What the server granted. Onboarding completes only when this is acknowledged with a server
/// answer (or on a build without a backend, the free plan).
struct TrialOfferView: View {
    @Environment(AppModel.self) private var model
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        let store = model.onboarding
        let offer = store.answers.offer
        // The server rejected the account's session after sign-in: no retry can load the plan, and
        // this page has no way back, so it offers the sign-in sheet (which also lets them go on
        // as a guest).
        let signedOut = model.account?.isSignedOut == true
        OnboardingPage(top: .wordmark) {
            if let offer {
                Spacer(minLength: 24)
                Self.picture(for: offer)
                Spacer(minLength: 24)
                Chip(Self.badge(for: offer), solid: offer == .subscriber)
                    .padding(.bottom, 12)
                OnboardingTitle(Self.title(for: offer), line: Self.subtitle(for: offer), size: .statement)
                if let footnote = Self.footnote(for: offer) {
                    Text(verbatim: footnote)
                        .font(.murmur(.footnote))
                        .foregroundStyle(Theme.third)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            } else if failed {
                Spacer(minLength: 24)
                OnboardingTitle(signedOut ? OnboardingCopy.Offer.signedOutTitle : OnboardingCopy.Offer.failedTitle,
                                line: signedOut ? Self.signedOutDetail(model.account?.phrase) : OnboardingCopy.Offer.failedLine)
            } else {
                Spacer(minLength: 24)
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.ink)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 24)
            }
        } actions: {
            if offer == nil && failed && signedOut {
                Button(OnboardingCopy.Offer.signInAgain) { model.signInSheet = .options }
                    .buttonStyle(.murmur(.primary))
            } else if offer == nil && failed {
                Button(OnboardingCopy.Offer.retry) { Task { await load() } }
                    .buttonStyle(.murmur(.primary))
                    .disabled(loading)
            } else {
                Button(OnboardingCopy.Offer.button) { store.send(.next) }
                    .buttonStyle(.murmur(.primary))
                    .disabled(offer == nil)
            }
        }
        .task {
            if store.answers.offer == nil { await load() }
        }
        .onChange(of: signedOut) { _, stillSignedOut in
            // Signed in again, or going on as a guest: the plan can load now.
            guard !stillSignedOut, failed, store.answers.offer == nil else { return }
            failed = false
            Task { await load() }
        }
    }

    /// Under "You're signed out".
    static func signedOutDetail(_ phrase: String?) -> String {
        OnboardingCopy.Offer.signedOutLine(phrase)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let offer = try await model.onboardingServices.offers.currentOffer()
            model.onboarding.send(.offerResolved(offer))
            failed = false
        } catch {
            failed = true
        }
    }

    /// Fetches the offer while "You're set." is on screen, so the next page appears filled in.
    static func prefetch(_ model: AppModel) async {
        guard model.onboarding.answers.offer == nil,
              let offer = try? await model.onboardingServices.offers.currentOffer() else { return }
        model.onboarding.send(.offerResolved(offer))
    }

    /// The plan as a number: the trial's days over one segment a day, or what the plan gives.
    @ViewBuilder
    private static func picture(for offer: OfferVariant) -> some View {
        switch offer {
        case .trial(let days):
            let caption = OnboardingCopy.Offer.trialCaption(days: days)
            // One segment a day, up to a month of them.
            let segments = min(max(days, 1), 31)
            BigNumber(number: "\(days)", caption: caption, meter: (segments, segments))
        case .subscriber:
            BigNumber(number: OnboardingCopy.Offer.subscriberBadge, caption: OnboardingCopy.Offer.subscriberCaption)
        case .free:
            BigNumber(number: OnboardingCopy.Offer.freeNumber, caption: OnboardingCopy.Offer.freeCaption)
        }
    }

    static func badge(for offer: OfferVariant) -> String {
        switch offer {
        case .trial: OnboardingCopy.Offer.trialBadge
        case .subscriber: OnboardingCopy.Offer.subscriberBadge
        case .free: OnboardingCopy.Offer.freeBadge
        }
    }

    static func title(for offer: OfferVariant) -> String {
        switch offer {
        case .trial(let days): OnboardingCopy.Offer.trialTitle(days: days)
        case .subscriber: OnboardingCopy.Offer.subscriberTitle
        case .free: OnboardingCopy.Offer.freeTitle
        }
    }

    static func subtitle(for offer: OfferVariant) -> String {
        switch offer {
        case .trial(let days): OnboardingCopy.Offer.trialLine(days: days)
        case .subscriber: OnboardingCopy.Offer.subscriberLine
        case .free: OnboardingCopy.Offer.freeLine
        }
    }

    static func footnote(for offer: OfferVariant) -> String? {
        switch offer {
        case .trial: OnboardingCopy.Offer.trialFootnote
        case .subscriber: nil
        case .free: OnboardingCopy.Offer.freeFootnote
        }
    }

    /// 14 → "2 weeks", 7 → "1 week", 10 → "10 days".
    static func duration(_ days: Int) -> String {
        OnboardingCopy.Offer.duration(days)
    }
}
