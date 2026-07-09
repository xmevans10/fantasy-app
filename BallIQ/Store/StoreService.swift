import StoreKit

enum StoreError: Error { case failedVerification }

/// Free function (not actor-isolated) so it's callable from `Task.detached` transaction
/// listeners without hopping back onto `StoreService`'s main actor first.
private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
    switch result {
    case .unverified: throw StoreError.failedVerification
    case .verified(let safe): return safe
    }
}

/// StoreKit 2 wrapper: product catalog + purchase/restore + on-device entitlement derivation
/// from `Transaction.currentEntitlements`. Owned by `RepositoryContainer`, which mirrors
/// `entitlements` into its own published state (repository-seam constraint — views read
/// `RepositoryContainer`, never this service directly, except via `container.products`/
/// `container.purchase(_:)` passthroughs).
@MainActor
final class StoreService: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlements: Entitlements = .free
    @Published private(set) var isLoadingProducts = false

    private var updateListenerTask: Task<Void, Never>?

    init() {
        updateListenerTask = listenForTransactionUpdates()
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
        }
    }

    deinit { updateListenerTask?.cancel() }

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        products = (try? await Product.products(for: StoreProduct.allCases.map(\.rawValue))) ?? []
    }

    /// Returns true if the purchase completed (and entitlements were refreshed); false on
    /// cancel/pending (parental approval, etc.) — not an error, just "not entitled yet."
    ///
    /// `appAccountToken` ties the StoreKit transaction to our own `user_id` (Apple echoes it
    /// back in the signed transaction/renewal info); without it, the server-side
    /// `app-store-notifications` webhook (Phase B) has no way to know which Supabase user a
    /// purchase belongs to. Pass the signed-in user's uuid whenever one exists.
    @discardableResult
    func purchase(_ product: Product, appAccountToken: UUID? = nil) async throws -> Bool {
        var options: Set<Product.PurchaseOption> = []
        if let appAccountToken { options.insert(.appAccountToken(appAccountToken)) }
        switch try await product.purchase(options: options) {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshEntitlements()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Instant, on-device entitlement read for UX. Phase B layers server-side verification
    /// (App Store Server Notifications → `entitlements` table) on top of this, not instead.
    func refreshEntitlements() async {
        var isPro = false
        var packs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard let product = StoreProduct(rawValue: transaction.productID) else { continue }
            if product.isSubscription { isPro = true } else { packs.insert(product.rawValue) }
        }
        entitlements = Entitlements(isPro: isPro, unlockedPacks: packs)
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let transaction = try? checkVerified(result) else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }
}
