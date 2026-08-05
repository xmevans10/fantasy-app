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
/// Where the product catalog stands. Replaces a pair of booleans whose combinations included
/// one the UI could not tell apart from failure: before the first fetch, `isLoadingProducts` was
/// `false` and `productLoadFailed` was `false`, and the paywall rendered that as "Couldn't reach
/// the App Store" — an error message as the *first frame*, before a single request had been made.
/// "Nobody has asked yet" is its own state, and `.idle` is it.
enum ProductLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

@MainActor
final class StoreService: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlements: Entitlements = .free
    @Published private(set) var productLoadState: ProductLoadState = .idle

    private var updateListenerTask: Task<Void, Never>?

    /// How many times `loadProducts` has actually asked the store. Test-visible so the retry
    /// policy can be asserted on directly rather than inferred from the resulting catalog.
    private(set) var productFetchAttempts = 0

    init() {
        updateListenerTask = listenForTransactionUpdates()
        // Debug-launch runs (`-skipStoreKit`, the simctl screenshot flows) skip the launch
        // fetch: on a simulator with no Apple ID, `Product.products(for:)` raises the system
        // "Sign in to Apple Account" sheet, which overlays every screenshot. Real devices are
        // unaffected — the paywall's own `.task` still loads the catalog when a player opens
        // it (`loadProducts`), and purchase/restore never go through this init.
        guard !DebugLaunch.skipStoreKit else { return }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
        }
    }

    /// Test-only init: no transaction listener, no launch fetch, and a stubbed catalog fetch.
    /// The retry policy is the thing that was broken and got the build rejected, so it needs to
    /// be assertable without a live StoreKit — `Product` itself can't be constructed in a unit
    /// test, which is exactly why the original single-shot `try?` went unnoticed.
    init(fetchStub: @escaping ([String]) async throws -> [Product]) {
        self.fetchProducts = fetchStub
        self.retryDelays = [0, 0]   // don't make the suite sit through real backoff
    }

    /// Pause before each retry. Two entries because there are three attempts.
    private var retryDelays: [UInt64] = [500_000_000, 1_500_000_000]

    /// Seam over `Product.products(for:)`. Production uses the real call; tests substitute a
    /// closure that can fail, return empty, or succeed on the Nth attempt.
    private var fetchProducts: ([String]) async throws -> [Product] = { ids in
        try await Product.products(for: ids)
    }

    deinit { updateListenerTask?.cancel() }

    /// The load currently in flight, if any. A cold start runs two callers at once — the launch
    /// fetch from `init` and the paywall's `.task` — and before this they raced: both ran a full
    /// three-attempt cycle, and whichever finished first published its own outcome while the
    /// other was still going, so the paywall could drop from "Loading…" into an error a
    /// still-running fetch was about to contradict. Now the second caller awaits the first.
    private var inFlightLoad: Task<Void, Never>?

    /// Why the last load failed, for diagnosis only — surfaced on the paywall in DEBUG builds.
    ///
    /// "Couldn't reach the App Store" is one message covering two opposite causes: the fetch
    /// threw (network/StoreKit unreachable) or it succeeded and returned an empty array (ids the
    /// store doesn't recognise, products not available in this storefront, agreement not
    /// active). Told apart, one of those is a device problem and the other is an App Store
    /// Connect problem; told together they cost a build cycle to guess at, which is exactly what
    /// happened chasing the 1.3 rejections.
    @Published private(set) var lastLoadDiagnostic: String?

    /// Fetches the catalog, retrying with backoff.
    ///
    /// This used to be a single `try?` whose failure collapsed to `[]` with no retry, called
    /// exactly once from `init`. That is a cold-launch race: `Product.products(for:)` needs the
    /// network *and* StoreKit to be ready, and on a first launch neither is guaranteed. One
    /// unlucky request left the app with no products for the entire process lifetime, and the
    /// paywall stuck on "Plans unavailable right now" with no way back.
    ///
    /// It is not hypothetical — App Review rejected 1.3 (build 16) under Guideline 2.1(a) on
    /// 2026-07-28 with exactly this symptom ("the subscriptions and the non-consumable in-app
    /// purchases were not available at time of review"), on a fresh iPad install. A reviewer's
    /// device is the worst case for this race: brand-new install, first launch, one attempt.
    func loadProducts() async {
        if let inFlightLoad {
            await inFlightLoad.value
            return
        }
        let task = Task { await runLoad() }
        inFlightLoad = task
        await task.value
        inFlightLoad = nil
    }

    private func runLoad() async {
        productLoadState = .loading
        lastLoadDiagnostic = nil
        let ids = StoreProduct.allCases.map(\.rawValue)
        // Three attempts, ~0.5s then ~1.5s apart. Deliberately short: this runs at launch and
        // again when the paywall opens, so the goal is riding out a transient failure, not
        // grinding against a genuine outage.
        for attempt in 0..<3 {
            do {
                productFetchAttempts += 1
                let fetched = try await fetchProducts(ids)
                // An empty result is NOT success. StoreKit returns [] for unknown ids, which is
                // also what a not-yet-propagated App Store Connect product looks like — worth
                // another attempt rather than caching the empty answer for the session.
                if !fetched.isEmpty {
                    products = fetched
                    productLoadState = .loaded
                    return
                }
                // Reached only when the fetch succeeded but returned nothing. That is a
                // completely different diagnosis from a throw and must not be recorded as one:
                // StoreKit answers with [] for ids it doesn't recognise, which is what an
                // unknown product id, a product not available in this storefront, or an
                // inactive Paid Applications Agreement all look like.
                lastLoadDiagnostic = "store returned no products for \(ids.count) ids"
            } catch {
                // Swallowed deliberately, but only after the retries are exhausted below.
                lastLoadDiagnostic = String(describing: error)
            }
            if attempt < retryDelays.count, retryDelays[attempt] > 0 {
                try? await Task.sleep(nanoseconds: retryDelays[attempt])
            }
        }
        productLoadState = .failed
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
