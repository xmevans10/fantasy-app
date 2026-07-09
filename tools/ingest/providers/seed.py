"""Curated seed provider — real, factual player-seasons hand-sourced from public
records (Basketball-Reference for NBA; well-documented record/award-winning
seasons for baseball/soccer/tennis).

Used when a live source is unavailable or (for soccer/tennis) doesn't exist yet, so
the pipeline still produces real (not fictional) content offline. Every row is a real
stat line. NFL needs no seed — nflverse covers it live; baseball's `mlb_stats.py` is
also live, so `load_baseball()` is a fallback, not the primary path.

**Soccer and tennis are seed-only for now** (no live provider) — verified this
session that the assumed sources didn't check out: ESPN's soccer stats endpoint only
ever returned international-duty splits (not club-season stats) for the players
tested, and the assumed tennis data-source repo doesn't exist under that account.
These seed sets are small and hand-curated from well-documented record/award seasons;
broadening them needs a real data source, not more manual rows.

**Re-verified 2026-07-08** (a follow-up pass expanding soccer GK/DF and tennis
depth, prompted by Draft & Spin's soccer DF slot only ever offering one candidate):
the canonical Jeff Sackmann `tennis_atp` GitHub repo (the usual free bulk source for
ATP match-level history) now 404s, and a live GitHub search over 246 repos matching
"tennis_atp" found no maintained mirror — tennis stays seed-only, confirmed still
correct, not just assumed. Soccer GK/DF live-source re-check: API-Football (this
app's only live soccer provider, see `api_football.py`) is confirmed still lacking a
clean-sheets field; FBref has the stat but no API and scraping-hostile ToS;
football-data.org has no player-season stats; Understat is xG-only. The
hand-curated-permanently decision for soccer GK/DF stands. That same 2026-07-08 pass
expanded both CSVs (soccer GK 7→21 rows, DF 1→2, tennis 16→20 including its first
women's rows) — every added row's stats were individually verified against a primary
Wikipedia career-statistics table, not bulk-sourced, which is why the expansion
undershot its original ~40-60/20-30/50-80 target: several strong candidates
(Cannavaro, Maldini, Xavi, Modrić, Graf, Barty) were dropped rather than shipped when
a full real stat line (especially per-defender clean sheets, which Wikipedia rarely
tabulates per-player) couldn't be confirmed. Further DF/tennis depth is a good
candidate for a dedicated pass against a real stats database/API instead of more
manual Wikipedia lookups.
"""
from __future__ import annotations

import csv
from pathlib import Path

from ..models import RawSeason
from .mlb_stats import HEADSHOT_URL

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def _f(row: dict, key: str) -> float:
    raw = row.get(key, "")
    return float(raw) if raw not in ("", None) else 0.0


def load_nba() -> list[RawSeason]:
    path = DATA_DIR / "nba_seed.csv"
    out: list[RawSeason] = []
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            stats = {
                "games": _f(row, "games"),
                "ppg": _f(row, "ppg"),
                "rpg": _f(row, "rpg"),
                "apg": _f(row, "apg"),
                "spg": _f(row, "spg"),
                "bpg": _f(row, "bpg"),
                "fg_pct": _f(row, "fg_pct"),
                "ts_pct": _f(row, "ts_pct"),
            }
            out.append(
                RawSeason(
                    name=row["name"],
                    team_abbr=row["team_abbr"],
                    season_year=int(row["season_year"]),
                    sport="nba",
                    position=row["position"],
                    stats=stats,
                    source="seed",
                )
            )
    return out


def load_baseball() -> list[RawSeason]:
    """Fallback for `mlb_stats.py`. Hitting/pitching rows share one CSV (position
    'H'/'P' selects which stat block is real; the other side's columns are blank).
    `mlb_id` (the real MLB person id, same as `main.MLB_LIVE_TARGETS`) builds a headshot
    via the same image CDN `mlb_stats.py` uses live — no separate image source needed."""
    path = DATA_DIR / "baseball_seed.csv"
    out: list[RawSeason] = []
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            position = row["position"]
            if position == "H":
                stats = {
                    "plate_appearances": _f(row, "plate_appearances"),
                    "at_bats": _f(row, "at_bats"),
                    "hits": _f(row, "hits"),
                    "doubles": _f(row, "doubles"),
                    "triples": _f(row, "triples"),
                    "home_runs": _f(row, "home_runs"),
                    "runs": _f(row, "runs"),
                    "rbi": _f(row, "rbi"),
                    "base_on_balls": _f(row, "base_on_balls"),
                    "stolen_bases": _f(row, "stolen_bases"),
                    "avg": _f(row, "avg"),
                    "obp": _f(row, "obp"),
                    "slg": _f(row, "slg"),
                    "ops": _f(row, "ops"),
                }
            else:
                stats = {
                    "innings_pitched": _f(row, "innings_pitched"),
                    "wins": _f(row, "wins"),
                    "losses": _f(row, "losses"),
                    "saves": _f(row, "saves"),
                    "strike_outs": _f(row, "strike_outs"),
                    "earned_runs": _f(row, "earned_runs"),
                    "era": _f(row, "era"),
                    "whip": _f(row, "whip"),
                }
            mlb_id = row.get("mlb_id", "")
            out.append(
                RawSeason(
                    name=row["name"],
                    team_abbr=row["team_abbr"],
                    season_year=int(row["season_year"]),
                    sport="baseball",
                    position=position,
                    stats=stats,
                    source="seed",
                    headshot=HEADSHOT_URL.format(id=mlb_id) if mlb_id else "",
                )
            )
    return out


def load_soccer() -> list[RawSeason]:
    """Seed-only (no live provider — see module docstring). Hand-curated from
    well-documented Golden Boot/Golden Glove/record seasons. `headshot` is a real
    Wikimedia Commons image URL, resolved once per player against Wikipedia's summary
    API while writing this CSV (not fetched live by this loader — see `models.py`).

    A couple of these rows' seasons (Haaland 2023, Benzema 2022) now also get pulled
    live by providers/api_football.py — kept here anyway (not pruned) because the
    puzzle-generation tests pin specific names/counts against this seed *alone* as the
    no-live-data fallback pool. api_football.merge_with_seed() is responsible for
    deduping the overlap when both are present; see that function's docstring for why
    it compares by last name rather than the full string (api-football's full legal
    name, e.g. "Karim Mostafa Benzema", never matches this CSV's casual one)."""
    path = DATA_DIR / "soccer_seed.csv"
    out: list[RawSeason] = []
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            stats = {
                "appearances": _f(row, "appearances"),
                "goals": _f(row, "goals"),
                "assists": _f(row, "assists"),
                "clean_sheets": _f(row, "clean_sheets"),
            }
            out.append(
                RawSeason(
                    name=row["name"],
                    team_abbr=row["team_abbr"],
                    season_year=int(row["season_year"]),
                    sport="soccer",
                    position=row["position"],
                    stats=stats,
                    source="seed",
                    headshot=row.get("headshot", ""),
                )
            )
    return out


def load_tennis() -> list[RawSeason]:
    """Seed-only (no live provider — see module docstring). `position` is a constant
    'Player' — tennis has no position families. `team_abbr` holds the player's
    country code (real, but standing in for the team-color/team-badge slot the app's
    other sports use; tennis cards fall back to the no-team styling). `headshot` is a
    real Wikimedia Commons image URL, resolved once per player against Wikipedia's
    summary API while writing this CSV (not fetched live by this loader)."""
    path = DATA_DIR / "tennis_seed.csv"
    out: list[RawSeason] = []
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            stats = {
                "matches_won": _f(row, "matches_won"),
                "matches_lost": _f(row, "matches_lost"),
                "titles": _f(row, "titles"),
                "grand_slams": _f(row, "grand_slams"),
            }
            out.append(
                RawSeason(
                    name=row["name"],
                    team_abbr=row["team_abbr"],
                    season_year=int(row["season_year"]),
                    sport="tennis",
                    position="Player",
                    stats=stats,
                    source="seed",
                    headshot=row.get("headshot", ""),
                )
            )
    return out
