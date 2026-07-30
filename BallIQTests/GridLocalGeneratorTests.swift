import XCTest
@testable import BallIQ

/// `GridLocalGenerator`'s own guarantees, on synthetic data — the rules it has to uphold no
/// matter which board the rotation happens to draw. `GridCrossCheckTests` covers the other half
/// (that its answers agree with `tools/ingest/grid.py` on real production data).
final class GridLocalGeneratorTests: XCTestCase {

    /// A pool where every team/decade combination has several players, so a viable board exists
    /// for both archetypes and any failure is the generator's, not the data's.
    private func richIndex(sport: Sport = .nba,
                           teams: [String] = ["BOS", "LAL", "CHI", "NYK", "PHI", "MIA"],
                           decades: [Int] = [1980, 1990, 2000, 2010],
                           league: String = "") -> GridMembershipIndex {
        var players: [String] = []
        var memberships: [String] = []
        let minYear = decades.min() ?? 1980
        // Every player appears for two teams, so career-grain (team x team) cells fill too.
        for (t, _) in teams.enumerated() {
            for (d, decade) in decades.enumerated() {
                for n in 0..<4 {
                    players.append("P\(t)_\(decade)_\(n)")
                    let other = (t + 1 + n % (teams.count - 1)) % teams.count
                    memberships.append("\(t):\(decade - minYear + n);"
                                       + "\(other):\(decade - minYear + n)")
                }
                _ = d
            }
        }
        return GridMembershipIndex(
            sport: sport, version: 1, minYear: minYear,
            teams: teams.map { .init(abbr: $0, league: league) },
            players: players, memberships: memberships)
    }

    private func generator(_ index: GridMembershipIndex) -> GridLocalGenerator {
        // Pinned league code so a test never depends on a warmed `TeamIdentityIndex`.
        GridLocalGenerator(index: index, leagueCode: { _ in "ENG" })
    }

    // MARK: - Viability

    func testEveryCellOfAGeneratedBoardHasAtLeastOneAnswer() throws {
        let board = try XCTUnwrap(generator(richIndex()).board(seed: 1))
        XCTAssertEqual(board.puzzle.cells.count, 9)
        for cell in board.puzzle.cells {
            XCTAssertFalse(cell.validAnswerNames.isEmpty)
            XCTAssertEqual(cell.validAnswerIds.count, cell.validAnswerNames.count)
        }
    }

    /// The all-or-nothing gate: a pool that cannot fill nine cells must yield *no* board rather
    /// than one with an unanswerable square. Same posture as grid.py returning None.
    func testUnbuildablePoolReturnsNilRatherThanABrokenBoard() {
        // Three teams, three decades, but each player appears exactly once — so most
        // (team, decade) pairs are empty and no 3x3 selection is fully viable.
        let index = GridMembershipIndex(
            sport: .nba, version: 1, minYear: 1980,
            teams: [.init(abbr: "A", league: ""), .init(abbr: "B", league: ""),
                    .init(abbr: "C", league: "")],
            players: ["Solo"], memberships: ["0:0"])
        XCTAssertNil(generator(index).board(seed: 3))
    }

    func testTooFewTeamsOffersNoArchetypeAtAll() {
        let index = GridMembershipIndex(
            sport: .nba, version: 1, minYear: 1980,
            teams: [.init(abbr: "A", league: ""), .init(abbr: "B", league: "")],
            players: ["X"], memberships: ["0:0;1:5"])
        XCTAssertTrue(generator(index).feasibleArchetypes.isEmpty)
        XCTAssertNil(generator(index).board(seed: 1))
    }

    // MARK: - Board shape

    func testTheSameAxisNeverAppearsOnBothARowAndAColumn() throws {
        for seed in UInt64(0)..<25 {
            guard let board = generator(richIndex()).board(seed: seed) else { continue }
            let rows = Set(board.puzzle.rows.map { "\($0.kind.rawValue):\($0.label)" })
            let cols = Set(board.puzzle.cols.map { "\($0.kind.rawValue):\($0.label)" })
            XCTAssertTrue(rows.isDisjoint(with: cols), "seed \(seed) produced a degenerate cell")
        }
    }

    /// Every cell must be anchored to a team — the product rule grid.py pins in
    /// `TEAM_DIMENSIONS`. Here it holds by construction (both archetypes have an all-team
    /// dimension), and this is what would catch a future archetype breaking it.
    func testEveryCellIsAnchoredToATeam() throws {
        for seed in UInt64(0)..<25 {
            guard let board = generator(richIndex()).board(seed: seed) else { continue }
            XCTAssertTrue(board.puzzle.rows.allSatisfy { $0.kind == .team }
                          || board.puzzle.cols.allSatisfy { $0.kind == .team })
        }
    }

    func testGenerationIsDeterministicForAGivenSeed() throws {
        let index = richIndex()
        let first = try XCTUnwrap(generator(index).board(seed: 99))
        let second = try XCTUnwrap(generator(index).board(seed: 99))
        XCTAssertEqual(first.comboKey, second.comboKey)
        XCTAssertEqual(first.puzzle, second.puzzle)
    }

    /// Endlessness is the entire point of the feature, so "different seeds give different
    /// boards" is a product requirement, not a nicety.
    func testDifferentSeedsProduceDifferentBoards() {
        let index = richIndex()
        let keys = Set((UInt64(0)..<20).compactMap { generator(index).board(seed: $0)?.comboKey })
        XCTAssertGreaterThan(keys.count, 5, "the pool of generated boards is too shallow")
    }

    func testARecentlyServedComboIsRejectedInFavourOfAnother() throws {
        let index = richIndex()
        let first = try XCTUnwrap(generator(index).board(seed: 5))
        let second = try XCTUnwrap(generator(index).board(seed: 5,
                                                         recentlyServed: [first.comboKey]))
        XCTAssertNotEqual(second.comboKey, first.comboKey)
    }

    // MARK: - Sport rules carried over from grid_axes.py

    /// Tennis "teams" are countries and players don't change nationality, so a team x team board
    /// would have no answers in any cell. grid_axes excludes tennis from `TEAM_MOBILE_SPORTS`;
    /// this pins that the client honours the same exclusion instead of generating a dead board.
    func testTennisNeverGetsATeamByTeamBoard() {
        let index = richIndex(sport: .tennis, teams: ["USA", "ESP", "SUI", "SRB", "AUS", "GBR"])
        let feasible = generator(index).feasibleArchetypes
        XCTAssertFalse(feasible.contains(.teamsXTeams))
        XCTAssertTrue(feasible.contains(.teamsXDecades), "tennis still gets its usual shape")
        for seed in UInt64(0)..<20 {
            guard let board = generator(index).board(seed: seed) else { continue }
            XCTAssertEqual(board.puzzle.archetype, "teams-x-decades")
        }
    }

    func testTeamMobileSportsDoGetTeamByTeamBoards() {
        for sport in [Sport.nfl, .nba, .baseball, .soccer] {
            let index = richIndex(sport: sport)
            XCTAssertTrue(generator(index).feasibleArchetypes.contains(.teamsXTeams),
                          "\(sport.rawValue) should be able to ask 'played for both'")
        }
    }

    /// Soccer abbreviations collide across countries (MCI is Manchester City *and* Melbourne
    /// City), so a soccer team axis has to carry its league and render a qualified label — the
    /// same disambiguation `grid_axes.qualified_team_label` does server-side.
    func testSoccerTeamAxesCarryTheirLeagueAndRenderAQualifiedLabel() throws {
        let index = richIndex(sport: .soccer, league: "England")
        let board = try XCTUnwrap(generator(index).board(seed: 2))
        let teamAxes = (board.puzzle.rows + board.puzzle.cols).filter { $0.kind == .team }
        XCTAssertFalse(teamAxes.isEmpty)
        for axis in teamAxes {
            XCTAssertEqual(axis.league, "England")
            XCTAssertTrue(axis.label.hasSuffix("-ENG"), axis.label)
            // The crest lookup must still key on the raw code, not the qualified label.
            XCTAssertFalse(axis.teamAbbr.contains("-"))
        }
    }

    func testUSSportTeamAxesStayUnqualified() throws {
        let board = try XCTUnwrap(generator(richIndex()).board(seed: 2))
        for axis in board.puzzle.rows + board.puzzle.cols where axis.kind == .team {
            XCTAssertEqual(axis.label, axis.teamAbbr)
        }
    }

    // MARK: - Rarity + parsing

    func testRarityStarsUseGridPyBoundaries() {
        XCTAssertEqual(GridLocalGenerator.rarityStars(0), 5)
        XCTAssertEqual(GridLocalGenerator.rarityStars(1), 5)
        XCTAssertEqual(GridLocalGenerator.rarityStars(2), 4)
        XCTAssertEqual(GridLocalGenerator.rarityStars(3), 4)
        XCTAssertEqual(GridLocalGenerator.rarityStars(4), 3)
        XCTAssertEqual(GridLocalGenerator.rarityStars(7), 3)
        XCTAssertEqual(GridLocalGenerator.rarityStars(8), 2)
        XCTAssertEqual(GridLocalGenerator.rarityStars(14), 2)
        XCTAssertEqual(GridLocalGenerator.rarityStars(15), 1)
        XCTAssertEqual(GridLocalGenerator.rarityStars(400), 1)
    }

    /// The wire format is the contract between the RPC and this generator; a silent
    /// mis-parse would look like a thin catalog rather than a bug.
    func testMembershipLinesParseIntoBothGrains() {
        let index = GridMembershipIndex(
            sport: .nba, version: 1, minYear: 1980,
            teams: [.init(abbr: "A", league: ""), .init(abbr: "B", league: "")],
            players: ["Journeyman", "Lifer"],
            memberships: ["0:0,1;1:25", "0:3"])
        let tables = GridMembershipTables(index)
        // Career grain: "ever played for".
        XCTAssertEqual(tables.teamPlayers[0], [0, 1])
        XCTAssertEqual(tables.teamPlayers[1], [0])
        // Season grain: the 1980 seasons land in the 1980s, the +25 one in the 2000s.
        XCTAssertEqual(tables.teamDecadePlayers[.init(team: 0, decade: 1980)], [0, 1])
        XCTAssertEqual(tables.teamDecadePlayers[.init(team: 1, decade: 2000)], [0])
        XCTAssertNil(tables.teamDecadePlayers[.init(team: 1, decade: 1980)])
        XCTAssertEqual(tables.decades, [1980, 2000])
    }

    /// Prominence ordering is what keeps a soccer team x team board out of the 676-club long
    /// tail, where two random clubs almost never share a player.
    func testTeamsAreRankedByDistinctPlayerCount() {
        let index = GridMembershipIndex(
            sport: .nba, version: 1, minYear: 2000,
            teams: [.init(abbr: "SMALL", league: ""), .init(abbr: "BIG", league: ""),
                    .init(abbr: "MID", league: "")],
            players: ["a", "b", "c", "d"],
            memberships: ["1:0", "1:1;2:1", "1:2;2:2", "0:3;1:3"])
        XCTAssertEqual(GridMembershipTables(index).teamsByProminence, [1, 2, 0])
    }

    func testAnswerSlugMirrorsThePythonSlug() {
        XCTAssertEqual(GridLocalGenerator.answerSlug("Joe Montana"), "joe-montana")
        XCTAssertEqual(GridLocalGenerator.answerSlug("Amar'e Stoudemire"), "amar-e-stoudemire")
        XCTAssertEqual(GridLocalGenerator.answerSlug("Nikola Jokić"), "nikola-jokic")
    }

    // MARK: - Usability gate

    func testAnEmptyOrFutureVersionIndexIsNotUsable() {
        let empty = GridMembershipIndex(sport: .nba, version: 1, minYear: 0,
                                        teams: [], players: [], memberships: [])
        XCTAssertFalse(empty.isUsable)
        let future = GridMembershipIndex(
            sport: .nba, version: 99, minYear: 1980,
            teams: [.init(abbr: "A", league: ""), .init(abbr: "B", league: ""),
                    .init(abbr: "C", league: "")],
            players: ["x"], memberships: ["0:0"])
        XCTAssertFalse(future.isUsable, "an unknown wire version must not drive generation")
    }

    // MARK: - v2 axes (stat / position archetypes)

    /// `richIndex` plus stat and position axis membership, in the v2 wire shape: `axisMemberships`
    /// is the career-grain "ever satisfied" axis list, `axisTeams` the season-grain (axis, team)
    /// pairs a single season satisfied. Every player satisfies all four axes for both of their
    /// teams, so any drawn board is viable and a failure is the generator's, not the fixture's.
    private func axisIndex() -> GridMembershipIndex {
        var index = richIndex()
        index.axes = [
            .init(key: "stat:points:gte:2000", kind: "stat", label: "2,000+ Points"),
            .init(key: "stat:rebounds:gte:700", kind: "stat", label: "700+ Rebounds"),
            .init(key: "stat:assists:gte:500", kind: "stat", label: "500+ Assists"),
            .init(key: "pos:G", kind: "position", label: "Guards"),
        ]
        let axisList = (0..<4).map(String.init).joined(separator: ",")
        index.axisMemberships = index.players.map { _ in axisList }
        index.axisTeams = index.memberships.map { line in
            // `richIndex` writes "t:year;other:year" — take the team ids back out and credit every
            // axis for each, which is what makes a (team x stat) cell fillable here.
            let teams = line.split(separator: ";").compactMap { run -> String? in
                guard let colon = run.firstIndex(of: ":") else { return nil }
                return String(run[run.startIndex..<colon])
            }
            guard !teams.isEmpty else { return "" }
            let csv = teams.sorted().joined(separator: ",")
            return (0..<4).map { "\($0):\(csv)" }.joined(separator: ";")
        }
        return index
    }

    func testV2IndexUnlocksTheStatAndPositionArchetypes() {
        let shapes = Set(generator(axisIndex()).feasibleArchetypes.map(\.rawValue))
        XCTAssertTrue(shapes.contains("teams-x-stats"))
        XCTAssertTrue(shapes.contains("teams-x-mixed"))
        XCTAssertTrue(shapes.contains("mixed-x-teams"))
    }

    /// The compatibility promise: a v1 payload — a cached one from a previous build, or a sport
    /// whose catalog satisfies no axis — must still generate, just from the two team shapes.
    /// Losing generation entirely would drop practice back to the small server pool.
    func testV1IndexStillGeneratesFromTheTeamShapesOnly() throws {
        let gen = generator(richIndex())
        XCTAssertEqual(Set(gen.feasibleArchetypes.map(\.rawValue)),
                       ["teams-x-decades", "teams-x-teams"])
        XCTAssertNotNil(try XCTUnwrap(gen.board(seed: 7)).puzzle)
    }

    /// Every board the v2 rotation can draw still has to satisfy the invariants, whichever of the
    /// five shapes it lands on — including the answer ceiling the mixed shapes made necessary
    /// (a position axis is the loosest thing on a board: "KC x RB" is every RB the club had).
    func testEveryV2BoardStaysViableAndUnderTheCeiling() throws {
        let gen = generator(axisIndex())
        var seen: Set<String> = []
        for seed in UInt64(1)...60 {
            guard let board = gen.board(seed: seed) else { continue }
            seen.insert(board.puzzle.archetype ?? "")
            XCTAssertEqual(board.puzzle.cells.count, 9)
            for cell in board.puzzle.cells {
                XCTAssertFalse(cell.validAnswerNames.isEmpty)
                XCTAssertLessThanOrEqual(cell.validAnswerNames.count,
                                         GridLocalGenerator.maxCellAnswers)
            }
        }
        XCTAssertGreaterThan(seen.count, 1, "the rotation should reach more than one shape")
    }

    /// A `mixed-x-teams` row edge that drew three teams is just teams-x-teams wearing another
    /// label — the sameness the shape exists to break, and `grid.py` rejects it for the same
    /// reason (`_is_varied`).
    func testMixedRowsAreNeverAllTeams() throws {
        let gen = generator(axisIndex())
        for seed in UInt64(1)...80 {
            guard let board = gen.board(seed: seed),
                  board.puzzle.archetype == "mixed-x-teams" else { continue }
            XCTAssertGreaterThan(Set(board.puzzle.rows.map(\.kind)).count, 1,
                                 "mixed_any must actually mix kinds")
        }
    }

    /// An axis array that doesn't line up with `players` would make every lookup read some other
    /// player's milestones. Degrade to no axes, never to wrong ones.
    func testMisalignedAxisMembershipsAreRejected() {
        var index = axisIndex()
        index.axisMemberships.removeLast()
        XCTAssertFalse(index.isUsable,
                       "a v2 payload whose axis rows don't match its players must not be used")
    }

    /// `hasAxes` is what gates the three new shapes, so a v2 payload carrying an empty axis list
    /// (a sport whose catalog satisfies nothing) must behave exactly like v1 rather than
    /// half-enabling a shape with no axes to draw.
    func testV2WithNoAxesBehavesLikeV1() {
        var index = richIndex()
        index.axes = []
        index.axisMemberships = index.players.map { _ in "" }
        index.axisTeams = index.players.map { _ in "" }
        XCTAssertTrue(index.isUsable)
        XCTAssertFalse(index.hasAxes)
        XCTAssertEqual(Set(generator(index).feasibleArchetypes.map(\.rawValue)),
                       ["teams-x-decades", "teams-x-teams"])
    }
}
