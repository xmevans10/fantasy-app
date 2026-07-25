"""Builds `teams` and `leagues` Supabase rows — data-driven club/league identity (logos
rehosted to Storage, real colors, full names) for every sport BallIQ carries clubs for.

Soccer identity comes from `providers.espn_soccer.load_team_identity()` — captured for
free from the same match-summary payload that provider's own player sweep already
downloads (espn_id/logo/colors/full name straight off ESPN's `roster.team` object; see
that module's `_build_team_identity`). NFL/NBA/MLB have no single live source with
authoritative crest+color for all three, so their colors come from the committed
`data/us_team_colors.csv` seed (mirrors `BallIQ/DesignSystem/TeamColors.swift`'s tables
exactly, so this ingest becomes the single source of truth going forward — the Swift
tables stay as an offline fallback, untouched by this module) and their logo is
hotlinked-then-rehosted from ESPN's public team-logo CDN (same "no licensed asset
scraping beyond a stable, keyless, already-trusted-elsewhere-in-this-pipeline CDN"
posture `espn_nba.py`/`espn_soccer.py` already rely on). Tennis has no clubs — skipped.

Both builders are pure aside from `logos.rehost` calls (itself trivially mockable, see
`test_teams.py`), so this stays unit-testable with no network and no pandas — same
discipline as every other provider in this pipeline.
"""
from __future__ import annotations

import csv
from pathlib import Path

from . import logos
from .providers import espn_soccer

DATA_DIR = Path(__file__).resolve().parent / "data"
US_COLORS_PATH = DATA_DIR / "us_team_colors.csv"

US_SPORTS = ("nfl", "nba", "baseball")

# Pipeline-wide sport name -> ESPN's team-logo CDN path segment. `baseball` is this
# pipeline's sport name throughout (see models.py/main.py); ESPN's own CDN slug for it is
# `mlb`, not `baseball` — kept as an explicit mapping rather than a guess.
_ESPN_LOGO_SLUG = {"nfl": "nfl", "nba": "nba", "baseball": "mlb"}

# Mirrors `BallIQ/Models/DraftSpin.swift`'s `majorSoccerLeagues` value -> display-name
# pairs. Any country/league label this dict doesn't cover (most of the ~38 ESPN sweeps)
# falls back to the raw label itself as its display name.
_SOCCER_LEAGUE_DISPLAY_NAMES: dict[str, str] = {
    "England": "Premier League", "Spain": "La Liga", "Germany": "Bundesliga",
    "Italy": "Serie A", "France": "Ligue 1", "USA (MLS)": "MLS",
    "Netherlands": "Eredivisie", "Portugal": "Primeira Liga",
    "Brazil": "Brasileirão", "Mexico": "Liga MX",
}


def load_us_colors() -> list[dict]:
    """Stdlib-only read of the committed NFL/NBA/MLB color seed; tolerant of a missing
    file (empty list, never an exception)."""
    if not US_COLORS_PATH.exists():
        return []
    with US_COLORS_PATH.open(encoding="utf-8") as f:
        return list(csv.DictReader(f))


def build_teams() -> list[dict]:
    """One `teams` row per (sport, team_abbr, league) — the table's own PK, so a row here
    maps 1:1 to a stored row. `logo_url` is null (not omitted) when `logos.rehost` can't
    resolve a source, matching the client's null-safe abbr/color fallback rendering."""
    rows: list[dict] = []

    soccer_identity = espn_soccer.load_team_identity()
    soccer_logo_count = 0
    for entry in soccer_identity:
        logo_url = logos.rehost(entry.get("logo_url") or None,
                                logos.logo_key("soccer", entry["league"], entry["team_abbr"]))
        if logo_url:
            soccer_logo_count += 1
        rows.append({
            "sport": "soccer",
            "team_abbr": entry["team_abbr"],
            "league": entry["league"],
            "full_name": entry.get("full_name") or "",
            "logo_url": logo_url,
            "primary_color": entry.get("primary_color") or None,
            "secondary_color": entry.get("secondary_color") or None,
            "espn_id": entry.get("espn_id") or None,
        })
    print(f"[teams] soccer: {len(soccer_identity)} clubs, {soccer_logo_count} logo(s) rehosted")

    us_colors = load_us_colors()
    for sport in US_SPORTS:
        sport_rows = [r for r in us_colors if r["sport"] == sport]
        slug = _ESPN_LOGO_SLUG[sport]
        logo_count = 0
        for r in sport_rows:
            abbr = r["team_abbr"]
            source_url = f"https://a.espncdn.com/i/teamlogos/{slug}/500/{abbr.lower()}.png"
            logo_url = logos.rehost(source_url, logos.logo_key(sport, "", abbr))
            if logo_url:
                logo_count += 1
            rows.append({
                "sport": sport,
                "team_abbr": abbr,
                "league": "",
                "full_name": r.get("full_name") or "",
                "logo_url": logo_url,
                "primary_color": r.get("primary_color") or None,
                "secondary_color": r.get("secondary_color") or None,
                "espn_id": None,
            })
        print(f"[teams] {sport}: {len(sport_rows)} teams, {logo_count} logo(s) rehosted")

    # Tennis: no clubs — no rows.
    return rows


def build_leagues() -> list[dict]:
    """One `leagues` row per (sport, league) — the distinct soccer country/competition
    labels the identity sweep discovered, plus a fixed placeholder row for each of the
    single-league US sports (league='' matches `teams`' own league column for them)."""
    rows: list[dict] = []

    soccer_leagues = sorted({entry["league"] for entry in espn_soccer.load_team_identity()})
    for league in soccer_leagues:
        display_name = _SOCCER_LEAGUE_DISPLAY_NAMES.get(league, league)
        rows.append({"sport": "soccer", "league": league,
                    "display_name": display_name, "logo_url": None})
    print(f"[leagues] soccer: {len(soccer_leagues)} league(s)")

    us_league_rows = [("nfl", "NFL", "nfl"), ("nba", "NBA", "nba"), ("baseball", "MLB", "mlb")]
    for sport, display_name, slug in us_league_rows:
        source_url = f"https://a.espncdn.com/i/teamlogos/leagues/500/{slug}.png"
        logo_url = logos.rehost(source_url, logos.league_logo_key(sport, ""))
        rows.append({"sport": sport, "league": "", "display_name": display_name,
                    "logo_url": logo_url})
    print(f"[leagues] {len(us_league_rows)} US league(s)")

    return rows
