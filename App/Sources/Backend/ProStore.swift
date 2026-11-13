import Foundation
import os
import StoreKit

/// Murmur Pro on the App Store: the monthly and annual subscriptions, buying and restoring them,
/// and handing every Murmur Pro transaction StoreKit verifies (a purchase, a renewal, one from
/// another device, a refund) to the server's `verify-purchase`, which grants Pro until the
/// subscription expires. A transaction is finished once the server has it, so one that couldn't
/// be sent comes back the next time.
@MainActor
@Observable
final class ProStore {
    nonisolated static let monthlyID = "com.antonmironenko.murmur.pro.monthly"
    nonisolated static let annualID = "com.antonmironenko.murmur.pro.annual"
    nonisolated static let productIDs: Set<String> = [monthlyID, annualID]

    enum PurchaseOutcome: Equatable {
        case purchased
        case cancelled
        /// Waiting for Ask to Buy or a payment problem to be sorted out.
        case pending
        case failed(String)
    }

    /// Annual first.
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    /// This Apple Account has a current Murmur Pro subscription, as StoreKit sees it. Whether the
    /// signed-in account has it is the server's answer (`AppModel.hasProSubscription`).
    private(set) var isSubscribed = false
    /// Why the server didn't take the subscription the last time it was sent (another account
    /// holds it, or it couldn't be reached); nil once it took it. The paywall shows it with
    /// Restore purchase.
    private(set) var syncMessage: String?

    /// After the server took a transaction, so the plan shown can be refreshed.
    @ObservationIgnored var onSynced: (() -> Void)?
    @ObservationIgnored private let functions: EdgeFunctionClient?
    /// The Murmur account a purchase is for (its user ID), so the server and Apple's notifications
    /// tie the subscription to it.
    @ObservationIgnored private let accountToken: () -> UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Store")

    init(functions: EdgeFunctionClient?, accountToken: @escaping () -> UUID?, defaults: UserDefaults = .standard) {
        self.functions = functions
        self.accountToken = accountToken
        self.defaults = defaults
    }

    /// Listens for transactions from outside a purchase (renewals, refunds, Ask to Buy approvals,
    /// purchases on other devices) and brings the server up to date with the current subscription.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refresh() }
    }

    /// Returns false when the App Store didn't answer with the plans.
    @discardableResult
    func loadProducts() async -> Bool {
        guard products.isEmpty else { return true }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Self.productIDs)
                .sorted { $0.id == Self.annualID && $1.id != Self.annualID }
        } catch {
            logger.error("Products failed: \(error.localizedDescription, privacy: .public)")
        }
        return !products.isEmpty
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        isPurchasing = true
        defer { isPurchasing = false }
        var options: Set<Product.PurchaseOption> = []
        if let token = accountToken() { options.insert(.appAccountToken(token)) }
        do {
            switch try await product.purchase(options: options) {
            case .success(let result):
                guard case .verified = result else {
                    return .failed("The App Store couldn't confirm this purchase. Try Restore purchase.")
                }
                if let failure = await handle(result) { return .failed(failure) }
                return .purchased
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .cancelled
            }
        } catch {
            logger.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            return .failed("The purchase didn't go through. \(error.localizedDescription)")
        }
    }

    /// "Restore purchase": the App Store's purchases for this Apple Account (it may ask to sign
    /// in), with the current subscription sent to the server. Returns a message unless it worked.
    func restore() async -> String? {
        do {
            try await AppStore.sync()
        } catch {
            return "Couldn't reach the App Store. Check your connection and try again."
        }
        if let failure = await refresh(force: true) { return failure }
        return isSubscribed ? nil : "There's no Murmur Pro subscription on this Apple Account."
    }

    /// Another account signed in, or a guest's session started: the subscription is sent again,
    /// so the server gives it to this account when it can (the account it was tied to is gone).
    func accountChanged() async {
        syncMessage = nil
        await refresh(force: true)
    }

    /// The current subscription, to the server, unless the same transaction went there for the
    /// same account in the last few hours (`force` sends it anyway). Returns a message when it
    /// couldn't be confirmed.
    @discardableResult
    func refresh(force: Bool = false) async -> String? {
        var subscribed = false
        var failure: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID) else {
                continue
            }
            subscribed = subscribed || transaction.revocationDate == nil
            guard force || !recentlySent(transaction.id) else { continue }
            if let message = await handle(result) { failure = message }
        }
        isSubscribed = subscribed
        return failure
    }

    // MARK: Server

    /// Sends a verified Murmur Pro transaction to the server, then finishes it. Unverified and
    /// unrelated ones are left alone; a failed send leaves it unfinished, so StoreKit offers it
    /// again. Returns a message when the server didn't take it.
    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> String? {
        guard case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID) else {
            return nil
        }
        if transaction.revocationDate != nil {
            isSubscribed = false
        } else if (transaction.expirationDate ?? .distantFuture) > Date() {
            isSubscribed = true
        }
        do {
            try await send(result.jwsRepresentation)
        } catch .httpError(code: 409) {
            syncMessage = "This subscription belongs to another Murmur account. Sign in with that account to use it."
            return syncMessage
        } catch {
            logger.error("verify-purchase failed: \(error.localizedDescription, privacy: .public)")
            syncMessage = "Your purchase went through, but Murmur couldn't confirm it yet. It tries again on its own, or tap Restore purchase."
            return syncMessage
        }
        syncMessage = nil
        markSent(transaction.id)
        await transaction.finish()
        onSynced?()
        return nil
    }

    private func send(_ jws: String) async throws(EdgeFunctionError) {
        guard let functions else { throw .transport(URLError(.unsupportedURL)) }
        _ = try await functions.post("verify-purchase", body: ["transaction": jws], timeout: 20)
    }

    private static let sentKey = "pro.sentTransaction"
    private static let sentAtKey = "pro.sentAt"
    private static let sentAccountKey = "pro.sentAccount"
    /// A subscriber's every launch would otherwise ask the server again.
    static let resendAfter: TimeInterval = 6 * 3600

    /// Sent lately, and for the account signed in now: one sent for another account (deleted, or
    /// signed out of) says nothing about this one's plan.
    func recentlySent(_ id: UInt64, now: Date = Date()) -> Bool {
        guard defaults.string(forKey: Self.sentKey) == String(id),
              let at = defaults.object(forKey: Self.sentAtKey) as? Date else { return false }
        if let account = accountToken(), defaults.string(forKey: Self.sentAccountKey) != account.uuidString {
            return false
        }
        return now.timeIntervalSince(at) < Self.resendAfter
    }

    func markSent(_ id: UInt64, now: Date = Date()) {
        defaults.set(String(id), forKey: Self.sentKey)
        defaults.set(now, forKey: Self.sentAtKey)
        if let account = accountToken() {
            defaults.set(account.uuidString, forKey: Self.sentAccountKey)
        } else {
            defaults.removeObject(forKey: Self.sentAccountKey)
        }
    }
}
