import XCTest
@testable import BallIQ

/// The drift guard between the app's `GridLocalGenerator` and `tools/ingest/grid.py`.
///
/// A client-side Grid generator was deferred for a long time for one reason: it is a **second**
/// implementation of the same rules, and two implementations diverge silently. What makes it
/// shippable is that the divergence is now checked, against real production data, by comparing
/// the Swift cell computation with answers the *Python* generator actually produced (see
/// `GridCrossCheckFixture` for how they were captured).
///
/// If this file ever fails, the fix is never "update the expectations to match Swift" — it's to
/// find which side changed and why.
///
/// ⚠️ **COVERAGE GAP, 2026-07-28.** The fixture is a curated **v1** payload, captured before the
/// stat/position axes landed. Verified against the live RPC that day: `grid_membership_index`
/// returns v2 with 13 nba axes, and v1 with no `axes` key at all, and the two are otherwise
/// byte-identical (same teams, players, memberships, minYear). So everything below cross-checks
/// only the team/decade archetypes — **the axes path has never been compared against grid.py.**
/// That is precisely the silent-divergence risk this file exists to prevent, so it is a real
/// hole, not a nitpick. Closing it means re-deriving the curated subset at v2 *and* capturing
/// matching expected cells for a stat axis (the full v2 nba payload is 315 KB against v1's
/// 190 KB, so a raw dump is not the answer).
final class GridCrossCheckTests: XCTestCase {

    private func loadIndex() throws -> GridMembershipIndex {
        let data = Data(GridCrossCheckFixture.indexJSON.utf8)
        return try JSONDecoder().decode(GridMembershipIndex.self, from: data)
    }

    private func loadExpected() throws -> [GridCrossCheckFixture.ExpectedCell] {
        let data = Data(GridCrossCheckFixture.expectedJSON.utf8)
        return try JSONDecoder().decode([GridCrossCheckFixture.ExpectedCell].self, from: data)
    }

    /// The RPC payload decodes with a *plain* decoder. Pinned because using the shared
    /// `JSONDecoder.supabase` would silently fail on `minYear` (its snake_case key strategy
    /// expects `min_year`) and surface as "no index", i.e. as a permanently empty practice pool —
    /// which is exactly how the same mistake presented for Grid content once already.
    func testIndexDecodesWithAPlainDecoder() throws {
        let index = try loadIndex()
        XCTAssertEqual(index.sport, .nba)
        // Asserted as *supported*, not as `== currentVersion`. This fixture is a curated v1
        // payload; pinning it to `currentVersion` made an unrelated constant bump fail a test
        // about decoding, which is what happened when the axes work moved currentVersion to 2.
        // What this test actually guards is that a real RPC payload decodes with a plain
        // decoder — see the note above about `JSONDecoder.supabase` silently breaking `minYear`.
        XCTAssertTrue(GridMembershipIndex.supportedVersions.contains(index.version),
                      "fixture version \(index.version) is outside supportedVersions")
        XCTAssertTrue(index.isUsable)
        XCTAssertEqual(index.players.count, index.memberships.count)
        XCTAssertGreaterThan(index.minYear, 1900)
    }

    /// The core claim: for the same axes, the Swift tables produce the same answer set grid.py
    /// produced from `player_seasons` — name for name, not merely count for count.
    func testSwiftCellAnswersMatchThePythonGeneratorExactly() throws {
        let tables = GridMembershipTables(try loadIndex())
        let expected = try loadExpected()
        XCTAssertGreaterThanOrEqual(expected.count, 8, "fixture lost cases")

        for cell in expected {
            let players: Set<Int>
            switch cell.archetype {
            case "teams-x-decades":
                let decade = try XCTUnwrap(cell.decade)
                players = tables.teamDecadePlayers[.init(team: cell.rowTeam, decade: decade)] ?? []
            case "teams-x-teams":
                let col = try XCTUnwrap(cell.colTeam)
                players = tables.teamPlayers[cell.rowTeam].intersection(tables.teamPlayers[col])
            default:
                return XCTFail("unknown archetype \(cell.archetype)")
            }
            let names = players.map { tables.index.players[$0] }.sorted()
            XCTAssertEqual(names, cell.names,
                           "\(cell.rowKey) x \(cell.colKey) disagrees with grid.py")
        }
    }

    /// Rarity has to agree too, not just validity — a cell's stars are the only scoring signal on
    /// the board, and grid.py derives them from the very same graded pool this index is built
    /// from, so "close enough" is not the bar. The fixture deliberately spans every bucket:
    /// unviable (0 answers), 5-star (1), 4-star (2–3), 3-star (4–7), 2-star (8–14) and 1-star.
    func testRarityStarsMatchThePythonThresholds() throws {
        let expected = try loadExpected()
        for cell in expected where cell.stars > 0 {
            XCTAssertEqual(GridLocalGenerator.rarityStars(cell.names.count), cell.stars,
                           "\(cell.rowKey) x \(cell.colKey): \(cell.names.count) answers")
        }
        XCTAssertTrue(expected.contains { $0.stars == 5 }, "fixture no longer covers rare cells")
        XCTAssertTrue(expected.contains { $0.stars == 1 }, "fixture no longer covers common cells")
    }

    /// A zero-answer cell is grid.py's *viability* failure — it returns no cell at all rather
    /// than a 5-star one — and the Swift generator has to reject the whole board on it, not ship
    /// an unanswerable square.
    func testCellsWithNoAnswersAreRejectedRatherThanScoredFiveStars() throws {
        let tables = GridMembershipTables(try loadIndex())
        let unviable = try loadExpected().filter { $0.stars == 0 }
        XCTAssertFalse(unviable.isEmpty, "fixture no longer covers the viability gate")
        for cell in unviable {
            XCTAssertTrue(cell.names.isEmpty)
            if cell.archetype == "teams-x-teams", let col = cell.colTeam {
                XCTAssertTrue(tables.teamPlayers[cell.rowTeam]
                    .intersection(tables.teamPlayers[col]).isEmpty)
            } else if let decade = cell.decade {
                XCTAssertNil(tables.teamDecadePlayers[.init(team: cell.rowTeam, decade: decade)])
            }
        }
    }

    /// End to end on the real payload: a full, playable board comes out, every cell holds real
    /// NBA names, and a guess against it grades correctly. The synthetic-pool tests in
    /// `GridLocalGeneratorTests` pin the rules; this pins that the rules survive contact with
    /// production data — the shape of catalog the generator will actually meet.
    func testRealPayloadProducesPlayableBoards() throws {
        let generator = GridLocalGenerator(index: try loadIndex(), leagueCode: { _ in "" })
        var seen: Set<String> = []
        var boards = 0
        for seed in UInt64(0)..<40 {
            guard let board = generator.board(seed: seed, recentlyServed: seen) else { continue }
            boards += 1
            seen.insert(board.comboKey)
            XCTAssertEqual(board.puzzle.cells.count, 9)
            for (n, cell) in board.puzzle.cells.enumerated() {
                let name = try XCTUnwrap(cell.validAnswerNames.first)
                XCTAssertFalse(name.isEmpty)
                XCTAssertTrue(board.puzzle.isCorrect(row: n / 3, col: n % 3, guess: name),
                              "\(name) should grade as correct in its own cell")
                XCTAssertTrue((1...5).contains(cell.rarityStars))
            }
        }
        // "Endless" is the feature. 14 teams of one sport already yield dozens of distinct
        // boards; the live index carries 30–676 depending on the sport.
        XCTAssertGreaterThan(boards, 25, "the real index should generate freely")
        XCTAssertEqual(seen.count, boards, "every board should be a distinct combo")
    }

    /// Axis keys are the shared vocabulary between the two generators — `grid_history` dedup and
    /// this generator's own repeat-rejection both key on them, so a drift here would silently
    /// stop matching server-minted history.
    func testAxisKeysUseThePythonVocabulary() throws {
        let expected = try loadExpected()
        for cell in expected {
            XCTAssertTrue(cell.rowKey.hasPrefix("team:"), cell.rowKey)
            XCTAssertTrue(cell.colKey.hasPrefix("team:") || cell.colKey.hasPrefix("decade:"),
                          cell.colKey)
        }
        let index = try loadIndex()
        let generator = GridLocalGenerator(index: index, leagueCode: { _ in "XXX" })
        let board = try XCTUnwrap(generator.board(seed: 7))
        // Whatever shape came out, every axis on it has to key the same way the fixture's do.
        for axis in board.puzzle.rows + board.puzzle.cols {
            switch axis.kind {
            case .team: XCTAssertFalse(axis.teamAbbr.isEmpty)
            case .decade: XCTAssertTrue(axis.label.hasSuffix("s"))
            default: XCTFail("a v1 board can only carry team and decade axes")
            }
        }
    }

    // MARK: - v2: the stat/position archetypes

    /// The v1 payload plus the axis arrays — the same index the app builds when the RPC is asked
    /// for v2, assembled from two fixtures so teams/players/memberships aren't duplicated.
    private func loadV2Index() throws -> GridMembershipIndex {
        struct Axes: Decodable {
            let axes: [GridMembershipIndex.Axis]
            let axisMemberships: [String]
        }
        let extra = try JSONDecoder().decode(Axes.self,
                                             from: Data(GridCrossCheckFixture.axesJSON.utf8))
        var index = try loadIndex()
        index.axes = extra.axes
        index.axisMemberships = extra.axisMemberships
        return index
    }

    private func loadExpectedAxisCells() throws -> [GridCrossCheckFixture.ExpectedAxisCell] {
        try JSONDecoder().decode([GridCrossCheckFixture.ExpectedAxisCell].self,
                                 from: Data(GridCrossCheckFixture.expectedAxisJSON.utf8))
    }

    /// **The cell computation this whole file exists for, for the archetypes it could not reach
    /// until now.** A `teams-x-stats` cell is season-grain on both sides: one season must satisfy
    /// the team AND the milestone together ("1,000 yards *as a Bear*"). The tempting shortcut —
    /// intersecting "played here ever" with "cleared it ever" — silently answers a different,
    /// much easier question, and would pass every synthetic test in `GridLocalGeneratorTests`.
    /// Only real data with real career movement distinguishes them, which is what this does.
    func testSeasonGrainStatCellsMatchGridPy() throws {
        let tables = GridMembershipTables(try loadV2Index())
        let axisIndex = Dictionary(uniqueKeysWithValues:
            tables.index.axes.enumerated().map { ($0.element.key, $0.offset) })
        let cells = try loadExpectedAxisCells().filter { $0.archetype == "teams-x-stats" }
        XCTAssertFalse(cells.isEmpty, "fixture no longer covers teams-x-stats")

        for cell in cells {
            let axis = try XCTUnwrap(axisIndex[cell.axisKey], cell.axisKey)
            let got = tables.axisTeamPlayers[.init(axis: axis, team: cell.rowTeam)] ?? []
            let names = Set(got.map { tables.index.players[$0] })
            XCTAssertEqual(names, Set(cell.names),
                           "\(cell.rowKey) x \(cell.colKey) disagrees with grid.py")
        }
    }

    /// The career-grain half. In `mixed-x-teams` the team column is career grain, which makes the
    /// stat row the cell's only season-grain constraint — so the rule reduces to "some season
    /// satisfied it", and a plain set intersection becomes correct *here and nowhere else*.
    /// Pinned because that asymmetry is exactly the kind of thing a later refactor "tidies away".
    func testCareerGrainMixedCellsMatchGridPy() throws {
        let tables = GridMembershipTables(try loadV2Index())
        let axisIndex = Dictionary(uniqueKeysWithValues:
            tables.index.axes.enumerated().map { ($0.element.key, $0.offset) })
        let cells = try loadExpectedAxisCells().filter { $0.archetype == "mixed-x-teams" }
        XCTAssertFalse(cells.isEmpty, "fixture no longer covers mixed-x-teams")

        for cell in cells {
            let axis = try XCTUnwrap(axisIndex[cell.axisKey], cell.axisKey)
            let got = tables.axisPlayers[axis].intersection(tables.teamPlayers[cell.rowTeam])
            let names = Set(got.map { tables.index.players[$0] })
            XCTAssertEqual(names, Set(cell.names),
                           "\(cell.rowKey) x \(cell.colKey) disagrees with grid.py")
        }
    }

    /// Season and career grain must actually differ on this data, or the two tests above would
    /// both pass against a generator that had collapsed them into one. Guards the guard.
    func testTheTwoGrainsAreNotTheSameQuestionOnRealData() throws {
        let tables = GridMembershipTables(try loadV2Index())
        let axisIndex = Dictionary(uniqueKeysWithValues:
            tables.index.axes.enumerated().map { ($0.element.key, $0.offset) })
        var differed = false
        for cell in try loadExpectedAxisCells() where cell.archetype == "teams-x-stats" {
            guard let axis = axisIndex[cell.axisKey] else { continue }
            let season = tables.axisTeamPlayers[.init(axis: axis, team: cell.rowTeam)] ?? []
            let career = tables.axisPlayers[axis].intersection(tables.teamPlayers[cell.rowTeam])
            if season != career { differed = true; break }
        }
        XCTAssertTrue(differed,
                      "if career grain always equalled season grain here, the fixture proves nothing")
    }

    /// A v2 board can legitimately carry stat and position axes, which the v1 assertion above
    /// rejects — so the vocabulary check has its own v2 form rather than a loosened shared one.
    func testV2BoardsCarryRealAxisVocabulary() throws {
        let generator = GridLocalGenerator(index: try loadV2Index(), leagueCode: { _ in "" })
        var kinds: Set<GridPuzzle.GridAxis.Kind> = []
        for seed in UInt64(0)..<60 {
            guard let board = generator.board(seed: seed) else { continue }
            for axis in board.puzzle.rows + board.puzzle.cols {
                kinds.insert(axis.kind)
                XCTAssertFalse(axis.label.isEmpty)
            }
        }
        XCTAssertTrue(kinds.contains(.stat) || kinds.contains(.position),
                      "the v2 rotation should reach a milestone axis on real data")
    }
}
