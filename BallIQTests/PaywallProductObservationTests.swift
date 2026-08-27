import XCTest
import SwiftUI
import Combine
import StoreKit
import StoreKitTest
@testable import BallIQ

/// Regression cover for the Guideline 2.1(a) rejection of 1.3 **build 17** (2026-07-29): "The
/// plans did not load."
///
/// Build 16 was rejected for the same symptom and the fix went into `StoreService.loadProducts()`
/// — a real bug (single-shot `try?`, no retry), but not *this* one. `RepositoryContainer` exposed
/// `products`/`isLoadingProducts`/`productLoadFailed` as plain computed passthroughs to
/// `StoreService`, a **separate** `ObservableObject`, while subscribing only to
/// `store.$entitlements`. SwiftUI does not auto-forward nested observables, so a catalog that
/// arrived *while the paywall was on screen* never triggered `container.objectWillChange`,
/// `PaywallView.body` was never re-evaluated, and the plans never rendered. The "Try again"
/// button was dead for the same reason — there was nowhere to tap to start a purchase.
///
/// It only bites on a cold, fresh install where the launch fetch loses its race, which is every
/// reviewer's device and no developer's. `StoreProductLoadTests` could not catch it (it only ever
/// touches a bare `StoreService`), and `PaywallGalleryTests` could not either — it loads products
/// *before* creating the view, so the first body evaluation already sees a full catalog.
///
/// The rule these encode: **the container must republish when the store's catalog or load state
/// changes.** Assert on `objectWillChange`, because that — not the value of `container.products`
/// — is what SwiftUI actually re-renders on.
@MainActor
final class PaywallProductObservationTests: XCTestCase {

    private struct StoreDown: Error {}
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// The exact rejection, minus StoreKit: a load that *completes while the paywall is open*
    /// must move the container, or the view never re-renders. Runs everywhere — no SKTestSession,
    /// no store configuration — so it can never silently skip the way the SKTestSession tests can.
    func testContainerRepublishesWhenAProductLoadFails() async {
        let store = StoreService(fetchStub: { _ in throw StoreDown() })
        let container = RepositoryContainer.make(client: nil, store: store)

        var publishes = 0
        container.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        await container.reloadProducts()

        XCTAssertEqual(container.productLoadState, .failed)
        XCTAssertGreaterThan(publishes, 0,
            "the container must republish when the load state changes — otherwise the paywall's "
            + "'Try again' button can never redraw and is permanently dead")
    }

    /// The state a reviewer opens the paywall in must never be an error state. Before this,
    /// `isLoadingProducts` was `false` until `.task` ran, so the *first frame* read "Couldn't
    /// reach the App Store" before a single fetch had been attempted.
    func testTheCatalogStartsIdleRatherThanFailed() {
        let store = StoreService(fetchStub: { _ in throw StoreDown() })
        let container = RepositoryContainer.make(client: nil, store: store)

        XCTAssertEqual(container.productLoadState, .idle,
            "a catalog nobody has asked for yet is not a failed catalog")
    }

    /// The launch fetch and the paywall's `.task` can overlap on a cold start. Two concurrent
    /// loads used to run in parallel, and whichever finished first cleared the loading flag via
    /// `defer` while the other was still in flight — so the paywall could drop out of "Loading…"
    /// into an error state that a still-running fetch was about to contradict.
    func testConcurrentLoadsCollapseIntoASingleFetchCycle() async {
        var calls = 0
        let store = StoreService(fetchStub: { _ in
            calls += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            throw StoreDown()
        })
        let container = RepositoryContainer.make(client: nil, store: store)

        async let first: Void = container.reloadProducts()
        async let second: Void = container.reloadProducts()
        _ = await (first, second)

        XCTAssertEqual(calls, 3,
            "two overlapping loads must share one three-attempt cycle, not run six fetches")
    }

    /// The success path, and the one that reproduces the rejection literally: build the paywall
    /// against an **empty** container first, *then* let the catalog arrive. `PaywallGalleryTests`
    /// does this in the opposite order, which is precisely why it stayed green through two
    /// rejected builds.
    func testPaywallRendersPlansThatArriveWhileItIsOnScreen() async throws {
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BallIQ/Store/Products.storekit")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Products.storekit not reachable from test runtime")
        }
        let session = try SKTestSession(contentsOf: configURL)
        session.resetToDefaultState()
        session.clearTransactions()

        // The store starts unreachable and is opened part-way through. Without this gate the
        // paywall's own `.task` fetch succeeds during the first settle and the baseline snapshot
        // already contains the plans — which is exactly what happened on the first draft of this
        // test, and it silently measured nothing.
        var storeReachable = false
        // The stub init does no launch fetch, so the container genuinely starts cold — a fresh
        // install whose first catalog request is the one the paywall makes.
        let store = StoreService(fetchStub: { ids in
            guard storeReachable else { return [] }   // empty == unreachable, per loadProducts
            return try await Product.products(for: ids)
        })
        let container = RepositoryContainer.make(client: nil, store: store)
        XCTAssertTrue(container.products.isEmpty, "the container must start with no catalog")

        var publishes = 0
        container.objectWillChange.sink { _ in publishes += 1 }.store(in: &cancellables)

        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first,
            "no window in hosted test app")
        let host = UIHostingController(rootView: PaywallView(trigger: .other).environmentObject(container))
        let previousRoot = window.rootViewController
        window.rootViewController = host
        defer { window.rootViewController = previousRoot }
        await settle()

        // Two near-identical frames before touching the catalog: proof the entrance animation
        // has finished, so a later difference can only come from the plans arriving and not from
        // `heroReveal` still moving. Measured with the same yardstick as the assertion below, so
        // the test states its own noise floor instead of assuming one.
        let settledEmpty = snapshot(window)
        await settle()
        let settledEmptyAgain = snapshot(window)
        let idleDrift = difference(settledEmpty, settledEmptyAgain)
        XCTAssertLessThan(idleDrift, 0.01,
            "the empty paywall is still moving between frames (\(idleDrift)); the comparison "
            + "below could not tell a new plan row from leftover animation")
        XCTAssertEqual(container.productLoadState, .failed,
            "baseline must be the empty paywall a reviewer saw, not one that already has plans")

        storeReachable = true
        await container.reloadProducts()
        guard !container.products.isEmpty else {
            throw XCTSkip("No StoreKit products — SKTestSession config not applied")
        }
        await settle()

        XCTAssertGreaterThan(publishes, 0,
            "the catalog arrived while the paywall was on screen and the container never "
            + "republished — this is the 1.3 build 17 rejection")

        // Assert on pixels, not on text: SwiftUI backs `Text` with neither `UILabel` nor a
        // populated accessibility tree in a hosted unit test, so every string-based check reads
        // an empty hierarchy and "passes" no matter what rendered. What a reviewer's complaint
        // actually means is that the screen did not change when the plans loaded — so that is
        // what this measures.
        // Judged against the noise floor this run actually measured, not a number picked in
        // advance: two plan rows redraw a large part of the screen, so a real render clears the
        // residual-animation drift by an order of magnitude.
        let loadedDrift = difference(snapshot(window), settledEmptyAgain)
        XCTAssertGreaterThan(loadedDrift, max(0.05, idleDrift * 5),
            "the paywall rendered essentially identically before and after the catalog loaded "
            + "(\(loadedDrift) vs an idle floor of \(idleDrift)) — the plans never appeared on "
            + "screen, which is exactly what App Review saw")
    }

    /// Long enough for `heroReveal`'s staggered entrance (the last row is delayed several
    /// hundred ms) to finish completely — a shorter wait leaves the frame still drifting, and
    /// the pixel comparison then can't separate a new plan row from the tail of an animation.
    private func settle() async {
        for _ in 0..<6 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    /// Raw RGBA bytes at a fixed small size. Downsampled because the comparison below cares
    /// about "did the layout change", not about a pixel of antialiasing, and a fixed size keeps
    /// two snapshots byte-comparable regardless of the host device.
    private func snapshot(_ window: UIWindow) -> [UInt8] {
        let size = CGSize(width: 80, height: 160)
        let width = Int(size.width), height = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return bytes }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
        return bytes
    }

    /// Fraction of bytes that differ between two snapshots (0…1).
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let differing = zip(a, b).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
        return Double(differing) / Double(a.count)
    }
}
