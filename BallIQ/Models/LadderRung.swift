import SwiftUI

/// One rung of the bot ladder. Mirrors `ladder_rungs` — see
/// `supabase/migrations/0016_bot_ladder.sql`.
///
/// A rung carries only the **inputs** to a bot's run (which board, which bot, how good, how
/// long, what seed). Nothing about how the bot actually played is stored server-side: the
/// client feeds these five columns to `BotSolver` and reproduces the identical run on every
/// device. That is what makes a rung comparable, leaderboard-able and speedrun-able without a
/// single server round trip during play.
struct LadderRung: Codable, Equatable, Identifiable {
    let rung: Int
    let tier: Tier
    let mode: PuzzleFormat
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

    /// "K4C4 · NFL", the line under the bot's name.
    var boardLine: String { "\(rung.mode.displayName) · \(rung.sport.displayName)" }
}
