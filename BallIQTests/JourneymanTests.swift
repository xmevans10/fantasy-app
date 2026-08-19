import XCTest
import SwiftUI
@testable import BallIQ

/// Scoring, decoding and share-text rules for Journeyman (M22).
///
/// The whole career is on screen from the first second, so the only thing that can move a score
/// is guessing wrong — which makes the guess limit and its decay table the surface worth pinning
/// hardest, along with the rating invariant every format in this app shares.
final class JourneymanScoringTests: XCTestCase {

    // MARK: - The curve

    func testTheFirstGuessPaysTheFullBase() {
        XCTAssertEqual(JourneymanScoring.value(guess: 1, difficulty: nil),
                       JourneymanScoring.perGuess[0])
        XCTAssertEqual(JourneymanScoring.maxScore(difficulty: nil), 1000)
    }

    /// Deliberately the same table Who Am I? uses — the two formats share a points language, and
    /// a silent divergence would make "600" mean two different things in one app.
    func testTheDecayTableMatchesWhoAmIs() {
        XCTAssertEqual(JourneymanScoring.perGuess, Array(WhoAmIScoring.perClue.prefix(5)))
    }

    func testEachWrongGuessCostsTwoHundredAtAnUnratedTier() {
        for guess in 1..<JourneymanScoring.maxGuesses {
            XCTAssertEqual(JourneymanScoring.nextGuessCost(guess: guess, difficulty: nil), 200)
        }
    }

    func testValueDecaysMonotonicallyAndStaysPositiveWhileGuessesRemain() {
        var previous = Int.max
        for guess in 1...JourneymanScoring.maxGuesses {
            let value = JourneymanScoring.value(guess: guess, difficulty: .hard)
            XCTAssertLessThan(value, previous)
            XCTAssertGreaterThan(value, 0)
            previous = value
        }
    }

    func testGuessesPastTheLimitClampRatherThanOvershooting() {
        XCTAssertEqual(JourneymanScoring.value(guess: 99, difficulty: nil),
                       JourneymanScoring.value(guess: JourneymanScoring.maxGuesses, difficulty: nil))
        let result = JourneymanScoring.score(guessesUsed: 99, solved: true)
        XCTAssertEqual(result.guessesUsed, JourneymanScoring.maxGuesses)
    }

    /// A run that used every guess and never landed one scores nothing — the limit has to bite,
    /// or an early solve is worth no more than grinding through the whole list.
    func testRunningOutOfGuessesScoresNothing() {
        let result = JourneymanScoring.score(guessesUsed: JourneymanScoring.maxGuesses,
                                             solved: false, difficulty: .hard)
        XCTAssertEqual(result.total, 0)
        XCTAssertEqual(result.performance, 0)
        XCTAssertEqual(result.wrongGuesses, JourneymanScoring.maxGuesses)
    }

    func testWrongGuessesAreDerivedFromTheOutcome() {
        XCTAssertEqual(JourneymanScoring.score(guessesUsed: 3, solved: true).wrongGuesses, 2)
        XCTAssertEqual(JourneymanScoring.score(guessesUsed: 3, solved: false).wrongGuesses, 3)
    }

    // MARK: - Difficulty and the rating invariant

    func testDifficultyScalesPointsButNeverPerformance() {
        let easy = JourneymanScoring.score(guessesUsed: 2, solved: true, difficulty: .easy)
        let hard = JourneymanScoring.score(guessesUsed: 2, solved: true, difficulty: .hard)
        XCTAssertGreaterThan(hard.total, easy.total)
        // §4's invariant: the tier the pipeline happened to serve must not move a rating.
        XCTAssertEqual(hard.performance, easy.performance, accuracy: 0.0001)
    }

    func testAnUnratedBoardScoresExactlyAsAnEasyOneDoes() {
        XCTAssertEqual(JourneymanScoring.multiplier(nil), 1.0)
        XCTAssertEqual(JourneymanScoring.value(guess: 1, difficulty: nil),
                       JourneymanScoring.value(guess: 1, difficulty: .easy))
    }

    // MARK: - Duel comparability

    /// Both duellists play the same board, and the denominator is a constant — but the mapping
    /// still has to reward naming it sooner, or a duel would go to whoever guessed most.
    func testDuelHitsRewardNamingItEarly() {
        let early = JourneymanScoring.score(guessesUsed: 1, solved: true)
        let late = JourneymanScoring.score(guessesUsed: 5, solved: true)
        let lost = JourneymanScoring.score(guessesUsed: 5, solved: false)
        XCTAssertEqual(ChallengeLink.journeymanHits(early), 5)
        XCTAssertEqual(ChallengeLink.journeymanHits(late), 1)
        XCTAssertEqual(ChallengeLink.journeymanHits(lost), 0)
        XCTAssertEqual(ChallengeLink.journeymanOutOf, 5)
    }
}

// MARK: - Content

final class JourneymanPuzzleTests: XCTestCase {

    /// The exact wire shape `tools/ingest/journeyman.py` writes into `puzzles.content`. Decoded
    /// from raw JSON rather than round-tripped through `Encodable`, because a round trip only
    /// proves the model agrees with itself.
    private let liveContent = """
    {
      "id": "nfl-drew-brees-journeyman-daily-20260819",
      "sport": "nfl",
      "difficulty": "medium",
      "answer": {"canonical": "Drew Brees", "aliases": []},
      "position": "QB",
      "headshot": "https://example.test/brees.png",
      "stints": [
        {"order": 1, "teamAbbr": "LAC", "teamName": "Chargers", "league": "",
         "firstYear": 2001, "lastYear": 2005},
        {"order": 2, "teamAbbr": "NO", "teamName": "Saints", "league": "",
         "firstYear": 2006, "lastYear": 2020}
      ]
    }
    """

    func testDecodesThePipelinesContent() throws {
        let puzzle = try JSONDecoder().decode(JourneymanPuzzle.self,
                                              from: Data(liveContent.utf8))
        XCTAssertEqual(puzzle.sport, .nfl)
        XCTAssertEqual(puzzle.difficulty, .medium)
        XCTAssertEqual(puzzle.stints.count, 2)
        XCTAssertEqual(puzzle.stints[0].teamName, "Chargers")
        XCTAssertEqual(puzzle.stints[0].yearsLabel, "2001–2005")
        XCTAssertNil(puzzle.truncated)
        XCTAssertNil(puzzle.stints[0].historical)
    }

    /// `historical`/`truncated` are additive fields the pipeline only writes when true — an
    /// older bundled pool has neither, and decoding must treat their absence as "no", not throw.
    func testOptionalFieldsAreTrulyOptional() throws {
        let minimal = """
        {"id": "x", "sport": "nba", "answer": {"canonical": "A B", "aliases": []},
         "stints": [{"order": 1, "teamAbbr": "LAL", "teamName": "Lakers", "league": "",
                     "firstYear": 2010, "lastYear": 2012},
                    {"order": 2, "teamAbbr": "MIA", "teamName": "Heat", "league": "",
                     "firstYear": 2013, "lastYear": 2015}]}
        """
        let puzzle = try JSONDecoder().decode(JourneymanPuzzle.self, from: Data(minimal.utf8))
        XCTAssertNil(puzzle.difficulty)          // unrated, not medium
        XCTAssertNil(puzzle.position)
        XCTAssertNil(puzzle.headshot)
    }

    /// An unrecognized difficulty must not throw: the whole archive is decoded as one array, so
    /// one bad word would empty Browse. Same trap `ClueKind` and `PuzzleFormat` document.
    func testAnUnknownDifficultyDecodesRatherThanThrowing() throws {
        let json = liveContent.replacingOccurrences(of: "\"medium\"", with: "\"legendary\"")
        let puzzle = try JSONDecoder().decode(JourneymanPuzzle.self, from: Data(json.utf8))
        XCTAssertEqual(puzzle.difficulty, .medium)
    }

    func testASingleSeasonStintReadsAsOneYear() {
        let stint = JourneymanPuzzle.Stint(order: 1, teamAbbr: "NYJ", teamName: "Jets",
                                           league: "", firstYear: 2019, lastYear: 2019)
        XCTAssertEqual(stint.yearsLabel, "2019")
        XCTAssertEqual(stint.seasonCount, 1)
    }

    func testTheBundledOfflinePoolDecodes() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "journeyman_puzzles",
                                                withExtension: "json"),
                                "journeyman_puzzles.json missing from the app bundle")
        let puzzles = try JSONDecoder().decode([JourneymanPuzzle].self,
                                               from: Data(contentsOf: url))
        XCTAssertFalse(puzzles.isEmpty)
        for puzzle in puzzles {
            XCTAssertGreaterThanOrEqual(puzzle.stints.count, 2, "\(puzzle.id) has no path to reveal")
            XCTAssertFalse(puzzle.answer.canonical.isEmpty)
            // Chronological, and never the same club twice in a row — the two things the board
            // renders directly and cannot recover from.
            for (a, b) in zip(puzzle.stints, puzzle.stints.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.firstYear, a.firstYear, "\(puzzle.id) is out of order")
                XCTAssertNotEqual(a.teamName, b.teamName, "\(puzzle.id) repeats a club")
            }
        }
    }
}

// MARK: - Sharing

final class JourneymanShareTests: XCTestCase {

    private func puzzle(stints: Int = 4) -> JourneymanPuzzle {
        JourneymanPuzzle(
            id: "nfl-test-journeyman", sport: .nfl,
            stints: (1...stints).map {
                JourneymanPuzzle.Stint(order: $0, teamAbbr: "NO", teamName: "Club \($0)",
                                       league: "", firstYear: 2000 + $0, lastYear: 2000 + $0)
            },
            answer: .init(canonical: "Drew Brees", aliases: []),
            difficulty: .medium, position: "QB", headshot: nil)
    }

    func testEmojiRowMarksTheGuessThatLanded() {
        let result = JourneymanScoring.score(guessesUsed: 2, solved: true)
        XCTAssertEqual(JourneymanResultView.emojiPath(result: result), "⬛🟩⬜⬜⬜")
    }

    func testAnUnsolvedRowHasNothingGreen() {
        let result = JourneymanScoring.score(guessesUsed: 5, solved: false)
        XCTAssertEqual(JourneymanResultView.emojiPath(result: result), "⬛⬛⬛⬛⬛")
    }

    /// The share artifact must be spoiler-free: this format's answer is one name and its board is
    /// a handful of club names, so leaking either ruins the puzzle for every reader.
    func testShareTextNeverLeaksTheAnswerOrAClub() {
        let p = puzzle()
        let result = JourneymanScoring.score(guessesUsed: 2, solved: true)
        for isDaily in [true, false] {
            let text = JourneymanResultView.shareText(puzzle: p, result: result, isDaily: isDaily)
            XCTAssertFalse(text.contains("Brees"), "share text leaked the answer")
            for stint in p.stints {
                XCTAssertFalse(text.contains(stint.teamName), "share text leaked a club")
            }
        }
    }

    func testTheChallengeLinkCarriesTheGuessLimit() {
        let result = JourneymanScoring.score(guessesUsed: 2, solved: true)
        let link = JourneymanResultView.challengeLink(puzzle: puzzle(), result: result)
        XCTAssertEqual(link.format, .journeyman)
        XCTAssertEqual(link.outOf, JourneymanScoring.maxGuesses)
        XCTAssertEqual(link.hits, 4)
    }
}

// MARK: - Bot

final class JourneymanBotTests: XCTestCase {

    private func board(clubs: Int) -> JourneymanPuzzle {
        JourneymanPuzzle(
            id: "b", sport: .nfl,
            stints: (1...clubs).map {
                JourneymanPuzzle.Stint(order: $0, teamAbbr: "NO", teamName: "Club \($0)",
                                       league: "", firstYear: 2000 + $0, lastYear: 2000 + $0)
            },
            answer: .init(canonical: "A B", aliases: []))
    }

    func testTheBotNeverExceedsTheGuessLimit() {
        for clubs in 2...8 {
            for seed in UInt64(0)..<20 {
                let run = BotSolver.playJourneyman(board(clubs: clubs), skill: 0.5, seed: seed,
                                                   timeLimit: 120)
                XCTAssertLessThanOrEqual(run.beats.count, JourneymanScoring.maxGuesses)
                XCTAssertEqual(run.outOf, JourneymanScoring.maxGuesses)
                XCTAssertLessThanOrEqual(run.correct, JourneymanScoring.maxGuesses)
            }
        }
    }

    func testTheBotIsDeterministicForASeed() {
        let a = BotSolver.playJourneyman(board(clubs: 5), skill: 0.7, seed: 42, timeLimit: 120)
        let b = BotSolver.playJourneyman(board(clubs: 5), skill: 0.7, seed: 42, timeLimit: 120)
        XCTAssertEqual(a.performance, b.performance)
        XCTAssertEqual(a.beats.count, b.beats.count)
    }

    func testAStrongerBotSolvesEarlierOnAverage() {
        func meanGuesses(skill: Double) -> Double {
            let runs = (UInt64(0)..<60).map {
                BotSolver.playJourneyman(board(clubs: 6), skill: skill, seed: $0, timeLimit: 120)
            }
            return Double(runs.map(\.beats.count).reduce(0, +)) / Double(runs.count)
        }
        XCTAssertLessThan(meanGuesses(skill: 0.95), meanGuesses(skill: 0.35))
    }
}

// MARK: - Archive teasers

final class JourneymanTeaserTests: XCTestCase {

    /// Club names are deliberately distinctive words, not "A"/"B"/"C": a single letter is inside
    /// half the English language, so the leak assertion below would fail on "**A** stop" and
    /// "**A**bsence" and prove nothing. Same reason `tools/ingest/validate.py`'s clue-leak check
    /// skips short name parts — a substring test needs substrings worth testing.
    private func board(id: String = "b", clubs: [(String, Int)],
                       truncated: Bool? = nil) -> JourneymanPuzzle {
        var year = 2000
        var stints: [JourneymanPuzzle.Stint] = []
        for (i, club) in clubs.enumerated() {
            stints.append(JourneymanPuzzle.Stint(order: i + 1, teamAbbr: club.0, teamName: club.0,
                                                 league: "", firstYear: year,
                                                 lastYear: year + club.1 - 1))
            year += club.1
        }
        return JourneymanPuzzle(id: id, sport: .nfl, stints: stints,
                                answer: .init(canonical: "Drew Brees", aliases: []),
                                truncated: truncated)
    }

    /// The card has to read the same on every launch and every device — `String.hashValue` is
    /// randomized per process, which is exactly the trap this seeds around.
    func testATeaserIsStableForAGivenPuzzle() {
        let puzzle = board(id: "nfl-someone-journeyman", clubs: [("Zephyrs", 3), ("Quokkas", 4), ("Vipers", 2)])
        let first = JourneymanTeaser.line(for: puzzle)
        for _ in 0..<50 {
            XCTAssertEqual(JourneymanTeaser.line(for: puzzle), first)
        }
    }

    /// Two different boards should mostly not read identically — a pool that collapsed to one
    /// line would make the archive a wall of the same joke.
    func testDifferentPuzzlesGetDifferentTeasers() {
        let lines = (0..<40).map { i in
            JourneymanTeaser.line(for: board(id: "id-\(i)", clubs: [("Zephyrs", 3), ("Quokkas", 4), ("Vipers", 2)]))
        }
        XCTAssertGreaterThan(Set(lines).count, 1)
    }

    /// The one hard rule: a teaser is derived from the path's shape and can never name the
    /// player. Checked against every branch, using an answer whose name parts are common words.
    func testATeaserNeverContainsTheAnswer() {
        let shapes: [[(String, Int)]] = [
            [("Zephyrs", 12), ("Quokkas", 2)],                                        // loyal
            [("Zephyrs", 1), ("Quokkas", 1), ("Vipers", 3)],                               // cup of coffee
            [("Zephyrs", 3), ("Quokkas", 2), ("Zephyrs", 2)],                               // return
            [("Zephyrs", 2), ("Quokkas", 2), ("Vipers", 2), ("Wombats", 2)],                     // wanderer
            [("Zephyrs", 2), ("Quokkas", 2), ("Vipers", 2), ("Wombats", 2), ("Xenons", 2), ("Yaks", 2)], // journeyman
            [("Zephyrs", 4), ("Quokkas", 3)],                                         // default
        ]
        for (i, shape) in shapes.enumerated() {
            for seed in 0..<20 {
                let puzzle = board(id: "s\(i)-\(seed)", clubs: shape)
                let line = JourneymanTeaser.line(for: puzzle)
                XCTAssertFalse(line.localizedCaseInsensitiveContains("Drew"), line)
                XCTAssertFalse(line.localizedCaseInsensitiveContains("Brees"), line)
                for stint in puzzle.stints {
                    XCTAssertFalse(line.contains(stint.teamName), line)
                }
                XCTAssertFalse(line.isEmpty)
            }
        }
    }

    /// A truncated board must say so, whatever else its shape qualifies for — the club count
    /// printed underneath it is a floor, not a total, and a joke about a "tidy little career"
    /// over a truncated 12-club path is simply false.
    func testATruncatedPathAlwaysSaysSo() {
        for seed in 0..<20 {
            let puzzle = board(id: "t\(seed)", clubs: [("Zephyrs", 2), ("Quokkas", 3)], truncated: true)
            let line = JourneymanTeaser.line(for: puzzle)
            XCTAssertTrue(line.contains("more") || line.contains("recent"), line)
        }
    }

    func testAReturnSpellIsDetectedByClubNameNotByCode() {
        let returned = board(clubs: [("Zephyrs", 2), ("Quokkas", 2), ("Zephyrs", 2)])
        XCTAssertTrue(JourneymanTeaser.returnedSomewhere(returned.stints))
        let straightThrough = board(clubs: [("Zephyrs", 2), ("Quokkas", 2), ("Vipers", 2)])
        XCTAssertFalse(JourneymanTeaser.returnedSomewhere(straightThrough.stints))
    }

    /// Every board gets a line, including the degenerate ones the pipeline never mints.
    func testEveryBoardGetsALine() {
        XCTAssertFalse(JourneymanTeaser.line(for: board(clubs: [("Zephyrs", 1)])).isEmpty)
        XCTAssertFalse(JourneymanTeaser.line(for: board(clubs: [("Zephyrs", 20), ("Quokkas", 20)])).isEmpty)
    }
}
