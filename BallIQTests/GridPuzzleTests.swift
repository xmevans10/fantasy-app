import XCTest
@testable import BallIQ

final class GridPuzzleTests: XCTestCase {

    private static let names = [
        "Joe Montana", "Steve Young", "Jerry Rice", "Emmitt Smith", "Barry Sanders",
        "Peyton Manning", "Tom Brady", "Randy Moss", "Adrian Peterson",
    ]

    private static func teams(_ labels: [String]) -> [GridPuzzle.GridAxis] {
        labels.map { GridPuzzle.GridAxis(kind: .team, label: $0) }
    }

    private static func decades(_ labels: [String]) -> [GridPuzzle.GridAxis] {
        labels.map { GridPuzzle.GridAxis(kind: .decade, label: $0) }
    }

    private func puzzle(cells: [GridPuzzle.GridCell]? = nil) -> GridPuzzle {
        GridPuzzle(sport: .nfl,
                   rows: Self.teams(["CLE", "SEA", "LA"]),
                   cols: Self.decades(["1990s", "2010s", "2020s"]),
                   cells: cells ?? (0..<9).map { i in
                       GridPuzzle.GridCell(validAnswerIds: ["id-\(i)"],
                                           validAnswerNames: [Self.names[i]],
                                           rarityStars: (i % 5) + 1)
                   })
    }

    func testCellIndexingIsRowMajor() {
        let p = puzzle()
        XCTAssertEqual(p.cell(row: 0, col: 0).validAnswerNames, ["Joe Montana"])
        XCTAssertEqual(p.cell(row: 0, col: 2).validAnswerNames, ["Jerry Rice"])
        XCTAssertEqual(p.cell(row: 1, col: 0).validAnswerNames, ["Emmitt Smith"])
        XCTAssertEqual(p.cell(row: 2, col: 2).validAnswerNames, ["Adrian Peterson"])
    }

    func testExactNameMatches() {
        XCTAssertTrue(puzzle().isCorrect(row: 0, col: 0, guess: "Joe Montana"))
    }

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(puzzle().isCorrect(row: 0, col: 0, guess: "joe montana"))
    }

    func testWrongGuessIsRejected() {
        XCTAssertFalse(puzzle().isCorrect(row: 0, col: 0, guess: "Someone Else"))
    }

    func testGuessOnlyMatchesItsOwnCell() {
        let p = puzzle()
        // "Tom Brady" is Self.names[6] -> index 6 = row 2, col 0.
        XCTAssertFalse(p.isCorrect(row: 0, col: 0, guess: "Tom Brady"))
        XCTAssertTrue(p.isCorrect(row: 2, col: 0, guess: "Tom Brady"))
    }

    func testMultipleValidAnswersInOneCellAllMatch() {
        var cells = puzzle().cells
        cells[0] = GridPuzzle.GridCell(validAnswerIds: ["a", "b"],
                                       validAnswerNames: ["Joe Montana", "Steve Young"],
                                       rarityStars: 2)
        let p = puzzle(cells: cells)
        XCTAssertTrue(p.isCorrect(row: 0, col: 0, guess: "montana"))
        XCTAssertTrue(p.isCorrect(row: 0, col: 0, guess: "Steve Young"))
    }

    // MARK: - Decoding the real pipeline shape (tools/ingest/grid.py's to_content)

    /// The v2 symmetric payload: rows and cols are both axis lists, any kind on either side.
    func testDecodesSymmetricAxisContent() throws {
        let json = """
        {
          "sport": "nfl",
          "version": 2,
          "archetype": "teams-x-stats",
          "rows": [
            {"kind": "team", "label": "KC", "grain": "season", "key": "team:KC"},
            {"kind": "team", "label": "DAL", "grain": "season", "key": "team:DAL"},
            {"kind": "team", "label": "SEA", "grain": "season", "key": "team:SEA"}
          ],
          "cols": [
            {"kind": "stat", "label": "1,000+ Rush Yds", "grain": "season", "key": "stat:rushing_yards:gte:1000"},
            {"kind": "decade", "label": "1990s", "grain": "season", "key": "decade:1990"},
            {"kind": "position", "label": "QB", "grain": "season", "key": "pos:QB"}
          ],
          "cells": [
            {"validAnswerIds": ["joe-montana"], "validAnswerNames": ["Joe Montana"], "rarityStars": 3}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(GridPuzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sport, .nfl)
        XCTAssertEqual(decoded.archetype, "teams-x-stats")
        XCTAssertEqual(decoded.rows.map(\.label), ["KC", "DAL", "SEA"])
        XCTAssertEqual(decoded.rows.map(\.kind), [.team, .team, .team])
        XCTAssertEqual(decoded.cols.map(\.label), ["1,000+ Rush Yds", "1990s", "QB"])
        XCTAssertEqual(decoded.cols.map(\.kind), [.stat, .decade, .position])
        XCTAssertEqual(decoded.cells.first?.rarityStars, 3)
    }

    /// A board minted before 2026-07-27 carries only `rowTeams`/`colDecades`. Live boards are
    /// immutable for their day and a player can be mid-grid when a new build ships, so the legacy
    /// shape must still decode — into equivalent team/decade axes — rather than failing and
    /// showing "No Grid today".
    func testDecodesLegacyTeamsByDecadesContent() throws {
        let json = """
        {
          "sport": "nfl",
          "rowTeams": ["CLE", "SEA", "LA"],
          "colDecades": [1990, 2010, 2020],
          "cells": [
            {"validAnswerIds": ["joe-montana"], "validAnswerNames": ["Joe Montana"], "rarityStars": 3}
          ]
        }
        """
        let decoded = try JSONDecoder().decode(GridPuzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rows.map(\.label), ["CLE", "SEA", "LA"])
        XCTAssertEqual(decoded.rows.map(\.kind), [.team, .team, .team])
        XCTAssertEqual(decoded.cols.map(\.label), ["1990s", "2010s", "2020s"])
        XCTAssertEqual(decoded.cols.map(\.kind), [.decade, .decade, .decade])
        XCTAssertEqual(decoded.archetype, "")
        XCTAssertEqual(decoded.cells.first?.validAnswerNames, ["Joe Montana"])
    }

    /// The generator keeps emitting the legacy keys alongside the new ones for classic-shaped
    /// boards. The modern payload must win, or the rollout would silently keep using the old path.
    func testSymmetricAxesWinWhenBothShapesArePresent() throws {
        let json = """
        {
          "sport": "nfl",
          "rowTeams": ["OLD", "OLD2", "OLD3"],
          "colDecades": [1900, 1910, 1920],
          "rows": [
            {"kind": "team", "label": "NEW", "grain": "season", "key": "team:NEW"}
          ],
          "cols": [
            {"kind": "decade", "label": "2020s", "grain": "season", "key": "decade:2020"}
          ],
          "cells": []
        }
        """
        let decoded = try JSONDecoder().decode(GridPuzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rows.map(\.label), ["NEW"])
        XCTAssertEqual(decoded.cols.map(\.label), ["2020s"])
    }

    /// Soccer team axes carry the league that identifies which club the code means. Without it
    /// the crest/color lookup resolves "MCI" to whichever of Manchester City / Melbourne City
    /// `TeamIdentityIndex` matches first — 51 of 954 soccer codes are genuinely shared.
    func testTeamAxisCarriesAbbrAndLeagueForCrestResolution() throws {
        let json = """
        {
          "sport": "soccer",
          "rows": [{"kind": "team", "label": "MCI", "grain": "career", "key": "team:MCI@England",
                    "abbr": "MCI", "league": "England"}],
          "cols": [{"kind": "team", "label": "TOR", "grain": "career", "key": "team:TOR@Italy",
                    "abbr": "TOR", "league": "Italy"}],
          "cells": []
        }
        """
        let decoded = try JSONDecoder().decode(GridPuzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rows.first?.teamAbbr, "MCI")
        XCTAssertEqual(decoded.rows.first?.teamLeague, "England")
        XCTAssertEqual(decoded.cols.first?.teamLeague, "Italy")
    }

    /// US-sport and legacy content carry no league; the lookup must fall back to "any league"
    /// rather than searching for a club whose league is the empty string.
    func testMissingOrEmptyLeagueResolvesToNil() throws {
        let json = """
        {
          "sport": "nfl",
          "rows": [{"kind": "team", "label": "KC", "grain": "season", "key": "team:KC",
                    "abbr": "KC", "league": ""}],
          "cols": [{"kind": "decade", "label": "1990s", "grain": "season", "key": "decade:1990"}],
          "cells": []
        }
        """
        let decoded = try JSONDecoder().decode(GridPuzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rows.first?.teamAbbr, "KC")
        XCTAssertNil(decoded.rows.first?.teamLeague)
        // Legacy content has no `abbr` at all — the label has to stand in.
        let legacy = GridPuzzle.GridAxis(kind: .team, label: "CLE")
        XCTAssertEqual(legacy.teamAbbr, "CLE")
        XCTAssertNil(legacy.teamLeague)
    }

    /// An axis kind this build doesn't know (awards, college, draft — all on the roadmap) must
    /// degrade to a plain text label, not fail the whole puzzle. Server content can lead the
    /// client, and "render the label as text" is always a correct fallback.
    func testUnknownAxisKindDecodesAsOtherRatherThanFailing() throws {
        let json = """
        {
          "sport": "nfl",
          "rows": [{"kind": "award", "label": "MVP", "grain": "season", "key": "award:mvp"}],
          "cols": [{"kind": "team", "label": "KC", "grain": "season", "key": "team:KC"}],
          "cells": []
        }
        """
        let decoded = try JSONDecoder().decode(GridPuzzle.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rows.first?.kind, .other)
        XCTAssertEqual(decoded.rows.first?.label, "MVP")
    }

    // MARK: - Prompts and instructions

    /// The old prompt hardcoded "\\(team) in the \\(decade)s", which reads as nonsense on any
    /// board that isn't teams x decades ("PIT in the CARs").
    func testPromptReadsFromBothAxisLabels() {
        let p = GridPuzzle(sport: .nfl,
                           rows: Self.teams(["KC", "DAL", "SEA"]),
                           cols: [GridPuzzle.GridAxis(kind: .stat, label: "1,000+ Rush Yds"),
                                  GridPuzzle.GridAxis(kind: .decade, label: "1990s"),
                                  GridPuzzle.GridAxis(kind: .position, label: "QB")],
                           cells: [])
        XCTAssertEqual(p.prompt(row: 0, col: 0), "KC · 1,000+ RUSH YDS")
        XCTAssertEqual(p.prompt(row: 2, col: 1), "SEA · 1990S")
    }

    /// teams x teams asks a career question ("played for both"); every other shape asks about a
    /// single season. The footer has to say which.
    func testInstructionsMatchTheBoardShape() {
        let career = GridPuzzle(sport: .nfl, rows: Self.teams(["KC"]), cols: Self.teams(["DAL"]),
                                cells: [], archetype: "teams-x-teams")
        XCTAssertTrue(career.instructions.contains("played for both"))

        let classic = puzzle()
        XCTAssertFalse(classic.instructions.contains("played for both"))
        XCTAssertTrue(classic.instructions.contains("row and the column"))
    }

    // MARK: - SessionDetail (career log)

    /// Every cell always gets a final answer — `GridGameView.finish` only runs once
    /// `attemptedCount` hits 9 — so `correct`/`attempted` are always `solved.count`/9, never a
    /// partial count.
    func testBuildSessionDetailCountsSolvedAgainstAllNineCells() {
        let p = puzzle()
        let solved: [Int: String] = [0: "Joe Montana", 4: "Barry Sanders"]
        let wrong: Set<Int> = [1, 2, 3, 5, 6, 7, 8]
        let started = Date(timeIntervalSince1970: 0)
        let detail = GridGameView.buildSessionDetail(puzzle: p, solved: solved, wrong: wrong,
                                                      mode: .daily, startedAt: started)
        XCTAssertEqual(detail.correct, 2)
        XCTAssertEqual(detail.attempted, 9)
        XCTAssertEqual(detail.mode, .daily)
        XCTAssertEqual(detail.startedAt, started)
        XCTAssertEqual(detail.maxScore, 1800)
        XCTAssertEqual(detail.details.cellsSolved, 2)
    }

    /// Score is 100/solve plus 20/rarity-star, summed only over solved cells — this fixture's
    /// `rarityStars` are `(i % 5) + 1`, so cell 0 is 1 star and cell 4 is 5 stars.
    func testBuildSessionDetailScoresSolvedCellsByRarity() {
        let p = puzzle()
        let solved: [Int: String] = [0: "Joe Montana", 4: "Barry Sanders"]
        let detail = GridGameView.buildSessionDetail(puzzle: p, solved: solved, wrong: [],
                                                      mode: .daily, startedAt: nil)
        // cell 0 rarity = (0 % 5) + 1 = 1, cell 4 rarity = (4 % 5) + 1 = 5 -> totalStars = 6
        XCTAssertEqual(detail.details.rarityStars, 6)
        XCTAssertEqual(detail.score, 2 * 100 + 6 * 20)
    }

    /// Powers the "nemesis category" stat — both axis labels of every unsolved cell, in cell
    /// order, without needing `grid_guesses` (write-only, no select policy).
    func testBuildSessionDetailCapturesMissedCellHeaders() {
        let p = puzzle()   // rows: CLE, SEA, LA · cols: 1990s, 2010s, 2020s
        let solved: [Int: String] = [0: "Joe Montana"]
        let wrong: Set<Int> = [4, 8]   // (row1,col1)=SEA/2010s, (row2,col2)=LA/2020s
        let detail = GridGameView.buildSessionDetail(puzzle: p, solved: solved, wrong: wrong,
                                                      mode: .daily, startedAt: nil)
        XCTAssertEqual(detail.details.missedCellHeaders, ["SEA", "2010s", "LA", "2020s"])
    }

    /// A practice run must log with `.practice` so `PlayMode.countsForRecords` (already false
    /// for practice) keeps it out of personal bests while still logging the reps.
    func testBuildSessionDetailUsesPracticeMode() {
        let p = puzzle()
        let detail = GridGameView.buildSessionDetail(puzzle: p, solved: [:], wrong: Set(0..<9),
                                                      mode: .practice, startedAt: nil)
        XCTAssertEqual(detail.mode, .practice)
        XCTAssertFalse(detail.mode.countsForRecords)
        XCTAssertEqual(detail.correct, 0)
        XCTAssertEqual(detail.attempted, 9)
    }
}
