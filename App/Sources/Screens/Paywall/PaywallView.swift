import MurmurCore
import MurmurUI
import StoreKit
import SwiftUI

/// Murmur Pro: what it adds, the annual and monthly plans with the App Store's local prices,
/// Continue, Restore purchase and the terms. A subscriber sees their plan and Manage subscription
/// instead.
struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ProStore.annualID
    @State private var message: String?
    @State private var managing = false
    @State private var unavailable = false
    @State private var restoring = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let store = model.pro
        let options = model.launchOptions.useFixtures ? PlanOption.fixtures : PlanOption.options(from: store.products)
        // At the largest text sizes the buttons scroll with the rest: pinned, they would leave
        // no room for the plans.
        let pinsFooter = !dynamicTypeSize.isAccessibilitySize
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Wordmark(height: 24)
                        Chip("Pro", solid: true)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Brand.name) Pro")
                    Text("Unlimited words")
                        .font(.murmur(.display))
                        .tracking(-0.8)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(AccessibilityID.screen("paywall"))
                        .padding(.top, 14)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Self.features, id: \.self) { feature in
                            Label {
                                Text(feature)
                                    .font(.murmur(.body))
                                    .foregroundStyle(Theme.ink)
                            } icon: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    .padding(.top, 18)
                    if store.isSubscribed {
                        subscribed
                    } else {
                        plans(options, loading: store.isLoading)
                        if !pinsFooter {
                            footer(options)
                                .padding(.horizontal, -24)
                                .padding(.top, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            if !store.isSubscribed, pinsFooter {
                footer(options)
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
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
        VStack(spacing: 10) {
            if options.isEmpty {
                if loading || !unavailable {
                    ProgressView()
                        .tint(Theme.ink)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 12) {
                        Text("The plans didn’t load. Check your connection and try again.")
                            .font(.murmur(.callout))
                            .foregroundStyle(Theme.second)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { unavailable = !(await model.pro.loadProducts()) }
                        }
                        .buttonStyle(.murmur(.secondary, size: .compact))
                    }
                    .padding(.vertical, 24)
                }
            }
            ForEach(options) { option in
                PlanCard(option: option, isSelected: option.id == selection) { selection = option.id }
            }
            Text("Basic stays free, with 1,000 words a week.")
                .font(.murmur(.footnote))
                .foregroundStyle(Theme.third)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var subscribed: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You’re on \(Brand.name) Pro")
                .font(.murmur(.headline))
                .foregroundStyle(Theme.ink)
            Text("Thanks for supporting \(Brand.name).")
                .font(.murmur(.subhead))
                .foregroundStyle(Theme.second)
            Button("Manage subscription") { managing = true }
                .buttonStyle(.murmur(.secondary))
                .padding(.top, 14)
        }
        .padding(.top, 28)
    }

    private func footer(_ options: [PlanOption]) -> some View {
        let store = model.pro
        let busy = store.isPurchasing || restoring
        return VStack(spacing: 6) {
            FieldError(message: message)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            Button(action: purchase) {
                HStack(spacing: 10) {
                    if store.isPurchasing { ProgressView().tint(Theme.ink) }
                    Text("Continue with \(Brand.name) Pro")
                }
            }
            .buttonStyle(.murmur(.primary))
            .disabled(busy || !options.contains { $0.id == selection })
            Button(action: restore) {
                Text(restoring ? "Restoring…" : "Restore purchase")
                    .font(.murmur(.subhead, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            Text("Renews automatically until you cancel. Cancel anytime in Settings › Apple Account › Subscriptions.")
                .font(.murmur(.caption))
                .foregroundStyle(Theme.third)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                Link("Terms of Use", destination: Self.termsURL)
                if let privacy = AccountView.privacyURL {
                    Link("Privacy Policy", destination: privacy)
                }
            }
            .font(.murmur(.footnote))
            .underline()
            .tint(Theme.ink)
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.canvas)
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

/// A plan's card: its name with the saving, the price that is charged, and the mark that shows
/// which is chosen. The charged amount is the price that stands out; the annual plan's price a
/// month is worked out from it, so it sits under the name, smaller and grey (App Review 3.1.2).
private struct PlanCard: View {
    let option: PlanOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 8 pt apart: on a 375 pt screen that leaves the annual price its full size.
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    // Two empty lines, so a card with one line is as tall as one with two at any
                    // text size.
                    VStack(spacing: 3) {
                        Text(verbatim: " ").font(.murmur(.headline))
                        Text(verbatim: " ").font(.murmur(.footnote))
                    }
                    .hidden()
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(option.title)
                                .font(.murmur(.headline))
                                .foregroundStyle(Theme.ink)
                                .fixedSize()
                            if let saving = option.saving {
                                Chip(saving, solid: true)
                            }
                        }
                        if let perMonth = option.perMonth {
                            Text(perMonth)
                                .font(.murmur(.footnote))
                                .monospacedDigit()
                                .foregroundStyle(Theme.second)
                                .fixedSize()
                        }
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                // The one part that may shrink when the card is narrow.
                Text(option.price)
                    .font(.murmur(.headline))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                SelectionMark(isOn: isSelected)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? Theme.ink : Theme.line, lineWidth: 1.5)
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
    /// What is charged each period: "$79.99 / year".
    let price: String
    /// The annual plan's price a month, worked out from `price`: "$6.67 / month".
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
