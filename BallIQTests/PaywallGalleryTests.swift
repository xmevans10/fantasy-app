import XCTest
import SwiftUI
import StoreKitTest
@testable import BallIQ

/// Renders the live PaywallView with products served by an `SKTestSession` over the
/// repo's `Products.storekit` — the only way to capture the real purchase UI
/// non-interactively (the simulator can't query sandbox StoreKit for products that
/// haven't finished App Store Connect review metadata yet, and the scheme-level
/// StoreKit configuration doesn't apply under `xcodebuild test`). Same pattern as
/// `ScoringGalleryTests`: writes a PNG to tmp and prints the path (`PAYWALL_GALLERY:`).
/// First used 2026-07-15 to produce the App Store IAP review screenshots.
@MainActor
final class PaywallGalleryTests: XCTestCase {

    func testRenderPaywallWithProducts() async throws {
        // The simulator sees the host filesystem, so the repo file works directly; skip
        // (rather than fail) anywhere it doesn't exist so the suite stays portable.
        let configURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BallIQ/Store/Products.storekit")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Products.storekit not reachable from test runtime")
        }
        let session = try SKTestSession(contentsOf: configURL)
        session.resetToDefaultState()
        session.clearTransactions()

        let container = RepositoryContainer.make()
        await container.store.loadProducts()
        guard !container.products.isEmpty else {
            throw XCTSkip("No StoreKit products — SKTestSession config not applied")
        }

        // ImageRenderer can't lay out a NavigationStack offscreen ("no interface idiom"),
        // so snapshot through a real window instead — hosted tests run inside the live
        // app process, which has one.
        let window = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first,
            "no window in hosted test app")
        let host = UIHostingController(rootView: PaywallView().environmentObject(container))
        let previousRoot = window.rootViewController
        window.rootViewController = host
        defer { window.rootViewController = previousRoot }

        // Let SwiftUI complete layout + the heroReveal entrance animation.
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paywall_gallery.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("PAYWALL_GALLERY: \(url.path) (\(container.products.count) products)")
    }
}
