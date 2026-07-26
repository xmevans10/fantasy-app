"""The committed soccer competition table (`data/soccer_leagues.csv`) as a lookup.

One row per ESPN league slug — `espn_slug, country, display_name, tier, espn_logo_id` — and
the single place the pipeline answers "which nation is `ger.2`?" and "what is Germany's top
flight?". It lives here rather than in `teams.py` because both soccer providers need it and
`teams.py` imports `providers.espn_soccer`; a provider importing `teams` back would cycle.

It replaces `espn_soccer._LEAGUES` (a 38-entry slug -> country dict) and
`transfermarkt_soccer._COMPETITION_COUNTRY`'s country half, which had drifted into two
independent copies of the same fact — the exact shape AGENTS.md §4 warns about. Both now
derive their nation label from this file, so a competition added here is immediately known to
every provider instead of needing three edits.

Stdlib-only and tolerant of a missing file (empty table, never an exception), like
`teams.load_us_colors` — the runtime `load_seasons()` path must never depend on it existing.
"""
from __future__ import annotations

import csv
from functools import lru_cache
from pathlib import Path

CSV_PATH = Path(__file__).resolve().parent / "data" / "soccer_leagues.csv"


@lru_cache(maxsize=1)
def load() -> tuple[dict, ...]:
    """Every competition row, `tier` coerced to int. Cached — the file is committed and
    small, and both providers read it once per row otherwise."""
    if not CSV_PATH.exists():
        return ()
    with CSV_PATH.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["tier"] = int(r["tier"]) if str(r.get("tier", "")).strip() else 1
    return tuple(rows)


def nations_by_slug() -> dict[str, str]:
    """ESPN slug -> nation label ("ger.2" -> "Germany"). Both divisions of a country map to
    the SAME nation on purpose: the nation is the country, and the division is the slug."""
    return {r["espn_slug"]: r["country"] for r in load()}


def nation_for(slug: str) -> str:
    """Nation label for a slug, falling back to the slug itself so an unknown competition
    still produces a stable (if ugly) label rather than an empty string."""
    return nations_by_slug().get(slug, slug)


def tier_for(slug: str) -> int:
    """Division depth; 1 = top flight. Unknown slugs are assumed top-flight, which is the
    conservative guess — it never hides a competition from a tier-1-only default."""
    return next((r["tier"] for r in load() if r["espn_slug"] == slug), 1)


def top_flight_slug(country: str) -> str | None:
    """A nation's tier-1 competition slug ("Germany" -> "ger.1"), or None if unknown."""
    return next((r["espn_slug"] for r in load()
                 if r["country"] == country and r["tier"] == 1), None)


def season_meta(row: dict) -> dict[str, str]:
    """`RawSeason.meta` for one committed soccer CSV row — the nation under "league" and the
    division under "competition", with either column allowed to be absent.

    Both are read defensively because the committed CSVs gained these columns at different
    times and an older file must still load: `soccer_transfermarkt_seasons.csv` was written
    before `league` existed at all (which is why ~75k prod rows carried no nation), and
    `competition` is newer still. When a row knows its competition but not its nation, the
    nation is DERIVED rather than left blank — the competition is the stronger fact, and
    deriving is what keeps the two columns from ever disagreeing.
    """
    meta: dict[str, str] = {}
    competition = (row.get("competition") or "").strip()
    league = (row.get("league") or "").strip()
    if competition:
        meta["competition"] = competition
        league = league or nation_for(competition)
    if league:
        meta["league"] = league
    return meta


def slugs(*, tier: int | None = None) -> list[str]:
    """Known competition slugs, optionally restricted to one tier. `tier=1` is what a
    default full sweep uses — lower divisions are opt-in per league, not swept by default."""
    return sorted(r["espn_slug"] for r in load() if tier is None or r["tier"] == tier)
