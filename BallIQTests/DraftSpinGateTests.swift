import XCTest
@testable import BallIQ

/// Regression coverage for the 2026-07-29 fix: `Entitlements.canPlayDraftSpin()` existed since
/// M5 but was never called from any entry point, so the $1.99 draft-spin pack unlocked nothing.
/// `HomeView.launchDraftSpin(daily:)` now calls it before presenting `DraftSpinView`/daily draft
/// mode, mirroring `canPlayGrid()`'s enforcement — but that call site is a private view method,
/// unreachable from a unit test. This locks in the entitlements contract it depends on, so a
/// future change to `canPlayDraftSpin()` that silently loosens the gate fails a test even though
/// the call site itself can't be exercised here.
final class DraftSpinGateTests: XCTestCase {

    func testFreeEntitlementsCannotPlayDraftSpin() {
        XCTAssertFalse(Entitlements.free.canPlayDraftSpin())
    }

    func testProCanPlayDraftSpin() {
        XCTAssertTrue(Entitlements(isPro: true).canPlayDraftSpin())
    }

    func testAdminCanPlayDraftSpin() {
        XCTAssertTrue(Entitlements(isPro: false, isAdmin: true).canPlayDraftSpin())
    }

    func testOwningTheDraftSpinPackCanPlayDraftSpin() {
        let packOwner = Entitlements(isPro: false,
                                     unlockedPacks: [StoreProduct.draftSpinPack.rawValue])
        XCTAssertTrue(packOwner.canPlayDraftSpin())
    }

    /// Owning the Grid pack must not spill over into Draft & Spin — each pack is a distinct
    /// $1.99 purchase, not a bundle.
    func testOwningTheGridPackDoesNotUnlockDraftSpin() {
        let gridOwner = Entitlements(isPro: false, unlockedPacks: [StoreProduct.gridPack.rawValue])
        XCTAssertFalse(gridOwner.canPlayDraftSpin())
    }
}
