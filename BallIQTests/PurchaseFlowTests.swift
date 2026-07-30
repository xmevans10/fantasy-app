import XCTest
import StoreKit
import StoreKitTest
@testable import BallIQ

/// End-to-end purchase cover, driven by an `SKTestSession` over the repo's `Products.storekit`.
///
/// Everything else in the suite stops at "the catalog loaded". Nobody had ever exercised the
/// step after that — `product.purchase()` → verify the signed transaction → `finish()` →
/// derive entitlements from `Transaction.currentEntitlements` → unlock the gated formats. That
/// is the path a reviewer walks, and a break anywhere along it looks identical to the paywall
/// bugs that got 1.3 rejected twice: a purchase screen that doesn't do anything.
///
/// `SKTestSession` auto-approves purchases (no Ask-to-Buy, no interactive sheet), so the whole
/// chain runs headless.
@MainActor
final class PurchaseFlowTests: XCTestCase {

    private var session: SKTestSession!

    override func setUpWithError() throws {
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BallIQ/Store/Products.storekit")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Products.storekit not reachable from test runtime")
        }
        session = try SKTestSession(contentsOf: configURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
    }

    override func tearDown() {
        session?.clearTransactions()
        session = nil
        super.tearDown()
    }

    private func loadedService() async throws -> StoreService {
        let service = StoreService(fetchStub: { ids in try await Product.products(for: ids) })
        await service.loadProducts()
        guard !service.products.isEmpty else {
            throw XCTSkip("No StoreKit products — SKTestSession config not applied")
        }
        return service
    }

    private func product(_ id: StoreProduct, in service: StoreService) throws -> Product {
        try XCTUnwrap(service.products.first { $0.id == id.rawValue }, "\(id.rawValue) missing")
    }

    /// Buying the monthly subscription must actually grant Pro. If entitlement derivation is
    /// broken, the user pays and the app still locks them out — worse than not selling at all.
    func testBuyingTheMonthlySubscriptionGrantsPro() async throws {
        let service = try await loadedService()
        XCTAssertFalse(service.entitlements.isPro, "must start unentitled")

        let purchased = try await service.purchase(try product(.proMonthly, in: service))

        XCTAssertTrue(purchased, "SKTestSession auto-approves — this should complete")
        XCTAssertTrue(service.entitlements.isPro, "a completed subscription purchase must grant Pro")
    }

    /// The one-time packs unlock exactly their own format and nothing else — the whole reason
    /// they exist alongside the subscription.
    func testBuyingTheGridPackUnlocksOnlyTheGrid() async throws {
        let service = try await loadedService()

        let purchased = try await service.purchase(try product(.gridPack, in: service))

        XCTAssertTrue(purchased)
        XCTAssertFalse(service.entitlements.isPro, "a pack must not confer full Pro")
        XCTAssertTrue(service.entitlements.canPlayGrid(), "the grid pack must unlock the Grid")
        XCTAssertFalse(service.entitlements.canPlayDraftSpin(),
                       "the grid pack must NOT unlock Draft & Spin — they're sold separately")
    }

    /// The gate wired this session: the draft-spin pack must actually unlock Draft & Spin.
    /// Before it was wired this product took $1.99 and changed nothing observable.
    func testBuyingTheDraftSpinPackUnlocksDraftSpin() async throws {
        let service = try await loadedService()

        let purchased = try await service.purchase(try product(.draftSpinPack, in: service))

        XCTAssertTrue(purchased)
        XCTAssertTrue(service.entitlements.canPlayDraftSpin())
        XCTAssertFalse(service.entitlements.canPlayGrid(),
                       "the draft-spin pack must NOT unlock the Grid")
    }

    /// A purchase must reach the container's published entitlements, not just the service's —
    /// the same nested-ObservableObject seam that broke the catalog. If it stops here the user
    /// pays and the UI stays locked until relaunch.
    func testAPurchasePropagatesToTheContainer() async throws {
        let service = StoreService(fetchStub: { ids in try await Product.products(for: ids) })
        let container = RepositoryContainer.make(client: nil, store: service)
        await container.reloadProducts()
        guard !container.products.isEmpty else {
            throw XCTSkip("No StoreKit products — SKTestSession config not applied")
        }
        XCTAssertFalse(container.entitlements.isPro)

        let monthly = try XCTUnwrap(container.products.first { $0.id == StoreProduct.proMonthly.rawValue })
        _ = try await container.purchase(monthly)

        XCTAssertTrue(container.entitlements.isPro,
            "the container must republish entitlements after a purchase — otherwise every gated "
            + "surface stays locked behind a subscription the user just paid for")
    }

    /// Restore has to re-derive entitlements from existing transactions. Apple tests this
    /// explicitly (it's a 3.1.1 requirement for a fresh install on a second device).
    func testRestoreReDerivesEntitlementsFromExistingTransactions() async throws {
        let service = try await loadedService()
        _ = try await service.purchase(try product(.proMonthly, in: service))
        XCTAssertTrue(service.entitlements.isPro)

        // A fresh service over the same transaction store — i.e. a reinstall.
        let reinstalled = StoreService(fetchStub: { ids in try await Product.products(for: ids) })
        XCTAssertFalse(reinstalled.entitlements.isPro, "starts blank before restoring")

        await reinstalled.restore()

        XCTAssertTrue(reinstalled.entitlements.isPro,
                      "restore must recover Pro from the existing transaction")
    }

    /// Every product the paywall can show must carry a displayable localized price. A blank or
    /// malformed price is the other way a purchase screen reads as broken.
    func testEveryProductHasADisplayablePrice() async throws {
        let service = try await loadedService()
        XCTAssertEqual(service.products.count, 4)
        for product in service.products {
            XCTAssertFalse(product.displayPrice.isEmpty, "\(product.id) has no display price")
            XCTAssertFalse(product.displayName.isEmpty, "\(product.id) has no display name")
            XCTAssertGreaterThan(product.price, 0, "\(product.id) is priced at zero")
        }
    }

    /// The two subscriptions must expose a subscription period — the paywall derives the
    /// per-month comparison and the savings badge from it, and Apple requires the billing
    /// period be stated in the purchase flow (the 3.1.2(c) rejection of 1.1).
    func testSubscriptionsExposeTheirBillingPeriod() async throws {
        let service = try await loadedService()
        for id in [StoreProduct.proMonthly, .proYearly] {
            let subscription = try XCTUnwrap(try product(id, in: service).subscription,
                                             "\(id.rawValue) has no subscription info")
            XCTAssertGreaterThan(subscription.subscriptionPeriod.value, 0)
        }
    }
}
