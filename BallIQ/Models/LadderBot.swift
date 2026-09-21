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
    /// How this bot plays, as distinct from how well — see `BotStyle`. Changes `BotSolver`'s
    /// policy, so it is a gameplay property, not a label.
    var style: BotStyle = .consistent
    /// The one-line description of `style` shown before the duel. A style the player cannot
    /// anticipate is noise rather than personality, so this is content, not derived text.
    var styleLine: String = ""
    var backstory: String = ""
    var palette: BotPalette = .electric
    /// What they say, keyed by the moment. Every field optional — silence beats a filler line.
    var voice: BotVoice = .empty
    /// What they KNOW, as distinct from how well they play — eras, sports, and which end of
    /// the fame range they are better at. See `BotKnowledge`; `.neutral` is the identity, so a
    /// bot without a profile plays exactly as it did before knowledge existed.
    var knowledge: BotKnowledge = .neutral
    /// `knowledge` stated to the player before the duel — the same contract `styleLine` has.
    /// A blind spot the player cannot anticipate isn't a character trait, it's an unexplained
    /// loss, and the one thing that separates this from a random difficulty wobble is that the
    /// player was told first and can pick their board.
    var knowledgeLine: String = ""
    /// Who they support, in order. Rendered as real crests by `TeamAbbrChip` — in a sports app
    /// this is characterisation, not data: three logos say more about someone than a paragraph.
    /// Empty is meaningful rather than missing (Nova has no allegiances, and the card says so).
    var favoriteTeams: [BotTeam] = []

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, tagline, persona, style, backstory, palette, voice, knowledge
        case knowledgeLine = "knowledge_line"
        case baseSkill = "base_skill"
        case styleLine = "style_line"
        case favoriteTeams = "favorite_teams"
    }

    /// Hand-written so a bot row cached before the character columns landed still decodes —
    /// `DiskCache` has no schema version, so a stale roster outlives the upgrade and a throw
    /// here would empty the ladder.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatar = try c.decode(String.self, forKey: .avatar)
        tagline = try c.decode(String.self, forKey: .tagline)
        baseSkill = try c.decode(Double.self, forKey: .baseSkill)
        persona = try c.decodeIfPresent(String.self, forKey: .persona) ?? ""
        style = try c.decodeIfPresent(BotStyle.self, forKey: .style) ?? .consistent
        styleLine = try c.decodeIfPresent(String.self, forKey: .styleLine) ?? ""
        backstory = try c.decodeIfPresent(String.self, forKey: .backstory) ?? ""
        palette = try c.decodeIfPresent(BotPalette.self, forKey: .palette) ?? .electric
        voice = try c.decodeIfPresent(BotVoice.self, forKey: .voice) ?? .empty
        favoriteTeams = try c.decodeIfPresent([BotTeam].self, forKey: .favoriteTeams) ?? []
        knowledge = try c.decodeIfPresent(BotKnowledge.self, forKey: .knowledge) ?? .neutral
        knowledgeLine = try c.decodeIfPresent(String.self, forKey: .knowledgeLine) ?? ""
    }

    init(id: String, name: String, avatar: String, tagline: String, baseSkill: Double,
         persona: String, style: BotStyle = .consistent, styleLine: String = "",
         backstory: String = "", palette: BotPalette = .electric, voice: BotVoice = .empty,
         favoriteTeams: [BotTeam] = [], knowledge: BotKnowledge = .neutral,
         knowledgeLine: String = "") {
        self.id = id; self.name = name; self.avatar = avatar; self.tagline = tagline
        self.baseSkill = baseSkill; self.persona = persona; self.style = style
        self.styleLine = styleLine; self.backstory = backstory; self.palette = palette
        self.voice = voice
        self.favoriteTeams = favoriteTeams
        self.knowledge = knowledge
        self.knowledgeLine = knowledgeLine
    }
}

/// One team a bot supports. A `(sport, abbr)` pair rather than a name string, so it resolves
/// through `TeamIdentityIndex` like every other team reference in the app — soccer abbreviations
/// collide across leagues, so the pair is the identity, never the abbreviation alone.
struct BotTeam: Codable, Equatable, Hashable, Identifiable {
    let sport: Sport
    let abbr: String
    var id: String { "\(sport.rawValue)-\(abbr)" }
}
