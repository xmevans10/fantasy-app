import Foundation

/// What a bot *knows*, as distinct from how well it plays (`bot_skill`) and how it plays
/// (`BotStyle`).
///
/// The roster has always described knowledge-shaped people. Ray "couldn't tell you a single
/// advanced metric and could tell you what the weather was like"; Marisol "can name every
/// player to wear the shirt since 1994" and "could not name three players on any other team";
/// Solomon's style line is, verbatim, "Unbeatable on the forgotten decades, human on this
/// one". None of that was true of the opponent the player actually faced. `BotStyle` reshapes
/// the *board's* difficulty signal — a grade gap, a rarity star, a clue index — and that signal
/// knows nothing about which decade a card is from or which sport it belongs to, so Solomon was
/// exactly as good on 1974 as on 2024 and Marisol was as sharp on the NBA as on her own club.
/// The characters wrote cheques the solver could not cash.
///
/// This is the missing axis: a transform on difficulty that depends on **what the decision is
/// about** rather than on how close the call is.
///
/// ## Three dimensions, because three is what the content can actually support
///
/// * **Era** — every Keep4 card carries `seasonYear`, and every Who Am I? / Journeyman subject
///   carries a career span. A bot with an era window is sharper inside it and fades outside.
/// * **Sport** — a bot who follows one sport is guessing at the others. `sports` lists the ones
///   they know; `otherSports` is what everything unlisted costs them.
/// * **Fame** — whether a bot is better on household names or on the players nobody remembers.
///   **Today this only has a signal on Who Am I? and Journeyman**, whose subjects carry an
///   obscurity tier; a Keep4 card has no fame number in the catalog, so the term is simply
///   absent there (see `DecisionContext.fame`).
///
/// ## Neutral is the identity, and that is load-bearing
///
/// `.neutral` adds nothing to any decision, so a bot with no profile plays *bit-identically* to
/// how it played before this type existed. That is what lets the ladder's calibration
/// (`ladder_rungs.target_win_rate`, solved by `tools/ingest/ladder.py`) stay valid until each
/// rung is deliberately re-solved: populating a profile is the change that moves numbers, not
/// shipping this file.
///
/// ## Mirrored in Python, pinned by a test
///
/// `tools/ingest/ladder.py` re-implements every formula here, the same duplicate-and-pin
/// arrangement `grade.py`/`GradeFormula.swift` live under — the ladder solves `bot_skill`
/// against the bot's real policy, so a knowledge term the calibrator can't see would
/// mis-tune every rung its owner guards. `BallIQTests/LadderCurveTests` re-measures with this
/// solver and fails if the two drift apart. **Change a formula here and you must change it
/// there.**
struct BotKnowledge: Codable, Equatable {
    /// First and last year of the bot's era, inclusive. Both nil = no era opinion at all,
    /// which is the honest profile for someone like Nova.
    var eraFrom: Int?
    var eraTo: Int?

    /// How much difficulty one decade outside the era window adds. Also sets the bonus *inside*
    /// it, at half this value — a specialist is both better at home and worse away, and folding
    /// the two into one knob keeps a profile readable as a sentence ("knows 1990-2008, fades
    /// hard outside") rather than as a tuning panel.
    var eraFade: Double = 0

    /// Per-sport difficulty delta. Negative is a specialty, positive is a weak spot. A sport
    /// that isn't listed gets `otherSports`, so a profile names what the character's backstory
    /// names and nothing else.
    var sports: [String: Double] = [:]

    /// What every sport absent from `sports` costs. 0 means "fine everywhere", which is the
    /// right default for a professional and the wrong one for a one-club obsessive.
    var otherSports: Double = 0

    /// Which end of the fame range this bot is better at. Positive = better on household names
    /// (the fan who started last season); negative = better on the forgotten ones (the scout,
    /// the kit man, the programme collector). Magnitude is the swing between the two ends.
    ///
    /// This is the axis that gets sharper the day subject fame stops being a production
    /// percentile — see `tools/ingest/fame_probe.py`. Until then it reads the Who Am I?
    /// obscurity tier, which is derived from exactly that percentile.
    var fameBias: Double = 0

    static let neutral = BotKnowledge()

    /// Hard cap on the total swing knowledge may apply to one decision.
    ///
    /// Knowledge has to be able to lose a bot a card it should have had, and it must never be
    /// able to turn a whole board into a coin flip: at the top of the ladder `bot_skill` is
    /// already at 1.0, so anything knowledge subtracts up there cannot be compensated for by
    /// the calibrator — the same ceiling `BotStyle.blinkChance` documents, for the same reason.
    /// 0.45 is enough to be visible on a reveal screen (a 0.8-skill bot on a 0.5-difficulty
    /// card goes from 89% to 79%) without letting a profile outrank skill.
    static let maxDelta = 0.45

    var isNeutral: Bool { self == .neutral }

    /// The difficulty delta this bot's knowledge applies to one decision. 0 when the profile is
    /// neutral or the context carries nothing to judge.
    ///
    /// Signs: **positive is harder**, matching `difficulty` itself, so every term reads the same
    /// way and the sum is just a sum.
    func delta(for context: DecisionContext) -> Double {
        guard !isNeutral else { return 0 }
        let total = eraDelta(year: context.year)
            + sportDelta(sport: context.sport)
            + fameDelta(fame: context.fame)
        return min(max(total, -Self.maxDelta), Self.maxDelta)
    }

    /// Era term. Inside the window a bot is sharper by half `eraFade`; outside, it pays
    /// `eraFade` per decade of distance from the nearer edge.
    ///
    /// Distance from the *edge*, not from the midpoint: someone who watched from 1970 to 2010
    /// should find 2011 nearly as easy as 2009, and a midpoint model would make 1970 and 2010
    /// equally hard, which is the opposite of what a long era means.
    func eraDelta(year: Int?) -> Double {
        guard eraFade != 0, let year else { return 0 }
        let from = eraFrom ?? Int.min
        let to = eraTo ?? Int.max
        guard from <= to else { return 0 }
        if year >= from && year <= to { return -eraFade / 2 }
        let distance = year < from ? from - year : year - to
        return eraFade * (Double(distance) / 10)
    }

    /// Sport term. An unlisted sport falls back to `otherSports` rather than to 0, so a profile
    /// only has to name the sports the character's backstory names.
    func sportDelta(sport: Sport?) -> Double {
        guard let sport else { return 0 }
        return sports[sport.rawValue] ?? otherSports
    }

    /// Fame term. `fame` is 0...1, 1 being a household name.
    ///
    /// Negated because the two scales run opposite ways: a *positive* `fameBias` means famous
    /// subjects are EASIER for this bot, and easier means a lower difficulty.
    func fameDelta(fame: Double?) -> Double {
        guard fameBias != 0, let fame else { return 0 }
        return -fameBias * (2 * min(max(fame, 0), 1) - 1)
    }

    /// Decodes leniently in every direction — a profile written server-side must never empty
    /// the roster on a shipped build (the rule `BotStyle` and `ClueKind` document). A row from
    /// before this column existed, or one with a key this build doesn't know, decodes as
    /// `.neutral` and the bot plays the way it always did.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .neutral
            return
        }
        eraFrom = try? c.decodeIfPresent(Int.self, forKey: .eraFrom)
        eraTo = try? c.decodeIfPresent(Int.self, forKey: .eraTo)
        eraFade = (try? c.decodeIfPresent(Double.self, forKey: .eraFade)) as? Double ?? 0
        sports = (try? c.decodeIfPresent([String: Double].self, forKey: .sports)) as? [String: Double] ?? [:]
        otherSports = (try? c.decodeIfPresent(Double.self, forKey: .otherSports)) as? Double ?? 0
        fameBias = (try? c.decodeIfPresent(Double.self, forKey: .fameBias)) as? Double ?? 0
    }

    init(eraFrom: Int? = nil, eraTo: Int? = nil, eraFade: Double = 0,
         sports: [String: Double] = [:], otherSports: Double = 0, fameBias: Double = 0) {
        self.eraFrom = eraFrom; self.eraTo = eraTo; self.eraFade = eraFade
        self.sports = sports; self.otherSports = otherSports; self.fameBias = fameBias
    }

    enum CodingKeys: String, CodingKey {
        case eraFrom = "era_from"
        case eraTo = "era_to"
        case eraFade = "era_fade"
        case sports
        case otherSports = "other_sports"
        case fameBias = "fame_bias"
    }
}

/// What one decision is *about* — the inputs a knowledge profile judges, as opposed to
/// `difficulty`, which is how close the call is.
///
/// Every field is optional because the formats genuinely differ in what they can say about a
/// decision, and inventing a value would be worse than having none: a Keep4 card has a real
/// `seasonYear` and no fame number, a Who Am I? subject has a career span and an obscurity
/// tier, and a Grid cell has neither (its rarity star is already the difficulty signal, so
/// reading it as fame as well would count the same fact twice).
struct DecisionContext: Equatable {
    var sport: Sport?
    /// The year this decision is about — a card's season, or the midpoint of a subject's career.
    var year: Int?
    /// 0...1, 1 being a household name. nil where the content carries no fame signal.
    var fame: Double?

    static let none = DecisionContext()

    init(sport: Sport? = nil, year: Int? = nil, fame: Double? = nil) {
        self.sport = sport; self.year = year; self.fame = fame
    }

    /// Fame implied by a Who Am I? / Journeyman obscurity tier.
    ///
    /// Spread wide (0.85 / 0.5 / 0.15) rather than hugging the middle, because the tiers are
    /// already a coarse three-way cut of a continuous percentile — compressing them further
    /// would leave `fameBias` with nothing to bite on. `nil` stays nil: an unrated puzzle is
    /// unrated, not medium (the distinction `WhoAmIPuzzle.difficulty` exists to preserve).
    static func fame(for difficulty: SubjectDifficulty?) -> Double? {
        switch difficulty {
        case .easy: return 0.85
        case .medium: return 0.5
        case .hard: return 0.15
        case nil: return nil
        }
    }
}
