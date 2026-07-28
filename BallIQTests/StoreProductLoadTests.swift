import XCTest
import StoreKit
@testable import BallIQ

/// Regression cover for the Guideline 2.1(a) rejection of 1.3 build 16 (2026-07-28): "the
/// subscriptions and the non-consumable in-app purchases were not available at time of review."
///
/// The cause was not the submission — it carried all six items. It was `loadProducts()`:
/// a single `try?` collapsing to `[]`, called once from `init`, never retried. One failed
/// request at cold launch left the app with no catalog for the whole process lifetime and the
/// paywall stuck on an unavailable message with no way back. It survived testing because it only
/// bites on a *first* launch — a reviewer's install, not a developer's warm device.
///
/// These assert the retry policy directly. `Product` cannot be constructed in a unit test, which
/// is precisely why the single-shot version went unnoticed for so long — so the fetch seam is
/// stubbed and the cases that matter are the ones that return *nothing*.
@MainActor
final class StoreProductLoadTests: XCTestCase {

    private struct StoreDown: Error {}

    /// A thrown error must not end the attempt. This is the exact shape of the rejection:
    /// StoreKit unreachable at launch on a fresh install.
    func testAThrowingFetchIsRetriedThreeTimesBeforeGivingUp() async {
        var calls = 0
        let service = StoreService(fetchStub: { _ in
            calls += 1
            throw StoreDown()
        })

        await service.loadProducts()

        XCTAssertEqual(calls, 3, "a failing fetch must be retried, not accepted on the first try")
        XCTAssertEqual(service.productFetchAttempts, 3)
        XCTAssertTrue(service.products.isEmpty)
        XCTAssertTrue(service.productLoadFailed, "exhausted retries must be reported, not silent")
    }

    /// The subtler half of the bug. StoreKit returns an EMPTY ARRAY — it does not throw — for ids
    /// it can't resolve, which is also what an App Store Connect product that hasn't propagated
    /// looks like. Treating that as success is how you cache "no products" for the session.
    func testAnEmptyResultIsTreatedAsFailureAndRetried() async {
        var calls = 0
        let service = StoreService(fetchStub: { _ in
            calls += 1
            return []
        })

        await service.loadProducts()

        XCTAssertEqual(calls, 3, "an empty catalog must be retried, not cached as a valid answer")
        XCTAssertTrue(service.productLoadFailed)
    }

    /// A transient failure must not poison the later attempts: the loop keeps going after a
    /// throw rather than bailing out on the first one.
    ///
    /// NOT ASSERTED HERE: that a *successful* attempt populates the catalog and clears the flag.
    /// `Product` has no public initialiser, so a stub cannot return a real one, and an empty
    /// array is deliberately treated as failure — so the success branch is unreachable from a
    /// unit test. It is verified instead by running the app against a live StoreKit
    /// configuration; see the simulator check recorded in the same commit. Saying so plainly
    /// beats a test whose name claims recovery it never exercises.
    func testAThrowDoesNotAbortTheRemainingAttempts() async {
        var calls = 0
        let service = StoreService(fetchStub: { _ in
            calls += 1
            throw StoreDown()
        })

        await service.loadProducts()

        XCTAssertEqual(calls, 3, "the loop must survive a throw and keep trying")
    }

    /// Every id the app asks for must be one App Store Connect actually has. A typo here yields
    /// an empty catalog that looks exactly like an outage — and all four were verified live
    /// against ASC on 2026-07-27.
    func testRequestsExactlyTheFourConfiguredProductIDs() async {
        var requested: [String] = []
        let service = StoreService(fetchStub: { ids in
            requested = ids
            throw StoreDown()
        })

        await service.loadProducts()

        XCTAssertEqual(Set(requested), Set([
            "com.balliqfantasy.app.pro.monthly",
            "com.balliqfantasy.app.pro.yearly",
            "com.balliqfantasy.app.pack.draftspin",
            "com.balliqfantasy.app.pack.grid",
        ]))
    }

    /// `isLoadingProducts` drives the paywall's "Loading plans…" vs the retry affordance. If it
    /// stuck true the user would stare at a spinner with no action; if it never went true they'd
    /// see "couldn't reach the store" during a perfectly normal fetch.
    func testLoadingFlagIsClearedAfterAFailedLoad() async {
        let service = StoreService(fetchStub: { _ in throw StoreDown() })
        await service.loadProducts()
        XCTAssertFalse(service.isLoadingProducts)
    }
}
