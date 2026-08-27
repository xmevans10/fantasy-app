import XCTest
import SwiftUI
import UIKit          // `UIColor` for the resolved-colour comparison below
@testable import BallIQ

final class ClueFamilyTests: XCTestCase {

    private func clue(_ order: Int, _ kind: ClueKind, dimension: String? = nil) -> WhoAmIPuzzle.Clue {
        WhoAmIPuzzle.Clue(order: order, kind: kind, text: "t", dimension: dimension, label: nil)
    }

    /// Resolved RGBA, so two tokens can be compared without relying on `Color: Equatable`
    /// (which compares provenance, not appearance).
    private func rgba(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f,%.3f,%.3f,%.3f", r, g, b, a)
    }

    func testDimensionWinsOverKind() {
        // 16 dimensions ride on `.fact`; the dimension is what actually says which angle it is.
        XCTAssertEqual(ClueFamily.of(clue(1, .fact, dimension: "draftClass")), .draft)
        XCTAssertEqual(ClueFamily.of(clue(2, .fact, dimension: "weight")), .bio)
        XCTAssertEqual(ClueFamily.of(clue(3, .fact, dimension: "accolades")), .story)
    }

    func testLegacyClueWithNoDimensionFallsBackToKind() {
        XCTAssertEqual(ClueFamily.of(clue(1, .era)), .career)
        XCTAssertEqual(ClueFamily.of(clue(2, .position)), .bio)
        XCTAssertEqual(ClueFamily.of(clue(3, .teams)), .team)
        XCTAssertEqual(ClueFamily.of(clue(4, .statLine)), .production)
        XCTAssertEqual(ClueFamily.of(clue(5, .fact)), .story)
        XCTAssertEqual(ClueFamily.of(clue(6, .jersey)), .bio)
    }

    /// A dimension the pipeline ships before this map learns about it must still colour, not
    /// crash or blank.
    func testUnknownDimensionFallsBackToKind() {
        XCTAssertEqual(ClueFamily.of(clue(1, .fact, dimension: "somethingNewIn2027")), .story)
    }

    /// The real production board that motivated keying off family instead of kind: by `kind`
    /// it is five identical chips out of six.
    func testBarrySandersBoardNeverRepeatsAFamilyMoreThanTwice() {
        let board = [clue(1, .era,  dimension: "era"),
                     clue(2, .fact, dimension: "weight"),
                     clue(3, .fact, dimension: "draftClass"),
                     clue(4, .fact, dimension: "ageAtDebut"),
                     clue(5, .fact, dimension: "draftPick"),
                     clue(6, .fact, dimension: "accolades")]
        let byKind = Dictionary(grouping: board, by: { $0.kind }).values.map(\.count).max()
        XCTAssertEqual(byKind, 5, "fixture drifted — this board is the 5-identical-kinds case")

        let byFamily = Dictionary(grouping: board, by: ClueFamily.of).values.map(\.count).max()
        XCTAssertEqual(byFamily, 2)
    }

    func testEveryFamilyHasItsOwnChipColour() {
        let fills = Set(ClueFamily.allCases.map { rgba($0.chipFill) })
        XCTAssertEqual(fills.count, ClueFamily.allCases.count)
    }

    /// The wrong-guess counter on the same screen is `dangerText`. A clue chip in the danger
    /// family would read as "you got that one wrong".
    func testNoFamilyUsesTheDangerTokens() {
        let banned = Set([rgba(.dangerFill), rgba(.dangerText)])
        for family in ClueFamily.allCases {
            XCTAssertFalse(banned.contains(rgba(family.chipFill)),
                           "\(family) took a danger token")
        }
    }
}
