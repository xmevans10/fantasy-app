import XCTest
@testable import BallIQ

/// Locks Draft & Spin's per-round time budget.
///
/// **Every round now runs the full reel** (2026-08-01). This reverses an earlier pass that
/// abbreviated rounds 2+: that was added when the repetition read as lag, and removed on the
/// report that the shortened spins felt cut off rather than snappy. `SpinRevealView.tickCounts`
/// still carries both branches, but `DraftSpinView` always asks for the full one.
///
/// The point of this file is unchanged, only its direction: the whole-draft cost must stay
/// **asserted and visible** rather than drifting. Full length is not free — 8-round soccer spends
/// ~34s in the reveal — so the budget tests below pin that number instead of capping it. If the
/// pacing is revisited again, move these numbers deliberately; don't loosen them.
///
/// Note the prose elsewhere ("~4.8s a spin", "~38s") is **stale**: it assumes a 1.0s landing beat,
/// but `landingSeconds(abbreviated: false)` returns 0.5, making a full spin 4.28s and soccer 34.24s.
/// Compute from the constants, as `testOneFullSpinCostsWhatTheTickMathSaysItDoes` does — don't
/// quote the comments.
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

    /// The abbreviated branch still exists as a tuning knob, so this asserts the *call site's*
    /// intent rather than the constants: whatever `DraftSpinView` asks for, round 5 must cost
    /// exactly what round 1 does. A regression here means someone reintroduced `roundIndex > 0`.
    func testEveryRoundRunsTheFullReel() {
        XCTAssertFalse(SpinReveal.abbreviatesLaterRounds,
                       "later rounds are meant to run the full casino reel")
        // What DraftSpinView actually asks for, at round 1 and at round 5.
        let opening = SpinReveal.totalSeconds(abbreviated: SpinReveal.abbreviatesLaterRounds && false)
        let later = SpinReveal.totalSeconds(abbreviated: SpinReveal.abbreviatesLaterRounds && true)
        XCTAssertEqual(opening, later, accuracy: 0.0001, "every spin should cost the same")
        XCTAssertEqual(later, SpinReveal.totalSeconds(abbreviated: false), accuracy: 0.0001,
                       "and that cost should be the full-length run")
    }

    /// Pins — rather than caps — what full-length-everywhere actually costs across a whole draft.
    /// This is the number that drove the original abbreviation, so it should be impossible to
    /// change the pacing without this test noticing.
    /// One spin, computed rather than quoted: 21 ticks of `0.05 + 0.013·elapsed` is
    /// `21×0.05 + 0.013×210` = 3.78s of reel, plus a 0.5s landing beat = **4.28s**.
    ///
    /// Worth pinning separately because the source docstrings say "~4.8s a spin", which assumes a
    /// 1.0s landing beat that `landingSeconds(abbreviated: false)` no longer returns. The comment
    /// went stale when the beat was halved; this assertion is the thing that's actually true.
    private let fullSpinSeconds = 4.28

    func testOneFullSpinCostsWhatTheTickMathSaysItDoes() {
        XCTAssertEqual(SpinReveal.reelSeconds(abbreviated: false), 3.78, accuracy: 0.01)
        XCTAssertEqual(SpinReveal.landingSeconds(abbreviated: false), 0.5, accuracy: 0.001)
        XCTAssertEqual(SpinReveal.totalSeconds(abbreviated: false), fullSpinSeconds, accuracy: 0.01)
    }

    func testWholeDraftReelBudgetIsPinnedAtFullLength() {
        for (sport, rounds) in roundsPerSport {
            guard rounds > 0 else { continue }
            let total = Double(rounds) * SpinReveal.totalSeconds(abbreviated: false)
            XCTAssertEqual(total, Double(rounds) * fullSpinSeconds, accuracy: 0.05,
                           "\(sport.rawValue): \(rounds) rounds = \(total)s of reel")
        }
    }

    /// Soccer is the worst case and the one that prompted both pacing changes — call its number
    /// out explicitly so nobody has to multiply in their head to see the cost.
    func testSoccerDraftSpendsAboutThirtyFourSecondsInTheReveal() {
        let rounds = DraftSpinConstraint.lineupSlots(for: .soccer).count
        XCTAssertEqual(rounds, 8, "soccer formation changed, re-check this budget")
        let total = Double(rounds) * SpinReveal.totalSeconds(abbreviated: false)
        XCTAssertEqual(total, 34.24, accuracy: 0.05,
                       "full-length every round is a deliberate trade, see the file header")
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
