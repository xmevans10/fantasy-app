import XCTest
@testable import BallIQ

/// Cover for the account-switch leak reported 2026-07-30: signing in with a brand-new account on
/// a device that had another account's data showed the *previous* user's 1231 NFL rating.
///
/// Cause: local rating/progress/streak keys are not namespaced by user, and
/// `RemoteSync.mergeRating` is `max(local, remote)`. That is deliberate so a guest who builds a
/// rating before signing up keeps it — but it cannot distinguish that from signing in as someone
/// else on the same device, where the same `max` hands the previous user's rating to the new one.
///
/// `adoptLocalData(for:)` records an owner so the two cases separate: unclaimed data migrates,
/// somebody else's data is wiped.
@MainActor
final class LocalDataOwnershipTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private var saved: [String: Any] = [:]
    private let touchedKeys = ["rating.nfl", "xp", "streakCount", RepositoryContainer.localDataOwnerKey]

    override func setUp() {
        super.setUp()
        // Hosted tests share UserDefaults with the real app on this simulator, so anything
        // written here has to be put back or it corrupts the next manual launch.
        saved = touchedKeys.reduce(into: [:]) { $0[$1] = defaults.object(forKey: $1) }
    }

    override func tearDown() {
        for key in touchedKeys {
            if let value = saved[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func makeContainer() -> RepositoryContainer {
        RepositoryContainer.make(client: nil, store: StoreService(fetchStub: { _ in [] }))
    }

    private func seedLocalProgress() {
        defaults.set(1231, forKey: "rating.nfl")
        defaults.set(4200, forKey: "xp")
        defaults.set(9, forKey: "streakCount")
    }

    /// The reported bug: a different account must not inherit the previous user's numbers.
    func testSigningInAsADifferentUserClearsThepreviousUsersProgress() {
        let container = makeContainer()
        seedLocalProgress()
        container.adoptLocalData(for: "user-a")

        container.adoptLocalData(for: "user-b")

        XCTAssertEqual(defaults.integer(forKey: "rating.nfl"), 0,
            "a new account must not open holding the previous account's rating")
        XCTAssertEqual(defaults.integer(forKey: "xp"), 0)
        XCTAssertEqual(defaults.integer(forKey: "streakCount"), 0)
        XCTAssertEqual(defaults.string(forKey: RepositoryContainer.localDataOwnerKey), "user-b")
    }

    /// The case the `max` merge exists for, and which must keep working: a guest builds progress,
    /// then signs up. Nobody owns the data yet, so it migrates into the new account.
    func testGuestProgressStillMigratesIntoAFirstAccount() {
        let container = makeContainer()
        defaults.removeObject(forKey: RepositoryContainer.localDataOwnerKey)
        seedLocalProgress()

        container.adoptLocalData(for: "user-a")

        XCTAssertEqual(defaults.integer(forKey: "rating.nfl"), 1231,
            "unclaimed guest progress must carry into the account the guest signs up with")
        XCTAssertEqual(defaults.string(forKey: RepositoryContainer.localDataOwnerKey), "user-a")
    }

    /// Signing back in as the same user — the common case — must not throw away their device state.
    func testTheSameUserSigningBackInKeepsTheirProgress() {
        let container = makeContainer()
        seedLocalProgress()
        container.adoptLocalData(for: "user-a")

        container.adoptLocalData(for: "user-a")

        XCTAssertEqual(defaults.integer(forKey: "rating.nfl"), 1231)
        XCTAssertEqual(defaults.integer(forKey: "streakCount"), 9)
    }

    /// Ownership itself must be cleared by the wipe, so the device is genuinely unclaimed after a
    /// deletion rather than still pointing at an account that no longer exists.
    func testDeletingClearsOwnershipSoTheDeviceReadsAsUnclaimed() {
        let container = makeContainer()
        seedLocalProgress()
        container.adoptLocalData(for: "user-a")

        container.adoptLocalData(for: "user-b")   // wipes, which must also clear the owner key…
        defaults.removeObject(forKey: RepositoryContainer.localDataOwnerKey)  // …as deletion does

        XCTAssertNil(defaults.string(forKey: RepositoryContainer.localDataOwnerKey))
    }
}
