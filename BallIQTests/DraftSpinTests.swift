import XCTest
@testable import BallIQ

final class DraftSpinTests: XCTestCase {

    private func season(_ id: String, position: String, stats: [String: Double],
                       team: String = "SF", year: Int = 2020) -> CatalogSeason {
        CatalogSeason(id: id, sport: .nfl, name: "Player \(id)", teamAbbr: team,
                      seasonYear: year, position: position, stats: stats)
    }

    private var nflPool: [CatalogSeason] {
        let qbs: [CatalogSeason] = (0..<10).map { i in
            season("qb\(i)", position: "QB", stats: ["passing_yards": Double(3500 + i * 100), "passing_tds": Double(25 + i)])
        }
        let rbs: [CatalogSeason] = (0..<10).map { i in
            season("rb\(i)", position: "RB", stats: ["rushing_yards": Double(900 + i * 50), "rushing_tds": Double(6 + i)])
        }
        let wrs: [CatalogSeason] = (0..<10).map { i in
            season("wr\(i)", position: "WR", stats: ["receiving_yards": Double(1000 + i * 50), "receptions": Double(70 + i)])
        }
        let tes: [CatalogSeason] = (0..<10).map { i in
            season("te\(i)", position: "TE", stats: ["receiving_yards": Double(600 + i * 30), "receptions": Double(50 + i)])
        }
        return qbs + rbs + wrs + tes
    }

    /// A single real (team, year) roster with enough distinct players to fill every NFL
    /// formation role (QB, 2×WR, 2×RB, TE) *and* leave real surplus for FLEX (RB/WR/TE) —
    /// 2 QB, 4 RB, 4 WR, 3 TE, all "SF"/2020, matching real NFL team-year depth (median WR
    /// depth ~6, RB ~4, TE ~3 per the live catalog).
    private var richNFLRoster: [CatalogSeason] {
        var roster: [CatalogSeason] = []
        for i in 0..<2 {
            roster.append(season("qb\(i)", position: "QB", stats: ["passing_yards": Double(3800 + i * 200), "passing_tds": Double(28 + i)]))
        }
        for i in 0..<4 {
            roster.append(season("rb\(i)", position: "RB", stats: ["rushing_yards": Double(1000 + i * 100), "rushing_tds": Double(7 + i)]))
        }
        for i in 0..<4 {
            roster.append(season("wr\(i)", position: "WR", stats: ["receiving_yards": Double(1000 + i * 100), "receptions": Double(70 + i)]))
        }
        for i in 0..<3 {
            roster.append(season("te\(i)", position: "TE", stats: ["receiving_yards": Double(600 + i * 60), "receptions": Double(45 + i)]))
        }
        return roster
    }

    // MARK: - Constraint / lineup shape

    func testSportOfTheDayIsDeterministic() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        XCTAssertEqual(DraftSpinConstraint.sportOfTheDay(date), DraftSpinConstraint.sportOfTheDay(date))
    }

    func testLineupSlotsMatchExpectedShapePerSport() {
        XCTAssertEqual(DraftSpinConstraint.lineupSlots(for: .nfl).map(\.role), ["QB", "RB", "WR", "TE", "FLEX", "FLEX"])
        XCTAssertEqual(DraftSpinConstraint.lineupSlots(for: .nba).map(\.role), ["G", "G", "F", "F", "C"])
        XCTAssertEqual(DraftSpinConstraint.lineupSlots(for: .baseball).map(\.role),
                       ["Hitter", "Hitter", "Hitter", "Hitter", "Pitcher", "Pitcher"])
        XCTAssertTrue(DraftSpinConstraint.lineupSlots(for: .nfl).allSatisfy { $0.pick == nil })
    }

    // MARK: - spinRound

    func testSpinRoundIsDeterministicForSameRoundAndReroll() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        let a = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl, date: date,
                                              roundIndex: 0, reroll: 0, openRoles: ["QB", "RB", "WR", "TE", "FLEX", "FLEX"])
        let b = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl, date: date,
                                              roundIndex: 0, reroll: 0, openRoles: ["QB", "RB", "WR", "TE", "FLEX", "FLEX"])
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.team, b?.team)
        XCTAssertEqual(a?.year, b?.year)
    }

    func testSpinRoundOnlyPicksATeamYearWithARealCandidateForAnOpenRole() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        // Only QBs exist; asking for a round where only RB/TE/FLEX are open must fail to spin —
        // there is nothing real to place — rather than spin an unplaceable team/year.
        let qbOnly = (0..<3).map { season("qb\($0)", position: "QB", stats: ["passing_yards": 3800, "passing_tds": 28]) }
        let picked = DraftSpinConstraint.spinRound(from: qbOnly, sport: .nfl, date: date,
                                                   roundIndex: 0, reroll: 0, openRoles: ["RB", "TE"])
        XCTAssertNil(picked)
    }

    func testSpinRoundRerollCanChangeTheResult() {
        // Two real, equally-viable team/years — across a spread of reroll values, at least one
        // reroll should land on a different team than reroll 0 (proves reroll actually reseeds).
        let pool = [
            season("qb-a", position: "QB", stats: ["passing_yards": 3800, "passing_tds": 28], team: "SF", year: 2020),
            season("qb-b", position: "QB", stats: ["passing_yards": 3900, "passing_tds": 29], team: "DAL", year: 2020),
        ]
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        let first = DraftSpinConstraint.spinRound(from: pool, sport: .nfl, date: date, roundIndex: 0, reroll: 0, openRoles: ["QB"])
        var sawDifferentTeam = false
        for reroll in 1...5 {
            let rerolled = DraftSpinConstraint.spinRound(from: pool, sport: .nfl, date: date, roundIndex: 0, reroll: reroll, openRoles: ["QB"])
            if rerolled?.team != first?.team { sawDifferentTeam = true }
        }
        XCTAssertTrue(sawDifferentTeam, "at least one reroll should change the spun team across 5 attempts")
    }

    func testSpinRoundEmptyPoolReturnsNil() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        XCTAssertNil(DraftSpinConstraint.spinRound(from: [], sport: .nfl, date: date, roundIndex: 0, reroll: 0, openRoles: ["QB"]))
    }

    // MARK: - eligibleSlots

    func testEligibleSlotsMatchesExactRoleAndFlex() {
        let slots = DraftSpinConstraint.lineupSlots(for: .nfl)
        let rbEligible = DraftSpinConstraint.eligibleSlots(for: "RB", in: slots, sport: .nfl)
        XCTAssertEqual(Set(rbEligible.map(\.role)), ["RB", "FLEX"])

        let qbEligible = DraftSpinConstraint.eligibleSlots(for: "QB", in: slots, sport: .nfl)
        XCTAssertEqual(Set(qbEligible.map(\.role)), ["QB"], "QB is not FLEX-eligible")
    }

    func testEligibleSlotsExcludesAlreadyFilledSlots() {
        var slots = DraftSpinConstraint.lineupSlots(for: .nfl)
        slots[slots.firstIndex(where: { $0.role == "RB" })!].pick = season("rb-filled", position: "RB", stats: [:])
        let stillOpen = slots.filter { $0.pick == nil }
        let eligible = DraftSpinConstraint.eligibleSlots(for: "RB", in: stillOpen, sport: .nfl)
        // The dedicated RB slot is now filled — both remaining FLEX slots (RB-eligible) are
        // still open, and the RB role itself is gone from the open set.
        XCTAssertEqual(eligible.map(\.role), ["FLEX", "FLEX"])
        XCTAssertFalse(stillOpen.contains { $0.role == "RB" })
    }

    func testEligibleSlotsEmptyWhenPositionHasNoOpenMatch() {
        let slots = DraftSpinConstraint.lineupSlots(for: .soccer).filter { $0.role != "GK" }
        let eligible = DraftSpinConstraint.eligibleSlots(for: "GK", in: slots, sport: .soccer)
        XCTAssertTrue(eligible.isEmpty)
    }

    // MARK: - Power (pure normalization)

    func testPowerIsBoundedZeroToOne() {
        for s in nflPool {
            let p = DraftSpinSimulator.power(s, sport: .nfl)
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThanOrEqual(p, 1)
        }
    }

    func testHigherStatsYieldHigherPower() {
        let weak = season("weak", position: "WR", stats: ["receiving_yards": 850, "receptions": 60])
        let strong = season("strong", position: "WR", stats: ["receiving_yards": 1950, "receptions": 145])
        XCTAssertGreaterThan(DraftSpinSimulator.power(strong, sport: .nfl), DraftSpinSimulator.power(weak, sport: .nfl))
    }

    func testEmptyStatsFallBackToNeutralPower() {
        let blank = season("blank", position: "WR", stats: [:])
        XCTAssertEqual(DraftSpinSimulator.power(blank, sport: .nfl), 0.3, accuracy: 0.001)
    }

    // MARK: - Simulator

    private var fixedLineup: [CatalogSeason] {
        [
            season("qb0", position: "QB", stats: ["passing_yards": 4200, "passing_tds": 32]),
            season("rb0", position: "RB", stats: ["rushing_yards": 1300, "rushing_tds": 11]),
            season("wr0", position: "WR", stats: ["receiving_yards": 1400, "receptions": 95]),
            season("te0", position: "TE", stats: ["receiving_yards": 750, "receptions": 62]),
        ]
    }

    func testSimulationIsDeterministicForSameLineupAndDate() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        let a = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, date: date)
        let b = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, date: date)
        XCTAssertEqual(a, b)
    }

    func testSimulationDiffersAcrossDifferentDays() {
        let day1 = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        let day2 = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!
        let a = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, date: day1)
        let b = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, date: day2)
        XCTAssertNotEqual(a, b)
    }

    func testWinsAndLossesAlwaysSumToSeasonLength() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        for sport in Sport.allCases {
            let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: sport, date: date)
            XCTAssertEqual(result.wins + result.losses, DraftSpinSimulator.seasonShape(for: sport).gameCount,
                            "sport: \(sport.rawValue)")
        }
    }

    func testOutcomeTiersMatchWinThresholds() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        for sport in Sport.allCases {
            let shape = DraftSpinSimulator.seasonShape(for: sport)
            let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: sport, date: date)
            switch result.outcome {
            case .champion: XCTAssertGreaterThanOrEqual(result.wins, shape.championshipWins, "sport: \(sport.rawValue)")
            case .madePlayoffs:
                XCTAssertGreaterThanOrEqual(result.wins, shape.playoffWins, "sport: \(sport.rawValue)")
                XCTAssertLessThan(result.wins, shape.championshipWins, "sport: \(sport.rawValue)")
            case .missedPlayoffs: XCTAssertLessThan(result.wins, shape.playoffWins, "sport: \(sport.rawValue)")
            }
        }
    }

    /// Each sport's outcome tiers should be reachable at roughly comparable odds (matched by
    /// `seasonShape`'s own design) — a coarse sanity check, not a precise distribution test.
    /// Every sport's title must also be distinct text so the result screen never shows the
    /// wrong sport's vocabulary.
    func testOutcomeTitlesAreDistinctPerSport() {
        for sport in Sport.allCases {
            let titles = Set(DraftSpinResult.Outcome.allCases.map { $0.title(for: sport) })
            XCTAssertEqual(titles.count, DraftSpinResult.Outcome.allCases.count, "sport: \(sport.rawValue)")
        }
    }

    /// Locked-value regression: pins this exact lineup+date+seed sequence's output so a future
    /// refactor of the RNG/scoring math can't silently drift the result.
    func testLockedSimulationValueForFixedLineupAndDate() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, date: date)
        XCTAssertEqual(result.wins, 4)
        XCTAssertEqual(result.losses, 13)
        XCTAssertEqual(result.totalPoints, 481)
        XCTAssertEqual(result.outcome, .missedPlayoffs)
    }

    func testEmptyLineupNeverCrashes() {
        let date = Date()
        for sport in Sport.allCases {
            let result = DraftSpinSimulator.simulate(lineup: [], sport: sport, date: date)
            XCTAssertEqual(result.wins + result.losses, DraftSpinSimulator.seasonShape(for: sport).gameCount,
                            "sport: \(sport.rawValue)")
        }
    }

    /// Locked-value regression for a non-NFL sport: pins soccer's exact output for this
    /// lineup+date+seed so the per-sport `seasonShape` table can't silently drift either.
    func testLockedSimulationValueForNonNFLSport() {
        let date = ISO8601DateFormatter().date(from: "2026-07-08T00:00:00Z")!
        let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .soccer, date: date)
        XCTAssertEqual(result.wins, 22)
        XCTAssertEqual(result.losses, 16)
        XCTAssertEqual(result.totalPoints, 1115)
        XCTAssertEqual(result.outcome, .madePlayoffs)
    }
}
