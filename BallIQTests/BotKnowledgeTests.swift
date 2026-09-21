import XCTest
@testable import BallIQ

/// Knowledge has to be a **gameplay** property, the same way `BotStyle` is — the roster's copy
/// makes specific claims ("could not name three players on any other team", "unbeatable on the
/// forgotten decades") and these pin the claims to behaviour. If a profile stops doing what its
/// own card says, that card has become a lie and this goes red.
///
/// The parity half of the contract lives elsewhere: `tools/ingest/ladder.py` re-implements every
/// formula here so the ladder can calibrate against a bot's real policy, and
/// `tools/ingest/tests/test_ladder_knowledge.py` asserts the two agree on a shared table of
/// cases (and reads `maxDelta` back out of this file, so the clamp cannot drift silently).
final class BotKnowledgeTests: XCTestCase {

    private let skill = 0.70

    /// Hal: fifty years of tape across three sports, thin on the last decade.
    private let archivist = BotKnowledge(
        eraFrom: 1960, eraTo: 2010, eraFade: 0.07,
        sports: ["nba": -0.12, "nfl": -0.12, "baseball": -0.12], otherSports: 0.12,
        fameBias: -0.12)

    /// Marisol: one club since 1994, and nothing else at all.
    private let marisol = BotKnowledge(
        eraFrom: 1994, eraTo: 2026, eraFade: 0.069,
        sports: ["soccer": -0.124], otherSports: 0.234, fameBias: -0.138)

    // MARK: - Neutral is the identity, and that is what lets this ship uncalibrated

    func testNeutralChangesNothingForAnyContext() {
        let contexts = [DecisionContext(sport: .nba, year: 1971, fame: 0.9),
                        DecisionContext(sport: .f1, year: 2026, fame: 0.0),
                        DecisionContext.none]
        for context in contexts {
            XCTAssertEqual(BotKnowledge.neutral.delta(for: context), 0)
            for d in stride(from: 0.0, through: 1.0, by: 0.25) {
                XCTAssertEqual(
                    BotSolver.hitProbability(skill: skill, difficulty: d,
                                             knowledge: .neutral, context: context),
                    BotSolver.hitProbability(skill: skill, difficulty: d),
                    accuracy: 1e-12)
            }
        }
    }

    /// A profile with no context to judge is also the identity — which is what makes it safe for
    /// a format to hand over only what it honestly has (a Grid cell has no year, a Keep4 card has
    /// no fame) instead of inventing the rest.
    func testAProfileWithNothingToJudgeIsAlsoTheIdentity() {
        XCTAssertEqual(archivist.delta(for: .none), 0)
        XCTAssertEqual(archivist.delta(for: DecisionContext(year: 1985)), -0.035, accuracy: 1e-9)
    }

    // MARK: - Era

    func testInsideTheEraIsSharperAndOutsideDecaysPerDecade() {
        XCTAssertEqual(archivist.eraDelta(year: 1985), -0.035, accuracy: 1e-9)   // home
        XCTAssertEqual(archivist.eraDelta(year: 2020), 0.07, accuracy: 1e-9)     // one decade out
        XCTAssertEqual(archivist.eraDelta(year: 2030), 0.14, accuracy: 1e-9)     // two
        XCTAssertEqual(archivist.eraDelta(year: 1950), 0.07, accuracy: 1e-9)     // symmetric
    }

    /// Distance from the nearer EDGE, not from the midpoint: someone who watched 1960-2010
    /// should find 2011 nearly as easy as 2009, where a midpoint model would make both ends of
    /// a long era equally hard — the opposite of what a long era means.
    func testEraDistanceIsMeasuredFromTheEdgeNotTheMidpoint() {
        XCTAssertEqual(archivist.eraDelta(year: 2009), archivist.eraDelta(year: 1961))
        XCTAssertLessThan(archivist.eraDelta(year: 2011), archivist.eraDelta(year: 2040))
    }

    func testAnOpenEndedEraOnlyFadesOnTheSideItBounds() {
        // Solomon's decades run back as far as the catalog goes; only the modern side fades.
        let solomon = BotKnowledge(eraFrom: nil, eraTo: 1990, eraFade: 0.1)
        XCTAssertEqual(solomon.eraDelta(year: 1908), -0.05, accuracy: 1e-9)
        XCTAssertEqual(solomon.eraDelta(year: 2020), 0.30, accuracy: 1e-9)
    }

    // MARK: - Sport

    func testAnUnlistedSportFallsBackToOtherSports() {
        XCTAssertEqual(marisol.sportDelta(sport: .soccer), -0.124, accuracy: 1e-9)
        XCTAssertEqual(marisol.sportDelta(sport: .nba), 0.234, accuracy: 1e-9)
        XCTAssertEqual(marisol.sportDelta(sport: .f1), 0.234, accuracy: 1e-9)
        XCTAssertEqual(marisol.sportDelta(sport: nil), 0)
    }

    // MARK: - Fame

    /// Positive bias = better on household names, and famous means EASIER, so the delta it
    /// produces on a famous subject has to be negative. The sign is the one thing about this
    /// term that is easy to get backwards.
    func testFameBiasSignsPointTheRightWay() {
        let starsOnly = BotKnowledge(fameBias: 0.2)
        let deepCuts = BotKnowledge(fameBias: -0.2)
        XCTAssertEqual(starsOnly.fameDelta(fame: 1.0), -0.2, accuracy: 1e-9)
        XCTAssertEqual(starsOnly.fameDelta(fame: 0.0), 0.2, accuracy: 1e-9)
        XCTAssertEqual(starsOnly.fameDelta(fame: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(deepCuts.fameDelta(fame: 1.0), 0.2, accuracy: 1e-9)
        XCTAssertNil(DecisionContext.fame(for: nil))
    }

    /// An unrated subject stays unrated rather than becoming medium — the same distinction
    /// `WhoAmIPuzzle.difficulty` exists to preserve, carried through to the bot side.
    func testUnratedSubjectsDropTheFameTermEntirely() {
        let deepCuts = BotKnowledge(fameBias: -0.3)
        XCTAssertEqual(deepCuts.delta(for: DecisionContext(fame: DecisionContext.fame(for: nil))), 0)
        // An obscure subject is EASIER for a deep-cuts profile, so the delta is negative — the
        // same sign convention `testFameBiasSignsPointTheRightWay` pins from the other end.
        XCTAssertEqual(deepCuts.delta(for: DecisionContext(fame: DecisionContext.fame(for: .hard))),
                       -0.21, accuracy: 1e-9)
    }

    // MARK: - The clamp

    /// The cap has to hold, because at the top of the ladder `bot_skill` is already 1.0 and
    /// nothing the calibrator can do compensates for what knowledge takes away up there — the
    /// same ceiling `BotStyle.blinkChance` documents.
    func testTotalSwingIsClamped() {
        let absurd = BotKnowledge(eraFrom: 2000, eraTo: 2001, eraFade: 0.4,
                                  sports: [:], otherSports: 0.4, fameBias: -0.4)
        let worst = DecisionContext(sport: .f1, year: 1900, fame: 0.0)
        XCTAssertEqual(absurd.delta(for: worst), BotKnowledge.maxDelta, accuracy: 1e-12)
        let best = BotKnowledge(eraFrom: 2000, eraTo: 2001, eraFade: 0.4,
                                sports: ["nba": -0.4], otherSports: 0, fameBias: 0.9)
        XCTAssertEqual(best.delta(for: DecisionContext(sport: .nba, year: 2000, fame: 1.0)),
                       -BotKnowledge.maxDelta, accuracy: 1e-12)
    }

    // MARK: - Through the solver

    /// The headline claim: the same bot, the same board difficulty, two different decades.
    func testTheSameBotIsMeasurablyWorseOutsideItsEra() {
        let home = BotSolver.hitProbability(skill: skill, difficulty: 0.5, knowledge: archivist,
                                            context: DecisionContext(sport: .nba, year: 1985))
        let away = BotSolver.hitProbability(skill: skill, difficulty: 0.5, knowledge: archivist,
                                            context: DecisionContext(sport: .nba, year: 2024))
        XCTAssertGreaterThan(home - away, 0.02,
                             "an era profile the player is told about has to be visible in play")
    }

    /// Knowledge is applied BEFORE style, so `deepCuts` inverts a difficulty that already knows
    /// what the decision was about. Pinning it here because the two orders differ numerically and
    /// only one of them matches `tools/ingest/ladder.py` — a silent swap would mis-calibrate
    /// every rung guarded by a character who has both.
    func testKnowledgeIsAppliedBeforeStyle() {
        let knowledge = BotKnowledge(sports: ["nba": 0.3])
        let context = DecisionContext(sport: .nba)
        let actual = BotSolver.hitProbability(skill: skill, difficulty: 0.4, style: .deepCuts,
                                              knowledge: knowledge, context: context)
        let knowledgeFirst = pow(skill, BotStyle.deepCuts.difficulty(0.7, progress: 0))
        let styleFirst = pow(skill, BotStyle.deepCuts.difficulty(0.4, progress: 0) + 0.3)
        XCTAssertEqual(actual, knowledgeFirst, accuracy: 1e-12)
        XCTAssertNotEqual(actual, styleFirst, accuracy: 1e-6)
    }

    /// A Keep4 run still has to respect the 4/4 cap whatever knowledge does to the odds — the
    /// cap is the thing that keeps a bot's run comparable to a human's rather than an easier game.
    func testKeep4PilesStillSplitFourFourUnderAProfile() {
        let puzzle = Self.puzzle()
        for seed in UInt64(1)...25 {
            let piles = BotSolver.keep4PileCounts(puzzle, skill: 0.5, seed: seed,
                                                  knowledge: marisol)
            XCTAssertEqual(piles.keep, 4)
            XCTAssertEqual(piles.cut, 4)
        }
    }

    /// The whole run moves, not just one card: an out-of-era board should cost a bot real
    /// correct answers across repeated seeds, which is what a player would actually notice.
    func testAnOutOfEraBoardCostsTheBotCorrectAnswersAcrossSeeds() {
        let inEra = Self.puzzle(year: 1985)
        let outOfEra = Self.puzzle(year: 2024)
        func meanCorrect(_ puzzle: Keep4Puzzle) -> Double {
            let runs = (UInt64(1)...120).map {
                BotSolver.playKeep4(puzzle, skill: 0.6, seed: $0, timeLimit: 120,
                                    knowledge: archivist)
            }
            return Double(runs.reduce(0) { $0 + $1.correct }) / Double(runs.count)
        }
        XCTAssertGreaterThan(meanCorrect(inEra), meanCorrect(outOfEra))
    }

    /// Same board, same rung, two different characters — the property the ladder's board pools
    /// turn into a strategy surface, and the reason `build_pool` screens each candidate with its
    /// own contexts rather than the primary's.
    func testTwoCharactersDisagreeAboutTheSameBoard() {
        let board = Self.puzzle(year: 2024)
        func meanCorrect(_ knowledge: BotKnowledge) -> Double {
            let runs = (UInt64(1)...120).map {
                BotSolver.playKeep4(board, skill: 0.6, seed: $0, timeLimit: 120,
                                    knowledge: knowledge)
            }
            return Double(runs.reduce(0) { $0 + $1.correct }) / Double(runs.count)
        }
        // A modern NBA board: home turf for a 2018-2026 fan, away for fifty years of tape.
        let toby = BotKnowledge(eraFrom: 2018, eraTo: 2026, eraFade: 0.095,
                                sports: ["nba": -0.03], otherSports: 0.166, fameBias: 0.178)
        XCTAssertGreaterThan(meanCorrect(toby), meanCorrect(archivist))
    }

    // MARK: - Fixtures

    private static func puzzle(year: Int = 1985) -> Keep4Puzzle {
        let players = (0..<8).map { i in
            PlayerSeason(id: "p\(i)", name: "Player \(i)", teamAbbr: "BOS", seasonYear: year,
                         stats: [], grade: Double(100 + i * 10))
        }
        return Keep4Puzzle(id: "k", theme: "Test", sport: .nba, players: players)
    }
}
