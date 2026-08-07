import XCTest
@testable import BallIQ

final class WhoAmIScoringTests: XCTestCase {

    func testFirstClueSolveScoresMax() {
        let r = WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true)
        XCTAssertEqual(r.total, 1000)
        XCTAssertEqual(r.performance, 1.0, accuracy: 0.0001)
        XCTAssertTrue(r.solved)
    }

    func testLaterClueScoresLess() {
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 3, wrongGuesses: 0, solved: true).total, 600)
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 0, solved: true).total, 100)
    }

    func testWrongGuessesDeduct() {
        let r = WhoAmIScoring.score(cluesUsed: 2, wrongGuesses: 2, solved: true)
        XCTAssertEqual(r.total, 800 - 200) // 600
    }

    func testScoreFloorsAtZero() {
        let r = WhoAmIScoring.score(cluesUsed: 6, wrongGuesses: 5, solved: true)
        XCTAssertEqual(r.total, 0) // 100 - 500, clamped
    }

    func testUnsolvedScoresZeroPerformance() {
        let r = WhoAmIScoring.score(cluesUsed: 4, wrongGuesses: 1, solved: false)
        XCTAssertEqual(r.total, 0)
        XCTAssertEqual(r.performance, 0)
        XCTAssertFalse(r.solved)
    }

    /// `perClue[0]` is the max any solve can score (first clue, no wrong guesses) — the value
    /// `WhoAmIGameView.finish` reports as the session's `maxScore`.
    func testFirstEntryIsTheMaxAttainableScore() {
        XCTAssertEqual(WhoAmIScoring.perClue[0], WhoAmIScoring.perClue.max())
        XCTAssertEqual(WhoAmIScoring.perClue[0], 1000)
    }


    // MARK: - Difficulty

    /// The whole point of the tier: an obscurer player pays more for the same solve.
    func testDifficultyScalesThePayout() {
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true,
                                           difficulty: .easy).total, 1000)
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true,
                                           difficulty: .medium).total, 1250)
        XCTAssertEqual(WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true,
                                           difficulty: .hard).total, 1600)
    }

    /// An unrated puzzle (community-authored, or minted before tiers existed) must score
    /// exactly as it did before tiers shipped — no silent 1.25x on existing content.
    func testUnratedPuzzlesScoreUnchanged() {
        for clues in 1...6 {
            XCTAssertEqual(WhoAmIScoring.score(cluesUsed: clues, wrongGuesses: 0, solved: true,
                                               difficulty: nil).total,
                           WhoAmIScoring.perClue[clues - 1],
                           "unrated clue \(clues) drifted from the flat table")
        }
        XCTAssertEqual(WhoAmIScoring.multiplier(nil), 1.0)
    }

    /// The wrong-guess penalty stays flat across tiers, so guessing wildly is never *cheaper*
    /// on a hard puzzle than an easy one in relative terms.
    func testWrongGuessPenaltyIsNotScaledByDifficulty() {
        let easy = WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 2, solved: true, difficulty: .easy)
        let hard = WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 2, solved: true, difficulty: .hard)
        XCTAssertEqual(easy.total, 1000 - 200)
        XCTAssertEqual(hard.total, 1600 - 200)
    }

    /// `performance` feeds the competitive rating engine and means "how efficiently was this
    /// solved", so the tier must not move it — otherwise the difficulty the pipeline happened
    /// to serve would shift a player's rating.
    func testDifficultyDoesNotAffectRatingPerformance() {
        let values = WhoAmIPuzzle.Difficulty.allCases.map {
            WhoAmIScoring.score(cluesUsed: 3, wrongGuesses: 0, solved: true, difficulty: $0).performance
        }
        XCTAssertEqual(Set(values).count, 1)
        XCTAssertEqual(values[0], 0.6, accuracy: 0.0001)
    }

    func testMaxScoreTracksTheTier() {
        XCTAssertEqual(WhoAmIScoring.maxScore(difficulty: nil), 1000)
        XCTAssertEqual(WhoAmIScoring.maxScore(difficulty: .hard), 1600)
        // A solve can never exceed the reported max — the ratio the session detail records.
        for difficulty in WhoAmIPuzzle.Difficulty.allCases {
            let best = WhoAmIScoring.score(cluesUsed: 1, wrongGuesses: 0, solved: true,
                                           difficulty: difficulty)
            XCTAssertEqual(best.total, WhoAmIScoring.maxScore(difficulty: difficulty))
        }
    }

    // MARK: - Decoding

    private func decode(_ json: String) throws -> WhoAmIPuzzle {
        try JSONDecoder().decode(WhoAmIPuzzle.self, from: Data(json.utf8))
    }

    /// The exact shape of pre-2026-08 content: three-key clues, no difficulty. This is what
    /// the bundled pool and every already-published community puzzle look like.
    func testLegacyContentDecodesAsUnrated() throws {
        let puzzle = try decode("""
        {"id": "x", "sport": "nfl",
         "clues": [{"order": 1, "kind": "era", "text": "Played from 1991 to 2010"}],
         "answer": {"canonical": "Brett Favre", "aliases": []}}
        """)
        XCTAssertNil(puzzle.difficulty)
        XCTAssertNil(puzzle.clues[0].label)
        XCTAssertEqual(puzzle.clues[0].displayLabel, ClueKind.era.label)
    }

    func testCurrentContentDecodesDimensionLabelAndTier() throws {
        let puzzle = try decode("""
        {"id": "x", "sport": "nfl", "difficulty": "hard",
         "clues": [{"order": 1, "kind": "fact", "text": "Selected 199th overall",
                    "dimension": "draftPick", "label": "Draft slot"}],
         "answer": {"canonical": "Tom Brady", "aliases": []}}
        """)
        XCTAssertEqual(puzzle.difficulty, .hard)
        XCTAssertEqual(puzzle.clues[0].dimension, "draftPick")
        XCTAssertEqual(puzzle.clues[0].displayLabel, "Draft slot")
    }

    /// Forward compatibility, and the reason the pipeline is allowed to keep adding dimensions:
    /// an unrecognized `kind` or `difficulty` must degrade to a usable value rather than throw.
    /// A throw here fails the decode for the WHOLE fetched array, dropping the user to the
    /// bundled pool over one unknown word.
    func testUnknownKindAndTierDegradeInsteadOfFailingTheDecode() throws {
        let puzzle = try decode("""
        {"id": "x", "sport": "nfl", "difficulty": "nightmare",
         "clues": [{"order": 1, "kind": "birthplace", "text": "Born in Kiln, Mississippi"}],
         "answer": {"canonical": "Brett Favre", "aliases": []}}
        """)
        XCTAssertEqual(puzzle.clues[0].kind, .fact)
        XCTAssertEqual(puzzle.difficulty, .medium)
    }

    /// Every tier the pipeline can emit must round-trip, so a new tier can't be shipped in
    /// content without the client understanding it.
    func testEveryPipelineTierIsRepresentable() throws {
        for raw in ["easy", "medium", "hard"] {
            let puzzle = try decode("""
            {"id": "x", "sport": "nba", "difficulty": "\(raw)", "clues": [],
             "answer": {"canonical": "A B", "aliases": []}}
            """)
            XCTAssertEqual(puzzle.difficulty?.rawValue, raw)
        }
    }

    // MARK: - Answer matching

    private let answer = WhoAmIPuzzle.AcceptedAnswer(
        canonical: "Allen Iverson", aliases: ["ai", "the answer"])

    func testExactAndCaseInsensitive() {
        XCTAssertTrue(AnswerMatcher.matches("Allen Iverson", answer: answer))
        XCTAssertTrue(AnswerMatcher.matches("allen iverson", answer: answer))
    }

    func testLastNameAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("Iverson", answer: answer))
    }

    func testAliasAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("The Answer", answer: answer))
    }

    func testSingleTypoAccepted() {
        XCTAssertTrue(AnswerMatcher.matches("Iverson", answer:
            .init(canonical: "Iverson", aliases: [])))
        XCTAssertTrue(AnswerMatcher.matches("Iversen", answer:
            .init(canonical: "Iverson", aliases: [])))
    }

    func testWrongAnswerRejected() {
        XCTAssertFalse(AnswerMatcher.matches("Kobe Bryant", answer: answer))
        XCTAssertFalse(AnswerMatcher.matches("", answer: answer))
    }
}

/// `WhoAmIAnswerPhoto` — the reveal-time headshot resolution (WhoAmI content carries no
/// photo URL). The stakes are "whose face shows on the answer card," so these lock the
/// conservative rules: exact-name equality only, era-clue span excludes same-name players,
/// latest matching row wins.
final class WhoAmIAnswerPhotoTests: XCTestCase {
    private func puzzle(canonical: String, aliases: [String] = [], era: String?) -> WhoAmIPuzzle {
        var clues = [WhoAmIPuzzle.Clue(order: 2, kind: .fact, text: "Known for something")]
        if let era { clues.insert(.init(order: 1, kind: .era, text: era), at: 0) }
        return WhoAmIPuzzle(id: "t", sport: .nba, clues: clues,
                            answer: .init(canonical: canonical, aliases: aliases))
    }

    private func row(_ name: String, year: Int, headshot: String? = "https://img/x.png",
                     first: Int? = nil, last: Int? = nil) -> CatalogSeason {
        CatalogSeason(id: "\(name)-\(year)", sport: .nba, name: name, teamAbbr: "X",
                      seasonYear: year, position: "G", stats: [:],
                      headshot: headshot, firstYear: first, lastYear: last)
    }

    func testEraSpanParsesBothPipelineShapes() {
        XCTAssertEqual(WhoAmIAnswerPhoto.eraSpan(of: puzzle(canonical: "A", era: "Played from 1992 to 2011")), 1992...2011)
        XCTAssertEqual(WhoAmIAnswerPhoto.eraSpan(of: puzzle(canonical: "A", era: "Played in 1998")), 1998...1998)
        XCTAssertNil(WhoAmIAnswerPhoto.eraSpan(of: puzzle(canonical: "A", era: nil)))
    }

    func testExactNameMatchPicksLatestHeadshot() {
        let p = puzzle(canonical: "Shaquille O'Neal", era: "Played from 1992 to 2011")
        let rows = [row("Shaquille O'Neal", year: 1994), row("Shaquille O'Neal", year: 2009),
                    row("Kobe Bryant", year: 2009)]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: p), "https://img/x.png")
        // Latest row wins — prove it by giving the rows distinct URLs.
        let distinct = [row("Shaquille O'Neal", year: 1994, headshot: "https://img/old.png"),
                        row("Shaquille O'Neal", year: 2009, headshot: "https://img/new.png")]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: distinct, for: p), "https://img/new.png")
    }

    func testEraSpanExcludesSameNamePlayerFromAnotherEra() {
        // Jaren Jackson Sr. (1990s) must never supply Jr.'s (2018+) face, and vice versa.
        let junior = puzzle(canonical: "Jaren Jackson", era: "Played from 2018 to 2025")
        let rows = [row("Jaren Jackson", year: 1998, headshot: "https://img/sr.png"),
                    row("Jaren Jackson", year: 2023, headshot: "https://img/jr.png")]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: junior), "https://img/jr.png")
        let senior = puzzle(canonical: "Jaren Jackson", era: "Played from 1990 to 2002")
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: senior), "https://img/sr.png")
    }

    func testNoFuzzyMatchingAndNoEmptyHeadshots() {
        let p = puzzle(canonical: "Allen Iverson", era: nil)
        // Last-name-only and near-miss names are guess-grading leniency, not face-picking.
        let rows = [row("Iverson", year: 2001), row("Allan Iverson", year: 2001),
                    row("Allen Iverson", year: 2001, headshot: "")]
        XCTAssertNil(WhoAmIAnswerPhoto.headshot(from: rows, for: p))
    }

    func testCareerRowSpanUsesFirstAndLastYear() {
        let p = puzzle(canonical: "Tim Duncan", era: "Played from 1997 to 2016")
        // A career row keyed to its LAST season still overlaps via first/last span.
        let rows = [row("Tim Duncan", year: 2016, first: 1997, last: 2016)]
        XCTAssertEqual(WhoAmIAnswerPhoto.headshot(from: rows, for: p), "https://img/x.png")
    }
}
