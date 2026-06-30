"""Core data structures shared across the ingestion pipeline.

A `RawSeason` is a single real player-season pulled from a provider (nflverse,
balldontlie, or the curated seed). It carries the raw numeric stats keyed by a
stable name; `grade.py` turns those into a 0-100 quality score and `assemble.py`
turns them into the camelCase `content` JSON the Swift Codable models decode.
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
    source: str = "seed"     # provenance: 'nflverse' | 'balldontlie' | 'seed'

    @property
    def player_id(self) -> str:
        """Stable id for this season inside a puzzle, e.g. 'derrick-henry-2020'."""
        return f"{slug(self.name)}-{self.season_year}"


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
