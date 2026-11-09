import MurmurCore
import MurmurUI
import StoreKit
import SwiftUI

/// "Get unlimited words", Wispr Flow's paywall: what Pro adds, the annual and monthly plans with
/// the App Store's local prices, Continue, Restore purchase and the terms. A subscriber sees their
/// plan and Manage subscription instead.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ProStore.annualID
    @State private var message: String?
    @State private var managing = false
    @State private var unavailable = false
    @State private var restoring = false

    var body: some View {
        let store = model.pro
        let options = model.launchOptions.useFixtures ? PlanOption.fixtures : PlanOption.options(from: store.products)
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Wordmark(height: 26)
                        PlanBadge(text: "Pro")
                    }
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Brand.name) Pro")
                    SerifTitle("Get unlimited words", accent: "unlimited", accentStyle: .italic, size: 40,
                               color: Palette.ink)
                        .padding(.top, 22)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.features, id: \.self) { feature in
                            Label {
                                Text(feature).font(.ui(17)).foregroundStyle(Palette.text)
                            } icon: {
                                Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.top, 28)
                    if store.isSubscribed {
                        subscribed
                    } else {
                        plans(options, loading: store.isLoading)
                    }
                }
                .padding(.bottom, 16)
            }
            if !store.isSubscribed {
                footer(options)
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .task {
            guard !model.launchOptions.useFixtures else { return }
            unavailable = !(await store.loadProducts())
        }
        .manageSubscriptionsSheet(isPresented: $managing)
    }

    static let features = [
        "Unlimited words, every week",
        "Translate and polish as much as you like",
        "Support an independent app",
    ]

    private func plans(_ options: [PlanOption], loading: Bool) -> some View {
        VStack(spacing: 14) {
            if options.isEmpty {
                if loading || !unavailable {
                    ProgressView().padding(.vertical, 40)
                } else {
                    VStack(spacing: 12) {
                        Text("The plans didn't load. Check your connection and try again.")
                            .font(.ui(16))
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { unavailable = !(await model.pro.loadProducts()) }
                        }
                        .font(.ui(16, .medium))
                    }
                    .padding(.vertical, 24)
                }
            }
            ForEach(options) { option in
                PlanCard(option: option, isSelected: option.id == selection) { selection = option.id }
            }
            Text("Basic stays free, with 1,000 words a week.")
                .font(.ui(14))
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
    }

    private var subscribed: some View {
        VStack(spacing: 14) {
            Text("You're on \(Brand.name) Pro")
                .font(.ui(20, .semibold))
                .foregroundStyle(Palette.text)
            Text("Thanks for supporting \(Brand.name).")
                .font(.ui(16))
                .foregroundStyle(Palette.textSecondary)
            Button("Manage subscription") { managing = true }
                .buttonStyle(.pill(.outline))
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
    }

    private func footer(_ options: [PlanOption]) -> some View {
        let store = model.pro
        let busy = store.isPurchasing || restoring
        return VStack(spacing: 10) {
            if let message {
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: purchase) {
                HStack(spacing: 10) {
                    if store.isPurchasing { ProgressView().tint(.white) }
                    Text("Continue with \(Brand.name) Pro")
                }
            }
            .buttonStyle(.pill(.ink))
            .disabled(busy || !options.contains { $0.id == selection })
            Button(action: restore) {
                Text(restoring ? "Restoring…" : "Restore purchase")
                    .font(.ui(16, .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minHeight: 44)
            }
            .disabled(busy)
            Text("Renews automatically until you cancel. Cancel anytime in Settings › Apple Account › Subscriptions.")
                .font(.ui(12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Link("Terms of Use", destination: Self.termsURL)
                if let privacy = AccountView.privacyURL {
                    Link("Privacy Policy", destination: privacy)
                }
            }
            .font(.ui(12, .medium))
            .tint(Palette.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Palette.paper)
    }

    private func purchase() {
        guard let product = model.pro.products.first(where: { $0.id == selection }) else { return }
        message = nil
        Task {
            switch await model.pro.purchase(product) {
            case .purchased:
                dismiss()
            case .pending:
                message = "Your purchase is waiting for approval. Pro starts as soon as it's approved."
            case .failed(let reason):
                message = reason
            case .cancelled:
                break
            }
        }
    }

    private func restore() {
        message = nil
        restoring = true
        Task {
            message = await model.pro.restore()
            restoring = false
            if message == nil { dismiss() }
        }
    }

    /// The app's own terms when configured, else Apple's standard licence agreement.
    static var termsURL: URL {
        (Bundle.main.object(forInfoDictionaryKey: "MurmurTermsURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            ?? URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    }
}

/// A plan's card: a radio, its name, the price per period, and for the annual plan the monthly
/// price and the saving.
private struct PlanCard: View {
    let option: PlanOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected ? Palette.tabSelectedLabel : Palette.cardBorder)
                    .accessibilityHidden(true)
                Text(option.title)
                    .font(.ui(22, .semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(option.price)
                        .font(.ui(19, .semibold))
                        .foregroundStyle(Palette.text)
                    if let perMonth = option.perMonth {
                        Text(perMonth)
                            .font(.ui(14))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(Palette.paper, in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Palette.tabSelectedLabel : Palette.cardBorder, lineWidth: isSelected ? 2 : 1.5)
            }
            .overlay(alignment: .topTrailing) {
                if let saving = option.saving {
                    Text(saving)
                        .font(.ui(14, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Palette.proBadge, in: .capsule)
                        .offset(x: -16, y: -14)
                }
            }
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A plan card's text, from the App Store's product (fixed for screenshot runs).
struct PlanOption: Identifiable, Equatable {
    let id: String
    let title: String
    /// "$79.99 / year".
    let price: String
    /// The annual plan's price a month: "$6.67 / month".
    let perMonth: String?
    /// "Save 33%".
    let saving: String?

    static func options(from products: [Product]) -> [PlanOption] {
        let annual = products.first { $0.id == ProStore.annualID }
        let monthly = products.first { $0.id == ProStore.monthlyID }
        var options: [PlanOption] = []
        if let annual {
            options.append(PlanOption(
                id: annual.id, title: "Annual", price: "\(annual.displayPrice) / year",
                perMonth: "\((annual.price / 12).formatted(annual.priceFormatStyle)) / month",
                saving: monthly.flatMap { saving(annual: annual.price, monthly: $0.price) }))
        }
        if let monthly {
            options.append(PlanOption(id: monthly.id, title: "Monthly", price: "\(monthly.displayPrice) / month",
                                      perMonth: nil, saving: nil))
        }
        return options
    }

    /// "Save 33%": a year on the annual plan against twelve months, rounded down; nil under 5%.
    static func saving(annual: Decimal, monthly: Decimal) -> String? {
        let year = NSDecimalNumber(decimal: monthly * 12).doubleValue
        guard year > 0 else { return nil }
        let percent = Int(((1 - NSDecimalNumber(decimal: annual).doubleValue / year) * 100).rounded(.down))
        return percent >= 5 ? "Save \(percent)%" : nil
    }

    static let fixtures = [
        PlanOption(id: ProStore.annualID, title: "Annual", price: "$79.99 / year", perMonth: "$6.67 / month",
                   saving: "Save 33%"),
        PlanOption(id: ProStore.monthlyID, title: "Monthly", price: "$9.99 / month", perMonth: nil, saving: nil),
    ]
}
