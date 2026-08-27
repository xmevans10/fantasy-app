import XCTest
@testable import BallIQ

/// Puzzle Blitz — the scoring purse, the clock's one job, and the config that feeds both.
///
/// The two tests worth reading first are `testEveryFormatPaysTheSameRateAtPar` and
/// `testChanceAlonePaysNothing`: together they are the whole fairness claim of the mode, which is
/// that ticking a different set of formats changes what you *play*, never what you can *win*.
final class BlitzTests: XCTestCase {

    private func round(_ format: BlitzFormat, performance: Double, cleared: Bool? = nil,
                       sport: Sport = .nfl, elapsed: TimeInterval = 10) -> BlitzRoundResult {
        BlitzRoundResult(format: format, sport: sport, puzzleID: "p-\(format.rawValue)-\(performance)",
                         performance: performance,
                         cleared: cleared ?? (performance > format.chanceFloor), elapsed: elapsed)
    }

    // MARK: - The fairness invariant

    /// **The mode's central promise, enforced rather than merely true** (AGENTS.md §3).
    ///
    /// A blitz draws formats uniformly, so if one format paid more per second than another, the
    /// optimal play would be to untick everything else — the format picker would become a
    /// strategy dial rather than a taste one, and the score would stop being about knowing ball.
    /// `maxRoundPoints` is `pointsPerParSecond × par` by construction; this pins that the
    /// construction is actually what ships, for every case, including any future one.
    func testEveryFormatPaysTheSameRateAtPar() {
        for format in BlitzFormat.allCases {
            let rate = Double(BlitzScoring.maxRoundPoints(format)) / format.parSeconds
            XCTAssertEqual(rate, BlitzScoring.pointsPerParSecond, accuracy: 0.001,
                           "\(format.rawValue) pays \(rate)/s at par, not \(BlitzScoring.pointsPerParSecond)")
        }
    }

    /// The other half of the same promise: a format with a chance floor must pay **nothing** for
    /// play that only matched chance. Without this an Over/Under-only blitz would bank half of
    /// every round's value for free, at the shortest par in the mode.
    func testChanceAlonePaysNothing() {
        // Coin-flip accuracy on the two formats that have a floor.
        XCTAssertEqual(BlitzScoring.quality(0.5, format: .overunder), 0, accuracy: 0.0001)
        XCTAssertEqual(BlitzScoring.quality(0.5, format: .keep4), 0, accuracy: 0.0001)
        // ...and worse than chance is floored at zero, never negative.
        XCTAssertEqual(BlitzScoring.quality(0.125, format: .keep4), 0, accuracy: 0.0001)
        // The two with no floor pay from the first point.
        XCTAssertEqual(BlitzScoring.quality(0.5, format: .whoami), 0.5, accuracy: 0.0001)
        XCTAssertEqual(BlitzScoring.quality(0.5, format: .journeyman), 0.5, accuracy: 0.0001)
        // Perfect is 1.0 everywhere, floor or not.
        for format in BlitzFormat.allCases {
            XCTAssertEqual(BlitzScoring.quality(1, format: format), 1, accuracy: 0.0001, format.rawValue)
        }
    }

    /// Chance nets out **end to end**, on the format where it's hardest to make it: ten
    /// Over/Under calls, half of them right, is exactly what a coin does — and it is worth zero.
    ///
    /// This is the test that caught the original clamped-at-zero rebase (see
    /// `BlitzScoring.surplus`). Under that version this run scored 400, which made guessing on
    /// the shortest-par format the most efficient thing a bad player could do.
    func testARunOfPureGuessworkScoresZero() {
        let rounds = (0..<10).map { i in
            round(.overunder, performance: i.isMultiple(of: 2) ? 1 : 0)
        }
        let summary = BlitzRunSummary(config: .default, rounds: rounds, elapsed: 300)
        XCTAssertEqual(summary.cleared, 5)
        XCTAssertEqual(summary.rawTotal, 0, "a coin flip must average to nothing")
        XCTAssertEqual(summary.total, 0)
    }

    /// ...and playing *worse* than chance can't produce a negative headline. The breakdown row
    /// still shows the real loss (that's how the run stays legible), but the score a player is
    /// shown bottoms out at zero.
    func testWorseThanChanceFloorsAtZeroOnScreenButNotInTheBreakdown() {
        let rounds = (0..<6).map { _ in round(.overunder, performance: 0) }
        let summary = BlitzRunSummary(config: .default, rounds: rounds, elapsed: 300)
        XCTAssertLessThan(summary.rawTotal, 0)
        XCTAssertEqual(summary.total, 0, "a negative score reads as a penalty for playing")
        XCTAssertEqual(summary.byFormat.first?.points, summary.rawTotal,
                       "the breakdown reports the honest number, not the floored one")
    }

    /// A streak makes good boards worth more and must never make a bad one worth less — otherwise
    /// the better you'd been playing, the more one miss would cost.
    func testTheComboScalesGainsButNotLosses() {
        let miss = round(.overunder, performance: 0)
        XCTAssertEqual(BlitzScoring.points(miss, consecutiveCleared: 0),
                       BlitzScoring.points(miss, consecutiveCleared: 5))
        let hit = round(.overunder, performance: 1)
        XCTAssertGreaterThan(BlitzScoring.points(hit, consecutiveCleared: 5),
                             BlitzScoring.points(hit, consecutiveCleared: 0))
    }

    /// The two floorless formats can never cost points. Not knowing a name is worth zero; it is
    /// not worth less than zero.
    func testFloorlessFormatsNeverGoNegative() {
        for format in [BlitzFormat.whoami, .journeyman] {
            for performance in stride(from: 0.0, through: 1.0, by: 0.1) {
                XCTAssertGreaterThanOrEqual(
                    BlitzScoring.points(round(format, performance: performance, cleared: false),
                                        consecutiveCleared: 0), 0, format.rawValue)
            }
        }
    }

    // MARK: - Combo

    func testComboMultiplierStepsAndCaps() {
        XCTAssertEqual(BlitzScoring.comboMultiplier(consecutiveCleared: 0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(BlitzScoring.comboMultiplier(consecutiveCleared: 3), 1.3, accuracy: 0.0001)
        XCTAssertEqual(BlitzScoring.comboMultiplier(consecutiveCleared: 5), 1.5, accuracy: 0.0001)
        // Capped: a twenty-board streak is worth the same multiplier as a five-board one, so a
        // long run can't compound into a number that swamps accuracy.
        XCTAssertEqual(BlitzScoring.comboMultiplier(consecutiveCleared: 20), 1.5, accuracy: 0.0001)
        XCTAssertEqual(BlitzScoring.comboMultiplier(consecutiveCleared: -3), 1.0, accuracy: 0.0001,
                       "a negative streak is nonsense input, not a penalty")
    }

    /// The combo is a property of the **sequence**, so the same boards in a different order are
    /// worth different amounts. Pinned because it's the one thing that makes `total` unable to be
    /// a `reduce` over an unordered set, and a future refactor toward one would silently change
    /// every score.
    func testScoringIsOrderDependent() {
        let good = round(.whoami, performance: 1)
        let bad = round(.whoami, performance: 0)
        let clustered = BlitzScoring.total([good, good, good, bad])
        let alternating = BlitzScoring.total([good, bad, good, good])
        XCTAssertGreaterThan(clustered, alternating,
                             "three in a row must beat the same three split by a miss")
    }

    func testBestStreakCountsTheLongestRunNotTheLast() {
        let good = round(.journeyman, performance: 1)
        let bad = round(.journeyman, performance: 0)
        XCTAssertEqual(BlitzScoring.bestStreak([good, good, good, bad, good]), 3)
        XCTAssertEqual(BlitzScoring.bestStreak([bad, bad]), 0)
        XCTAssertEqual(BlitzScoring.bestStreak([]), 0)
    }

    // MARK: - The clock

    /// **The clock is a hard stop.** Reversed 2026-08-27 on request: it used to gate only the
    /// *next* board, deliberately never reaching into the one on screen, which was the
    /// reconciliation with M25's "no timers" rule. The run now ends the moment time is up.
    ///
    /// This replaces `testTheClockOnlyGatesTheNextBoardNeverTheCurrentOne`, which asserted the
    /// opposite. Recorded here rather than deleted quietly so the reversal is visible to whoever
    /// reads `BlitzFormat`'s doc comment and expects the old behaviour.
    func testTheClockEndsTheRunOutright() async {
        let start = Date()
        let session = await BlitzSession(config: BlitzConfig(sports: [.nfl], formats: [.whoami],
                                                             duration: .one), now: start)
        await session.beginRound(format: .whoami, sport: .nfl, at: start)
        let afterExpiry = start.addingTimeInterval(90)   // well past the 60s run

        let accepts = await session.acceptsNewRound(at: afterExpiry)
        XCTAssertFalse(accepts)

        await session.expire(at: afterExpiry)

        let over = await session.isOver
        XCTAssertTrue(over, "time up must end the run immediately")
        let rounds = await session.rounds
        XCTAssertTrue(rounds.isEmpty, "the board in flight is not scored")
        let cutOff = await session.cutOff
        XCTAssertEqual(cutOff, BlitzCutOff(format: .whoami, sport: .nfl),
                       "it is reported as cut off so the result screen can still account for it")
    }

    func testARunStaysOpenWhileTimeRemains() async {
        let start = Date()
        let session = await BlitzSession(config: BlitzConfig(sports: [.nfl], formats: [.whoami],
                                                             duration: .five), now: start)
        await session.finishRound(format: .whoami, sport: .nfl, puzzleID: "p1",
                                  performance: 1, cleared: true, now: start.addingTimeInterval(20))
        let over = await session.isOver
        XCTAssertFalse(over)
        let left = await session.secondsLeft(at: start.addingTimeInterval(20))
        XCTAssertEqual(left, 280)
    }

    func testQuittingBanksWhatWasPlayed() async {
        let session = await BlitzSession(config: .default)
        await session.finishRound(format: .keep4, sport: .nfl, puzzleID: "p1",
                                  performance: 1, cleared: true)
        await session.endEarly()
        let summary = await session.summary()
        let over = await session.isOver
        XCTAssertTrue(over)
        XCTAssertEqual(summary.played, 1)
        XCTAssertGreaterThan(summary.total, 0, "quitting is stopping, not forfeiting")
    }

    // MARK: - Summary

    /// `game_results.performance` is `check (performance >= 0 and performance <= 1)` in Postgres,
    /// so a run whose mean quality left that range would fail the insert *silently* (the push is
    /// fire-and-forget) and the career log would quietly lose blitz rows.
    func testRunPerformanceAlwaysSatisfiesTheDatabaseCheck() {
        let extremes: [BlitzRoundResult] = [
            round(.keep4, performance: 0), round(.keep4, performance: 1),
            round(.overunder, performance: 0), round(.overunder, performance: 1),
            round(.whoami, performance: 0), round(.whoami, performance: 1),
            round(.journeyman, performance: 0.37)
        ]
        for count in 0...extremes.count {
            let summary = BlitzRunSummary(config: .default, rounds: Array(extremes.prefix(count)),
                                          elapsed: 300)
            XCTAssertGreaterThanOrEqual(summary.performance, 0)
            XCTAssertLessThanOrEqual(summary.performance, 1)
        }
    }

    func testEmptyRunHasNoAccuracyRatherThanZeroPercent() {
        let summary = BlitzRunSummary(config: .default, rounds: [], elapsed: 60)
        XCTAssertNil(summary.accuracy, "a run with no boards has no accuracy, it isn't 0% accurate")
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.performance, 0)
        XCTAssertTrue(summary.byFormat.isEmpty)
    }

    func testFormatBreakdownSumsToTheRunTotal() {
        let rounds = [round(.keep4, performance: 0.875), round(.overunder, performance: 1),
                      round(.whoami, performance: 0.6), round(.overunder, performance: 0),
                      round(.journeyman, performance: 1)]
        let summary = BlitzRunSummary(config: .default, rounds: rounds, elapsed: 300)
        XCTAssertEqual(summary.byFormat.reduce(0) { $0 + $1.points }, summary.rawTotal,
                       "the 'where it came from' rows must account for every point on screen")
        XCTAssertEqual(summary.byFormat.reduce(0) { $0 + $1.played }, summary.played)
        // Sorted biggest-contribution first, which is the whole point of the panel.
        XCTAssertEqual(summary.byFormat.map(\.points), summary.byFormat.map(\.points).sorted(by: >))
    }

    func testMaxPossibleBoundsTheScoreActuallyEarned() {
        let rounds = [round(.keep4, performance: 0.625), round(.whoami, performance: 0.4),
                      round(.overunder, performance: 1)]
        let summary = BlitzRunSummary(config: .default, rounds: rounds, elapsed: 300)
        XCTAssertLessThanOrEqual(summary.total, summary.maxPossible)
        XCTAssertGreaterThan(summary.maxPossible, 0)
    }

    /// A single-sport run must report that sport; a mixed run reports the modal one, and reports
    /// the *same* one every time it's asked (ties broken by `Sport.allCases` order, not by
    /// dictionary iteration, which is unordered).
    func testDominantSportIsTheModalSportAndIsStable() {
        let mixed = BlitzRunSummary(
            config: .default,
            rounds: [round(.whoami, performance: 1, sport: .nba),
                     round(.whoami, performance: 1, sport: .nba),
                     round(.keep4, performance: 1, sport: .nfl)],
            elapsed: 300)
        XCTAssertEqual(BlitzGameView.dominantSport(mixed), .nba)

        let tied = BlitzRunSummary(
            config: .default,
            rounds: [round(.whoami, performance: 1, sport: .nba),
                     round(.keep4, performance: 1, sport: .nfl)],
            elapsed: 300)
        let first = BlitzGameView.dominantSport(tied)
        for _ in 0..<20 {
            XCTAssertEqual(BlitzGameView.dominantSport(tied), first, "tie-break must be stable")
        }

        XCTAssertNil(BlitzGameView.dominantSport(
            BlitzRunSummary(config: .default, rounds: [], elapsed: 0)))
    }

    // MARK: - Config

    func testConfigRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "blitz-config-\(UUID().uuidString)")!
        let config = BlitzConfig(sports: [.nfl, .nba], formats: [.whoami, .overunder], duration: .three)
        config.save(to: defaults)
        XCTAssertEqual(BlitzConfig.load(from: defaults), config)
    }

    /// A saved config that can't serve a board (an older build's shape, a hand-edited plist)
    /// falls back to the default rather than opening a blitz that dead-ends on Start.
    func testUnplayableSavedConfigFallsBackToTheDefault() {
        let defaults = UserDefaults(suiteName: "blitz-config-\(UUID().uuidString)")!
        BlitzConfig(sports: [], formats: [], duration: .one).save(to: defaults)
        XCTAssertEqual(BlitzConfig.load(from: defaults), .default)
        XCTAssertTrue(BlitzConfig.default.isPlayable)
    }

    /// The default must be playable without an entitlement — a first run that opens the paywall
    /// on Start is a bad first impression, and NFL is the sport no tier gates.
    func testDefaultConfigNeedsNoEntitlement() {
        for sport in BlitzConfig.default.sports {
            XCTAssertTrue(Entitlements.free.canSelect(SportFilter(rawValue: sport.rawValue) ?? .all),
                          "\(sport.rawValue) is Pro-gated and can't be the blitz default")
        }
    }

    /// The setup screen's honesty line. An all-formats five-minute run really is only a handful
    /// of boards, and trimming the mix really does multiply that — if these ever stop being true
    /// the caption is lying to the player about the dial they're turning.
    func testEstimatedBoardsRewardsTrimmingTheMix() {
        let everything = BlitzConfig(sports: [.nfl], formats: Set(BlitzFormat.allCases), duration: .five)
        let fastOnly = BlitzConfig(sports: [.nfl], formats: [.overunder], duration: .five)
        XCTAssertGreaterThan(fastOnly.estimatedBoards, everything.estimatedBoards * 5)
        XCTAssertLessThan(everything.estimatedBoards, 10)
        // Never zero, and never negative — the caption reads "About N puzzles".
        for duration in BlitzDuration.allCases {
            for format in BlitzFormat.allCases {
                let config = BlitzConfig(sports: [.nfl], formats: [format], duration: duration)
                XCTAssertGreaterThanOrEqual(config.estimatedBoards, 1)
            }
        }
    }

    func testOrderedAccessorsFollowCanonicalOrderNotSetOrder() {
        let config = BlitzConfig(sports: Set(Sport.allCases),
                                 formats: Set(BlitzFormat.allCases), duration: .one)
        XCTAssertEqual(config.orderedSports, Sport.allCases)
        XCTAssertEqual(config.orderedFormats, BlitzFormat.allCases)
    }

    // MARK: - What a sport can actually serve

    /// **Tennis cannot ever have a Journeyman board**, and blitz has to know that rather than
    /// discover it as an empty pool.
    ///
    /// Journeyman's board is a club history, and a tour player has a nationality instead. It is a
    /// category fact, not a backfill waiting to happen: `tools/ingest/journeyman.py`'s
    /// `MIN_STINTS` is keyed `{nfl, nba, baseball, soccer}` and never had a tennis entry, and the
    /// live pool agrees (2026-08-25: 158/150/158/87 boards, 0 for tennis).
    func testJourneymanIsUnavailableForTennisAndOnlyTennis() {
        XCTAssertFalse(Sport.tennis.hasClubCareers)
        for sport in Sport.allCases where sport != .tennis {
            XCTAssertTrue(sport.hasClubCareers, sport.rawValue)
        }
        XCTAssertFalse(BlitzFormat.journeyman.isAvailable(for: .tennis))
        for format in BlitzFormat.allCases {
            for sport in Sport.allCases where !(format == .journeyman && sport == .tennis) {
                XCTAssertTrue(format.isAvailable(for: sport), "\(format.rawValue)/\(sport.rawValue)")
            }
        }
    }

    /// The estimate has to describe the run the player will actually get: an all-formats tennis
    /// blitz *is* a three-format blitz, so ticking Journeyman must not move the number.
    ///
    /// Asserted as an equality against the explicit three-format config rather than as "tennis
    /// beats NFL". The mean par really does drop (84.5s to 72.7s) but `estimatedBoards` rounds,
    /// and at 1/3/5 minutes both sides round to the same integer — so a greater-than here would
    /// have been a claim the UI can't actually show. The honest property is that the unservable
    /// format contributes nothing.
    func testTennisEstimateIgnoresTheFormatItCannotServe() {
        let all = Set(BlitzFormat.allCases)
        for duration in BlitzDuration.allCases {
            let ticked = BlitzConfig(sports: [.tennis], formats: all, duration: duration)
            let honest = BlitzConfig(sports: [.tennis],
                                     formats: [.keep4, .whoami, .overunder], duration: duration)
            XCTAssertEqual(ticked.servableFormats, honest.servableFormats)
            XCTAssertEqual(ticked.estimatedBoards, honest.estimatedBoards,
                           "Journeyman must not be counted in a tennis estimate (\(duration.rawValue)s)")
        }

        XCTAssertEqual(BlitzConfig(sports: [.nfl], formats: all, duration: .five).servableFormats,
                       BlitzFormat.allCases)
        // Adding a club sport brings Journeyman back without the player re-ticking anything.
        XCTAssertEqual(BlitzConfig(sports: [.tennis, .nba], formats: all, duration: .five)
            .servableFormats, BlitzFormat.allCases)
    }

    /// A config whose every ticked format is unservable can't deal a board, so it must not read
    /// as playable — otherwise Start sails through into the empty state.
    func testTennisPlusJourneymanOnlyIsNotPlayable() {
        XCTAssertFalse(BlitzConfig(sports: [.tennis], formats: [.journeyman], duration: .one)
            .isPlayable)
        XCTAssertTrue(BlitzConfig(sports: [.tennis], formats: [.journeyman, .whoami], duration: .one)
            .isPlayable)
        XCTAssertTrue(BlitzConfig(sports: [.tennis, .soccer], formats: [.journeyman], duration: .one)
            .isPlayable)
    }

    /// Such a config is also what an older build (or a lapsed entitlement) can leave in defaults,
    /// so loading one must fall back rather than open a dead-end blitz.
    func testAnUnservableSavedConfigFallsBack() {
        let defaults = UserDefaults(suiteName: "blitz-unservable-\(UUID().uuidString)")!
        BlitzConfig(sports: [.tennis], formats: [.journeyman], duration: .three).save(to: defaults)
        XCTAssertEqual(BlitzConfig.load(from: defaults), .default)
    }

    // MARK: - Personal bests

    func testHighScoresAreKeptPerDurationAndATieIsNotABest() {
        let defaults = UserDefaults(suiteName: "blitz-best-\(UUID().uuidString)")!
        let store = LocalBlitzStore(defaults: defaults)

        XCTAssertTrue(store.recordScore(500, for: .one))
        XCTAssertEqual(store.highScore(for: .one), 500)
        // A one-minute best says nothing about the five-minute board.
        XCTAssertEqual(store.highScore(for: .five), 0)
        XCTAssertFalse(store.recordScore(500, for: .one), "a tie must not read as NEW BEST")
        XCTAssertFalse(store.recordScore(499, for: .one))
        XCTAssertTrue(store.recordScore(501, for: .one))
        XCTAssertEqual(store.highScore(for: .one), 501)
    }

    // MARK: - Cross-type wiring

    /// Blitz must not collect an M25 speed bonus: a run is already priced on speed (finishing a
    /// board sooner is what buys the next one), so a par here would charge the same second twice.
    /// It shares that nil with the two other formats whose own mechanics pace them.
    func testBlitzHasNoSpeedParSoSpeedIsNeverPricedTwice() {
        XCTAssertNil(SpeedMultiplier.par(for: GameFormatKind.blitz))
        XCTAssertEqual(SpeedMultiplier.points(1000, startedAt: Date().addingTimeInterval(-1),
                                              kind: .blitz), 1000)
    }

    /// Every blitzable format maps onto the format kind the career log will file its boards
    /// under, and onto the par the purse is built from. A new case that forgot either would score
    /// as zero-length (division by par) or file under the wrong format.
    func testEveryBlitzFormatHasAKindAndAPositivePar() {
        for format in BlitzFormat.allCases {
            XCTAssertGreaterThan(format.parSeconds, 0, format.rawValue)
            XCTAssertFalse(format.displayName.isEmpty, format.rawValue)
            XCTAssertFalse(format.symbol.isEmpty, format.rawValue)
            XCTAssertNotEqual(format.kind, .blitz,
                              "a board's kind is its own format's, never the run's")
        }
    }

    /// The three row-backed blitz formats are the same three `PuzzleFormat` knows, and Over/Under
    /// is deliberately the one without a row — the same absence `PuzzleFormat` documents.
    func testOnlyOverUnderLacksAPuzzleRow() {
        XCTAssertNil(BlitzFormat.overunder.puzzleFormat)
        for format in BlitzFormat.allCases where format != .overunder {
            XCTAssertNotNil(format.puzzleFormat, format.rawValue)
        }
        XCTAssertEqual(Set(BlitzFormat.allCases.compactMap(\.puzzleFormat)),
                       [.keep4, .whoami, .journeyman],
                       "The Grid stays out of blitz — a nine-cell board is a session, not a round")
    }

    // MARK: - Per-round breakdown (M31: the result screen's expandable list)

    /// The list on the result screen has to reconcile against the number above it. `rows` is the
    /// same fold `rawTotal` performs, and this is what keeps it that way — a breakdown that
    /// disagreed with the headline would be worse than showing no breakdown at all.
    func testBreakdownRowsSumToRawTotal() {
        let rounds = [
            round(.keep4, performance: 0.90, cleared: true),
            round(.overunder, performance: 1.0, cleared: true),
            round(.whoami, performance: 0.0, cleared: false),
            round(.overunder, performance: 0.0, cleared: false),
            round(.journeyman, performance: 0.75, cleared: true),
        ]
        let rows = BlitzScoring.rows(rounds)
        XCTAssertEqual(rows.count, rounds.count)
        XCTAssertEqual(rows.map(\.points).reduce(0, +), BlitzScoring.rawTotal(rounds),
                       "Per-round points must sum to the run's raw total")
    }

    /// The combo is a property of the sequence, so each row must carry the multiplier it actually
    /// received — not one recomputed from its own position.
    func testBreakdownCarriesTheComboEachRoundActuallyReceived() {
        let rounds = [
            round(.keep4, performance: 0.9, cleared: true),      // combo 0 → x1.0
            round(.keep4, performance: 0.9, cleared: true),      // combo 1 → x1.1
            round(.keep4, performance: 0.9, cleared: true),      // combo 2 → x1.2
            round(.overunder, performance: 0.0, cleared: false), // loss: never multiplied
            round(.keep4, performance: 0.9, cleared: true),      // streak reset → x1.0
        ]
        let rows = BlitzScoring.rows(rounds)
        XCTAssertEqual(rows[0].combo, 1.0, accuracy: 0.0001)
        XCTAssertEqual(rows[1].combo, 1.1, accuracy: 0.0001)
        XCTAssertEqual(rows[2].combo, 1.2, accuracy: 0.0001)
        XCTAssertEqual(rows[3].combo, 1.0, accuracy: 0.0001, "The combo must never scale a loss")
        XCTAssertEqual(rows[4].combo, 1.0, accuracy: 0.0001, "A miss resets the streak")
        XCTAssertFalse(rows[0].comboApplied)
        XCTAssertTrue(rows[1].comboApplied)
    }

    // MARK: - The clock is a hard stop (M31)

    /// Reversed on 2026-08-27: the clock used to gate only the *next* board. It now ends the run
    /// outright, and the board in flight is reported as `cutOff` rather than scored.
    func testExpireEndsTheRunAndNamesTheBoardInFlight() async {
        let session = await BlitzSession(config: BlitzConfig(sports: [.nfl], formats: [.keep4],
                                                             duration: .one))
        await session.beginRound(format: .keep4, sport: .nfl)
        let before = await session.isOver
        XCTAssertFalse(before)

        await session.expire()

        let over = await session.isOver
        XCTAssertTrue(over, "The clock must end the run, not wait for the board")
        let cutOff = await session.cutOff
        XCTAssertEqual(cutOff, BlitzCutOff(format: .keep4, sport: .nfl))
        let rounds = await session.rounds
        XCTAssertTrue(rounds.isEmpty, "An unfinished board must not be scored")
        let summary = await session.summary()
        XCTAssertEqual(summary.total, 0)
    }

    /// A board finished on the same tick the clock ran out was completed — there is nothing to
    /// cut off, and reporting one would show the player a board they actually finished as lost.
    func testAFinishedBoardIsNeverReportedAsCutOff() async {
        let session = await BlitzSession(config: BlitzConfig(sports: [.nfl], formats: [.keep4],
                                                             duration: .one))
        await session.beginRound(format: .keep4, sport: .nfl)
        await session.finishRound(format: .keep4, sport: .nfl, puzzleID: "p1",
                                  performance: 0.9, cleared: true)
        await session.expire()

        let cutOff = await session.cutOff
        XCTAssertNil(cutOff)
        let rounds = await session.rounds
        XCTAssertEqual(rounds.count, 1)
        let summary = await session.summary()
        XCTAssertNil(summary.cutOff)
    }

    /// `expire()` is raced by the deadline task, the foreground re-check and a board landing on
    /// the same tick. Only the first may take effect.
    func testExpireIsIdempotent() async {
        let session = await BlitzSession(config: BlitzConfig(sports: [.nfl], formats: [.whoami],
                                                             duration: .one))
        await session.beginRound(format: .whoami, sport: .nfl)
        await session.expire()
        let first = await session.cutOff

        await session.beginRound(format: .keep4, sport: .nba)  // as if a board were served after
        await session.expire()

        let second = await session.cutOff
        XCTAssertEqual(second, first, "A second expire must not overwrite the first")
    }

}
