import SwiftUI

/// What kind of contest a rung is: one of the four row-backed board formats, or a Puzzle Blitz
/// run. This is the ladder's own vocabulary, **not** `PuzzleFormat`.
///
/// `PuzzleFormat`'s contract (its own doc comment) is "a format whose board is a stable row in
/// `puzzles`", and it is shared with `versus_challenges.format` and `ChallengeLink`. A blitz rung
/// is none of those things: a run aggregates several boards across formats and sports, has no
/// single par, and pins no row. Adding `blitz` to `PuzzleFormat` would force a par, a decision
/// count and a `GameFormatKind` onto something that has none, and would let `ChallengeLink` mint
/// a challenge to a board that does not exist.
///
/// It is also the forward-compatibility seam. This type decodes an unknown mode to `.keep4` the
/// same way `PuzzleFormat` and `LadderRung.Tier` do, so a mode added server-side before a shipped
/// client understands it cannot throw the whole rung array — `LadderRepository.rungs()` decodes
/// all 30 under one `try?`, and a throw there empties the tab for every user. (In practice a
/// shipped client already maps `blitz` through `PuzzleFormat`'s identical lenient decoder to
/// `.keep4`, so the failure is a mislabelled rung that won't start, not a blank ladder — still
/// the reason the client must ship before the rows do.) Do not "simplify" this back to
/// `PuzzleFormat`.
enum LadderMode: String, Codable, CaseIterable {
    case keep4, whoami, grid, journeyman, blitz

    /// The row-backed board format this mode plays, or nil for `.blitz`, whose round is drawn
    /// fresh every attempt and has no single `puzzles` row. Mirrors `BlitzFormat.puzzleFormat`.
    var puzzleFormat: PuzzleFormat? {
        switch self {
        case .keep4:      return .keep4
        case .whoami:     return .whoami
        case .grid:       return .grid
        case .journeyman: return .journeyman
        case .blitz:      return nil
        }
    }

    /// Player-facing name. Blitz is its own name — there is no `PuzzleFormat` to borrow one from.
    var displayName: String { puzzleFormat?.displayName ?? String(localized: "Puzzle Blitz") }

    var isBlitz: Bool { self == .blitz }

    /// Unknown modes decode as `.keep4` rather than throwing — see this type's doc comment.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LadderMode(rawValue: raw) ?? .keep4
    }
}

/// One rung of the bot ladder. Mirrors `ladder_rungs` — see
/// `supabase/migrations/0016_bot_ladder.sql`.
///
/// A rung carries only the **inputs** to a bot's run (which board — or, for a blitz rung, which
/// run length — which bot, how good, how long, what seed). Nothing about how the bot actually
/// played is stored server-side: the client feeds these columns to `BotSolver` and reproduces the
/// identical run on every device with no server round trip during play.
///
/// A `mode == .blitz` rung is the exception to the "which board" half: it pins no `puzzles` row
/// (`puzzleId` carries the run shape, e.g. `blitz-180s`) and draws a fresh seeded board sequence
/// per attempt, so its `seed` column is unused — see `LadderBlitzMatch` and
/// `supabase/migrations/0030_ladder_blitz_mode.sql`.
struct LadderRung: Codable, Equatable, Identifiable {
    let rung: Int
    let tier: Tier
    let mode: LadderMode
    let sport: Sport
    let puzzleId: String
    let botId: String
    /// Overrides the bot's `baseSkill` for this rung, so one character can appear early as a
    /// warm-up and late as a boss.
    let botSkill: Double
    let timeLimitSeconds: Int
    let seed: Int64
    let isBoss: Bool

    var id: Int { rung }

    enum CodingKeys: String, CodingKey {
        case rung, tier, mode, sport, seed
        case puzzleId = "puzzle_id"
        case botId = "bot_id"
        case botSkill = "bot_skill"
        case timeLimitSeconds = "time_limit_seconds"
        case isBoss = "is_boss"
    }

    /// `SeededGenerator` wants a `UInt64`; the column is a signed `bigint` because Postgres has
    /// no unsigned integer type. The bit pattern is what matters, not the sign.
    var generatorSeed: UInt64 { UInt64(bitPattern: seed) }

    /// Bronze / Silver / Gold — the same three tiers Home already shows, reused rather than
    /// given the ladder its own vocabulary.
    enum Tier: String, Codable, CaseIterable {
        case bronze, silver, gold

        var displayName: String {
            switch self {
            case .bronze: return String(localized: "BRONZE")
            case .silver: return String(localized: "SILVER")
            case .gold:   return String(localized: "GOLD")
            }
        }

        /// Metal tints, from the existing role tokens — no new colours (the format-tile system
        /// reserves `ink` for Versus and this is its neighbour, not a replacement).
        var tint: Color {
            switch self {
            case .bronze: return .warningFill
            case .silver: return .textMuted
            case .gold:   return .proFill
            }
        }

        var onTint: Color {
            switch self {
            case .bronze: return .onWarning
            case .silver: return .surface0
            case .gold:   return .onPro
            }
        }

        /// Unknown tiers render as bronze rather than throwing — a fourth tier added
        /// server-side must not empty the ladder on a shipped build.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Tier(rawValue: raw) ?? .bronze
        }
    }
}

/// One board out of a rung's pool — what `next_ladder_board` hands back.
///
/// A rung is a *difficulty*, not a board. With a single `puzzle_id` per rung, losing and retrying
/// served the identical board with the answers already known, so the score meant nothing and
/// `ladder_attempts` filled with rows that look like skill and are actually recall.
///
/// The `seed` is per BOARD, not per rung: reusing the rung's seed across its pool would have the
/// bot replay the same decision pattern on every board it guards — the same blinks at the same
/// indices — which is the exact tell the pool exists to remove.
struct LadderBoard: Codable, Equatable {
    let puzzleId: String
    let seed: Int64
    let boardDifficulty: Double

    enum CodingKeys: String, CodingKey {
        case puzzleId = "puzzle_id"
        case seed
        case boardDifficulty = "board_difficulty"
    }

    /// Same signed-`bigint` bit-pattern reinterpretation as `LadderRung.generatorSeed`.
    var generatorSeed: UInt64 { UInt64(bitPattern: seed) }

    /// The rung's own columns, used when the RPC can't answer — offline, signed out with an empty
    /// pool, or a rung seeded before pools existed. `ladder_rungs.puzzle_id` **is** the pool's
    /// ordinal-0 board and `tools/ingest/ladder.py` derives the rung's seed from `board_seed(rung,
    /// 0)`, so this reproduces the byte-identical bot run the pooled path would have given.
    init(fallback rung: LadderRung) {
        puzzleId = rung.puzzleId
        seed = rung.seed
        boardDifficulty = 0
    }

    init(puzzleId: String, seed: Int64, boardDifficulty: Double) {
        self.puzzleId = puzzleId
        self.seed = seed
        self.boardDifficulty = boardDifficulty
    }
}

/// The player's position on the ladder. Mirrors `ladder_progress`.
struct LadderProgress: Codable, Equatable {
    let highestRung: Int

    enum CodingKeys: String, CodingKey { case highestRung = "highest_rung" }

    static let none = LadderProgress(highestRung: 0)
    init(highestRung: Int) { self.highestRung = highestRung }
    init(from decoder: Decoder) throws {
        highestRung = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Int.self, forKey: .highestRung) ?? 0
    }

    /// The next rung to play. Rungs unlock in a chain — `submit_ladder_attempt` only advances
    /// `highest_rung` to exactly `highest_rung + 1`, so a client can't post itself to rung 30.
    var nextRung: Int { highestRung + 1 }

    func state(of rung: Int) -> LadderRungState {
        if rung <= highestRung { return .cleared }
        if rung == nextRung { return .open }
        return .locked
    }
}

enum LadderRungState: Equatable { case cleared, open, locked }

/// A rung joined to the bot that guards it — what the ladder list and the pre-duel screen
/// actually render. Built client-side from two world-readable tables rather than a server-side
/// join, because both are tiny (30 rungs, 6 bots) and cached for a week.
struct LadderRungRow: Identifiable, Equatable {
    let rung: LadderRung
    let bot: LadderBot
    let state: LadderRungState
    var id: Int { rung.rung }

    /// "K4C4 · NFL", or "Puzzle Blitz · NFL" for a blitz rung — the line under the bot's name.
    var boardLine: String { "\(rung.mode.displayName) · \(rung.sport.displayName)" }
}
