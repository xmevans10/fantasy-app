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

SOCCER_LEAGUES_PATH = DATA_DIR / "soccer_leagues.csv"


def load_soccer_leagues() -> list[dict]:
    """The committed soccer competition table: one row per ESPN league slug with its country,
    broadcast display name, tier and crest id. Replaces the two hardcoded 10-entry dicts this
    module used to carry — those could only ever describe a country's TOP flight, because the
    `league` key they were keyed on IS the country label ("Germany"), so a second division had
    nowhere to live. That is why "give me Bundesliga 2" was impossible: not a UI gap, a model
    gap. `tier` + `espn_slug` are the missing middle layer of the FIFA-style
    Nation -> League -> Club hierarchy; the client groups a picker by `country` and orders by
    `tier`. Tolerant of a missing file (empty list, never an exception), like `load_us_colors`."""
    if not SOCCER_LEAGUES_PATH.exists():
        return []
    with SOCCER_LEAGUES_PATH.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["tier"] = int(r["tier"]) if str(r.get("tier", "")).strip() else 1
    return rows


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

    # Every competition the pipeline knows, not just the ones a club sweep has landed yet —
    # identity is cheap and a league row with no clubs is harmless, whereas a club whose league
    # has no row renders a bare text badge (live: the "AUSTRALIA" fallback in Draft & Spin).
    soccer_logo_count = 0
    for entry in load_soccer_leagues():
        logo_id = (entry.get("espn_logo_id") or "").strip()
        logo_url = logos.rehost(
            f"https://a.espncdn.com/i/leaguelogos/soccer/500/{logo_id}.png",
            logos.league_logo_key("soccer", entry["espn_slug"])) if logo_id else None
        if logo_url:
            soccer_logo_count += 1
        rows.append({"sport": "soccer", "league": entry["country"],
                    "display_name": entry["display_name"], "logo_url": logo_url,
                    "country": entry["country"], "tier": entry["tier"],
                    "espn_slug": entry["espn_slug"]})
    # One row per (sport, league) survives the upsert's PK, so a country with several tiers
    # currently collapses to its last-written row — harmless while only tier 1 has club data,
    # and the `espn_slug`/`tier` columns are what a future per-competition key will switch to.
    print(f"[leagues] soccer: {len(rows)} competition(s), {soccer_logo_count} logo(s) rehosted")

    us_league_rows = [("nfl", "NFL", "nfl"), ("nba", "NBA", "nba"), ("baseball", "MLB", "mlb")]
    for sport, display_name, slug in us_league_rows:
        source_url = f"https://a.espncdn.com/i/teamlogos/leagues/500/{slug}.png"
        logo_url = logos.rehost(source_url, logos.league_logo_key(sport, ""))
        # US sports are single-competition: no country grouping, tier 1 by definition.
        rows.append({"sport": sport, "league": "", "display_name": display_name,
                    "logo_url": logo_url, "country": None, "tier": 1, "espn_slug": slug})
    print(f"[leagues] {len(us_league_rows)} US league(s)")

    return rows
