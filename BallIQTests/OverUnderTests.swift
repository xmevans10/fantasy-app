import XCTest
@testable import BallIQ

final class OverUnderTests: XCTestCase {

    private func season(_ id: String, stats: [String: Double], position: String = "RB") -> CatalogSeason {
        CatalogSeason(id: id, sport: .nfl, name: "Player \(id)", teamAbbr: "SF",
                      seasonYear: 2020, position: position, stats: stats)
    }

    private var pool: [CatalogSeason] {
        (0..<20).map { i in
            season("p\(i)", stats: ["rushing_yards": Double(800 + i * 40), "rushing_tds": Double(4 + i)])
        }
    }

    // MARK: - Generator determinism

    func testSameSeedProducesIdenticalRound() {
        let date = ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!
        let a = OverUnderRoundGenerator.round(from: pool, sport: .nfl, date: date, index: 0)
        let b = OverUnderRoundGenerator.round(from: pool, sport: .nfl, date: date, index: 0)
        XCTAssertEqual(a, b)
    }

    func testDifferentIndexProducesDifferentSeed() {
        let date = ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!
        let rounds = (0..<10).compactMap { OverUnderRoundGenerator.round(from: pool, sport: .nfl, date: date, index: $0) }
        let ids = Set(rounds.map(\.id))
        XCTAssertEqual(ids.count, rounds.count, "each index should get its own id")
    }

    func testDifferentDayProducesDifferentRound() {
        let day1 = ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!
        let day2 = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        let a = OverUnderRoundGenerator.round(from: pool, sport: .nfl, date: day1, index: 0)
        let b = OverUnderRoundGenerator.round(from: pool, sport: .nfl, date: day2, index: 0)
        // Not guaranteed to always differ in every field, but the id (which encodes the day) must.
        XCTAssertNotEqual(a?.id, b?.id)
    }

    func testThresholdNeverEqualsActualValue() {
        let date = ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!
        for i in 0..<200 {
            guard let round = OverUnderRoundGenerator.round(from: pool, sport: .nfl, date: date, index: i) else { continue }
            XCTAssertNotEqual(round.threshold, round.actualValue, "round \(i) had a tied threshold")
        }
    }

    func testThresholdStaysWithinStatBounds() {
        let date = ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!
        for i in 0..<200 {
            guard let round = OverUnderRoundGenerator.round(from: pool, sport: .nfl, date: date, index: i) else { continue }
            XCTAssertGreaterThanOrEqual(round.threshold, round.stat.lo)
            XCTAssertLessThanOrEqual(round.threshold, round.stat.hi)
        }
    }

    func testEmptyPoolReturnsNil() {
        let date = Date()
        XCTAssertNil(OverUnderRoundGenerator.round(from: [], sport: .nfl, date: date, index: 0))
    }

    /// Regression: a real NFL row carries every offensive stat column regardless of position
    /// (nflverse's own export shape — see `nfl_nflverse.py`), so a WR's raw `stats` dict still
    /// has a `passing_yards` key, just zeroed. An unscoped presence filter picked that up and
    /// produced an "Over/Under 3000 passing yards" round for a receiver.
    func testStatSelectionNeverCrossesPosition() {
        let wr = season("wr", stats: [
            "passing_yards": 0, "passing_tds": 0, "interceptions": 0, "attempts": 0,
            "completions": 0, "completion_pct": 0, "carries": 2, "rushing_yards": 12,
            "rushing_tds": 0, "ypc": 6, "receptions": 70, "targets": 100,
            "receiving_yards": 900, "receiving_tds": 6, "ypr": 12.9,
        ], position: "WR")
        let date = ISO8601DateFormatter().date(from: "2026-07-07T00:00:00Z")!
        for i in 0..<200 {
            guard let round = OverUnderRoundGenerator.round(from: [wr], sport: .nfl, date: date, index: i) else { continue }
            XCTAssertFalse(round.stat.key.hasPrefix("passing_"), "WR got a passing stat: \(round.stat.key)")
        }
    }

    func testIsOverMatchesActualVsThreshold() {
        let s = season("solo", stats: ["rushing_yards": 1000])
        let stat = ScoringStat.find("rushing_yards", sport: .nfl)!
        let over = OverUnderRound(id: "x", player: s, stat: stat, threshold: 900)
        let under = OverUnderRound(id: "y", player: s, stat: stat, threshold: 1100)
        XCTAssertTrue(over.isOver)
        XCTAssertFalse(under.isOver)
    }

    // MARK: - Scoring / combo

    func testComboMultiplierIncreasesWithStreak() {
        XCTAssertEqual(OverUnderScoring.comboMultiplier(consecutiveCorrect: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(OverUnderScoring.comboMultiplier(consecutiveCorrect: 5), 1.5, accuracy: 0.001)
    }

    func testComboMultiplierCaps() {
        XCTAssertEqual(OverUnderScoring.comboMultiplier(consecutiveCorrect: 10), 2.0, accuracy: 0.001)
        XCTAssertEqual(OverUnderScoring.comboMultiplier(consecutiveCorrect: 999), 2.0, accuracy: 0.001,
                      "should cap, not grow unboundedly")
    }

    func testPointsScaleWithCombo() {
        XCTAssertEqual(OverUnderScoring.points(consecutiveCorrectBeforeThisRound: 0), 100)
        XCTAssertEqual(OverUnderScoring.points(consecutiveCorrectBeforeThisRound: 5), 150)
    }

    // MARK: - LivesBank

    func testInitialLivesIsFull() {
        XCTAssertEqual(LivesBank.initial.count, LivesBank.maxLives)
        XCTAssertFalse(LivesBank.initial.isEmpty)
    }

    func testLosingALifeDecrementsAndStampsTime() {
        let now = Date()
        let after = LivesBank.initial.losingALife(now: now)
        XCTAssertEqual(after.count, LivesBank.maxLives - 1)
        XCTAssertEqual(after.lastLostAt, now)
    }

    func testLivesNeverGoNegative() {
        let now = Date()
        var lives = LivesBank.initial
        for _ in 0..<10 { lives = lives.losingALife(now: now) }
        XCTAssertEqual(lives.count, 0)
        XCTAssertTrue(lives.isEmpty)
    }

    func testNoRegenBeforeAFullHourElapses() {
        let lost = Date()
        let bank = LivesBank(count: 1, lastLostAt: lost)
        let stillLow = bank.regenerated(now: lost.addingTimeInterval(59 * 60))
        XCTAssertEqual(stillLow.count, 1)
    }

    func testRegensOneLifePerFullHourElapsed() {
        let lost = Date()
        let bank = LivesBank(count: 1, lastLostAt: lost)
        let regened = bank.regenerated(now: lost.addingTimeInterval(2 * 3600 + 61))
        XCTAssertEqual(regened.count, 3, "1 starting + 2 full hours elapsed, capped at maxLives")
    }

    func testRegenCapsAtMaxLivesAndClearsTimestamp() {
        let lost = Date()
        let bank = LivesBank(count: 2, lastLostAt: lost)
        let regened = bank.regenerated(now: lost.addingTimeInterval(10 * 3600))
        XCTAssertEqual(regened.count, LivesBank.maxLives)
        XCTAssertNil(regened.lastLostAt, "fully regenerated — no more decay to track")
    }

    func testPartialRegenAdvancesTimestampRatherThanResetting() {
        let lost = Date()
        let bank = LivesBank(count: 1, lastLostAt: lost)
        let regened = bank.regenerated(now: lost.addingTimeInterval(3600 + 100)) // 1 full hour + a bit
        XCTAssertEqual(regened.count, 2)
        // The consumed hour is credited; the remainder (100s) still counts toward the next life.
        XCTAssertEqual(regened.lastLostAt, lost.addingTimeInterval(3600))
    }

    func testFullLivesNeverRegenBeyondMax() {
        let full = LivesBank.initial
        XCTAssertEqual(full.regenerated(now: Date().addingTimeInterval(100_000)), full)
    }
}
