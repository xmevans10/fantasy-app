import XCTest
@testable import BallIQ

final class DraftSpinTests: XCTestCase {

    private func season(_ id: String, position: String, stats: [String: Double],
                       team: String = "SF", year: Int = 2020, league: String? = nil,
                       competition: String? = nil) -> CatalogSeason {
        var s = CatalogSeason(id: id, sport: .nfl, name: "Player \(id)", teamAbbr: team,
                              seasonYear: year, position: position, stats: stats)
        s.league = league
        s.competition = competition
        return s
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

    /// Live repro (2026-07-19): "BRO 2006" (Blackburn Rovers 2005-06) spun in with only 4
    /// players — 2 DF, 1 GK, 1 MF, zero FW — against soccer's 8-slot formation, because the old
    /// eligibility check only required ONE matching candidate for ANY open role, not enough
    /// distinct candidates to cover every open slot. A combo this thin must never spin as long as
    /// a real fillable alternative exists.
    private var soccerFormationRoles: [String] {
        DraftSpinConstraint.formations[.soccer]!.map(\.role)   // GK, DF, DF, MF, MF, MF, FW, FW
    }

    private var thinSoccerRoster: [CatalogSeason] {
        [
            season("bro-gk", position: "GK", stats: [:], team: "BRO", year: 2006),
            season("bro-df0", position: "DF", stats: [:], team: "BRO", year: 2006),
            season("bro-df1", position: "DF", stats: [:], team: "BRO", year: 2006),
            season("bro-mf0", position: "MF", stats: [:], team: "BRO", year: 2006),
        ]
    }

    private var fullSoccerRoster: [CatalogSeason] {
        [
            season("che-gk", position: "GK", stats: [:], team: "CHE", year: 2006),
            season("che-df0", position: "DF", stats: [:], team: "CHE", year: 2006),
            season("che-df1", position: "DF", stats: [:], team: "CHE", year: 2006),
            season("che-mf0", position: "MF", stats: [:], team: "CHE", year: 2006),
            season("che-mf1", position: "MF", stats: [:], team: "CHE", year: 2006),
            season("che-mf2", position: "MF", stats: [:], team: "CHE", year: 2006),
            season("che-fw0", position: "FW", stats: [:], team: "CHE", year: 2006),
            season("che-fw1", position: "FW", stats: [:], team: "CHE", year: 2006),
        ]
    }

    // MARK: - Fillability against the COMPLETE roster (the real BRO-2006 guarantee)
    //
    // `spinRound`'s pool at runtime is the 2,000-row discovery sample, which live holds ~1.3
    // players per soccer (team, year, league) combo — so requiring 8 THERE rejected every soccer
    // combo and dead-ended every soccer draft into an empty lineup. The bar moved to the fetched
    // roster; these lock that it still catches a genuinely-thin club-season.

    func testCanFillLineupRejectsATooThinRosterAndAcceptsAnExactCover() {
        XCTAssertFalse(DraftSpinConstraint.canFillLineup(
            roster: thinSoccerRoster, sport: .soccer, openRoles: soccerFormationRoles),
            "4 players can never fill soccer's 8 slots — the live BRO 2006 bug")
        XCTAssertTrue(DraftSpinConstraint.canFillLineup(
            roster: fullSoccerRoster, sport: .soccer, openRoles: soccerFormationRoles),
            "exactly 8 distinct players for 8 open roles is the boundary case, and must pass")
    }

    func testCanFillLineupCountsDistinctNamesAndHonoursExcludedNames() {
        // Duplicate rows for one player (overlapping ingest sources) must not inflate depth...
        let duplicated = fullSoccerRoster + fullSoccerRoster
        XCTAssertTrue(DraftSpinConstraint.canFillLineup(
            roster: duplicated, sport: .soccer, openRoles: soccerFormationRoles))
        // ...and an already-drafted player no longer counts toward filling what's left.
        let drafted = Set(fullSoccerRoster.prefix(1).map(\.name))
        XCTAssertFalse(DraftSpinConstraint.canFillLineup(
            roster: fullSoccerRoster, sport: .soccer, openRoles: soccerFormationRoles,
            excludeNames: drafted),
            "8 slots with one player excluded leaves only 7 placeable")
    }

    func testSpinRoundInDiscoveryModeSurfacesThinCombosForTheRosterCheckToJudge() {
        // The live path passes minCandidates: 1 precisely so a sample-thin combo is NOT
        // pre-rejected — otherwise soccer has no candidates at all.
        var g = spinRNG("discovery")
        let spun = DraftSpinConstraint.spinRound(
            from: thinSoccerRoster, sport: .soccer, openRoles: soccerFormationRoles,
            minCandidates: 1, using: &g)
        XCTAssertEqual(spun?.team, "BRO", "discovery mode must still offer a thin combo")
    }

    func testSpinRoundSkipsExcludedCombos() {
        // How the view retries past a combo whose complete roster turned out unfillable.
        let pool = thinSoccerRoster + fullSoccerRoster
        var g = spinRNG("excluded")
        let spun = DraftSpinConstraint.spinRound(
            from: pool, sport: .soccer, openRoles: soccerFormationRoles, minCandidates: 1,
            excludeCombos: [DraftSpinConstraint.comboKey(team: "BRO", year: 2006, league: nil)],
            using: &g)
        XCTAssertEqual(spun?.team, "CHE", "the rejected BRO combo must not come back")
    }

    func testSpinRoundNeverPicksAComboWithFewerDistinctCandidatesThanOpenRoles() {
        let pool = thinSoccerRoster + fullSoccerRoster
        for i in 0...8 {
            var g = spinRNG("thin-vs-full-\(i)")
            let spun = DraftSpinConstraint.spinRound(from: pool, sport: .soccer, openRoles: soccerFormationRoles, using: &g)
            XCTAssertEqual(spun?.team, "CHE", "stream \(i) spun the too-thin BRO combo")
        }
    }

    func testSpinRoundReturnsNilWhenOnlyATooThinComboExists() {
        var g = spinRNG("only-thin")
        XCTAssertNil(DraftSpinConstraint.spinRound(from: thinSoccerRoster, sport: .soccer, openRoles: soccerFormationRoles, using: &g))
    }

    func testSpinRoundStillViableWhenDistinctCandidatesExactlyCoverOpenRoles() {
        // fullSoccerRoster has exactly 8 distinct players for 8 open roles — the boundary case
        // (>=), not just comfortably-over-provisioned rosters.
        var g = spinRNG("exact-cover")
        let spun = DraftSpinConstraint.spinRound(from: fullSoccerRoster, sport: .soccer, openRoles: soccerFormationRoles, using: &g)
        XCTAssertEqual(spun?.team, "CHE")
    }

    func testSpinRoundDedupesDuplicatePlayerRowsForTheSameCombo() {
        // Same player, two rows (e.g. overlapping ingest sources) for the same (team, year) —
        // must count once, not twice, when judging viability.
        let duplicatedRows = [
            season("dup-gk", position: "GK", stats: [:], team: "BRO", year: 2006),
            season("dup-gk", position: "GK", stats: [:], team: "BRO", year: 2006),   // same id/name, duplicate row
            season("bro-df0", position: "DF", stats: [:], team: "BRO", year: 2006),
        ]
        var g = spinRNG("dup-rows")
        // Only 2 distinct players (dup-gk counted once, plus bro-df0) against 8 open roles —
        // still too thin even though there are 3 rows.
        XCTAssertNil(DraftSpinConstraint.spinRound(from: duplicatedRows, sport: .soccer, openRoles: soccerFormationRoles, using: &g))
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

    // MARK: - spinRound Nation → League → Club filter (soccer LEAGUE setup option)

    private var twoLeaguePool: [CatalogSeason] {
        [
            season("gk-eng", position: "GK", stats: [:], team: "MCI", year: 2022,
                   league: "England", competition: "eng.1"),
            season("gk-esp", position: "GK", stats: [:], team: "FCB", year: 2022,
                   league: "Spain", competition: "esp.1"),
        ]
    }

    /// Both German divisions, which is the case a nation label alone cannot express.
    private var twoDivisionPool: [CatalogSeason] {
        [
            season("gk-ger1", position: "GK", stats: [:], team: "BAY", year: 2025,
                   league: "Germany", competition: "ger.1"),
            season("gk-ger2", position: "GK", stats: [:], team: "SPA", year: 2025,
                   league: "Germany", competition: "ger.2"),
        ]
    }

    func testSpinRoundLeagueOnlySpinsThatLeague() {
        for i in 0...5 {
            var g = spinRNG("league-\(i)")
            let spun = DraftSpinConstraint.spinRound(from: twoLeaguePool, sport: .soccer, openRoles: ["GK"],
                                                     filter: ClubFilter(nation: "England"), using: &g)
            XCTAssertEqual(spun?.team, "MCI", "stream \(i) escaped the league filter")
        }
    }

    func testSpinRoundLeagueFallsBackWhenThatLeagueHasNoViableCombo() {
        // Only Spain has a real candidate for this open role — the league filter must not
        // dead-end the round, same never-a-dead-spin shape as `lockedTeam`.
        let pool = [season("gk-esp", position: "GK", stats: [:], team: "FCB", year: 2022, league: "Spain")]
        var g = spinRNG("league-fallback")
        let spun = DraftSpinConstraint.spinRound(from: pool, sport: .soccer, openRoles: ["GK"],
                                                 filter: ClubFilter(nation: "England"), using: &g)
        XCTAssertEqual(spun?.team, "FCB")
    }

    func testSpinRoundNoLeagueFilterIgnoresLeagueField() {
        var g = spinRNG("no-league-filter")
        XCTAssertNotNil(DraftSpinConstraint.spinRound(from: twoLeaguePool, sport: .soccer,
                                                       openRoles: ["GK"], using: &g))
    }

    func testSpinRoundReturnsTheSpunCombosLeagueSoTheRosterFetchCanScope() {
        var g = spinRNG("league-in-result")
        let spun = DraftSpinConstraint.spinRound(from: twoLeaguePool, sport: .soccer, openRoles: ["GK"],
                                                 filter: ClubFilter(nation: "Spain"), using: &g)
        XCTAssertEqual(spun?.team, "FCB")
        XCTAssertEqual(spun?.league, "Spain")
    }

    // The whole point of the `competition` column: two divisions of ONE nation are now
    // separable, where a nation-label filter matched both.

    func testSpinRoundCompetitionSelectsOneDivisionOfANation() {
        for i in 0...5 {
            var g = spinRNG("competition-\(i)")
            let spun = DraftSpinConstraint.spinRound(
                from: twoDivisionPool, sport: .soccer, openRoles: ["GK"],
                filter: ClubFilter(nation: "Germany", competition: "ger.2"), using: &g)
            XCTAssertEqual(spun?.team, "SPA", "stream \(i) leaked a Bundesliga club into a 2. Bundesliga draft")
        }
    }

    func testSpinRoundNationAloneStillSpansEveryDivisionOfThatNation() {
        var seen: Set<String> = []
        for i in 0...20 {
            var g = spinRNG("nation-wide-\(i)")
            let spun = DraftSpinConstraint.spinRound(
                from: twoDivisionPool, sport: .soccer, openRoles: ["GK"],
                filter: ClubFilter(nation: "Germany"), using: &g)
            if let team = spun?.team { seen.insert(team) }
        }
        XCTAssertEqual(seen, ["BAY", "SPA"], "\"All of Germany\" must reach both divisions")
    }

    func testSpinRoundClubLevelPinsTheSpinToThatClub() {
        for i in 0...5 {
            var g = spinRNG("club-\(i)")
            let spun = DraftSpinConstraint.spinRound(
                from: twoDivisionPool, sport: .soccer, openRoles: ["GK"],
                filter: ClubFilter(nation: "Germany", competition: "ger.1", club: "BAY"), using: &g)
            XCTAssertEqual(spun?.team, "BAY", "stream \(i) escaped the club filter")
        }
    }

    func testClubFilterDoesNotMatchARowThatDoesNotKnowItsCompetition() {
        // A soccer row written before the column existed must not be silently swept into a
        // division draft — the fall-back-to-the-full-pool path is what stops that from
        // dead-ending a spin while the backfill catches up.
        let unlabelled = season("gk-old", position: "GK", stats: [:], team: "XYZ", year: 2015,
                                league: "Germany")
        XCTAssertFalse(ClubFilter(nation: "Germany", competition: "ger.2").matches(unlabelled))
        XCTAssertTrue(ClubFilter(nation: "Germany").matches(unlabelled))
    }

    // MARK: - spinRound league-collision (defense in depth, live collision: "BRO" is both
    // Blackburn Rovers, England and Brisbane Roar, Australia)

    func testSpinRoundTreatsSameTeamCodeInDifferentLeaguesAsDistinctCombos() {
        // Both leagues field a full, equally-viable roster under the same "BRO" code — if league
        // weren't part of the combo's identity, these would collapse into one dictionary entry
        // and silently mix an English and an Australian roster into one "combo".
        let englandBRO = fullSoccerRoster.map { s in
            season(s.id, position: s.position, stats: [:], team: "BRO", year: 2010, league: "England")
        }
        let australiaBRO = fullSoccerRoster.map { s in
            season("aus-" + s.id, position: s.position, stats: [:], team: "BRO", year: 2010, league: "Australia")
        }
        let pool = englandBRO + australiaBRO
        var sawEngland = false
        var sawAustralia = false
        for i in 0...20 {
            var g = spinRNG("collision-\(i)")
            let spun = DraftSpinConstraint.spinRound(from: pool, sport: .soccer, openRoles: soccerFormationRoles, using: &g)
            XCTAssertEqual(spun?.team, "BRO")
            if spun?.league == "England" { sawEngland = true }
            if spun?.league == "Australia" { sawAustralia = true }
        }
        XCTAssertTrue(sawEngland && sawAustralia,
                      "both same-code leagues should be independently viable and spinnable, not merged into one combo")
    }

    func testSpinRoundLeagueCollisionKeepsAThinLeagueOutEvenIfTheOtherIsFull() {
        // Only England's "BRO" has enough distinct candidates to cover every open role;
        // Australia's "BRO" (same code, same year) is too thin — the collision must not let the
        // thin Australian roster ride in on the back of the full English one.
        let englandBRO = fullSoccerRoster.map { s in
            season(s.id, position: s.position, stats: [:], team: "BRO", year: 2010, league: "England")
        }
        let australiaBRO = [season("aus-gk", position: "GK", stats: [:], team: "BRO", year: 2010, league: "Australia")]
        let pool = englandBRO + australiaBRO
        for i in 0...5 {
            var g = spinRNG("collision-thin-\(i)")
            let spun = DraftSpinConstraint.spinRound(from: pool, sport: .soccer, openRoles: soccerFormationRoles, using: &g)
            XCTAssertEqual(spun?.league, "England", "stream \(i) let the thin Australian BRO combo through")
        }
    }

    // MARK: - Daily Draft (backlog #4)

    func testDailyDraftRoundGeneratorIsDeterministicForSameDayAndRoundIndex() {
        let date = ISO8601DateFormatter().date(from: "2026-07-12T00:00:00Z")!
        var g1 = DraftSpinConstraint.dailyDraftRoundGenerator(sport: .nfl, date: date, roundIndex: 0)
        var g2 = DraftSpinConstraint.dailyDraftRoundGenerator(sport: .nfl, date: date, roundIndex: 0)
        let a = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl,
                                              openRoles: ["QB", "RB", "WR", "TE", "FLEX", "FLEX"], using: &g1)
        let b = DraftSpinConstraint.spinRound(from: richNFLRoster, sport: .nfl,
                                              openRoles: ["QB", "RB", "WR", "TE", "FLEX", "FLEX"], using: &g2)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.team, b?.team)
        XCTAssertEqual(a?.year, b?.year)
    }

    func testDailyDraftRoundGeneratorVariesAcrossRoundIndicesOrDays() {
        let date = ISO8601DateFormatter().date(from: "2026-07-12T00:00:00Z")!
        let otherDate = ISO8601DateFormatter().date(from: "2026-07-13T00:00:00Z")!
        var sameDayRound0 = DraftSpinConstraint.dailyDraftRoundGenerator(sport: .nfl, date: date, roundIndex: 0)
        var sameDayRound1 = DraftSpinConstraint.dailyDraftRoundGenerator(sport: .nfl, date: date, roundIndex: 1)
        var differentDayRound0 = DraftSpinConstraint.dailyDraftRoundGenerator(sport: .nfl, date: otherDate, roundIndex: 0)
        // The raw generator streams themselves must differ — that's what actually guarantees
        // varying results downstream, independent of any particular pool's viable-combo set.
        XCTAssertNotEqual(sameDayRound0.next(), sameDayRound1.next())
        XCTAssertNotEqual(sameDayRound0.next(), differentDayRound0.next())
    }

    /// The retired design's own caveat (now inherited by Daily Draft): once two "players"
    /// have drafted different players into the same open role, `excludeNames` reshapes the
    /// viable pool, so the same day+round seed can legitimately diverge. This is expected, not
    /// a bug — pinned here so a future change can't silently "fix" it into unconditional
    /// determinism (which `spinRound`'s exclusion behavior makes impossible to guarantee).
    /// The specific combo excluded here (SF/2020) is structurally guaranteed to never be the
    /// excluded call's answer, independent of the shared seed's exact draw.
    func testDailyDraftRoundGeneratorDivergesOnceExcludedNamesDiffer() {
        let date = ISO8601DateFormatter().date(from: "2026-07-12T00:00:00Z")!
        var gen = DraftSpinConstraint.dailyDraftRoundGenerator(sport: .nfl, date: date, roundIndex: 1)
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
        for sport in Sport.allCases {
            let a = DraftSpinSimulator.fantasyAnchors(for: sport)
            // p50 (a normal, unremarkable lineup) is still a favorable coin flip — the
            // "friendlier" recalibration ("still too harsh" feedback on the prior power-based
            // formula): an average real draft should win more than it loses.
            XCTAssertEqual(DraftSpinSimulator.winProbability(lineupTotal: a.p50, sport: sport),
                           0.55, accuracy: 0.0001, "sport: \(sport.rawValue)")
            // p90 (a well-drafted lineup) clearly contends; p99 (all-time-great) is a near-lock.
            XCTAssertEqual(DraftSpinSimulator.winProbability(lineupTotal: a.p90, sport: sport),
                           0.75, accuracy: 0.0001, "sport: \(sport.rawValue)")
            XCTAssertEqual(DraftSpinSimulator.winProbability(lineupTotal: a.p99, sport: sport),
                           0.93, accuracy: 0.0001, "sport: \(sport.rawValue)")
            // Monotonic in lineup total, and never a guaranteed sweep or wipeout.
            XCTAssertGreaterThan(DraftSpinSimulator.winProbability(lineupTotal: a.p99 * 2, sport: sport),
                                 DraftSpinSimulator.winProbability(lineupTotal: 0, sport: sport),
                                 "sport: \(sport.rawValue)")
            XCTAssertEqual(DraftSpinSimulator.winProbability(lineupTotal: 0, sport: sport),
                           0.30, accuracy: 0.0001, "sport: \(sport.rawValue)")
            XCTAssertEqual(DraftSpinSimulator.winProbability(lineupTotal: a.p99 * 10, sport: sport),
                           0.93, accuracy: 0.0001, "sport: \(sport.rawValue)")
        }
    }

    /// The whole point of anchoring on real percentiles: a lineup drafted from real, average
    /// seasons should score close to the p50 anchor, not near zero — the flaw that made the
    /// old `power()`-based formula feel "too harsh" even after its first recalibration.
    func testFantasyPointsUsesK4C4Formula() {
        let qb = season("qb", position: "QB", stats: ["passing_yards": 4200, "passing_tds": 32, "interceptions": 10])
        // nfl_fantasy: passing_yards*0.04 + passing_tds*4 + interceptions*-2
        let expected: Double = 4200.0 * 0.04 + 32.0 * 4.0 - 10.0 * 2.0
        XCTAssertEqual(DraftSpinSimulator.fantasyPoints(qb), expected, accuracy: 0.01)
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
    /// 2026-07-13 when the K4C4 fantasy-points recalibration replaced the `power`-based
    /// `winProbability`.)
    func testLockedSimulationValueForFixedLineupAndSeed() {
        var g = seededRNG("draftspin-locked-nfl")
        let result = DraftSpinSimulator.simulate(lineup: fixedLineup, sport: .nfl, using: &g)
        XCTAssertEqual(result.wins, 9)
        XCTAssertEqual(result.losses, 8)
        XCTAssertEqual(result.totalPoints, 886)
        XCTAssertEqual(result.outcome, .madePlayoffs)
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
        XCTAssertEqual(result.wins, 33)
        XCTAssertEqual(result.losses, 5)
        XCTAssertEqual(result.totalPoints, 849)
        XCTAssertEqual(result.outcome, .champion)
    }
}
