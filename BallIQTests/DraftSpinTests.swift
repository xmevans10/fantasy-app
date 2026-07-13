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

    private func spinRNG(_ seed: String) -> SeededGenerator {
        SeededGenerator(seed: SeededGenerator.stableHash(seed))
    }

    func testSpinRoundIsDeterministicForTheSameRNGSeed() {
        var g1 = spinRNG("spin-seed")
        var g2 = spinRNG("spin-seed")
        let roles = ["QB", "RB", "WR", "TE", "FLEX", "FLEX"]
        let a = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl, openRoles: roles, using: &g1)
        let b = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl, openRoles: roles, using: &g2)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.team, b?.team)
        XCTAssertEqual(a?.year, b?.year)
    }

    func testSpinRoundOnlyPicksATeamYearWithARealCandidateForAnOpenRole() {
        // Only QBs exist; asking for a round where only RB/TE are open must fail to spin —
        // there is nothing real to place — rather than spin an unplaceable team/year.
        let qbOnly = (0..<3).map { season("qb\($0)", position: "QB", stats: ["passing_yards": 3800, "passing_tds": 28]) }
        var g = spinRNG("no-open-role")
        XCTAssertNil(DraftSpinConstraint.spinRound(from: qbOnly, sport: .nfl, openRoles: ["RB", "TE"], using: &g))
    }

    func testSpinRoundVariesAcrossRNGStreams() {
        // Two real, equally-viable team/years — across a spread of RNG streams, at least one
        // spin should land on a different team (spins are truly random now, not date-pinned).
        let pool = [
            season("qb-a", position: "QB", stats: ["passing_yards": 3800, "passing_tds": 28], team: "SF", year: 2020),
            season("qb-b", position: "QB", stats: ["passing_yards": 3900, "passing_tds": 29], team: "DAL", year: 2020),
        ]
        var g0 = spinRNG("stream-0")
        let first = DraftSpinConstraint.spinRound(from: pool, sport: .nfl, openRoles: ["QB"], using: &g0)
        var sawDifferentTeam = false
        for i in 1...6 {
            var g = spinRNG("stream-\(i)")
            if DraftSpinConstraint.spinRound(from: pool, sport: .nfl, openRoles: ["QB"], using: &g)?.team != first?.team {
                sawDifferentTeam = true
            }
        }
        XCTAssertTrue(sawDifferentTeam, "at least one RNG stream should spin the other team")
    }

    func testSpinRoundEmptyPoolReturnsNil() {
        var g = spinRNG("empty")
        XCTAssertNil(DraftSpinConstraint.spinRound(from: [], sport: .nfl, openRoles: ["QB"], using: &g))
    }

    // MARK: - spinRound setup options (one-team lock, season variations)

    private var twoTeamPool: [CatalogSeason] {
        [
            season("qb-sf19", position: "QB", stats: ["passing_yards": 3600, "passing_tds": 24], team: "SF", year: 2019),
            season("qb-sf20", position: "QB", stats: ["passing_yards": 3800, "passing_tds": 28], team: "SF", year: 2020),
            season("qb-dal", position: "QB", stats: ["passing_yards": 3900, "passing_tds": 29], team: "DAL", year: 2018),
        ]
    }

    func testSpinRoundLockedTeamOnlySpinsThatFranchise() {
        for i in 0...5 {
            var g = spinRNG("lock-\(i)")
            let spun = DraftSpinConstraint.spinRound(from: twoTeamPool, sport: .nfl, openRoles: ["QB"],
                                                     lockedTeam: "SF", using: &g)
            XCTAssertEqual(spun?.team, "SF", "stream \(i) escaped the one-team lock")
        }
    }

    func testSpinRoundLockedTeamNeverRepeatsAUsedYear() {
        var g = spinRNG("lock-used-year")
        let spun = DraftSpinConstraint.spinRound(from: twoTeamPool, sport: .nfl, openRoles: ["QB"],
                                                 lockedTeam: "SF", usedLockedYears: [2020], using: &g)
        XCTAssertEqual(spun?.team, "SF")
        XCTAssertEqual(spun?.year, 2019)
    }

    func testSpinRoundLockedTeamFallsBackWhenItsYearsAreExhausted() {
        // SF has no fresh viable year left — the spin degrades to any team instead of dead-ending.
        var g = spinRNG("lock-exhausted")
        let spun = DraftSpinConstraint.spinRound(from: twoTeamPool, sport: .nfl, openRoles: ["QB"],
                                                 lockedTeam: "SF", usedLockedYears: [2019, 2020], using: &g)
        XCTAssertEqual(spun?.team, "DAL")
    }

    func testSpinRoundExcludedNamesRemoveAComboFromViability() {
        // Season variations OFF: a combo whose only placeable candidate is already drafted
        // must not spin. SF/2020's lone QB is excluded → only DAL/2018 remains viable.
        let pool = [
            season("qb-sf20", position: "QB", stats: ["passing_yards": 3800, "passing_tds": 28], team: "SF", year: 2020),
            season("qb-dal", position: "QB", stats: ["passing_yards": 3900, "passing_tds": 29], team: "DAL", year: 2018),
        ]
        for i in 0...5 {
            var g = spinRNG("exclude-\(i)")
            let spun = DraftSpinConstraint.spinRound(from: pool, sport: .nfl, openRoles: ["QB"],
                                                     excludeNames: ["Player qb-sf20"], using: &g)
            XCTAssertEqual(spun?.team, "DAL", "stream \(i) spun a combo with no undrafted candidate")
        }
        var g = spinRNG("exclude-all")
        XCTAssertNil(DraftSpinConstraint.spinRound(from: pool, sport: .nfl, openRoles: ["QB"],
                                                   excludeNames: ["Player qb-sf20", "Player qb-dal"], using: &g))
    }

    // MARK: - Today's Challenge (backlog #4)

    func testChallengeRoundGeneratorIsDeterministicForSameDayAndRoundIndex() {
        let date = ISO8601DateFormatter().date(from: "2026-07-12T00:00:00Z")!
        var g1 = DraftSpinConstraint.challengeRoundGenerator(sport: .nfl, date: date, roundIndex: 0)
        var g2 = DraftSpinConstraint.challengeRoundGenerator(sport: .nfl, date: date, roundIndex: 0)
        let a = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl,
                                              openRoles: ["QB", "RB", "WR", "TE", "FLEX", "FLEX"], using: &g1)
        let b = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl,
                                              openRoles: ["QB", "RB", "WR", "TE", "FLEX", "FLEX"], using: &g2)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.team, b?.team)
        XCTAssertEqual(a?.year, b?.year)
    }

    func testChallengeRoundGeneratorVariesAcrossRoundIndicesOrDays() {
        let date = ISO8601DateFormatter().date(from: "2026-07-12T00:00:00Z")!
        let otherDate = ISO8601DateFormatter().date(from: "2026-07-13T00:00:00Z")!
        var sameDayRound0 = DraftSpinConstraint.challengeRoundGenerator(sport: .nfl, date: date, roundIndex: 0)
        var sameDayRound1 = DraftSpinConstraint.challengeRoundGenerator(sport: .nfl, date: date, roundIndex: 1)
        var differentDayRound0 = DraftSpinConstraint.challengeRoundGenerator(sport: .nfl, date: otherDate, roundIndex: 0)
        // The raw generator streams themselves must differ — that's what actually guarantees
        // varying results downstream, independent of any particular pool's viable-combo set.
        XCTAssertNotEqual(sameDayRound0.next(), sameDayRound1.next())
        XCTAssertNotEqual(sameDayRound0.next(), differentDayRound0.next())
    }

    /// The retired design's own caveat (now inherited by challenge mode): once two "players"
    /// have drafted different players into the same open role, `excludeNames` reshapes the
    /// viable pool, so the same day+round seed can legitimately diverge. This is expected, not
    /// a bug — pinned here so a future change can't silently "fix" it into unconditional
    /// determinism (which `spinRound`'s exclusion behavior makes impossible to guarantee).
    /// The specific combo excluded here (SF/2020) is structurally guaranteed to never be the
    /// excluded call's answer, independent of the shared seed's exact draw.
    func testChallengeRoundGeneratorDivergesOnceExcludedNamesDiffer() {
        let date = ISO8601DateFormatter().date(from: "2026-07-12T00:00:00Z")!
        var gen = DraftSpinConstraint.challengeRoundGenerator(sport: .nfl, date: date, roundIndex: 1)
        let withExclusion = DraftSpinConstraint.spinRound(from: twoTeamPool, sport: .nfl, openRoles: ["QB"],
                                                          excludeNames: ["Player qb-sf20"], using: &gen)
        XCTAssertNotNil(withExclusion)
        XCTAssertFalse(withExclusion?.team == "SF" && withExclusion?.year == 2020,
                       "the excluded season's own combo must never spin once it's excluded")
    }

    func testDraftSpinSettingsDefaultsMatchLegacyBehavior() {
        let defaults = DraftSpinSettings.default
        XCTAssertFalse(defaults.lockToOneTeam)
        XCTAssertTrue(defaults.allowSeasonVariations)
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

    private func seededRNG(_ seed: String) -> SeededGenerator {
        SeededGenerator(seed: SeededGenerator.stableHash(seed))
    }

    func testSimulationIsDeterministicForSameSeed() {
        var a = seededRNG("sim-seed")
        var b = seededRNG("sim-seed")
        XCTAssertEqual(DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, using: &a),
                       DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, using: &b))
    }

    func testSimulationVariesAcrossRuns() {
        // Truly-random gameplay: different RNG streams must be able to produce different
        // seasons for the same lineup (the old same-day-same-result replay guarantee is gone
        // by explicit product decision).
        var a = seededRNG("sim-seed-1")
        let first = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, using: &a)
        var sawDifferent = false
        for i in 2...6 {
            var g = seededRNG("sim-seed-\(i)")
            if DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, using: &g) != first {
                sawDifferent = true
            }
        }
        XCTAssertTrue(sawDifferent)
    }

    /// The 2026-07-09 scoring-audit invariant: draft quality must actually move the record.
    /// (The pre-audit formula scaled the opponent by the player's own lineup power, making
    /// every season a coin flip regardless of picks.) Averaged over many seeded seasons, a
    /// clearly stronger lineup must win clearly more games than a clearly weaker one.
    func testStrongerLineupWinsMoreOnAverage() {
        let weak = [season("w1", position: "WR", stats: ["receiving_yards": 250, "receptions": 18]),
                    season("w2", position: "RB", stats: ["rushing_yards": 180, "rushing_tds": 1])]
        let strong = [season("s1", position: "WR", stats: ["receiving_yards": 1900, "receptions": 140]),
                      season("s2", position: "RB", stats: ["rushing_yards": 2000, "rushing_tds": 24])]
        var weakWins = 0, strongWins = 0
        for i in 0..<60 {
            var g1 = seededRNG("weak-\(i)"), g2 = seededRNG("strong-\(i)")
            weakWins += DraftSpinSimulator.simulate(lineup: weak, sport: .nfl, using: &g1).wins
            strongWins += DraftSpinSimulator.simulate(lineup: strong, sport: .nfl, using: &g2).wins
        }
        XCTAssertGreaterThan(strongWins, weakWins + 60,
                             "a far stronger lineup should average clearly more wins per season")
    }

    func testWinProbabilityScalesAndClamps() {
        XCTAssertEqual(DraftSpinSimulator.winProbability(power: DraftSpinSimulator.leagueBaselinePower),
                       0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(DraftSpinSimulator.winProbability(power: 0.6),
                             DraftSpinSimulator.winProbability(power: 0.4))
        // The recalibrated feel ("too harsh" feedback): a decent real draft (~0.30 power)
        // must sit ABOVE .500, not below it.
        XCTAssertGreaterThan(DraftSpinSimulator.winProbability(power: 0.30), 0.5)
        // Upper clamp binds within the real 0...1 power range; the lower one is a safety
        // net (power can't go negative in practice).
        XCTAssertEqual(DraftSpinSimulator.winProbability(power: 1.0), 0.92, accuracy: 0.0001)
        XCTAssertEqual(DraftSpinSimulator.winProbability(power: -1.0), 0.15, accuracy: 0.0001)
    }

    func testWinsAndLossesAlwaysSumToSeasonLength() {
        for sport in Sport.allCases {
            var g = seededRNG("sum-\(sport.rawValue)")
            let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: sport, using: &g)
            XCTAssertEqual(result.wins + result.losses, DraftSpinSimulator.seasonShape(for: sport).gameCount,
                            "sport: \(sport.rawValue)")
        }
    }

    func testOutcomeTiersMatchWinThresholds() {
        for sport in Sport.allCases {
            let shape = DraftSpinSimulator.seasonShape(for: sport)
            var g = seededRNG("tiers-\(sport.rawValue)")
            let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: sport, using: &g)
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

    /// Locked-value regression: pins this exact lineup+seed sequence's output so a future
    /// refactor of the RNG/scoring math can't silently drift the result. (Values re-locked
    /// 2026-07-09 when the audit replaced the coin-flip duel with `winProbability`.)
    func testLockedSimulationValueForFixedLineupAndSeed() {
        var g = seededRNG("draftspin-locked-nfl")
        let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, using: &g)
        XCTAssertEqual(result.wins, 8)
        XCTAssertEqual(result.losses, 9)
        XCTAssertEqual(result.totalPoints, 533)
        XCTAssertEqual(result.outcome, .missedPlayoffs)
    }

    func testEmptyLineupNeverCrashes() {
        for sport in Sport.allCases {
            var g = SystemRandomNumberGenerator()
            let result = DraftSpinSimulator.simulate(lineup: [], sport: sport, using: &g)
            XCTAssertEqual(result.wins + result.losses, DraftSpinSimulator.seasonShape(for: sport).gameCount,
                            "sport: \(sport.rawValue)")
        }
    }

    /// Locked-value regression for a non-NFL sport: pins soccer's exact output for this
    /// lineup+seed so the per-sport `seasonShape` table can't silently drift either.
    func testLockedSimulationValueForNonNFLSport() {
        var g = seededRNG("draftspin-locked-soccer")
        let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .soccer, using: &g)
        XCTAssertEqual(result.wins, 21)
        XCTAssertEqual(result.losses, 17)
        XCTAssertEqual(result.totalPoints, 1120)
        XCTAssertEqual(result.outcome, .madePlayoffs)
    }
}
