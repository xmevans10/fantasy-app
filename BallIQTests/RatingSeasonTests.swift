import XCTest
@testable import BallIQ

/// M5 Phase F — rating seasons. Locks the soft-reset seed math, the parallel per-season local
/// ladder (seed → move → peak), the cross-season reset, and the end-of-season peak-tier derivation.
final class RatingSeasonTests: XCTestCase {

    private var defaults: UserDefaults!
    private var repo: LocalSeasonRatingRepository!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "RatingSeasonTests")
        defaults.removePersistentDomain(forName: "RatingSeasonTests")
        repo = LocalSeasonRatingRepository(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "RatingSeasonTests")
        super.tearDown()
    }

    // MARK: - Seed math (locked values)

    func testSeedHalvesDistanceFromBaseline() {
        XCTAssertEqual(SeasonSeed.seed(fromAllTime: 1000), 1000)  // at baseline → baseline
        XCTAssertEqual(SeasonSeed.seed(fromAllTime: 1400), 1200)  // +400 → +200
        XCTAssertEqual(SeasonSeed.seed(fromAllTime: 1800), 1400)  // Legend all-time → Platinum seed
        XCTAssertEqual(SeasonSeed.seed(fromAllTime: 800), 900)    // below baseline halves too
    }

    func testSeedNeverNegative() {
        XCTAssertEqual(SeasonSeed.seed(fromAllTime: 0), 500)
        XCTAssertGreaterThanOrEqual(SeasonSeed.seed(fromAllTime: -10_000), 0)
    }

    // MARK: - Local per-season ladder

    func testUnseededSeasonReadsTheSeed() {
        XCTAssertFalse(repo.hasStored(seasonID: 1, sport: .nfl))
        XCTAssertEqual(repo.rating(seasonID: 1, sport: .nfl, seed: 1200), 1200)
        XCTAssertEqual(repo.peak(seasonID: 1, sport: .nfl, seed: 1200), 1200)
    }

    func testApplySeedsThenMovesFromTheSeedNotTheBaseline() {
        // A strong performance from a 1200 seed must start at 1200, not 1000.
        let change = repo.apply(GameOutcome(format: .grid, sport: .nfl, performance: 0.9),
                                seasonID: 1, seed: 1200, date: Date())
        XCTAssertEqual(change.old, 1200)
        XCTAssertGreaterThan(change.new, 1200)
        XCTAssertTrue(repo.hasStored(seasonID: 1, sport: .nfl))
        // Subsequent reads ignore the seed once stored.
        XCTAssertEqual(repo.rating(seasonID: 1, sport: .nfl, seed: 9999), change.new)
    }

    func testPeakIsAHighWaterMarkThatALossDoesNotLower() {
        let up = repo.apply(GameOutcome(format: .grid, sport: .nba, performance: 0.95),
                            seasonID: 2, seed: 1000, date: Date())
        let peakAfterWin = repo.peak(seasonID: 2, sport: .nba, seed: 1000)
        XCTAssertEqual(peakAfterWin, up.new)

        let down = repo.apply(GameOutcome(format: .keep4Normal, sport: .nba, performance: 0.0),
                              seasonID: 2, seed: 1000, date: Date())
        XCTAssertLessThan(down.new, up.new)                       // rating dropped
        XCTAssertEqual(repo.peak(seasonID: 2, sport: .nba, seed: 1000), peakAfterWin)  // peak held
    }

    func testDifferentSeasonIsAFreshLadder() {
        _ = repo.apply(GameOutcome(format: .grid, sport: .nfl, performance: 0.9),
                       seasonID: 1, seed: 1200, date: Date())
        // Season 2 has never been played → still reads its own (new) seed, unaffected by season 1.
        XCTAssertFalse(repo.hasStored(seasonID: 2, sport: .nfl))
        XCTAssertEqual(repo.rating(seasonID: 2, sport: .nfl, seed: 1300), 1300)
    }

    // MARK: - Full-cycle simulation + badge derivation

    /// Simulate a season of strong ranked play, then the rollover's peak-tier badge derivation, then
    /// the *next* season re-seeding from the (now higher) all-time rating — the whole 8-week loop.
    func testFullSeasonCycleProducesBadgeAndReseeds() {
        let sport = Sport.nfl
        // Season 5: seed from a 1400 all-time snapshot → 1200; grind a bunch of strong games.
        let allTimeBefore = 1400
        let seedS5 = SeasonSeed.seed(fromAllTime: allTimeBefore)
        XCTAssertEqual(seedS5, 1200)
        for _ in 0..<40 {
            _ = repo.apply(GameOutcome(format: .grid, sport: sport, performance: 0.85),
                           seasonID: 5, seed: seedS5, date: Date())
        }
        let peakS5 = repo.peak(seasonID: 5, sport: sport, seed: seedS5)
        XCTAssertGreaterThan(peakS5, 1400)                       // climbed above the seed

        // Rollover derives the cosmetic badge from the peak (same mapping the Swift badge display uses).
        let badgeTier = Tier.forRating(peakS5)
        XCTAssertTrue([.platinum, .diamond, .legend].contains(badgeTier))

        // Season 6 opens: a fresh row, re-seeded from the current (higher) all-time rating — the
        // soft-reset. It must start below the peak reached in season 5, proving the reset happened.
        let seedS6 = SeasonSeed.seed(fromAllTime: peakS5)
        XCTAssertLessThan(seedS6, peakS5)
        XCTAssertFalse(repo.hasStored(seasonID: 6, sport: sport))
        XCTAssertEqual(repo.rating(seasonID: 6, sport: sport, seed: seedS6), seedS6)
    }

    // MARK: - Decode regression (fractional seconds + convertFromSnakeCase)

    /// The `current_rating_season()` RPC returns Postgres `timestamptz` with microsecond fractional
    /// seconds and snake_case columns. Locks both fixes: `SupabaseDate` microsecond parsing, and
    /// camelCase properties (no explicit snake CodingKeys) so `.convertFromSnakeCase` can map them.
    func testRatingSeasonDecodesRpcShape() throws {
        let json = #"[{"id":1,"starts_at":"2026-07-20T00:03:09.088143+00:00","ends_at":"2026-09-14T00:03:09.088143+00:00","status":"active"}]"#
            .data(using: .utf8)!
        let seasons = try JSONDecoder.supabase.decode([RatingSeason].self, from: json)
        XCTAssertEqual(seasons.first?.id, 1)
        XCTAssertEqual(seasons.first?.status, "active")
        // 8-week span survives the microsecond-precision round trip.
        let span = seasons.first!.endsAt.timeIntervalSince(seasons.first!.startsAt)
        XCTAssertEqual(span, Double(RatingSeasonRules.cycleWeeks) * 7 * 86_400, accuracy: 1)
    }

    func testSeasonStandingRowDecodesRpcShape() throws {
        let json = #"[{"rank":1,"user_id":"u1","username":"ace","avatar":null,"rating":1520,"peak_rating":1600,"is_me":true}]"#
            .data(using: .utf8)!
        let rows = try JSONDecoder.supabase.decode([SeasonStandingRow].self, from: json)
        XCTAssertEqual(rows.first?.userId, "u1")
        XCTAssertEqual(rows.first?.peakRating, 1600)
        XCTAssertTrue(rows.first?.isMe == true)
        XCTAssertEqual(rows.first?.tier, .platinum)   // 1520 → Platinum band
    }

    func testSupabaseDateParsesMicrosecondsAndPlain() {
        XCTAssertNotNil(SupabaseDate.parse("2026-07-20T00:03:09.088143+00:00"))  // microseconds
        XCTAssertNotNil(SupabaseDate.parse("2026-07-20T00:03:09+00:00"))          // whole seconds
        XCTAssertNil(SupabaseDate.parse("not a date"))
    }

    // MARK: - Countdown labels

    func testRemainingTextUsesCoarseUnitsForALongSpan() {
        let now = Date(timeIntervalSince1970: 0)
        let inThreeWeeks = now.addingTimeInterval(21 * 86_400 + 5 * 3_600)
        XCTAssertEqual(RatingSeasonRules.remainingText(now: now, end: inThreeWeeks), "21d 5h")

        let inTwoHours = now.addingTimeInterval(2 * 3_600 + 30 * 60)
        XCTAssertEqual(RatingSeasonRules.remainingText(now: now, end: inTwoHours), "2h 30m")

        XCTAssertEqual(RatingSeasonRules.remainingText(now: now, end: now), "0m")  // ended
    }
}
