"""Generate Who Am I? subjects from the live catalog — the non-legend half of the pool.

`data/whoami_facts.json` is 24 hand-authored household names. That is a fine *editorial*
layer and a terrible *pool*: every Who Am I? the game has ever served has been a player
almost any fan could name, and a 24-entry rotation runs dry in under a month per sport. This
module mines `player_seasons` for everyone else — the 6-year starters, the one-great-season
guys, the deep cuts — scores how famous each one actually is, and writes the result to
`data/whoami_pool.json` for daily_whoami.py to rotate through alongside the curated set.

## Obscurity has a floor, and that floor is the whole design

"More obscure players" is only fun up to the point where the answer is unknowable; past it,
a puzzle is just six facts about a stranger and every player loses. So a subject has to earn
its way in through `qualify()` before difficulty is even considered:

- **A real career** — `MIN_SEASONS` seasons, so no one-cup-of-coffee names.
- **A headshot** — the reveal screen is a player card with a face on it, and a photo in the
  catalog is also a decent proxy for "this player was covered".
- **A unique name inside the sport** — a shared name makes the *answer* ambiguous, and
  `WhoAmIAnswerPhoto` would have no safe way to pick whose face to show.
- **Real production** — above `PRODUCTION_FLOOR` within their own position cohort.
- **Soccer only: a league the audience follows** (`SOCCER_LEAGUES`). The catalog's soccer
  sweep runs ~38 countries deep; the 40th-best 4-season midfielder in the Ukrainian top
  flight is not a hard puzzle for a US sports-trivia audience, it's an impossible one.

Only *within* that qualified set does `fame` (percentile of career production against the
same cohort) get computed and tiered. That's what makes `hard` mean "deep cut" instead of
"never heard of them": the bottom of the hard tier is still a player who lasted five years
and produced, just not one whose jersey got sold.

## Why this writes a committed file instead of running at mint time

Same reason `whoami_facts.json` is committed: daily_whoami.py runs nightly in CI and needs
to finish in seconds. This module's inputs are ~60-90k catalog rows per sport, so it runs
on demand (weekly-ish, or after a catalog ingest adds players) and leaves behind a plain
JSON pool that the nightly job just reads.

Examples:
    python -m tools.ingest.whoami_pool --dry-run                 # what would be generated
    python -m tools.ingest.whoami_pool --write                   # refresh every sport
    python -m tools.ingest.whoami_pool --write --sport nfl nba   # refresh two of them
"""
from __future__ import annotations

import argparse
import collections
import json
from dataclasses import dataclass, replace

from . import grid_axes
from . import main as ingest_main
from .assemble import build_whoami_row as assemble_whoami_row
from .assemble import load_whoami_entries
from .grade import grade
from .models import WhoAmIEntry, slug
from .themes import fmt_value
from .whoami_clues import DIFFICULTIES, join_list, tier_for_fame

POOL_FILE = "whoami_pool.json"

# Seasons played, per sport. Four is "a career a fan could have watched" everywhere except
# tennis, where the catalog's season grain is thinner and a four-year pro tour player is
# already a fairly deep cut.
MIN_SEASONS: dict[str, int] = {"nfl": 4, "nba": 4, "baseball": 4, "soccer": 5, "tennis": 4}

# Career-production percentile a subject must clear within their (sport, position) cohort to
# be considered nameable at all. Tuned to what it buys, not to a round number: see
# `--dry-run`'s per-tier sample, which is the only honest way to judge this.
PRODUCTION_FLOOR = 0.55

# ── Merged-career rejection ───────────────────────────────────────────────────
#
# `career.py` aggregates by NAME, so two different real players who share one collapse into a
# single career row with both careers' stats summed. This is invisible in the catalog (there
# is exactly one row, and it looks fine) and it is fatal here: the live pool's first draft
# offered "Frank Thomas (Position player, 1951-2008) — 4,139 hits, 807 home runs", which is
# the 1950s outfielder and the 1990s White Sox slugger welded together, with a hit total that
# would beat Pete Rose's record. Baseball alone has 23 career rows spanning 40+ years,
# topping out at a 134-year "career" (Billy Hamilton, 1890-2023).
#
# The tell is the span: no real career reaches 28 years, and a genuine one is nearly
# contiguous, so a long span with holes in it is two careers. Both bounds are needed —
# adjacent same-name careers (say 1990-2000 and 2001-2010) produce a plausible span and slip
# through, which is a known and accepted residual: the fix for those lives upstream in
# career.py's grouping key, not in a content filter.
MAX_CAREER_SPAN = 27          # Nolan Ryan and Cap Anson, the joint MLB record, are 27
MIN_SEASON_DENSITY = 0.75     # seasons played / calendar span

# How much of `fame` comes from peak rather than career volume. Career totals alone rank a
# short brilliant career below a long ordinary one: at 0.0 the live pool put Ashleigh Barty
# (a world No. 1 with two majors, five seasons) in the *hard* tier and Graham Zusi in easy.
# Blending the peak-season percentile in fixes that without flipping to peak-only, which
# would undersell the 15-year accumulators who genuinely are household names.
PEAK_FAME_WEIGHT = 0.4

# Soccer subjects must have played in one of these (the catalog's `league` column is a
# country label — see providers/espn_soccer.py). Not a judgment about the leagues; a
# judgment about which ones this app's audience has watched.
SOCCER_LEAGUES = frozenset({
    "England", "Spain", "Germany", "Italy", "France",
    "Netherlands", "Portugal", "USA (MLS)",
})

# Generated subjects kept per sport. The pool only has to outlast the rotation — at one
# serve per sport per day, 150 apiece is over a year of daily play per sport before a
# repeat, and daily_whoami's least-recently-served ordering means the repeat that eventually
# comes is the stalest entry, with a fresh clue draw.
PER_SPORT_CAP = 150

# Tier mix inside that cap. Deliberately not uniform: easy/medium subjects carry the daily
# for most players, and hard ones are the spice (and the points). The generator fills each
# tier best-fame-first, so "40 hard" means the 40 most identifiable of the hard tier, not a
# random 40 from the tail.
TIER_MIX: dict[str, float] = {"easy": 0.25, "medium": 0.45, "hard": 0.30}


# ── Cohorts: how a position is scored, described, and summarized ───────────────

@dataclass(frozen=True)
class Headline:
    """One stat in a prose stat line. `noun` is deliberately prose ("passing yards") rather
    than reusing `StatColumn.label`'s card abbreviations ("Pass Yds") — a clue is a
    sentence, and "Pass Yds 71,940" is not one."""
    stat: str
    noun: str
    fmt: str = "comma_int"
    per_game: bool = False   # phrase as an average ("25.0 points per game")
    one: str = ""            # singular form; "" = `noun` minus a trailing 's'

    def phrase(self, value: float) -> str:
        """"1 major title" / "18 major titles" — a value of exactly 1 is common enough in a
        clue (one ring, one major, one interception) that "1 major titles" would show up in
        production almost immediately."""
        noun = self.noun
        if value == 1 and not self.per_game:
            noun = self.one or (noun[:-1] if noun.endswith("s") else noun)
        text = f"{fmt_value(value, self.fmt)} {noun}"
        return f"{text} per game" if self.per_game else text


@dataclass(frozen=True)
class Cohort:
    scale: str                     # grade.py fantasy scale key for ranking this cohort
    position: str                  # prose position name for the position clue
    headline: tuple[Headline, ...]  # career stat line, in order


_YDS = "comma_int"
_INT = "int"
_D1 = "dec1"

# Keyed by (sport, position family) — the family comes from `grid_axes.position_family`, so
# the NFL defensive groupings (dl/lb/db) are the same membership The Grid uses rather than a
# second copy of the same list. A position absent from here is simply not generated for.
COHORTS: dict[tuple[str, str], Cohort] = {
    ("nfl", "QB"): Cohort("nfl_qb_fantasy", "Quarterback", (
        Headline("passing_yards", "passing yards", _YDS),
        Headline("passing_tds", "touchdown passes", _INT),
        Headline("interceptions", "interceptions", _INT))),
    ("nfl", "RB"): Cohort("nfl_skill_ppr", "Running back", (
        Headline("rushing_yards", "rushing yards", _YDS),
        Headline("rushing_tds", "rushing touchdowns", _INT),
        Headline("receptions", "catches", _YDS, one="catch"))),
    ("nfl", "FB"): Cohort("nfl_skill_ppr", "Fullback", (
        Headline("rushing_yards", "rushing yards", _YDS),
        Headline("rushing_tds", "rushing touchdowns", _INT),
        Headline("receptions", "catches", _YDS, one="catch"))),
    ("nfl", "WR"): Cohort("nfl_skill_ppr", "Wide receiver", (
        Headline("receiving_yards", "receiving yards", _YDS),
        Headline("receptions", "catches", _YDS, one="catch"),
        Headline("receiving_tds", "touchdown catches", _INT))),
    ("nfl", "TE"): Cohort("nfl_skill_ppr", "Tight end", (
        Headline("receiving_yards", "receiving yards", _YDS),
        Headline("receptions", "catches", _YDS, one="catch"),
        Headline("receiving_tds", "touchdown catches", _INT))),
    ("nfl", "dl"): Cohort("nfl_defense_fantasy", "Defensive lineman", (
        Headline("sacks", "sacks", _D1),
        Headline("tackles_combined", "tackles", _YDS),
        Headline("forced_fumbles", "forced fumbles", _INT))),
    ("nfl", "lb"): Cohort("nfl_defense_fantasy", "Linebacker", (
        Headline("tackles_combined", "tackles", _YDS),
        Headline("sacks", "sacks", _D1),
        Headline("def_interceptions", "interceptions", _INT))),
    ("nfl", "db"): Cohort("nfl_defense_fantasy", "Defensive back", (
        Headline("def_interceptions", "interceptions", _INT),
        Headline("tackles_combined", "tackles", _YDS),
        Headline("passes_defended", "passes defended", _INT, one="pass defended"))),
    # NBA career rows carry both summed totals and weight-averaged per-game rates
    # (career.py); the rates are how basketball is actually discussed, so the stat line
    # uses those and the *ranking* still uses the totals-based fantasy scale.
    ("nba", "G"): Cohort("nba_fantasy", "Guard", (
        Headline("ppg", "points", _D1, per_game=True),
        Headline("apg", "assists", _D1, per_game=True),
        Headline("rpg", "rebounds", _D1, per_game=True))),
    ("nba", "F"): Cohort("nba_fantasy", "Forward", (
        Headline("ppg", "points", _D1, per_game=True),
        Headline("rpg", "rebounds", _D1, per_game=True),
        Headline("apg", "assists", _D1, per_game=True))),
    ("nba", "C"): Cohort("nba_fantasy", "Center", (
        Headline("ppg", "points", _D1, per_game=True),
        Headline("rpg", "rebounds", _D1, per_game=True),
        Headline("bpg", "blocks", _D1, per_game=True))),
    ("baseball", "H"): Cohort("baseball_hitter_fantasy", "Position player", (
        Headline("hits", "hits", _YDS),
        Headline("home_runs", "home runs", _INT),
        Headline("rbi", "RBI", _YDS, one="RBI"))),
    ("baseball", "P"): Cohort("baseball_pitcher_fantasy", "Pitcher", (
        Headline("wins", "wins", _INT),
        Headline("strike_outs", "strikeouts", _YDS),
        Headline("saves", "saves", _INT))),
    ("soccer", "FW"): Cohort("soccer_attacker_fantasy", "Forward", (
        Headline("goals", "goals", _INT),
        Headline("assists", "assists", _INT),
        Headline("appearances", "appearances", _YDS))),
    ("soccer", "MF"): Cohort("soccer_attacker_fantasy", "Midfielder", (
        Headline("assists", "assists", _INT),
        Headline("goals", "goals", _INT),
        Headline("appearances", "appearances", _YDS))),
    ("soccer", "DF"): Cohort("soccer_defender_fantasy", "Defender", (
        Headline("appearances", "appearances", _YDS),
        Headline("clean_sheets", "clean sheets", _INT),
        Headline("goals", "goals", _INT))),
    ("soccer", "GK"): Cohort("soccer_defender_fantasy", "Goalkeeper", (
        Headline("clean_sheets", "clean sheets", _INT),
        Headline("appearances", "appearances", _YDS))),
    ("tennis", "Player"): Cohort("tennis_fantasy", "Tennis player", (
        Headline("titles", "tour titles", _INT),
        Headline("grand_slams", "major titles", _INT),
        Headline("matches_won", "match wins", _YDS, one="match win"))),
}


def cohort_for(sport: str, position: str) -> Cohort | None:
    return COHORTS.get((sport, grid_axes.position_family(sport, position)))


def position_is_informative(sport: str) -> bool:
    """False for a sport whose catalog `position` is a single degenerate value — tennis is all
    "Player", so a position clue there says "this tennis player is a tennis player" and burns
    one of six slots to do it. `grid_axes._POSITIONS` omits tennis for the same reason; this
    derives it from the cohort table instead of restating the sport by name, so a sport that
    gains real positions later starts getting the clue with no code change."""
    return len({pos for s, pos in COHORTS if s == sport}) > 1


def stat_line(cohort: Cohort, stats: dict[str, float]) -> str:
    """"12,918 rushing yards, 99 rushing touchdowns and 235 catches" — the career line.

    Zero-valued stats are dropped rather than printed: "0 forced fumbles" is noise, and for
    the pre-1994 seasons the catalog carries partial stat coverage it would also be a lie.
    """
    parts = []
    for h in cohort.headline:
        value = float(stats.get(h.stat) or 0.0)
        if value <= 0:
            continue
        parts.append(h.phrase(value))
    return join_list(parts)


# ── Fame ──────────────────────────────────────────────────────────────────────

def compute_fame(scored: list[tuple[str, str, float]]) -> dict[str, float]:
    """`{player_key: percentile}` from `(player_key, cohort_key, score)` triples.

    Percentile is computed **within a cohort**, never across them: an NBA guard's fantasy
    total and an NFL linebacker's are different units, and even inside one sport a QB's
    passing-heavy total dwarfs a running back's. Ranking a player against their own
    position is the only comparison that means "how famous, for what they did".

    Ties share the lower percentile (`rank / (n - 1)` over the sorted position), so a wall
    of equal-scored players can't be split arbitrarily into different difficulty tiers.
    """
    by_cohort: dict[str, list[tuple[str, float]]] = collections.defaultdict(list)
    for player_key, cohort_key, score in scored:
        by_cohort[cohort_key].append((player_key, score))

    fame: dict[str, float] = {}
    for rows in by_cohort.values():
        rows.sort(key=lambda t: (t[1], t[0]))
        n = len(rows)
        if n == 1:
            fame[rows[0][0]] = 1.0
            continue
        # Rank of the first row sharing each score, so equal scores get equal percentiles.
        first_index_of: dict[float, int] = {}
        for index, (_key, score) in enumerate(rows):
            first_index_of.setdefault(score, index)
        for _index, (player_key, score) in enumerate(rows):
            fame[player_key] = first_index_of[score] / (n - 1)
    return fame


def blended_fame(candidates: list[Candidate]) -> dict[str, float]:
    """`{player_key: fame}` blending career-volume and peak-season percentiles.

    Two percentiles, both cohort-relative (so both are unit-free and comparable), mixed at
    `PEAK_FAME_WEIGHT`. See that constant for the concrete failure this fixes — a career-only
    score is really a measure of *longevity*, and longevity is not fame.
    """
    career = compute_fame([(c.key, c.cohort_key, c.score) for c in candidates])
    peak = compute_fame([(c.key, c.cohort_key, c.peak_score) for c in candidates])
    return {c.key: (1 - PEAK_FAME_WEIGHT) * career[c.key] + PEAK_FAME_WEIGHT * peak[c.key]
            for c in candidates}


# ── Subject assembly ──────────────────────────────────────────────────────────

@dataclass
class Candidate:
    """A career row plus everything derived from that player's season rows."""
    name: str
    sport: str
    position: str
    cohort_key: str
    first_year: int
    last_year: int
    seasons: int
    teams: list[str]                  # resolvable franchise names, career order
    unnamed_teams: int                # teams whose abbr couldn't be named safely
    nationality: str                  # tennis only (its `team_abbr` is a country code)
    leagues: set[str]
    career_stats: dict[str, float]
    best: dict                        # {'year','team','line'} or {}
    active: bool                      # last season is the catalog's most recent for the sport
    score: float                      # graded career totals
    peak_score: float                 # graded best single season
    has_headshot: bool

    @property
    def key(self) -> str:
        return slug(self.name)

    @property
    def span(self) -> int:
        """Calendar years from first season to last, inclusive."""
        return self.last_year - self.first_year + 1

    @property
    def plausible_career(self) -> bool:
        """False when this row is two same-name players welded together — see
        MAX_CAREER_SPAN for the concrete case that motivated this."""
        return (self.span <= MAX_CAREER_SPAN
                and self.seasons <= MAX_CAREER_SPAN
                and self.seasons >= MIN_SEASON_DENSITY * self.span)


def _career_order_teams(sport: str, rows: list[dict],
                        soccer_names: dict[str, str]) -> tuple[list[str], int]:
    """(franchise names in first-appearance order, count of teams that couldn't be named).

    De-duplicated, so a player who left and came back shows up once, where they started.
    Unnamed teams are counted rather than included: `qualify` uses that count to withhold the
    team-naming dimensions from a player whose career touches a franchise this module can't
    name safely, instead of printing a raw abbreviation into a clue.
    """
    ordered: list[str] = []
    unnamed = 0
    seen_abbrs: set[str] = set()
    for row in sorted(rows, key=lambda r: r["season_year"]):
        abbr = row["team_abbr"]
        if not abbr or abbr in seen_abbrs or (sport, abbr) in EXHIBITION_TEAM_CODES:
            continue
        seen_abbrs.add(abbr)
        name = team_display(sport, abbr, soccer_names)
        if not name:
            unnamed += 1
        elif name not in ordered:
            ordered.append(name)
    return ordered, unnamed


def _best_season(sport: str, rows: list[dict], cohort: Cohort,
                 soccer_names: dict[str, str]) -> tuple[dict, float]:
    """The single highest-graded season as ({'year','team','line'}, its grade)."""
    best, best_score = None, 0.0
    for row in rows:
        score = grade(row.get("stats") or {}, cohort.scale)
        if best is None or score > best_score:
            best, best_score = row, score
    if best is None:
        return {}, 0.0
    line = stat_line(cohort, best.get("stats") or {})
    if not line:
        return {}, best_score
    return {"year": best["season_year"],
            # "" when the franchise can't be named safely — `_best_season`'s clue builder
            # drops the "with the ..." fragment rather than printing an abbreviation.
            "team": team_display(sport, best.get("team_abbr", ""), soccer_names),
            "line": line}, best_score


def build_candidates(career_rows: list[dict], season_rows: list[dict],
                     soccer_names: dict[str, str]) -> list[Candidate]:
    """Fold the two catalog grains into one candidate per player.

    Joined by name within a sport, which is exactly why `qualify` drops shared names: the
    catalog's own ids are per-season, so there is no id that identifies a *person* across
    both grains, and a name join on a shared name would silently blend two careers into one
    unanswerable puzzle.
    """
    by_name: dict[str, list[dict]] = collections.defaultdict(list)
    for row in season_rows:
        by_name[row["name"]].append(row)

    # "Active" is relative to the catalog, not the calendar: soccer labels a season by its END
    # year (so the newest rows read 2027 in mid-2026) and the NFL's current-season aggregate
    # doesn't publish until the year is over. Comparing against the newest season the sport
    # actually has is the only definition that doesn't retire active players a year early or
    # keep retired ones "active" forever.
    latest = max((r["season_year"] for r in season_rows), default=0)

    out: list[Candidate] = []
    for row in career_rows:
        cohort = cohort_for(row["sport"], row["position"])
        if cohort is None:
            continue
        seasons = by_name.get(row["name"], [])
        if not seasons:
            continue
        career_stats = row.get("stats") or {}
        sport = row["sport"]
        best, peak_score = _best_season(sport, seasons, cohort, soccer_names)
        teams, unnamed = ((_career_order_teams(sport, seasons, soccer_names))
                          if sport in TEAM_SPORTS else ([], 0))
        out.append(Candidate(
            name=row["name"],
            sport=row["sport"],
            position=row["position"],
            cohort_key=f"{row['sport']}|{grid_axes.position_family(row['sport'], row['position'])}",
            first_year=int(row.get("first_year") or row["season_year"]),
            last_year=int(row.get("last_year") or row["season_year"]),
            seasons=len({s["season_year"] for s in seasons}),
            teams=teams,
            unnamed_teams=unnamed,
            # Tennis `team_abbr` is a country code, not a club (see TEAM_SPORTS) — it becomes
            # the nationality dimension rather than a bogus team list.
            nationality=("" if sport in TEAM_SPORTS
                         else (row.get("team_abbr") or "").strip()),
            leagues={s["league"] for s in seasons if s.get("league")},
            career_stats=career_stats,
            best=best,
            active=int(row.get("last_year") or row["season_year"]) >= latest - 1,
            score=grade(career_stats, cohort.scale),
            peak_score=peak_score,
            has_headshot=bool(row.get("headshot")),
        ))
    return out


def qualify(candidates: list[Candidate]) -> list[Candidate]:
    """The subjects that clear the identifiability floor (see the module docstring)."""
    name_counts = collections.Counter(c.key for c in candidates)
    kept: list[Candidate] = []
    for c in candidates:
        if not c.has_headshot:
            continue
        if name_counts[c.key] > 1:
            continue
        if c.seasons < MIN_SEASONS.get(c.sport, 4):
            continue
        if not c.plausible_career:
            continue
        # Some affiliation must be known — a franchise for team sports, a country for tennis
        # (whose `team_abbr` is a country code, see TEAM_SPORTS). Checked per sport rather
        # than as a bare `not c.teams`: that form silently rejected every tennis player,
        # since tennis candidates carry a nationality and an empty team list by design.
        affiliation = (c.teams or c.unnamed_teams) if c.sport in TEAM_SPORTS else c.nationality
        if not affiliation or not c.best:
            continue
        if c.sport == "soccer" and not (c.leagues & SOCCER_LEAGUES):
            continue
        if c.score <= 0:            # no usable stats on the career row
            continue
        kept.append(c)

    # Production floor is applied *within* the surviving cohort, so it means "the top 45% of
    # players who lasted this long at this position" rather than a raw stat threshold that
    # would need a hand-tuned number per sport, position and era.
    fame = blended_fame(kept)
    return [c for c in kept if fame[c.key] >= PRODUCTION_FLOOR]


def to_entry(c: Candidate, fame: float, bio: dict[str, str] | None = None) -> WhoAmIEntry:
    """A qualified candidate as a `WhoAmIEntry`, with NFL bio folded in when available."""
    cohort = cohort_for(c.sport, c.position)
    assert cohort is not None       # qualify() only keeps candidates with a cohort
    bio = bio or {}

    def as_int(key: str) -> int | None:
        raw = (bio.get(key) or "").strip()
        return int(float(raw)) if raw.replace(".", "", 1).isdigit() else None

    last = c.name.split()[-1].lower()
    return WhoAmIEntry(
        sport=c.sport,
        canonical=c.name,
        # Last name alone is already accepted by the client's `AnswerMatcher`; listing the
        # full name keeps the accepted set explicit for anything that reads content directly.
        aliases=[c.name.lower()] + ([last] if len(last) >= 4 else []),
        # "" for a sport with one position (see `position_is_informative`) — the clue picker
        # treats an empty field as an absent dimension and draws something useful instead.
        position=cohort.position if position_is_informative(c.sport) else "",
        first_year=c.first_year,
        last_year=c.last_year,
        teams=c.teams,
        stat_line=stat_line(cohort, c.career_stats),
        jersey=(bio.get("jersey") or "").strip(),
        fact="",                    # curated-only: no provider carries a "known for" line
        seasons=c.seasons,
        league=next(iter(sorted(c.leagues & SOCCER_LEAGUES)), "") if c.sport == "soccer" else "",
        nationality=c.nationality,
        active=c.active,
        teams_named=c.unnamed_teams == 0,
        franchise_count=len(c.teams) + c.unnamed_teams,
        best_season=c.best,
        college=(bio.get("college") or "").strip(),
        college_conference=(bio.get("college_conference") or "").strip(),
        height_in=as_int("height_in"),
        weight_lb=as_int("weight_lb"),
        birth_year=as_int("birth_year"),
        draft_year=as_int("draft_year"),
        draft_round=as_int("draft_round"),
        draft_pick=as_int("draft_pick"),
        draft_team=(bio.get("draft_team") or "").strip(),
        # nflverse carries a draft row for every drafted player, so "we have bio for this
        # player and it has no draft year" is a real undrafted signal — but only when the
        # bio join actually landed. No bio at all means unknown, and unknown must not
        # become a confident "never got drafted" clue.
        undrafted=bool(bio) and not (bio.get("draft_year") or "").strip(),
        fame=round(fame, 4),
        difficulty=tier_for_fame(fame),
        source="catalog",
    )


def select(entries: list[WhoAmIEntry], cap: int = PER_SPORT_CAP) -> list[WhoAmIEntry]:
    """Trim one sport's entries to `cap`, filled per `TIER_MIX` best-fame-first.

    Any tier that can't fill its share hands the remainder to the others, so a sport with a
    thin hard tier still gets a full pool rather than a short one.
    """
    by_tier: dict[str, list[WhoAmIEntry]] = {t: [] for t in DIFFICULTIES}
    for e in entries:
        by_tier[e.difficulty or "hard"].append(e)
    for tier in by_tier:
        by_tier[tier].sort(key=lambda e: (-(e.fame or 0.0), e.canonical))

    picked: list[WhoAmIEntry] = []
    for tier, share in TIER_MIX.items():
        picked += by_tier[tier][: round(cap * share)]
    if len(picked) < cap:           # backfill from whatever's left, most famous first
        chosen = {e.canonical for e in picked}
        rest = sorted((e for e in entries if e.canonical not in chosen),
                      key=lambda e: (-(e.fame or 0.0), e.canonical))
        picked += rest[: cap - len(picked)]
    return sorted(picked, key=lambda e: (e.difficulty, -(e.fame or 0.0), e.canonical))


# ── Curated-entry enrichment ──────────────────────────────────────────────────

def enrich_curated(entries: list[WhoAmIEntry],
                   bio_by_name: dict[str, dict[str, str]]) -> list[WhoAmIEntry]:
    """Fold bio onto the hand-authored legends so they draw from the wide dimension set too.

    Without this the curated entries are stuck on the ~10 dimensions their JSON carries
    while generated ones get ~20, which would make the legends the *predictable* puzzles —
    backwards. Only fills fields the JSON left empty: an editorial value always wins over a
    provider's, since that's the whole point of hand-authoring one.
    """
    out: list[WhoAmIEntry] = []
    for entry in entries:
        bio = bio_by_name.get(entry.canonical)
        if not bio:
            out.append(entry)
            continue

        def as_int(key: str) -> int | None:
            raw = (bio.get(key) or "").strip()
            return int(float(raw)) if raw.replace(".", "", 1).isdigit() else None

        out.append(replace(
            entry,
            college=entry.college or (bio.get("college") or "").strip(),
            college_conference=entry.college_conference or (bio.get("college_conference") or "").strip(),
            height_in=entry.height_in or as_int("height_in"),
            weight_lb=entry.weight_lb or as_int("weight_lb"),
            birth_year=entry.birth_year or as_int("birth_year"),
            draft_year=entry.draft_year or as_int("draft_year"),
            draft_round=entry.draft_round or as_int("draft_round"),
            draft_pick=entry.draft_pick or as_int("draft_pick"),
            draft_team=entry.draft_team or (bio.get("draft_team") or "").strip(),
            seasons=entry.seasons or (entry.last_year - entry.first_year + 1),
        ))
    return out


# ── Serialization ─────────────────────────────────────────────────────────────

# `WhoAmIEntry`'s ten positional fields. Always written even when empty, because they have
# no dataclass default — omitting `jersey: ""` from a soccer entry (soccer bio carries no
# jersey number, so that is the common case, not an edge one) makes the row fail to load
# back with `WhoAmIEntry(**row)`.
_REQUIRED_JSON_FIELDS = frozenset({
    "sport", "canonical", "aliases", "position", "first_year", "last_year",
    "teams", "stat_line", "jersey", "fact",
})

_EMPTY_ENTRY = WhoAmIEntry(sport="", canonical="", aliases=[], position="", first_year=0,
                           last_year=0, teams=[], stat_line="", jersey="", fact="")


def entry_to_json(entry: WhoAmIEntry) -> dict:
    """One entry as a pool-file row. Optional fields still at their default are omitted, so
    the file stays readable and a regeneration diff shows real changes rather than a wall of
    nulls."""
    return {
        name: getattr(entry, name)
        for name in entry.__dataclass_fields__
        if name in _REQUIRED_JSON_FIELDS
        or getattr(entry, name) != getattr(_EMPTY_ENTRY, name)
    }


def load_pool(path) -> list[WhoAmIEntry]:
    """The generated pool, or an empty list when it hasn't been generated yet — a fresh
    checkout has no pool file and must still be able to mint from the curated entries."""
    if not path.exists():
        return []
    return [WhoAmIEntry(**row) for row in json.loads(path.read_text(encoding="utf-8"))]


# Bundled-fallback size, per (sport, tier). The offline bundle is what a user gets when
# Supabase is unreachable, so it wants breadth, not the whole pool: 8 × 5 sports × 3 tiers is
# ~120 puzzles at roughly 100 KB, against ~630 KB for all 762. (It held **12** puzzles across
# two sports before this — an offline soccer or tennis player had no Who Am I? at all.)
BUNDLE_PER_SPORT_PER_TIER = 8


def bundle_subset(rows: list) -> list:
    """A balanced slice of built `PuzzleRow`s for the offline bundle — up to
    `BUNDLE_PER_SPORT_PER_TIER` per (sport, difficulty), most famous first within each.

    Shared by `main.write_fallback` and `whoami_pool --write-bundle` so the two entry points
    can't produce different bundles.
    """
    picked: list = []
    counts: dict[tuple[str, str], int] = {}
    for row in rows:
        key = (row.sport, row.content.get("difficulty", "medium"))
        if counts.get(key, 0) >= BUNDLE_PER_SPORT_PER_TIER:
            continue
        counts[key] = counts.get(key, 0) + 1
        picked.append(row)
    return picked


def all_entries(data_dir) -> list[WhoAmIEntry]:
    """Every Who Am I? subject: the curated legends (bio-enriched) plus the generated pool.

    The single entry point for both consumers — main.py's archival pool build and
    daily_whoami.py's nightly mint — so neither can drift into using only half the pool.

    A curated entry always wins a name collision with a generated one: the generated version
    of a legend would have the same stats and none of the editorial nickname/known-for/
    accolade dimensions, so keeping it would be a strict downgrade served at random.
    """
    curated = load_whoami_entries(data_dir / "whoami_facts.json")
    try:
        curated = enrich_curated(curated, load_nfl_bio_by_name())
    except Exception as err:                                    # noqa: BLE001
        print(f"[whoami] curated bio enrichment skipped ({err})")
    curated_keys = {(e.sport, slug(e.canonical)) for e in curated}
    pool = [e for e in load_pool(data_dir / POOL_FILE)
            if (e.sport, slug(e.canonical)) not in curated_keys]
    return curated + pool


# ── CLI ───────────────────────────────────────────────────────────────────────

def generate_for_sport(sport: str, soccer_names: dict[str, str],
                       bio_by_name: dict[str, dict[str, str]]) -> list[WhoAmIEntry]:
    from .upsert import WHOAMI_CATALOG_COLUMNS, fetch_player_seasons
    cols = WHOAMI_CATALOG_COLUMNS
    career_rows = fetch_player_seasons(sport, career=True, columns=cols)
    season_rows = fetch_player_seasons(sport, columns=cols)
    print(f"[whoami-pool] {sport}: {len(career_rows)} career + {len(season_rows)} season rows")

    candidates = build_candidates(career_rows, season_rows, soccer_names)
    qualified = qualify(candidates)
    # Recomputed over the qualified set (not reused from `qualify`'s floor pass) so `fame`
    # spans the full 0-1 range across the pool that actually ships, and the difficulty cuts
    # partition that pool rather than a sliver at the top of it.
    fame = blended_fame(qualified)
    entries = [to_entry(c, fame[c.key], bio_by_name.get(c.name)) for c in qualified]
    picked = select(entries)
    tiers = collections.Counter(e.difficulty for e in picked)
    print(f"[whoami-pool] {sport}: {len(candidates)} candidates → {len(qualified)} qualified "
          f"→ {len(picked)} kept ({', '.join(f'{t}: {tiers[t]}' for t in DIFFICULTIES)})")
    return picked


def load_nfl_bio_by_name() -> dict[str, dict[str, str]]:
    """`{display name: bio fields}` from nflverse, **shared names dropped entirely**.

    The catalog has no `gsis_id` column, so a name is the only join key available from the
    live table — and 827 of nflverse's ~24k display names are shared by more than one real
    player. `nfl_players.pick_headshot` resolves that ambiguity with an era check because a
    photo has an era to check against; a college or a draft slot doesn't, so here the
    ambiguous names are simply excluded. Bio is a bonus dimension set, and the wrong college
    on a puzzle is worse than no college clue at all.
    """
    from .providers import nfl_players
    bio = nfl_players.load_bio()
    names = collections.Counter()
    by_name: dict[str, dict[str, str]] = {}
    for fields in bio.values():
        name = f"{fields.get('first_name', '')} {fields.get('last_name', '')}".strip()
        if not name:
            continue
        names[name] += 1
        by_name[name] = fields
    return {name: fields for name, fields in by_name.items() if names[name] == 1}


# ── Franchise names ───────────────────────────────────────────────────────────
#
# A generated clue reading "Started out with the NYG" is not a clue, so this module needs an
# abbreviation → franchise map.
#
# `data/us_team_colors.csv`'s `full_name` column was backfilled as its own piece of work on
# 2026-08-27 (the K4C4 card now prints the franchise name), so the live `teams` table does
# carry US names — but it carries the CURRENT franchise name keyed by the CURRENT code, which
# is not what a clue needs: this map covers era codes the table has no row for at all (OAK,
# PHO, SD, RAM) and deliberately omits codes a fan would read differently by era. It stays
# local for that reason, not because the column is empty any more.
#
# Only the abbreviations the catalog actually uses are listed, and **only where the code maps
# to exactly one franchise**. Codes that a fan would read differently depending on era are
# deliberately absent (see `_AMBIGUOUS_TEAM_CODES`) — an unnamed team costs a player three
# clue dimensions, and a wrongly-named one costs them the puzzle.
FRANCHISES: dict[tuple[str, str], str] = {
    ("nfl", "ARI"): "Cardinals", ("nfl", "ATL"): "Falcons", ("nfl", "BAL"): "Ravens",
    ("nfl", "BUF"): "Bills", ("nfl", "CAR"): "Panthers", ("nfl", "CHI"): "Bears",
    ("nfl", "CIN"): "Bengals", ("nfl", "CLE"): "Browns", ("nfl", "DAL"): "Cowboys",
    ("nfl", "DEN"): "Broncos", ("nfl", "DET"): "Lions", ("nfl", "GB"): "Packers",
    ("nfl", "HOU"): "Texans", ("nfl", "IND"): "Colts", ("nfl", "JAC"): "Jaguars",
    ("nfl", "JAX"): "Jaguars", ("nfl", "KC"): "Chiefs", ("nfl", "LAC"): "Chargers",
    ("nfl", "LV"): "Raiders", ("nfl", "MIA"): "Dolphins", ("nfl", "MIN"): "Vikings",
    ("nfl", "NE"): "Patriots", ("nfl", "NO"): "Saints", ("nfl", "NYG"): "Giants",
    ("nfl", "NYJ"): "Jets", ("nfl", "OAK"): "Raiders", ("nfl", "PHI"): "Eagles",
    ("nfl", "PHO"): "Cardinals", ("nfl", "PIT"): "Steelers", ("nfl", "RAM"): "Rams",
    ("nfl", "SD"): "Chargers", ("nfl", "SEA"): "Seahawks", ("nfl", "SF"): "49ers",
    ("nfl", "TB"): "Buccaneers", ("nfl", "TEN"): "Titans",

    ("nba", "ATL"): "Hawks", ("nba", "BAL"): "Bullets", ("nba", "BKN"): "Nets",
    ("nba", "BOS"): "Celtics", ("nba", "CAP"): "Bullets", ("nba", "CHH"): "Hornets",
    ("nba", "CHI"): "Bulls", ("nba", "CIN"): "Royals", ("nba", "CLE"): "Cavaliers",
    ("nba", "DAL"): "Mavericks", ("nba", "DEN"): "Nuggets", ("nba", "DET"): "Pistons",
    ("nba", "GS"): "Warriors", ("nba", "HOU"): "Rockets", ("nba", "IND"): "Pacers",
    ("nba", "KCK"): "Kings", ("nba", "KCO"): "Kings", ("nba", "LAC"): "Clippers",
    ("nba", "LAL"): "Lakers", ("nba", "MEM"): "Grizzlies", ("nba", "MIA"): "Heat",
    ("nba", "MIL"): "Bucks", ("nba", "MIN"): "Timberwolves", ("nba", "MNL"): "Lakers",
    ("nba", "NJ"): "Nets", ("nba", "NJN"): "Nets", ("nba", "NY"): "Knicks",
    ("nba", "NYN"): "Nets", ("nba", "OKC"): "Thunder", ("nba", "ORL"): "Magic",
    ("nba", "PHI"): "76ers", ("nba", "PHW"): "Warriors", ("nba", "PHX"): "Suns",
    ("nba", "POR"): "Trail Blazers", ("nba", "SA"): "Spurs", ("nba", "SAC"): "Kings",
    ("nba", "SDC"): "Clippers", ("nba", "SDR"): "Rockets", ("nba", "SEA"): "SuperSonics",
    ("nba", "SFW"): "Warriors", ("nba", "STL"): "Hawks", ("nba", "SYR"): "Nationals",
    ("nba", "TOR"): "Raptors", ("nba", "UTAH"): "Jazz", ("nba", "VAN"): "Grizzlies",
    ("nba", "WSB"): "Bullets",

    ("baseball", "ATH"): "Athletics", ("baseball", "ATL"): "Braves",
    ("baseball", "AZ"): "Diamondbacks", ("baseball", "BAL"): "Orioles",
    ("baseball", "BOS"): "Red Sox", ("baseball", "CHC"): "Cubs", ("baseball", "CIN"): "Reds",
    ("baseball", "COL"): "Rockies", ("baseball", "CWS"): "White Sox",
    ("baseball", "DET"): "Tigers", ("baseball", "HOU"): "Astros", ("baseball", "KC"): "Royals",
    ("baseball", "LAA"): "Angels", ("baseball", "LAD"): "Dodgers", ("baseball", "MIA"): "Marlins",
    ("baseball", "MIL"): "Brewers", ("baseball", "MIN"): "Twins", ("baseball", "NYM"): "Mets",
    ("baseball", "NYY"): "Yankees", ("baseball", "PHI"): "Phillies",
    ("baseball", "PIT"): "Pirates", ("baseball", "SD"): "Padres", ("baseball", "SEA"): "Mariners",
    ("baseball", "SF"): "Giants", ("baseball", "STL"): "Cardinals", ("baseball", "TB"): "Rays",
    ("baseball", "TEX"): "Rangers", ("baseball", "TOR"): "Blue Jays",
}

# Codes that named two different franchises depending on the year, so no single nickname is
# correct for every player who wore one. Listed explicitly (rather than merely omitted from
# `FRANCHISES`) so the next person to "fill in the missing teams" sees why these are missing:
#   nfl STL     — Cardinals through 1987, Rams from 1995
#   nfl LA      — Rams, but also the Raiders 1982-1994
#   nba CHA     — Hornets, then Bobcats 2004-2014, then Hornets again
#   nba NO      — Hornets 2002-2013, Pelicans since
#   nba/mlb WSH — Bullets vs Wizards; Senators vs Nationals
#   mlb CLE     — Indians through 2021, Guardians since
_AMBIGUOUS_TEAM_CODES = frozenset({
    ("nfl", "STL"), ("nfl", "LA"), ("nba", "CHA"), ("nba", "NO"), ("nba", "WSH"),
    ("baseball", "CLE"), ("baseball", "WSH"),
})

# Not franchises at all: NBA All-Star and Rising Stars rosters, which the catalog carries as
# ordinary season rows. Without this, a star's franchise count silently includes "Team LeBron"
# and the teams clue lists an exhibition roster alongside real clubs.
EXHIBITION_TEAM_CODES = frozenset({
    ("nba", "LEB"), ("nba", "GIA"), ("nba", "DUR"), ("nba", "WORLD"), ("nba", "GIANNIS"),
})

# Sports where `team_abbr` is a franchise a player can move between. Tennis is excluded
# because there it holds the player's COUNTRY (see grid_axes.TEAM_MOBILE_SPORTS, same fact) —
# so a tennis "teams" clue would be a nationality wearing the wrong label, and a tennis
# "spent an entire career with one club" clue would be true of literally every player.
TEAM_SPORTS = grid_axes.TEAM_MOBILE_SPORTS


def team_display(sport: str, abbr: str, soccer_names: dict[str, str]) -> str:
    """The franchise nickname for one catalog `team_abbr`, or "" when it can't be named
    safely. Soccer comes from the live `teams` table (which has full names for every club);
    everything else from `FRANCHISES`."""
    if not abbr or (sport, abbr) in _AMBIGUOUS_TEAM_CODES:
        return ""
    if (sport, abbr) in EXHIBITION_TEAM_CODES:
        return ""
    if sport == "soccer":
        return soccer_names.get(abbr, "")
    return FRANCHISES.get((sport, abbr), "")


def _soccer_team_names() -> dict[str, str]:
    """`{team_abbr: club name}` for soccer, from the live `teams` table. Unlike the US sports
    these are full club names ("AZ Alkmaar", "Ajax Amsterdam") and are used as-is — a club is
    called by its name, not by a nickname split off the end of it."""
    from .upsert import fetch_teams
    return {row["team_abbr"]: (row.get("full_name") or "").strip()
            for row in fetch_teams()
            if row["sport"] == "soccer" and (row.get("full_name") or "").strip()}


def _write_bundle(rows: list) -> int:
    """Write `bundle_subset(rows)` to the app's offline fallback JSON."""
    from .validate import validate
    subset = bundle_subset(rows)
    for row in subset:
        validate(row)
    ingest_main.FALLBACK_WHOAMI.write_text(
        json.dumps([r.content for r in subset], indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8")
    tiers = collections.Counter(r.content["difficulty"] for r in subset)
    sports = collections.Counter(r.sport for r in subset)
    print(f"[whoami-pool] bundle: {len(subset)} of {len(rows)} puzzles → "
          f"{ingest_main.FALLBACK_WHOAMI}")
    print(f"[whoami-pool]   sports {dict(sorted(sports.items()))}, "
          f"tiers {dict((t, tiers[t]) for t in DIFFICULTIES)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate the Who Am I? subject pool")
    ap.add_argument("--write", action="store_true", help=f"write data/{POOL_FILE}")
    ap.add_argument("--dry-run", action="store_true",
                    help="generate + print a per-tier sample, no file written")
    ap.add_argument("--sport", nargs="*", default=None,
                    help="sports to refresh (default: every sport with a cohort)")
    ap.add_argument("--samples", type=int, default=3, help="entries to print per tier")
    ap.add_argument("--write-bundle", action="store_true",
                    help="also refresh BallIQ/Data/whoami_puzzles.json from the pool file "
                         "(no catalog pull — use after --write, or on its own)")
    args = ap.parse_args()
    if not args.write and not args.dry_run and not args.write_bundle:
        args.dry_run = True

    if args.write_bundle and not args.write:
        # Bundle-only: the pool file on disk is the input, so this needs no network at all.
        # main.py --write-fallback does the same thing at the end of a full ingest; this is
        # the path for refreshing the bundle after a pool regeneration on its own.
        ingest_main.load_dotenv()
        rows = [assemble_whoami_row(e) for e in all_entries(ingest_main.DATA_DIR)]
        return _write_bundle(rows)

    ingest_main.load_dotenv()
    sports = args.sport or sorted({sport for sport, _ in COHORTS})
    path = ingest_main.DATA_DIR / POOL_FILE

    soccer_names = _soccer_team_names()
    print(f"[whoami-pool] {len(soccer_names)} soccer club names + "
          f"{len(FRANCHISES)} US franchise names loaded")
    try:
        bio_by_name = load_nfl_bio_by_name()
        print(f"[whoami-pool] {len(bio_by_name)} unambiguous NFL bio records")
    except Exception as err:                                    # noqa: BLE001
        bio_by_name = {}
        print(f"[whoami-pool] NFL bio join skipped ({err}): bio dimensions will be absent")

    # Regenerating one sport must not drop the others' entries from the file.
    existing = {e.canonical: e for e in load_pool(path) if e.sport not in sports}
    generated: list[WhoAmIEntry] = []
    for sport in sports:
        generated += generate_for_sport(sport, soccer_names, bio_by_name)

    pool = sorted(list(existing.values()) + generated,
                  key=lambda e: (e.sport, e.difficulty, -(e.fame or 0.0), e.canonical))

    for sport in sports:
        for tier in DIFFICULTIES:
            sample = [e for e in pool if e.sport == sport and e.difficulty == tier]
            print(f"\n── {sport} · {tier} ({len(sample)}) ──")
            for e in sample[:: max(1, len(sample) // max(1, args.samples))][: args.samples]:
                print(f"   {e.canonical} ({e.position}, {e.first_year}-{e.last_year}, "
                      f"fame {e.fame}) — {e.stat_line}")

    if args.write:
        path.write_text(
            json.dumps([entry_to_json(e) for e in pool], indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8")
        print(f"\n[whoami-pool] wrote {len(pool)} entries → {path}")
        if args.write_bundle:
            _write_bundle([assemble_whoami_row(e) for e in all_entries(ingest_main.DATA_DIR)])
    else:
        print(f"\n[whoami-pool] --dry-run: {len(pool)} entries not written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
