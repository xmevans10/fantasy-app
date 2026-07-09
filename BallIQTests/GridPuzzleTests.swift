import XCTest
@testable import BallIQ

final class GridPuzzleTests: XCTestCase {

    private static let names = [
        "Joe Montana", "Steve Young", "Jerry Rice", "Emmitt Smith", "Barry Sanders",
        "Peyton Manning", "Tom Brady", "Randy Moss", "Adrian Peterson",
    ]

    private func puzzle() -> GridPuzzle {
        GridPuzzle(sport: .nfl, rowTeams: ["CLE", "SEA", "LA"], colDecades: [1990, 2010, 2020],
                  cells: (0..<9).map { i in
                      GridPuzzle.GridCell(validAnswerIds: ["id-\(i)"], validAnswerNames: [Self.names[i]],
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
        let p = puzzle()
        XCTAssertTrue(p.isCorrect(row: 0, col: 0, guess: "Joe Montana"))
    }

    func testCaseInsensitiveMatch() {
        let p = puzzle()
        XCTAssertTrue(p.isCorrect(row: 0, col: 0, guess: "joe montana"))
    }

    func testWrongGuessIsRejected() {
        let p = puzzle()
        XCTAssertFalse(p.isCorrect(row: 0, col: 0, guess: "Someone Else"))
    }

    func testGuessOnlyMatchesItsOwnCell() {
        let p = puzzle()
        // "Tom Brady" is Self.names[6] -> index 6 = row 2, col 0.
        XCTAssertFalse(p.isCorrect(row: 0, col: 0, guess: "Tom Brady"))
        XCTAssertTrue(p.isCorrect(row: 2, col: 0, guess: "Tom Brady"))
    }

    func testMultipleValidAnswersInOneCellAllMatch() {
        var cells = puzzle().cells
        cells[0] = GridPuzzle.GridCell(validAnswerIds: ["a", "b"], validAnswerNames: ["Joe Montana", "Steve Young"],
                                       rarityStars: 2)
        let p = GridPuzzle(sport: .nfl, rowTeams: ["CLE", "SEA", "LA"], colDecades: [1990, 2010, 2020], cells: cells)
        XCTAssertTrue(p.isCorrect(row: 0, col: 0, guess: "montana"))
        XCTAssertTrue(p.isCorrect(row: 0, col: 0, guess: "Steve Young"))
    }

    // MARK: - Decoding the real pipeline shape (tools/ingest/grid.py's to_content)

    func testDecodesRealPipelineContentShape() throws {
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
        XCTAssertEqual(decoded.sport, .nfl)
        XCTAssertEqual(decoded.rowTeams, ["CLE", "SEA", "LA"])
        XCTAssertEqual(decoded.colDecades, [1990, 2010, 2020])
        XCTAssertEqual(decoded.cells.first?.validAnswerNames, ["Joe Montana"])
        XCTAssertEqual(decoded.cells.first?.rarityStars, 3)
    }
}
