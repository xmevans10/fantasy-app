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
    # Career-grain aggregate (see career.py) — one row per (sport, position, player) summing
    # every real season the pipeline pulled. Mutually exclusive with `week` (a career row is
    # never a single game); `season_year` holds the player's LAST season for sort/recency
    # purposes, with the full span in `meta["first_year"]`/`meta["last_year"]`.
    career: bool = False
    # Mutable bag of biographical/contextual fields for niche filters (first_name, college,
    # draft_round, draft_pick, height_in, age, jersey, birth_state, rookie_year, gsis_id …).
    # `frozen=True` only blocks rebinding the attribute, not mutating this dict — providers
    # and the bio join populate it in place.
    meta: dict[str, str] = field(default_factory=dict)

    @property
    def player_id(self) -> str:
        """Stable id for this entity inside a puzzle, e.g. 'derrick-henry-2020' (season),
        'derrick-henry-2020-wk12' (single game), or 'derrick-henry-career' (career aggregate)
        so none of the three grains ever collide."""
        if self.career:
            return f"{slug(self.name)}-career"
        base = f"{slug(self.name)}-{self.season_year}"
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
    """A curated, factual basis for a Who Am I? puzzle (see whoami_facts.json).

    Clue *text* is generated from these structured fields in assemble.py, so the
    output is data-derived rather than hand-written prose.
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
