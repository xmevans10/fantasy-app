import Foundation

/// A ladder opponent's identity. Mirrors the `bots` table (id, name, avatar, tagline,
/// base_skill, persona). Purely a content row — the skill-limited *play* of a bot lives in
/// `BotSolver`, decoupled so the same bot can be re-run at a rung-specific skill/clock without
/// touching this identity.
struct LadderBot: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    /// An emoji standing in for a portrait — pairs with the "never dress a bot as a human" rule
    /// (see HANDOFF-multiplayer.md's Phase 2), so the UI never needs a real headshot asset.
    let avatar: String
    let tagline: String
    let baseSkill: Double
    let persona: String

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, tagline, persona
        case baseSkill = "base_skill"
    }
}
