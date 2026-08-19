import SwiftUI

/// A "Journeyman" puzzle: name the player from their club history alone.
///
/// The board is a chronological list of `Stint`s — club crest, club name, years — and **the whole
/// path is on screen from the first second**. There is no drip-feed: the career is the question,
/// shown once, in full. What costs you is guessing wrong (see `JourneymanScoring`), which keeps
/// the pressure on identifying the player rather than on deciding when to spend a reveal.
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
         headshot: String? = nil, truncated: Bool? = nil, teaser: String? = nil) {
        self.id = id
        self.sport = sport
        self.stints = stints
        self.answer = answer
        self.difficulty = difficulty
        self.position = position
        self.headshot = headshot
        self.truncated = truncated
        self.teaser = teaser
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
/// Journeyman charges you for answers you got wrong.
enum JourneymanScoring {
    /// Points for naming the player on the Nth guess, at an unrated difficulty. Its length IS
    /// the guess limit.
    static let perGuess = [1000, 800, 600, 400, 200]
    static var maxGuesses: Int { perGuess.count }

    struct Result: Equatable {
        /// 1...`maxGuesses` — which guess landed it, or `maxGuesses` when it never did.
        let guessesUsed: Int
        let solved: Bool
        let total: Int
        /// Normalized 0...1 for the rating engine (guess efficiency; 0 if unsolved).
        let performance: Double

        /// Wrong guesses made. Derived rather than stored: on a solve the last guess was the
        /// right one, on a loss every guess was wrong.
        var wrongGuesses: Int { solved ? guessesUsed - 1 : guessesUsed }
    }

    /// Score multiplier for a tier, with **nil (unrated) scoring exactly 1.0** — see
    /// `JourneymanPuzzle.difficulty`.
    static func multiplier(_ difficulty: SubjectDifficulty?) -> Double {
        difficulty?.multiplier ?? 1.0
    }

    /// Points on offer for naming the player on `guess` (1-based) at `difficulty`.
    ///
    /// The multiplier scales the whole curve rather than adding a flat bonus, so naming a deep
    /// cut first time is worth the most — the behaviour the scoreboard should reward.
    static func value(guess: Int, difficulty: SubjectDifficulty?) -> Int {
        let idx = min(max(guess - 1, 0), perGuess.count - 1)
        return Int((Double(perGuess[idx]) * multiplier(difficulty)).rounded())
    }

    /// The most a puzzle at `difficulty` can pay — first guess, straight away.
    static func maxScore(difficulty: SubjectDifficulty?) -> Int {
        value(guess: 1, difficulty: difficulty)
    }

    /// What the next wrong guess would cost from here. Shown on the board, so it has to include
    /// the tier multiplier — a player weighing a hunch needs the price they'd actually pay.
    static func nextGuessCost(guess: Int, difficulty: SubjectDifficulty?) -> Int {
        guard guess < maxGuesses else { return value(guess: guess, difficulty: difficulty) }
        return value(guess: guess, difficulty: difficulty)
             - value(guess: guess + 1, difficulty: difficulty)
    }

    static func score(guessesUsed: Int, solved: Bool,
                      difficulty: SubjectDifficulty? = nil) -> Result {
        let used = min(max(guessesUsed, 1), maxGuesses)
        let total = solved ? value(guess: used, difficulty: difficulty) : 0
        // Difficulty-INDEPENDENT on purpose, the same invariant `WhoAmIScoring` documents:
        // `performance` feeds the rating engine and means "how efficiently was this solved",
        // not "how impressive was it". Folding the multiplier in would let the tier the
        // pipeline happened to serve move a player's rating.
        let performance = solved ? Double(perGuess[used - 1]) / Double(perGuess[0]) : 0
        return Result(guessesUsed: used, solved: solved, total: total, performance: performance)
    }
}
