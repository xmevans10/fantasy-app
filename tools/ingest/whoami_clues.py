"""Who Am I? clue dimensions — every angle a clue can take, plus the randomized,
difficulty-aware selection that turns one subject into six of them.

Before this module every Who Am I? puzzle in the game was the same six clues in the same
fixed order (era → position → teams → stat line → known-for → jersey), built inline in
`assemble.build_whoami_row`. That made the *format* predictable long before the answer
was: by clue 3 a player already knew they were about to be handed a team list, and two
puzzles about wildly different players read as the same puzzle twice.

Here a clue is one **dimension**, and a dimension is a small builder that either yields a
clue for a subject or yields nothing (missing data = absent dimension, never a filler
"Unknown college" line). Each carries:

- `reveal`  — how much it narrows the field, 0.0 (broad) to 1.0 (near-giveaway). Selected
              clues are sorted by this, so a puzzle still opens vague and closes tight no
              matter which dimensions the draw happened to pick.
- `family`  — the angle it comes from (bio / draft / team / career / production / story).
              Selection spreads across families, so a puzzle can't come out as six
              flavors of "here's another counting stat".
- `kind`    — see the compatibility note below.

## The `kind` field is a compatibility contract, not a label

`kind` must always be one of the six values the **already-shipped App Store build** knows:
`era`, `position`, `teams`, `statLine`, `fact`, `jersey`. That build decodes `ClueKind` as
a plain `String`-raw-value enum with no unknown-case fallback, so a seventh value coming
back from Supabase fails the decode for the whole `whoami` fetch and silently drops every
one of those users back to the 24-entry bundled pool. New dimensions therefore map onto
the closest legacy kind (most land on `fact`) and carry their real name in the additive
`dimension`/`label` fields, which older clients ignore and current ones render. Adding a
new `ClueKind` case to the wire format is a thing to do *after* the new build has adoption,
not something this module may do on its own.

Pure and seeded: `select_clues` takes an explicit seed, so the same (subject, seed) always
produces the same puzzle while the same subject served on a different day does not.
"""
from __future__ import annotations

import random
from collections.abc import Callable
from dataclasses import dataclass

from .models import WhoAmIEntry

# ── Difficulty ────────────────────────────────────────────────────────────────

DIFFICULTIES: tuple[str, ...] = ("easy", "medium", "hard")

# Score multiplier per tier. **Mirrored in Swift** — `WhoAmIPuzzle.Difficulty.multiplier`
# in BallIQ/Models/WhoAmIPuzzle.swift holds the same three numbers, and
# `test_point_multipliers_match_the_swift_table` reads them back out of that file so the
# two can't drift silently. The client owns its copy on purpose rather than trusting a
# number from `content`: community-authored puzzles go through the same model, and a
# score multiplier is not something puzzle content gets to set for itself.
POINT_MULTIPLIER: dict[str, float] = {"easy": 1.0, "medium": 1.25, "hard": 1.6}

# Fame percentile cuts. `fame` is where a subject's career production lands within their
# own (sport, position) cohort — see whoami_pool.compute_fame. The cuts are deliberately
# top-heavy: "easy" is the genuinely household names, and everything below the medium cut
# is hard *within an already-qualified pool* (whoami_pool refuses to generate a subject
# who isn't identifiable at all), so `hard` means deep-cut, never unknowable.
EASY_FAME_CUT = 0.90
MEDIUM_FAME_CUT = 0.55


def tier_for_fame(fame: float | None) -> str:
    """Difficulty tier for a fame percentile. `None` (a curated legend the generator never
    scored) is `easy` — the curated pool is exactly the household-name pool."""
    if fame is None:
        return "easy"
    if fame >= EASY_FAME_CUT:
        return "easy"
    if fame >= MEDIUM_FAME_CUT:
        return "medium"
    return "hard"


def difficulty_of(entry: WhoAmIEntry) -> str:
    """An entry's tier — its explicit override if it has one, else derived from fame."""
    if entry.difficulty in DIFFICULTIES:
        return entry.difficulty
    return tier_for_fame(entry.fame)


# ── Clues ─────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Clue:
    dimension: str    # the real name, e.g. 'draftPick' — rendered by current clients
    kind: str         # legacy ClueKind (see module docstring) — decoded by every client
    label: str        # display label for `dimension`, e.g. 'Draft slot'
    text: str
    reveal: float     # 0.0 broad … 1.0 near-giveaway
    family: str       # bio | draft | team | career | production | story

    def to_content(self, order: int) -> dict:
        return {"order": order, "kind": self.kind, "text": self.text,
                "dimension": self.dimension, "label": self.label}


@dataclass(frozen=True)
class Dimension:
    key: str
    kind: str
    label: str
    reveal: float
    family: str
    build: Callable[[WhoAmIEntry, random.Random], str | None]

    def clue(self, entry: WhoAmIEntry, rng: random.Random) -> Clue | None:
        text = self.build(entry, rng)
        if not text:
            return None
        return Clue(dimension=self.key, kind=self.kind, label=self.label,
                    text=text, reveal=self.reveal, family=self.family)


# ── Formatting helpers ────────────────────────────────────────────────────────

def ordinal(n: int) -> str:
    """1 -> '1st', 2 -> '2nd', 11 -> '11th', 22 -> '22nd'."""
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def height_text(inches: int) -> str:
    """74 -> \"6'2\\\"\". Values outside a plausible human range return '' so a bad bio row
    (nflverse carries a handful of 0s and one 3-digit typo) can't ship a 0'0\" clue."""
    if not 58 <= inches <= 90:
        return ""
    return f"{inches // 12}'{inches % 12}\""


def join_list(items: list[str], conjunction: str = "and") -> str:
    """['A'] -> 'A'; ['A','B'] -> 'A and B'; ['A','B','C'] -> 'A, B and C'."""
    items = [i for i in items if i]
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    return f"{', '.join(items[:-1])} {conjunction} {items[-1]}"


def article_for(word: str) -> str:
    """"a" / "an" for a following word, picked by how the word is *said* rather than spelled —
    "an 11-season career", "an 18-season career", "a 13-season career".

    English's rule is phonetic, so the digit check is on leading *sound*: 8 ("eight"), 11
    ("eleven"), 18 ("eighteen") and their multiples-of-ten forms ("eighty") all open on a
    vowel. Correct for every number this actually formats (season counts, 2-27); a general
    number-to-words rule would need more than a prefix test (110 reads "one hundred ten").
    """
    text = word.lstrip("([")
    if text[:1].isdigit():
        return "an" if text.startswith(("8", "11", "18")) else "a"
    return "an" if text[:1].lower() in "aeiou" else "a"


def _jersey_numbers(jersey: str) -> list[str]:
    """'4' -> ['4']; '8, 24' -> ['8','24'] — jersey is free text from curation/bio."""
    raw = jersey.replace("and", ",").replace("&", ",").replace("/", ",")
    return [part.strip() for part in raw.split(",") if part.strip()]


# ── Dimension builders ────────────────────────────────────────────────────────
#
# Every builder is pronoun-free by construction: the catalog spans men's and women's
# tennis, so there is no pronoun that is right for all of it, and "Wore number 4" reads
# better than "He wore number 4" regardless.

def _era(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """A career span. For an active player this can't be phrased as a closed range — "played
    from 2013 to 2026" reads as retired — so it becomes an open-ended one instead."""
    if e.last_year == e.first_year:
        return f"Played a single season, in {e.first_year}"
    decade = (e.first_year // 10) * 10
    if e.active:
        return rng.choice([
            f"Has been playing since {e.first_year}",
            f"Broke in during the {decade}s and is still at it",
        ])
    return rng.choice([
        f"Played from {e.first_year} to {e.last_year}",
        f"Career ran {e.first_year}-{e.last_year}",
        f"Broke in during the {decade}s and last played in {e.last_year}",
    ])


def _debut(e: WhoAmIEntry, rng: random.Random) -> str | None:
    return rng.choice([
        f"Played a first professional season in {e.first_year}",
        f"Debuted in {e.first_year}",
    ])


def _finale(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """Withheld for anyone still playing — asserting a retirement that hasn't happened is
    both wrong and a misleading clue (it dates the career to the wrong era)."""
    if e.active:
        return None
    return rng.choice([
        f"Played a final season in {e.last_year}",
        f"Last suited up in {e.last_year}",
    ])


def _longevity(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """Seasons *played*, not calendar span — a career with a missed year isn't a longer one."""
    n = e.seasons
    if not n or n < 2:
        return None
    if e.active:
        return rng.choice([
            f"{n} seasons in and still going",
            f"Has {n} seasons on the résumé so far",
        ])
    return rng.choice([
        f"Lasted {n} seasons",
        f"Put together {article_for(str(n))} {n}-season career",
    ])


def _position(e: WhoAmIEntry, rng: random.Random) -> str | None:
    return e.position or None


def _height(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.height_in:
        return None
    h = height_text(e.height_in)
    if not h:
        return None
    return rng.choice([f"Listed at {h}", f"Stood {h}"])


def _weight(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.weight_lb or not 120 <= e.weight_lb <= 400:
        return None
    return f"Listed at {e.weight_lb} pounds"


def _frame(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """Height and weight together — a tighter clue than either alone, so it carries its own
    higher `reveal` and the picker treats it as a third, distinct option."""
    if not e.height_in or not e.weight_lb:
        return None
    h = height_text(e.height_in)
    if not h or not 120 <= e.weight_lb <= 400:
        return None
    return f"Listed at {h}, {e.weight_lb} pounds"


def _born(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.birth_year:
        return None
    return rng.choice([
        f"Born in {e.birth_year}",
        f"A {e.birth_year} baby",
    ])


def _age_at_debut(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.birth_year:
        return None
    age = e.first_year - e.birth_year
    if not 16 <= age <= 32:      # anything outside this is a bad birth_year, not a story
        return None
    return f"Was roughly {age} years old as a rookie"


def _college(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.college:
        return None
    return rng.choice([
        f"Went to {e.college}",
        f"Played college ball at {e.college}",
        f"Came out of {e.college}",
    ])


def _conference(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """The conference without the school — a real middle step between "no college clue"
    and handing over the school, which for most players is most of the answer."""
    if not e.college_conference:
        return None
    return f"Came out of the {e.college_conference}"


def _draft_round(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.draft_round:
        return None
    return rng.choice([
        f"A {ordinal(e.draft_round)}-round pick",
        f"Came off the board in round {e.draft_round}",
    ])


def _draft_pick(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.draft_pick:
        return None
    return rng.choice([
        f"Selected {ordinal(e.draft_pick)} overall",
        f"Went {ordinal(e.draft_pick)} overall",
    ])


def _draft_class(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.draft_year:
        return None
    return f"Part of the {e.draft_year} draft class"


def _draft_team(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """Only interesting when the drafting team isn't the one the player is known for —
    otherwise it's the teams clue wearing a hat, and the picker would be spending one of
    six slots to say the same thing twice."""
    if not e.draft_team or not e.teams:
        return None
    if e.draft_team == e.teams[0]:
        return None
    return f"Drafted by the {e.draft_team}"


def _undrafted(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.undrafted:
        return None
    return rng.choice([
        "Never got drafted",
        "Went undrafted and had to earn a roster spot",
    ])


def _article(e: WhoAmIEntry) -> str:
    """"the " for US franchises ("the Packers"), "" for soccer clubs ("Arsenal"). Nobody says
    "the Arsenal", and the naming convention differs by sport, not by team."""
    return "" if e.sport == "soccer" else "the "


def _teams(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """Named teams only — see `WhoAmIEntry.teams_named`. A clue naming three of a player's
    five clubs is worse than no team clue: it reads as a complete list and isn't one."""
    if not e.teams or not e.teams_named:
        return None
    return join_list(e.teams)


def _first_team(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if _franchises(e) < 2 or not e.teams_named or not e.teams:
        return None                             # with one team this IS the teams clue
    return f"Started out with {_article(e)}{e.teams[0]}"


def _last_team(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if _franchises(e) < 2 or not e.teams_named or not e.teams:
        return None
    verb = "Currently with" if e.active else "Finished up with"
    return f"{verb} {_article(e)}{e.teams[-1]}"


def _franchises(e: WhoAmIEntry) -> int:
    """The real franchise count — `franchise_count` when the generator recorded one (it may
    exceed `len(teams)`, see that field), else the named list's length."""
    return e.franchise_count if e.franchise_count is not None else len(e.teams)


def _franchise_count(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """Usable even when the teams can't be *named* — a count needs no names, which is why
    this and `_one_team` are the two team dimensions that survive `teams_named == False`."""
    n = _franchises(e)
    if n < 2:                    # one-club players get `_one_team` instead
        return None
    return rng.choice([
        f"Suited up for {n} different franchises",
        f"Played for {n} teams",
    ])


def _one_team(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if _franchises(e) != 1 or (e.seasons or 0) < 4:
        return None              # a one-team career isn't loyalty if it was two seasons
    if e.active:
        return "Has never played for another club"
    return rng.choice([
        "Spent an entire career with one club",
        "A one-team player, start to finish",
    ])


def _league(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.league:
        return None
    return f"Made a name in {e.league}"


def _nationality(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """Tennis's stand-in for the team dimensions — its catalog `team_abbr` is a country code,
    which is a genuinely good clue as long as it's labeled as one."""
    if not e.nationality:
        return None
    return f"Competed for {e.nationality}"


def _stat_line(e: WhoAmIEntry, rng: random.Random) -> str | None:
    return e.stat_line or None


def _best_season(e: WhoAmIEntry, rng: random.Random) -> str | None:
    b = e.best_season or {}
    line, year = b.get("line"), b.get("year")
    if not line or not year:
        return None
    team = b.get("team")
    where = f" with {_article(e)}{team}" if team else ""
    return rng.choice([
        f"Best season came in {year}{where}: {line}",
        f"Peaked in {year}{where}: {line}",
    ])


def _peak_year(e: WhoAmIEntry, rng: random.Random) -> str | None:
    """The year of the best season without the stat line — the same fact at a fraction of
    the reveal, which is what makes it usable as an opening clue on a hard puzzle."""
    year = (e.best_season or {}).get("year")
    if not year:
        return None
    age = f", at about {year - e.birth_year}" if e.birth_year else ""
    return f"The best statistical season came in {year}{age}"


def _jersey(e: WhoAmIEntry, rng: random.Random) -> str | None:
    numbers = _jersey_numbers(e.jersey)
    if not numbers:
        return None
    if len(numbers) == 1:
        return rng.choice([f"Wore number {numbers[0]}", f"Number {numbers[0]}"])
    return f"Wore numbers {join_list(numbers)}"


def _initials(e: WhoAmIEntry, rng: random.Random) -> str | None:
    parts = [p for p in e.canonical.split() if p and p[0].isalpha()]
    if len(parts) < 2:
        return None
    return "Initials: " + ".".join(p[0].upper() for p in parts) + "."


def _nickname(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.nickname:
        return None
    return f'Known around the league as "{e.nickname}"'


def _accolade(e: WhoAmIEntry, rng: random.Random) -> str | None:
    if not e.accolades:
        return None
    return join_list(list(e.accolades))


def _fact(e: WhoAmIEntry, rng: random.Random) -> str | None:
    return e.fact or None


# The registry. Order here is irrelevant (selection sorts by `reveal`); it's grouped by
# family purely so a reader can see the whole space at a glance. To add a dimension:
# append one row — everything downstream (selection, ordering, validation, the app)
# already handles an arbitrary set. Remember the `kind` compatibility rule above.
DIMENSIONS: tuple[Dimension, ...] = (
    # career shape — the broad openers
    Dimension("era", "era", "Era", 0.10, "career", _era),
    Dimension("longevity", "era", "Longevity", 0.16, "career", _longevity),
    Dimension("debut", "era", "Debut", 0.22, "career", _debut),
    Dimension("finale", "era", "Final season", 0.24, "career", _finale),
    # bio
    Dimension("position", "position", "Position", 0.20, "bio", _position),
    Dimension("weight", "fact", "Weight", 0.22, "bio", _weight),
    Dimension("height", "fact", "Height", 0.26, "bio", _height),
    Dimension("born", "fact", "Born", 0.28, "bio", _born),
    Dimension("ageAtDebut", "fact", "Rookie year", 0.30, "bio", _age_at_debut),
    Dimension("frame", "fact", "Frame", 0.34, "bio", _frame),
    Dimension("jersey", "jersey", "Jersey", 0.50, "bio", _jersey),
    Dimension("college", "fact", "College", 0.56, "bio", _college),
    Dimension("conference", "fact", "College conference", 0.30, "bio", _conference),
    # draft
    Dimension("draftClass", "fact", "Draft class", 0.32, "draft", _draft_class),
    Dimension("undrafted", "fact", "Draft", 0.36, "draft", _undrafted),
    Dimension("draftRound", "fact", "Draft round", 0.38, "draft", _draft_round),
    Dimension("draftTeam", "teams", "Drafted by", 0.54, "draft", _draft_team),
    Dimension("draftPick", "fact", "Draft slot", 0.62, "draft", _draft_pick),
    # teams
    Dimension("league", "teams", "League", 0.20, "team", _league),
    Dimension("nationality", "teams", "Country", 0.36, "team", _nationality),
    Dimension("franchiseCount", "teams", "Franchises", 0.26, "team", _franchise_count),
    Dimension("oneTeam", "teams", "Loyalty", 0.32, "team", _one_team),
    Dimension("firstTeam", "teams", "First team", 0.48, "team", _first_team),
    Dimension("lastTeam", "teams", "Last team", 0.50, "team", _last_team),
    Dimension("teams", "teams", "Teams", 0.64, "team", _teams),
    # production
    Dimension("peakYear", "statLine", "Peak", 0.40, "production", _peak_year),
    Dimension("bestSeason", "statLine", "Best season", 0.66, "production", _best_season),
    Dimension("statLine", "statLine", "Career line", 0.70, "production", _stat_line),
    # story
    Dimension("accolades", "fact", "Résumé", 0.68, "story", _accolade),
    Dimension("initials", "fact", "Initials", 0.74, "story", _initials),
    Dimension("fact", "fact", "Known for", 0.76, "story", _fact),
    Dimension("nickname", "fact", "Nickname", 0.82, "story", _nickname),
)

CLUE_COUNT = 6

# Dimensions that say the same thing twice — at most one of each group survives a draw.
# (`teams` already contains first/last team; `frame` already contains height and weight;
# `bestSeason` already contains the peak year; a draft slot implies its round.)
_REDUNDANT: tuple[frozenset[str], ...] = (
    frozenset({"teams", "firstTeam", "lastTeam", "franchiseCount", "oneTeam"}),
    frozenset({"nationality", "league"}),
    frozenset({"frame", "height", "weight"}),
    frozenset({"bestSeason", "peakYear"}),
    frozenset({"draftPick", "draftRound"}),
    frozenset({"era", "debut", "finale"}),
    frozenset({"born", "ageAtDebut"}),
    frozenset({"college", "conference"}),
)

# How strongly the draw leans away from giveaway clues, per tier. An easy puzzle should be
# gettable in two or three clues, so it wants the identifying dimensions; a hard one earns
# its multiplier by making the player work from vaguer angles. This is the *second* half of
# what "hard" means — the first is that the subject is a deeper cut (see whoami_pool).
_REVEAL_BIAS: dict[str, float] = {"easy": 1.0, "medium": 0.0, "hard": -1.0}


def available_clues(entry: WhoAmIEntry, rng: random.Random) -> list[Clue]:
    """Every dimension that has data for `entry`, in registry order."""
    return [c for c in (d.clue(entry, rng) for d in DIMENSIONS) if c is not None]


def _weight_for(clue: Clue, bias: float) -> float:
    """Draw weight. Every dimension starts equal — variety is the point, so nothing is
    'the default clue' any more — then `bias` tilts the field toward (easy) or away from
    (hard) the identifying end. Kept strictly positive so no dimension is ever unreachable
    for a tier; a hard puzzle can still deal a team list, it's just less likely to.

    Note the sign: `bias` is positive for easy, and easy wants the *revealing* dimensions, so
    the term has to grow with `reveal`. Writing it the other way round (which is the intuitive
    reading of "bias away from giveaways") inverts the whole feature — easy cards come out
    vaguer than hard ones — and is invisible in any single puzzle, since each one still looks
    like a reasonable draw. `test_hard_puzzles_draw_vaguer_clues_than_easy_ones` is what
    catches it.
    """
    return max(0.05, 1.0 + bias * (clue.reveal - 0.5))


def select_clues(entry: WhoAmIEntry, seed: str, difficulty: str | None = None,
                 count: int = CLUE_COUNT) -> list[Clue]:
    """`count` clues for `entry`, drawn at random from whatever dimensions it supports and
    ordered vague → specific.

    The draw is weighted by tier (see `_REVEAL_BIAS`), spread across families so one angle
    can't fill the card, and de-duplicated against `_REDUNDANT`. Ordering is by `reveal`
    with a little jitter, so two puzzles that happen to draw the same six dimensions still
    don't play in identical order.

    Falls back to under-`count` clues only if the subject genuinely has fewer dimensions
    than that — whoami_pool won't generate one, but a thin hand-authored entry could, and
    silently repeating a clue to reach six would be worse than showing five.
    """
    rng = random.Random(f"whoami-clues|{entry.sport}|{entry.canonical}|{seed}")
    pool = available_clues(entry, rng)
    bias = _REVEAL_BIAS.get(difficulty or difficulty_of(entry), 0.0)

    picked: list[Clue] = []
    used_families: dict[str, int] = {}
    blocked: set[str] = set()
    # Families are capped at 2 while there's still enough breadth left to fill the card,
    # then the cap lifts — a subject with only three families' worth of data should still
    # get six clues rather than a short card for the sake of a spread that isn't available.
    while len(picked) < count:
        candidates = [c for c in pool
                      if c.dimension not in blocked
                      and used_families.get(c.family, 0) < 2]
        if not candidates:
            candidates = [c for c in pool if c.dimension not in blocked]
        if not candidates:
            break
        weights = [_weight_for(c, bias) for c in candidates]
        chosen = rng.choices(candidates, weights=weights, k=1)[0]
        picked.append(chosen)
        used_families[chosen.family] = used_families.get(chosen.family, 0) + 1
        blocked.add(chosen.dimension)
        for group in _REDUNDANT:
            if chosen.dimension in group:
                blocked |= group

    # Vague → specific, with enough jitter to reshuffle near-equal clues but not enough to
    # let a giveaway drift to the front. Ties break on dimension for determinism.
    return sorted(picked, key=lambda c: (c.reveal + rng.uniform(-0.05, 0.05), c.dimension))
