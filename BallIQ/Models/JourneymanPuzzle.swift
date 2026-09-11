import SwiftUI

/// A "Journeyman" puzzle: name the player from their club history alone.
///
/// The board is a chronological list of `Stint`s — club crest, club name, years — and **the whole
/// path is on screen from the first second**. There is no drip-feed: the career is the question,
/// shown once, in full. What costs you is guessing wrong (see `JourneymanScoring`), which keeps
/// the pressure on identifying the player rather than on deciding when to spend a reveal.
///
/// `hints` does not walk that back. It sells facts that are deliberately **not** on the board —
/// nothing about the clubs or the years is purchasable — so the question stays whole and the
/// decision a hint offers is "do I know this yet?", never "have I unlocked enough of it?".
///
/// **Why the board carries club NAMES and not crests alone.** The pitch for this format is
/// "just show the logos", and pure-crest is the prettier game. It is the wrong one here: the
/// catalog spans five sports and 1,182 distinct soccer club codes, crest coverage is real but
/// partial (defunct franchises have none — see `Stint.teamAbbr`), and a badge nobody recognizes
/// is unfair rather than hard. The crest carries the recognition; the name carries the fairness
/// and, incidentally, VoiceOver.
struct JourneymanPuzzle: Identifiable, Codable, Equatable {
    let id: String
    let sport: Sport
    /// Chronological, first club first. At least 2 (see `tools/ingest/journeyman.py`).
    let stints: [Stint]
    let answer: WhoAmIPuzzle.AcceptedAnswer
    /// Same optional-means-unrated posture as `WhoAmIPuzzle.difficulty` — content minted before
    /// a tier existed, or authored by a person, scores at ×1.0 and shows no chip.
    let difficulty: SubjectDifficulty?
    /// The answer's position ("QB", "F", …) — shown only on the reveal card, never on the board.
    let position: String?
    /// The answer's headshot, for the reveal card. Empty/nil renders the initials fallback,
    /// exactly like every other player surface.
    let headshot: String?
    /// The archive card's one line — a low-reveal fact about the subject with a jab about the
    /// shape of their career ("Part of the 2003 draft class — and no forwarding address").
    /// Written by `tools/ingest/journeyman.py`'s `build_teaser`, which draws it from the same
    /// dimension library the Who Am I? clue engine uses and leak-checks it against the answer.
    ///
    /// Optional, and the client has a real fallback (`JourneymanTeaser`) rather than a blank
    /// title: content minted before this existed carries no teaser, and a hand-authored board
    /// never would. The fallback can only joke about the path's shape — it deliberately cannot
    /// see the answer — which is exactly why the good version is generated server-side.
    let teaser: String?

    /// True when the career had more clubs than the board shows (`journeyman.py` truncates very
    /// long paths to the most recent `MAX_STINTS`). Stated on the board rather than hidden: a
    /// player counting clubs to identify a journeyman deserves to know the count is a floor.
    let truncated: Bool?

    /// Paid hints — facts about the subject that are **not** on the board, bought mid-run for
    /// points (see `JourneymanScoring.hintRetention`). Ordered vague → specific, at most
    /// `JourneymanScoring.maxHints`.
    ///
    /// This is not the drip-feed this format cut. The question — the career path — is still
    /// whole and visible from the first frame; a hint sells the *surrounding* metadata the
    /// pipeline already has (position, passport, résumé, initials), so a stuck player has
    /// something to spend other than a wrong guess. `tools/ingest/journeyman.py`'s
    /// `_HINT_EXCLUDED_DIMENSIONS` is what keeps that true: anything derivable from the
    /// timeline — the club list and the career span alike — can never be minted as a hint.
    ///
    /// Optional, and a **short** array is a normal outcome rather than a defect: only the NFL
    /// has a bio provider behind it, so a soccer or F1 subject draws from the catalog
    /// dimensions alone and may honestly support one or two. Nil (content minted before this
    /// shipped, or a hand-authored board) simply shows no hint button.
    let hints: [Hint]?

    /// One purchasable fact. `label` is its display name ("Résumé"), `dimension` its real
    /// identity in the pipeline's clue library ("accolades") — the same split, for the same
    /// reason, as `WhoAmIPuzzle.Clue.label`/`dimension`.
    struct Hint: Codable, Equatable, Identifiable {
        let order: Int
        let label: String
        let text: String
        /// Nil on hand-authored content; never rendered, carried for parity with Who Am I?'s
        /// clue rows so analytics can ask which angle people actually buy.
        let dimension: String?

        var id: Int { order }

        init(order: Int, label: String, text: String, dimension: String? = nil) {
            self.order = order
            self.label = label
            self.text = text
            self.dimension = dimension
        }
    }

    /// One unbroken spell at one club. A player who left and came back has two stints, which is
    /// the whole point of the format — the return spell is usually the giveaway.
    struct Stint: Codable, Equatable, Identifiable {
        let order: Int
        /// The catalog's franchise code, used for colors and the crest lookup. Not every code
        /// has a rehosted crest (defunct franchises especially), which is why
        /// `CareerPathTimeline` degrades to a color chip rather than treating a crest as
        /// required content.
        let teamAbbr: String
        /// Club display name — a franchise NICKNAME for the US sports ("Chargers"), the full
        /// club name for soccer ("Ajax Amsterdam").
        ///
        /// Nickname, never city, and that is a correctness decision: the catalog stores some
        /// relocated franchises under their modern code for every era (Drew Brees's 2001-2005
        /// rows say `LAC`), so "Los Angeles Chargers 2001-2005" would be plainly false where
        /// "Chargers 2001-2005" is true in both cities.
        let teamName: String
        /// League/country qualifier for the crest + palette lookup — "" for the US sports, the
        /// country label for soccer, where a bare club code is not unique (BRO is both Blackburn
        /// Rovers and Brisbane Roar).
        let league: String?
        let firstYear: Int
        let lastYear: Int
        /// True when `teamAbbr` names a *different* franchise today than it did during this
        /// spell — `HOU` was the Oilers through 1996 and has been the Texans since 2002. The
        /// crest is suppressed for these (see `CareerPathTimeline`), because the modern badge
        /// would contradict the label the pipeline worked to get right. Nil on every ordinary
        /// stint, including defunct-but-never-reused codes like `SD`, whose own crest is still
        /// the correct one.
        let historical: Bool?

        var id: Int { order }

        /// "2001–2005", or "2019" for a single season. En dash, not a hyphen — this is a range.
        var yearsLabel: String {
            firstYear == lastYear ? "\(firstYear)" : "\(firstYear)–\(lastYear)"
        }

        /// Seasons at the club, inclusive. A within-stint gap (an injury year) still counts as
        /// part of the spell, so this is the calendar span rather than rows in the catalog.
        var seasonCount: Int { max(1, lastYear - firstYear + 1) }

        /// `historical` defaults to nil so fixtures and previews stay six-argument calls, and so
        /// an older pool file (or a hand-authored board) decodes as "ordinary stint".
        init(order: Int, teamAbbr: String, teamName: String, league: String?,
             firstYear: Int, lastYear: Int, historical: Bool? = nil) {
            self.order = order
            self.teamAbbr = teamAbbr
            self.teamName = teamName
            self.league = league
            self.firstYear = firstYear
            self.lastYear = lastYear
            self.historical = historical
        }
    }

    init(id: String, sport: Sport, stints: [Stint], answer: WhoAmIPuzzle.AcceptedAnswer,
         difficulty: SubjectDifficulty? = nil, position: String? = nil,
         headshot: String? = nil, truncated: Bool? = nil, teaser: String? = nil,
         hints: [Hint]? = nil) {
        self.id = id
        self.sport = sport
        self.stints = stints
        self.answer = answer
        self.difficulty = difficulty
        self.position = position
        self.headshot = headshot
        self.truncated = truncated
        self.teaser = teaser
        self.hints = hints
    }
}

/// Pure scoring for Journeyman — you see the whole career at once, so the only thing that can
/// cost you is a wrong name.
///
/// Five guesses, and the board is worth less with each one spent: 1000 / 800 / 600 / 400 / 200,
/// then nothing. That is deliberately the same table `WhoAmIScoring.perClue` uses, because the
/// two formats are the same bet wearing different clothes — "how much do you know before you
/// commit?" — and a player who has learned what a 600 means in one should read it the same way
/// in the other. The axis differs: Who Am I? charges you for information you asked for,
/// Journeyman charges you for answers you got wrong — **and, since hints, for information you
/// asked for too**, on a second axis that multiplies rather than steps.
///
/// ## Why a hint is priced as a percentage and not a fixed number of points
///
/// A hint keeps `hintRetention` of whatever the board is worth *at the moment it is bought*, so
/// the first one off a full board costs 200 and the same hint bought after four wrong guesses
/// costs 80. Three properties fall out of that, all of which a flat price gets wrong:
///
/// - **It can never zero you out.** A flat 200-a-hint would make the third hint on a
///   fourth-guess board worth more than the board, so the feature would be unusable at exactly
///   the moment a stuck player wants it — which is the whole reason it exists.
/// - **It reads as the same bet as a wrong guess.** At the top of the ladder one hint and one
///   wrong guess both cost 200, so "a hint is about a guess" is a true sentence a player can
///   carry, without the price ever going negative further down.
/// - **All three hints is a real decision.** 0.8³ = 0.512, so a fully-hinted first-guess solve
///   pays 512: more than a cold fourth-guess solve (400), less than a cold third (600). Needing
///   all the help there is should beat flailing and lose to knowing it.
enum JourneymanScoring {
    /// Points for naming the player on the Nth guess, at an unrated difficulty. Its length IS
    /// the guess limit.
    static let perGuess = [1000, 800, 600, 400, 200]
    static var maxGuesses: Int { perGuess.count }

    /// The share of the board's value that survives one hint. See the type's doc comment for
    /// why this is a multiplier; `maxHints` bounds the total discount at ~49%.
    static let hintRetention = 0.8
    /// The most hints any board offers. The pipeline mints at most this many
    /// (`journeyman.py`'s `HINT_COUNT`); the client is the second half of that guarantee, since
    /// content is not allowed to price itself.
    static let maxHints = 3

    struct Result: Equatable {
        /// 1...`maxGuesses` — which guess landed it, or `maxGuesses` when it never did.
        let guessesUsed: Int
        let solved: Bool
        let total: Int
        /// Normalized 0...1 for the rating engine (guess efficiency **and** hint spend; 0 if
        /// unsolved).
        let performance: Double
        /// Hints bought, 0...`maxHints`.
        let hintsUsed: Int

        /// Wrong guesses made. Derived rather than stored: on a solve the last guess was the
        /// right one, on a loss every guess was wrong.
        var wrongGuesses: Int { solved ? guessesUsed - 1 : guessesUsed }

        /// `hintsUsed` defaults to 0 so the several dozen existing construction sites (tests,
        /// the bot solver, the live-duel fixtures) stay unchanged and keep meaning what they
        /// meant: a run with no hints bought.
        init(guessesUsed: Int, solved: Bool, total: Int, performance: Double,
             hintsUsed: Int = 0) {
            self.guessesUsed = guessesUsed
            self.solved = solved
            self.total = total
            self.performance = performance
            self.hintsUsed = hintsUsed
        }
    }

    /// What `hints` purchases leave of a board's value. `pow`, not a loop, so it is defined for
    /// the clamped range and nothing else has to know the shape.
    static func hintFactor(_ hints: Int) -> Double {
        pow(hintRetention, Double(min(max(hints, 0), maxHints)))
    }

    /// Score multiplier for a tier, with **nil (unrated) scoring exactly 1.0** — see
    /// `JourneymanPuzzle.difficulty`.
    static func multiplier(_ difficulty: SubjectDifficulty?) -> Double {
        difficulty?.multiplier ?? 1.0
    }

    /// Points on offer for naming the player on `guess` (1-based) at `difficulty`, after
    /// `hints` have been bought.
    ///
    /// The multiplier scales the whole curve rather than adding a flat bonus, so naming a deep
    /// cut first time is worth the most — the behaviour the scoreboard should reward.
    static func value(guess: Int, difficulty: SubjectDifficulty?, hints: Int = 0) -> Int {
        let idx = min(max(guess - 1, 0), perGuess.count - 1)
        return Int((Double(perGuess[idx]) * multiplier(difficulty) * hintFactor(hints)).rounded())
    }

    /// The most a puzzle at `difficulty` can pay — first guess, straight away, unhinted. Stays
    /// the denominator for `BlitzBoardValue` and `SessionDetail.maxScore` on a hinted run too:
    /// spending a hint should visibly cost a share of the board, which it can only do if the
    /// board's face value doesn't move with it.
    static func maxScore(difficulty: SubjectDifficulty?) -> Int {
        value(guess: 1, difficulty: difficulty)
    }

    /// What the next hint would cost from here — the points it takes off *this* board at this
    /// guess, which is the only honest way to state it (the same hint is worth less later).
    /// Zero when there is nothing left to buy.
    static func nextHintCost(guess: Int, hintsUsed: Int, difficulty: SubjectDifficulty?) -> Int {
        guard hintsUsed < maxHints else { return 0 }
        return value(guess: guess, difficulty: difficulty, hints: hintsUsed)
             - value(guess: guess, difficulty: difficulty, hints: hintsUsed + 1)
    }

    /// What the next wrong guess would cost from here. Shown on the board, so it has to include
    /// the tier multiplier and any hints already bought — a player weighing a hunch needs the
    /// price they'd actually pay.
    static func nextGuessCost(guess: Int, difficulty: SubjectDifficulty?, hints: Int = 0) -> Int {
        guard guess < maxGuesses else { return value(guess: guess, difficulty: difficulty, hints: hints) }
        return value(guess: guess, difficulty: difficulty, hints: hints)
             - value(guess: guess + 1, difficulty: difficulty, hints: hints)
    }

    static func score(guessesUsed: Int, solved: Bool,
                      difficulty: SubjectDifficulty? = nil, hintsUsed: Int = 0) -> Result {
        let used = min(max(guessesUsed, 1), maxGuesses)
        let hints = min(max(hintsUsed, 0), maxHints)
        let total = solved ? value(guess: used, difficulty: difficulty, hints: hints) : 0
        // Difficulty-INDEPENDENT on purpose, the same invariant `WhoAmIScoring` documents:
        // `performance` feeds the rating engine and means "how efficiently was this solved",
        // not "how impressive was it". Folding the multiplier in would let the tier the
        // pipeline happened to serve move a player's rating.
        //
        // Hints, however, ARE folded in, and must be: they are the player's own choice on the
        // same "how much did you know before committing?" axis as the guess count. Left out,
        // buying every hint and naming the player first time would report a perfect 1.0 — a
        // rating farm that costs points and pays rating, which is precisely backwards.
        let performance = solved
            ? Double(perGuess[used - 1]) / Double(perGuess[0]) * hintFactor(hints)
            : 0
        return Result(guessesUsed: used, solved: solved, total: total,
                      performance: performance, hintsUsed: hints)
    }
}
