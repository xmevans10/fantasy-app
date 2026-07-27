import XCTest
@testable import BallIQ

/// Row-encoding for the first-party `events` pipeline (M15). Pure — the network side is
/// fire-and-forget `try?` by design, so the encodable shape is the testable contract.
final class AnalyticsClientTests: XCTestCase {

    func testSignedInRowShape() throws {
        let data = try AnalyticsClient.encodeRow(event: .gameCompleted,
                                                 properties: ["format": "keep4", "ranked": "true"],
                                                 userID: "user-1")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)   // PostgREST bulk-insert array shape
        XCTAssertEqual(rows[0]["event_name"] as? String, "game_completed")
        XCTAssertEqual(rows[0]["user_id"] as? String, "user-1")
        XCTAssertEqual(rows[0]["properties"] as? [String: String],
                       ["format": "keep4", "ranked": "true"])
    }

    func testSignedOutRowOmitsUserID() throws {
        // The RLS policy accepts a null user_id but rejects a mismatched one — signed-out
        // rows must omit the column entirely so the DB default (null) applies.
        let data = try AnalyticsClient.encodeRow(event: .gameStarted, properties: [:], userID: nil)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertNil(rows[0]["user_id"])
        XCTAssertEqual(rows[0]["properties"] as? [String: String], [:])
    }

    // MARK: - Purchase funnel (M-commercial Phase 1)

    /// These strings are the funnel's column values — `docs/ANALYTICS.md`'s query groups by
    /// them and history is not retroactively renameable, so a rename has to break a test
    /// rather than silently split one funnel into two.
    func testPurchaseFunnelEventNamesAreStable() {
        XCTAssertEqual(AnalyticsEvent.paywallViewed.rawValue, "paywall_viewed")
        XCTAssertEqual(AnalyticsEvent.purchaseAttempted.rawValue, "purchase_attempted")
        XCTAssertEqual(AnalyticsEvent.purchaseFailed.rawValue, "purchase_failed")
        XCTAssertEqual(AnalyticsEvent.purchaseCompleted.rawValue, "purchase_completed")
    }

    /// Likewise for the trigger dimension — every paywall presentation site maps to one of
    /// these, and `other` exists only for the debug hook.
    func testPaywallTriggerRawValuesAreStable() {
        XCTAssertEqual(PaywallTrigger.sportPicker.rawValue, "sport_picker")
        XCTAssertEqual(PaywallTrigger.grid.rawValue, "grid")
        XCTAssertEqual(PaywallTrigger.hardMode.rawValue, "hard_mode")
        XCTAssertEqual(PaywallTrigger.archive.rawValue, "archive")
        XCTAssertEqual(PaywallTrigger.overUnderLives.rawValue, "over_under_lives")
        XCTAssertEqual(PaywallTrigger.other.rawValue, "other")
    }

    /// Backing out of Apple's sheet (`container.purchase` returns false without throwing) and
    /// a thrown failure are different signals — intent vs bug — and must not collapse into one
    /// `reason`.
    func testCancelledAndThrownPurchasesLogDifferentReasons() {
        struct StoreFailure: Error {}
        let cancelled = PaywallView.failureProperties(
            productID: "com.balliqfantasy.app.pro.monthly", trigger: .grid, error: nil)
        let failed = PaywallView.failureProperties(
            productID: "com.balliqfantasy.app.pro.monthly", trigger: .grid, error: StoreFailure())

        XCTAssertEqual(cancelled["reason"], "cancelled")
        XCTAssertEqual(failed["reason"], "error")
        // The other two keys are what makes a failure attributable at all — same product and
        // the same trigger dimension the rest of the funnel groups by.
        XCTAssertEqual(cancelled["product_id"], "com.balliqfantasy.app.pro.monthly")
        XCTAssertEqual(cancelled["trigger"], "grid")
        XCTAssertEqual(failed["trigger"], "grid")
    }

    /// End-to-end through the encoder: a paywall view is only useful if the trigger survives
    /// into the row PostgREST actually receives.
    func testPaywallViewedRowCarriesTrigger() throws {
        let data = try AnalyticsClient.encodeRow(event: .paywallViewed,
                                                 properties: ["trigger": PaywallTrigger.hardMode.rawValue],
                                                 userID: "user-1")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows[0]["event_name"] as? String, "paywall_viewed")
        XCTAssertEqual(rows[0]["properties"] as? [String: String], ["trigger": "hard_mode"])
    }
}
