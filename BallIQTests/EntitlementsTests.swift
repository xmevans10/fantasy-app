import XCTest
@testable import BallIQ

/// Pure-logic tests for `Entitlements` derivation (M5) — no StoreKit dependency, since
/// `Entitlements` itself never talks to StoreKit directly (`StoreService` does that).
final class EntitlementsTests: XCTestCase {

    func testFreeUserHasNoProCapabilities() {
        let free = Entitlements.free
        XCTAssertFalse(free.isPro)
        XCTAssertFalse(free.canPlayHardMode)
        XCTAssertFalse(free.canAccessArchive)
        XCTAssertFalse(free.hasUnlimitedOverUnderLives)
        XCTAssertFalse(free.canPlayGrid())
        XCTAssertFalse(free.canPlayDraftSpin())
    }

    func testProUnlocksEverything() {
        let pro = Entitlements(isPro: true)
        XCTAssertTrue(pro.canPlayHardMode)
        XCTAssertTrue(pro.canAccessArchive)
        XCTAssertTrue(pro.hasUnlimitedOverUnderLives)
        XCTAssertTrue(pro.canPlayGrid())
        XCTAssertTrue(pro.canPlayDraftSpin())
    }

    func testAdminUnlocksEverything() {
        let admin = Entitlements(isPro: false, isAdmin: true)
        XCTAssertTrue(admin.canPlayHardMode)
        XCTAssertTrue(admin.canAccessArchive)
        XCTAssertTrue(admin.hasUnlimitedOverUnderLives)
        XCTAssertTrue(admin.canPlayGrid())
        XCTAssertTrue(admin.canPlayDraftSpin())
        XCTAssertTrue(admin.canSelect(.baseball))
        XCTAssertTrue(admin.canSelect(.soccer))
        XCTAssertTrue(admin.canSelect(.tennis))
    }

    func testPackUnlocksOnlyItsOwnFormat() {
        let gridPackOnly = Entitlements(isPro: false, unlockedPacks: [StoreProduct.gridPack.rawValue])
        XCTAssertTrue(gridPackOnly.canPlayGrid())
        XCTAssertFalse(gridPackOnly.canPlayDraftSpin())
        XCTAssertFalse(gridPackOnly.canPlayHardMode)
    }

    // MARK: - Sport filter gating

    func testFreeUserCanSelectAllAndFreeSports() {
        let free = Entitlements.free
        XCTAssertTrue(free.canSelect(.all))
        XCTAssertTrue(free.canSelect(.nfl))
        XCTAssertTrue(free.canSelect(.nba))
    }

    func testFreeUserCannotSelectNonFreeSports() {
        let free = Entitlements.free
        XCTAssertFalse(free.canSelect(.baseball))
        XCTAssertFalse(free.canSelect(.soccer))
        XCTAssertFalse(free.canSelect(.tennis))
    }

    func testProUserCanSelectEverySport() {
        let pro = Entitlements(isPro: true)
        for filter in SportFilter.allCases {
            XCTAssertTrue(pro.canSelect(filter), "Pro should unlock \(filter)")
        }
    }
}
