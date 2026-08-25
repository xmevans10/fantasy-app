import Foundation

/// Speed as a **scoring gradient**, not a deadline (M25).
///
/// Every format used to run a countdown that could force-finish a run or zero it outright. That
/// made the clock a fail-state: a player who knew the answer but read slowly lost to the timer
/// rather than to an opponent, which is BALLIQ_SPEC §1 theme 5 inverted — an outcome decided by
/// something other than playing well. Timers are gone. What replaces them is this: finishing
/// under a format's **par time** multiplies the score, and finishing over it costs nothing.
///
/// ```
/// adjusted = score × (1 + bonus × fractionOfParRemaining)
/// ```
///
/// **Scaled by `score`, never added to it** — inherited from `LadderOutcome.adjusted`, which this
/// generalises, and the property that makes the whole mechanic safe: a 0.4 run finishing
/// instantly is still ~0.48, not a win. Speed can separate two players who both knew it; it can
/// never rescue one who didn't. Any future change here has to preserve that.
///
/// Mirrored by `speed_adjusted` in `tools/ingest/ladder.py`, which the bot calibration uses — the
/// two must agree or a rung's simulated difficulty stops describing the rung a player meets.
enum SpeedMultiplier {
    /// The most a perfect-speed run can gain. Deliberately modest: at 0.20, speed reorders
    /// players who are close on accuracy and is powerless between players who are not.
    static let bonus = 0.20

    /// Seconds a format is "expected" to take. **Par, not a limit** — nothing happens when it
    /// passes except that the bonus reaches zero. These are the numbers the codebase already used
    /// as duel clocks (`PuzzleFormat.defaultDuelSeconds`, `ladder.py`'s `base_seconds`), reused
    /// rather than re-invented so the gradient feels like the clock players already knew.
    static func par(for format: PuzzleFormat) -> TimeInterval {
        switch format {
        case .keep4:      return 120
        case .whoami:     return 90
        case .journeyman: return 120
        case .grid:       return 180
        }
    }

    /// Par for a recorded session's format, or **nil when the format isn't time-sensitive**.
    ///
    /// Over/Under and Draft & Spin return nil deliberately: neither ever had a clock, both are
    /// paced by their own mechanics (lives, spins), and awarding a speed bonus for tapping
    /// through an arcade run faster would reward haste rather than knowledge. Keep4 Hard shares
    /// Normal's par — hiding the stats makes the board harder, not longer.
    /// **Every case is explicitly `PuzzleFormat.…`, and that is not style.** `PuzzleFormat` and
    /// `GameFormatKind` share the case names `journeyman` and `grid`, so a bare `par(for: .grid)`
    /// inside this function resolves to *this* overload rather than the other one — infinite
    /// recursion, a blown stack, and a SIGSEGV that presents as "BallIQ quit unexpectedly" rather
    /// than as anything resembling a type error. Caught the hard way; pinned by
    /// `testParDoesNotRecurseBetweenTheTwoFormatEnums`.
    static func par(for kind: GameFormatKind) -> TimeInterval? {
        switch kind {
        case .keep4Normal, .keep4Hard: return par(for: PuzzleFormat.keep4)
        case .whoAmI:                  return par(for: PuzzleFormat.whoami)
        case .journeyman:              return par(for: PuzzleFormat.journeyman)
        case .grid:                    return par(for: PuzzleFormat.grid)
        // Blitz joins these two in having no par, and it is the most load-bearing nil of the
        // three: a blitz run is *already* priced on speed — finishing a board sooner is what
        // buys the next one — so an M25 bonus on top would charge the same second twice. See
        // `BlitzFormat`'s doc comment.
        case .overUnder, .draftSpin, .blitz: return nil
        }
    }

    /// `score` scaled for how far under par it finished.
    ///
    /// Over par returns `score` untouched — there is no penalty branch, and adding one later
    /// would re-create the fail-state this milestone removed. A non-positive `par` returns
    /// `score`, so a caller with no par to offer is scored exactly as before M25.
    ///
    /// **`elapsed == 0` is the FULL bonus, not the absence of one.** An earlier guard read
    /// `elapsed > 0` and meant it as "no timing information", which quietly made the fastest
    /// possible finish pay the least of any finish — caught by
    /// `testTheBonusScalesSmoothlyWithHowMuchParIsLeft`. "Untimed" is `points(startedAt: nil)`'s
    /// job to detect; it is not something an elapsed of zero can express. Negative elapsed (clock
    /// skew on a restored session) clamps to the full bonus rather than exploding.
    static func adjusted(score: Double, elapsed: TimeInterval, par: TimeInterval) -> Double {
        guard par > 0 else { return score }
        let remaining = min(1, max(0, (par - elapsed) / par))
        return score * (1 + bonus * remaining)
    }

    /// Convenience for the common call site: a format's own par.
    static func adjusted(score: Double, elapsed: TimeInterval, format: PuzzleFormat) -> Double {
        adjusted(score: score, elapsed: elapsed, par: par(for: format))
    }

    /// The points a finished session is actually credited, given how long it took.
    ///
    /// **Points only — never `performance`.** `performance` is the rating engine's input and is
    /// checked `0...1` by the database; multiplying it would both break that constraint and make
    /// a rating move for a reason other than how well the board was played (theme 5). This is
    /// exactly the rule the difficulty multiplier already follows: "difficulty pays out in points
    /// and XP only" (`WhoAmIScoring.score`). Speed now pays out the same way.
    static func points(_ score: Int, startedAt: Date?, finishedAt: Date = Date(),
                       kind: GameFormatKind) -> Int {
        guard score > 0, let startedAt, let par = par(for: kind) else { return score }
        let elapsed = finishedAt.timeIntervalSince(startedAt)
        return Int(adjusted(score: Double(score), elapsed: elapsed, par: par).rounded())
    }
}
