import MurmurCore
import MurmurUI
import SwiftUI

/// Reference 40.
struct ReadyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingPage(showsHeader: false, actionInset: 28.5) {
            VStack(spacing: 0) {
                ReadyIllustration()
                    .frame(width: 345, height: 345)
                    .padding(.top, 49)
                SerifTitle("You’re ready!", size: 64, color: Palette.ink, tracking: 0)
                    .padding(.top, 21)
                Text("\(Brand.name) works in every app,\ngo start \(Brand.name)ing")
                    .font(.ui(20))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 9.6)
                Spacer(minLength: 0)
            }
        } actions: {
            Button("Start \(Brand.name)ing") { model.onboarding.send(.next) }
                .buttonStyle(.pill(.lavender))
        }
        .task { await TrialOfferView.prefetch(model) }
    }
}

/// Reference 41: what the server granted. Onboarding completes only when this is acknowledged
/// with a server answer (or on a build without a backend, the free plan).
struct TrialOfferView: View {
    @Environment(AppModel.self) private var model
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        let store = model.onboarding
        let offer = store.answers.offer
        OnboardingPage(showsHeader: false, actionInset: 16) {
            VStack(spacing: 0) {
                if let offer {
                    Text(Self.badge(for: offer))
                        .font(.ui(13, .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 8)
                        .frame(height: 22.7)
                        .background(Palette.offerPill, in: .rect(cornerRadius: 5))
                        .padding(.top, 51.3)
                    SerifTitle(Self.title(for: offer), size: 33, color: Palette.ink, tracking: -0.2, lineHeight: 42)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                    Text(Self.subtitle(for: offer))
                        .font(.ui(17))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 17)
                    TrialIllustration()
                        .scaleEffect(1.08)
                        .frame(height: 312)
                        .padding(.top, 14)
                    Spacer(minLength: 0)
                    if let footnote = Self.footnote(for: offer) {
                        Text(footnote)
                            .font(.ui(15))
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                            .padding(.bottom, 49.4)
                    }
                } else if failed {
                    Spacer()
                    VStack(spacing: 12) {
                        Text("Couldn’t load your plan")
                            .font(.serif(32))
                            .foregroundStyle(Palette.ink)
                        Text("Check your connection and try again.")
                            .font(.ui(17))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        } actions: {
            if offer == nil && failed {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.pill(.ink))
                    .disabled(loading)
            } else {
                Button { store.send(.next) } label: {
                    // Smaller than the other primary buttons, as in the reference.
                    Text("Get started").font(.ui(16, .medium))
                }
                .buttonStyle(.pill(.ink))
                .disabled(offer == nil)
            }
        }
        .task {
            if store.answers.offer == nil { await load() }
        }
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

    /// Fetches the offer while "You're ready!" is on screen, so the next page appears filled in.
    static func prefetch(_ model: AppModel) async {
        guard model.onboarding.answers.offer == nil,
              let offer = try? await model.onboardingServices.offers.currentOffer() else { return }
        model.onboarding.send(.offerResolved(offer))
    }

    static func badge(for offer: OfferVariant) -> String {
        switch offer {
        case .trial: "Exclusive Offer"
        case .subscriber: "\(Brand.name) Pro"
        case .free: "\(Brand.name) Free"
        }
    }

    static func title(for offer: OfferVariant) -> String {
        switch offer {
        case .trial(let days): "You’ve unlocked unlimited access for \(duration(days)) 🎉"
        case .subscriber: "You’re all set with unlimited access 🎉"
        case .free: "You’re all set to start dictating 🎉"
        }
    }

    static func subtitle(for offer: OfferVariant) -> AttributedString {
        switch offer {
        case .trial(let days):
            var text = AttributedString("Enjoy \(duration(days)) of \(Brand.name) Pro access on us!\n")
            var bold = AttributedString("No credit card required.")
            bold.font = .ui(17, .semibold)
            text += bold
            return text
        case .subscriber:
            return AttributedString("Your \(Brand.name) Pro subscription is active on this account.")
        case .free:
            return AttributedString("\(Brand.name) Free includes \(freeWords) words of dictation every week.")
        }
    }

    static func footnote(for offer: OfferVariant) -> String? {
        switch offer {
        case .trial: "After your \(Brand.name) Pro trial, you’ll move to \(Brand.name) Free with a \(freeWords)-word limit per week."
        case .subscriber: nil
        case .free: "Your words reset every Sunday."
        }
    }

    /// `quota_status` in the backend: 1,000 words a week on the free plan.
    private static let freeWords = 1000.formatted()

    /// 14 → "2 weeks", 7 → "1 week", 10 → "10 days".
    static func duration(_ days: Int) -> String {
        if days % 7 == 0 {
            let weeks = days / 7
            return weeks == 1 ? "1 week" : "\(weeks) weeks"
        }
        return days == 1 ? "1 day" : "\(days) days"
    }
}
