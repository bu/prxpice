import StoreKit

@MainActor
final class SubscriptionManager: ObservableObject {

    static let shared = SubscriptionManager()

    // Product IDs — must match exactly what you create in App Store Connect
    static let monthlyID = "com.Dn0w.PrXpice.1M"
    static let yearlyID  = "com.Dn0w.PrXpice.1Y"

    @Published var products: [Product] = []
    @Published var isSubscribed = false
    @Published var isPurchasing = false
    @Published var errorMessage: String?

    private var transactionListenerTask: Task<Void, Never>?

    private init() {
        #if DEBUG
        isSubscribed = true
        return
        #endif
        transactionListenerTask = listenForTransactions()
        Task { await refresh() }
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Public

    func purchase(_ product: Product) async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await updateSubscriptionStatus()
            case .userCancelled:
                break
            case .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await updateSubscriptionStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    func refresh() async {
        await loadProducts()
        await updateSubscriptionStatus()
    }

    private func loadProducts() async {
        do {
            let fetched = try await Product.products(for: [Self.monthlyID, Self.yearlyID])
            // Sort: yearly first, then monthly
            products = fetched.sorted { lhs, _ in lhs.id == Self.yearlyID }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateSubscriptionStatus() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productType == .autoRenewable &&
               (transaction.productID == Self.monthlyID || transaction.productID == Self.yearlyID) &&
               transaction.revocationDate == nil {
                active = true
                break
            }
        }
        isSubscribed = active
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try await self.checkVerified(result)
                    await transaction.finish()
                    await self.updateSubscriptionStatus()
                } catch {
                    await MainActor.run { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let value):
            return value
        }
    }
}

enum StoreError: LocalizedError {
    case failedVerification

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            return "Transaction verification failed."
        }
    }
}
