import XCTest
@testable import BallIQ

/// Locks Draft & Spin's per-round time budget.
///
/// The reveal reel is the format's signature casino moment, but it plays once per ROUND and a
/// draft is 3–8 rounds. At its original length (21 ticks + a 1.0s landing beat = ~4.78s) it
/// dominated the format — 38s of an 8-round soccer draft spent watching reels — which is what
/// "there's a screen between each spin causing lag" was describing. Nothing was slow; there was
/// just too much of it.
///
/// These are pure arithmetic over the tick constants, so a future tuning pass that inflates the
/// budget fails here instead of shipping. If a change to the *feel* legitimately needs more time,
/// move the numbers deliberately — don't loosen the assertions.
final class SpinRevealTimingTests: XCTestCase {

    /// Slot counts per sport, from `DraftSpinConstraint.formations` — one reveal per slot.
    private var roundsPerSport: [Sport: Int] {
        var counts: [Sport: Int] = [:]
        for sport in [Sport.nfl, .nba, .baseball, .soccer, .tennis] {
            counts[sport] = DraftSpinConstraint.lineupSlots(for: sport).count
        }
        return counts
    }

    func testOpeningSpinKeepsTheFullCasinoRun() {
        // The signature moment is intact — this test exists to stop it being *cut*, not to cap it.
        XCTAssertGreaterThan(SpinReveal.reelSeconds(abbreviated: false), 3.0)
        XCTAssertLessThan(SpinReveal.totalSeconds(abbreviated: false), 4.5)
    }

    func testLaterRoundsAreSubstantiallyShorter() {
        let opening = SpinReveal.totalSeconds(abbreviated: false)
        let later = SpinReveal.totalSeconds(abbreviated: true)
        XCTAssertLessThan(later, opening / 2,
                          "a repeat spin should cost well under half the opening one")
        XCTAssertLessThan(later, 1.6)
        // Still long enough to read as a spin rather than a cut.
        XCTAssertGreaterThan(later, 0.9)
    }

    /// The number that actually matters to the player: total time watching reels across one
    /// complete draft. Soccer is the worst case at 8 rounds.
    func testWholeDraftReelBudgetStaysUnderTwentySeconds() {
        for (sport, rounds) in roundsPerSport {
            guard rounds > 0 else { continue }
            let total = SpinReveal.totalSeconds(abbreviated: false)
                + Double(rounds - 1) * SpinReveal.totalSeconds(abbreviated: true)
            XCTAssertLessThan(total, 20.0,
                              "\(sport.rawValue): \(rounds) rounds = \(total)s of reel")
        }
    }

    /// Regression guard on the specific number that caused the complaint: an 8-round soccer draft
    /// used to spend ~38s in the reveal. It must stay far below that.
    func testSoccerDraftIsFarBelowItsOriginalBudget() {
        let rounds = DraftSpinConstraint.lineupSlots(for: .soccer).count
        XCTAssertEqual(rounds, 8, "soccer formation changed — re-check this budget")
        let total = SpinReveal.totalSeconds(abbreviated: false)
            + Double(rounds - 1) * SpinReveal.totalSeconds(abbreviated: true)
        XCTAssertLessThan(total, 16.0, "was ~38s before the abbreviated later rounds")
    }

    func testTickDelayDeceleratesMonotonically() {
        // The glide is the whole reason the delay ramps; a flat or non-monotonic ramp would read
        // as a stutter rather than a slowdown.
        let delays = (0..<21).map { SpinReveal.tickDelay(elapsed: $0) }
        for (a, b) in zip(delays, delays.dropFirst()) {
            XCTAssertGreaterThan(b, a)
        }
    }
}

/// `SpinRevealView` is a `View`, so touching it from a non-`@MainActor` test would need isolation
/// hops for what is pure arithmetic. This alias keeps the intent readable at the call sites above.
private typealias SpinReveal = SpinRevealView
