import XCTest
@testable import BallIQ

/// The ladder's blitz half: the mode vocabulary the rung array decodes through, the fixed config a
/// rung plays, and the two normalisations that keep a run's numbers inside the `ladder_attempts`
/// `0...1` check constraints.
///
/// The seeder's own run/curve model is pinned on the Python side
/// (`tools/ingest/tests/test_ladder_blitz.py`); this file is the client half of that contract.
final class LadderBlitzTests: XCTestCase {

    // MARK: - The mode vocabulary

    /// **The decode must never throw on an unknown mode**, because `LadderRepository.rungs()`
    /// decodes all 30 rungs as one array under a single `try?` — one bad word would otherwise empty
    /// the Ladder tab for every user. A mode added server-side before this client understands it
    /// has to degrade, not detonate.
    func testUnknownModeDecodesToKeep4RatherThanThrowing() throws {
        let json = """
        [{"rung":1,"tier":"bronze","mode":"quadruple","sport":"nfl","puzzle_id":"p1",
          "bot_id":"b","bot_skill":0.5,"time_limit_seconds":60,"seed":1,"is_boss":false}]
        """
        let rungs = try JSONDecoder().decode([LadderRung].self, from: Data(json.utf8))
        XCTAssertEqual(rungs.count, 1, "an unknown mode must not take the whole array with it")
        XCTAssertEqual(rungs[0].mode, .keep4)
    }

    func testBlitzModeDecodesAndKeepsItsRunShapePuzzleId() throws {
        let json = """
        [{"rung":12,"tier":"silver","mode":"blitz","sport":"nfl","puzzle_id":"blitz-180s",
          "bot_id":"b","bot_skill":0.42,"time_limit_seconds":180,"seed":7919,"is_boss":false}]
        """
        let rungs = try JSONDecoder().decode([LadderRung].self, from: Data(json.utf8))
        XCTAssertEqual(rungs.first?.mode, .blitz)
        // The run shape is not a real puzzle row; it must decode as a plain non-optional string.
        XCTAssertEqual(rungs.first?.puzzleId, "blitz-180s")
    }

    /// Blitz is not a row-backed `PuzzleFormat`, and the mapping has to say so — that absence is
    /// the whole reason `LadderMode` exists beside `PuzzleFormat` instead of inside it.
    func testBlitzHasNoPuzzleFormatButTheFourBoardsDo() {
        XCTAssertNil(LadderMode.blitz.puzzleFormat)
        XCTAssertEqual(LadderMode.blitz.displayName, String(localized: "Puzzle Blitz"))
        XCTAssertTrue(LadderMode.blitz.isBlitz)
        for mode in [LadderMode.keep4, .whoami, .grid, .journeyman] {
            XCTAssertNotNil(mode.puzzleFormat, mode.rawValue)
            XCTAssertFalse(mode.isBlitz, mode.rawValue)
        }
        XCTAssertEqual(Set(LadderMode.allCases.compactMap(\.puzzleFormat)),
                       Set([.keep4, .whoami, .grid, .journeyman]))
    }

    // MARK: - Duration is a variance dial

    /// Mirrors `LadderBlitz`'s contract and the seeder's `duration_for`: bosses get five minutes,
    /// the low target band gets one, everything else three. A boss that quietly ran 60s would be a
    /// coin flip, not the tightest statement on the ladder.
    func testDurationRisesWithRungAndPeaksForBosses() {
        XCTAssertEqual(LadderBlitz.duration(forRung: 1, isBoss: false), .one)
        XCTAssertEqual(LadderBlitz.duration(forRung: LadderBlitz.oneMinuteMaxRung, isBoss: false), .one)
        XCTAssertEqual(LadderBlitz.duration(forRung: LadderBlitz.oneMinuteMaxRung + 1, isBoss: false), .three)
        XCTAssertEqual(LadderBlitz.duration(forRung: 30, isBoss: false), .three)
        // A boss is always the longest run, whatever its rung.
        XCTAssertEqual(LadderBlitz.duration(forRung: 10, isBoss: true), .five)
        XCTAssertEqual(LadderBlitz.duration(forRung: 30, isBoss: true), .five)
    }

    /// More boards than any run can reach, so the clock — never a short draw — ends a run. This
    /// mirrors `SEQUENCE_LENGTH` in `tools/ingest/ladder_blitz.py`, which the curve was measured at.
    func testSequenceLengthOutlastsAnyRun() {
        XCTAssertEqual(LadderBlitz.sequenceLength, 12)
    }

    // MARK: - The rung's fixed config

    /// A ladder rung is a difficulty, so its mix is fixed and matches the seeder: K4C4, Who Am I?
    /// and Journeyman. Over/Under is absent because the seeder cannot calibrate it, and The Grid is
    /// absent per `BlitzFormat.excluded`.
    func testLadderConfigUsesTheSeedersFormatsAndThePlayersEntitledSports() {
        let config = BlitzConfig.ladder(sports: [.nfl, .nba], duration: .three)
        XCTAssertEqual(config.formats, [.keep4, .whoami, .journeyman])
        XCTAssertEqual(config.sports, [.nfl, .nba])
        XCTAssertEqual(config.duration, .three)
        XCTAssertTrue(config.isPlayable)
        XCTAssertFalse(config.formats.contains(.overunder),
                       "the seeder cannot calibrate Over/Under, so a blitz rung must not serve it")
    }

    // MARK: - Normalisation for the corpus columns

    /// `ladder_attempts.bot_score` is `check (bot_score >= 0 and bot_score <= 1)`, so the bot's
    /// mean quality has to satisfy that for every run, including an empty one.
    func testBotMeanQualityAlwaysSatisfiesTheDatabaseCheck() {
        let rounds = [
            BlitzRoundResult(format: .keep4, sport: .nfl, puzzleID: "a", performance: 0.0, cleared: false, elapsed: 5),
            BlitzRoundResult(format: .whoami, sport: .nba, puzzleID: "b", performance: 1.0, cleared: true, elapsed: 5),
            BlitzRoundResult(format: .journeyman, sport: .nfl, puzzleID: "c", performance: 0.37, cleared: true, elapsed: 5),
        ]
        for count in 0...rounds.count {
            let run = BlitzBotRun(rounds: Array(rounds.prefix(count)), points: 0, elapsed: 0)
            XCTAssertGreaterThanOrEqual(run.meanQuality, 0)
            XCTAssertLessThanOrEqual(run.meanQuality, 1)
        }
        XCTAssertEqual(BlitzBotRun(rounds: [], points: 0, elapsed: 0).meanQuality, 0)
    }

    /// The player-side comparable the ladder stores is `BlitzRunSummary.performance`, which is
    /// already documented as `0...1`. This is the other half of the same constraint.
    func testPlayerRunPerformanceAlwaysSatisfiesTheDatabaseCheck() {
        let rounds = [
            BlitzRoundResult(format: .keep4, sport: .nfl, puzzleID: "a", performance: 0, cleared: false, elapsed: 5),
            BlitzRoundResult(format: .overunder, sport: .nfl, puzzleID: "b", performance: 0, cleared: false, elapsed: 5),
        ]
        let summary = BlitzRunSummary(config: .default, rounds: rounds, elapsed: 60)
        XCTAssertGreaterThanOrEqual(summary.performance, 0)
        XCTAssertLessThanOrEqual(summary.performance, 1)
    }
}
