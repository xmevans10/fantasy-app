"""Core data structures shared across the ingestion pipeline.

A `RawSeason` is a single real player-season pulled from a provider (nflverse,
balldontlie, or the curated seed). It carries the raw numeric stats keyed by a
stable name; `grade.py` turns those into a ranking quality score (raw fantasy
points) and `assemble.py` turns them into the camelCase `content` JSON the
Swift Codable models decode.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field


@dataclass(frozen=True)
class RawSeason:
    """One real player-season of stats from a provider."""

    name: str
    team_abbr: str
    season_year: int
    sport: str               # 'nfl' | 'nba'
    position: str            # 'WR','RB','QB' | 'G','F','C' ...
    stats: dict[str, float]  # raw numeric stats, e.g. {'rushing_yards': 2027, ...}
    source: str = "seed"     # provenance: 'nflverse' | 'espn' | 'balldontlie' | 'seed'
    headshot: str = ""       # player headshot URL (provider-supplied); "" when unavailable
    # Single-game grain (None/"" = season aggregate). A row with `week` set is one game.
    week: int | None = None
    opponent: str = ""       # opponent team abbr for game-grain rows, e.g. "DEN"
    # Pre-formatted display date for non-NFL game-grain rows (e.g. "Apr 8") — NFL's card
    # context reads as "vs OPP · Wk W", which doesn't make sense for MLB/NBA where the
    # game isn't identified by a week number; those providers set this instead so
    # PlayerSeason.swift's subtitle can read "vs OPP · Apr 8 · 2022". "" = use `week`.
    game_date: str = ""
    # Career-grain aggregate (see career.py) — one row per (sport, position, player) summing
    # every real season the pipeline pulled. Mutually exclusive with `week` (a career row is
    # never a single game); `season_year` holds the player's LAST season for sort/recency
    # purposes, with the full span in `meta["first_year"]`/`meta["last_year"]`.
    career: bool = False
    # Mutable bag of biographical/contextual fields for niche filters (first_name, college,
    # draft_round, draft_pick, height_in, age, jersey, birth_state, rookie_year, gsis_id,
    # league — this last one only populated by espn_soccer.py, e.g. "England" …).
    # `frozen=True` only blocks rebinding the attribute, not mutating this dict — providers
    # and the bio join populate it in place.
    meta: dict[str, str] = field(default_factory=dict)

    @property
    def player_id(self) -> str:
        """Stable id for this entity inside a puzzle, e.g. 'nfl-derrick-henry-2020' (season),
        'nfl-derrick-henry-2020-wk12' (single game), or 'nfl-derrick-henry-career' (career
        aggregate) so none of the three grains ever collide.

        Sport-prefixed (as of 2026-07-14) — this is `player_seasons.id`, the table's primary
        key / upsert conflict target, and it was NOT sport-scoped before this: two different
        real players sharing a name (e.g. NFL RB Chris Johnson and MLB 3B Chris Johnson, both
        active 2009-2016) collided on the bare `slug(name)-year` id for every overlapping year,
        and the later-ingested sport silently overwrote the earlier one on every upsert. Confirmed
        live: NFL Chris Johnson's actual 2009 season (2,006 rushing yards) was missing from the
        catalog, clobbered by MLB Chris Johnson's 2009 Astros season under the same id. A full
        re-ingest across every sport is required after this change to recover any seasons a past
        collision silently dropped — a bare format-string fix here only stops *future* collisions."""
        if self.career:
            return f"{self.sport}-{slug(self.name)}-career"
        base = f"{self.sport}-{slug(self.name)}-{self.season_year}"
        return f"{base}-wk{self.week:02d}" if self.week is not None else base


def slug(text: str) -> str:
    """Lowercase, ascii-folded, hyphenated slug. 'Amar'e Stoudemire' -> 'amare-stoudemire'."""
    ascii_text = (
        unicodedata.normalize("NFKD", text)
        .encode("ascii", "ignore")
        .decode("ascii")
    )
    ascii_text = ascii_text.lower()
    ascii_text = re.sub(r"[^a-z0-9]+", "-", ascii_text)
    return ascii_text.strip("-")


@dataclass(frozen=True)
class WhoAmIEntry:
    """A factual basis for a Who Am I? puzzle — the *subject*, not the puzzle.

    Clue text is generated from these structured fields (see whoami_clues.py), so the
    output is data-derived rather than hand-written prose. An entry is a bag of
    **optional dimensions**: whichever ones carry data are the ones the clue picker has
    to choose from, and a subject with more populated fields simply gets a wider, more
    varied draw. Nothing here is a placeholder — a missing college is an absent college
    clue, never an "Unknown college" one.

    Two sources populate these (`source`):
    - `curated`  — hand-authored editorial entries in `data/whoami_facts.json` (the
                   legends, whose `fact`/`nickname`/`accolades` are the good stuff no
                   provider carries), enriched in place from the catalog + bio join.
    - `catalog`  — generated from the live `player_seasons` catalog by whoami_pool.py.
                   This is where the non-legends come from; see that module for how the
                   fame percentile that tiers them is computed.

    The first ten fields are the original required set and stay required so existing
    `whoami_facts.json` rows keep loading unchanged; everything added since is optional.
    """

    sport: str
    canonical: str            # full name, e.g. 'Brett Favre'
    aliases: list[str]
    position: str             # 'Quarterback', 'Point Guard', ...
    first_year: int
    last_year: int
    teams: list[str]          # franchise names in career order
    stat_line: str            # a real, factual signature/career line
    jersey: str               # primary jersey number(s), e.g. '4'
    fact: str                 # curated "known-for" fact
    extra_aliases: list[str] = field(default_factory=list)

    # ── Bio dimensions (NFL today: nflverse players.csv via providers/nfl_players.py;
    # every other sport has no bio provider yet, so these stay empty and those sports
    # simply draw from the career/production/team dimensions instead) ──────────────
    college: str = ""
    college_conference: str = ""
    height_in: int | None = None     # inches, e.g. 74
    weight_lb: int | None = None
    birth_year: int | None = None

    # ── Draft dimensions. `undrafted` is deliberately explicit rather than inferred
    # from a missing round: "we have no draft data for this player" and "this player
    # went undrafted" are different facts, and only the second is a fair clue. ─────
    draft_year: int | None = None
    draft_round: int | None = None
    draft_pick: int | None = None    # overall pick
    draft_team: str = ""
    undrafted: bool = False

    # ── Career-shape dimensions ───────────────────────────────────────────────────
    seasons: int | None = None       # real seasons played (not last_year - first_year)
    league: str = ""                 # soccer only, e.g. 'England'
    # Tennis's catalog `team_abbr` is a country code, not a club — it becomes a nationality
    # clue instead of a (meaningless) team list. See whoami_pool.TEAM_SPORTS.
    nationality: str = ""
    # Still playing as of the last ingest. Gates the clues that would otherwise assert a
    # retirement that hasn't happened ("Played a final season in 2026").
    active: bool = False
    # True when this subject's franchises can all be named. False withholds the
    # team-*naming* dimensions while leaving the count ones usable — see
    # whoami_pool.FRANCHISES for why some abbreviations can't be named safely.
    teams_named: bool = True
    # The real number of franchises, which is NOT `len(teams)` when some couldn't be named.
    # Kept separate so "suited up for 5 different franchises" stays true for a player whose
    # clue can only name four of them. None = fall back to `len(teams)`.
    franchise_count: int | None = None

    # ── Production dimensions. `best_season` is {'year': int, 'team': str,
    # 'line': str} — a dict rather than a nested dataclass so `WhoAmIEntry(**row)`
    # still round-trips straight out of JSON. ─────────────────────────────────────
    best_season: dict = field(default_factory=dict)

    # ── Story dimensions (curated only — no provider carries these) ───────────────
    nickname: str = ""
    accolades: list[str] = field(default_factory=list)

    # ── Difficulty. `fame` is the 0-1 percentile of career production within the
    # subject's own (sport, position) cohort, computed by whoami_pool.py; `difficulty`
    # is the tier derived from it, stored rather than recomputed so a pool file is
    # auditable and a hand-tuned override survives a regeneration. ────────────────
    fame: float | None = None
    difficulty: str = ""             # 'easy' | 'medium' | 'hard'; "" = derive from fame
    source: str = "curated"          # 'curated' | 'catalog'
