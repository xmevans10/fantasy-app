"""NFL player bio provider — nflverse `players.csv` (one file, all players ever).

Supplies the biographical/contextual fields the niche-theme filters key on (first name,
college, draft round/pick, height, jersey, rookie season, birth year), plus a fallback
`headshot` URL. Joined onto each NFL `RawSeason` by `gsis_id` (collision-free — both files
use the same id).

Stdlib-only; goes through the shared on-disk cache. Bio is near-static, so it's cached
for a month. Values are stored as strings (the `meta` contract); `Filter` coerces numerics.

Headshot coverage note: the per-season `player_stats_season_{year}.csv` files' own
`headshot_url` column is a roster-snapshot field — it's frequently blank for a player's
older/retired seasons even though that player has a current photo. This `players.csv`
registry is nflverse's all-time player index and carries a `headshot` URL for ~97% of
players regardless of season, so `main.merge_nfl_bio` uses it as the fallback.
"""
from __future__ import annotations

import csv
import io

from .http import fetch_text

_URL = "https://github.com/nflverse/nflverse-data/releases/download/players/players.csv"


def _birth_year(birth_date: str) -> str:
    """'1987-01-25' -> '1987'; '' for unknown."""
    return birth_date[:4] if birth_date[:4].isdigit() else ""


def load_bio(*, ttl_hours: float = 24 * 30) -> dict[str, dict[str, str]]:
    """Return `{gsis_id: {bio fields}}`. Only non-empty fields are included, so a missing
    draft is simply an absent `draft_round` (which `Filter('draft_round','exists')` reads).
    Includes a `headshot` key (popped back out by `main.merge_nfl_bio` before the rest of
    the dict is merged onto `meta` — it's a fallback URL, not a filterable bio dimension)."""
    text = fetch_text(_URL, cache_key="nflverse_players.csv", ttl_hours=ttl_hours)
    out: dict[str, dict[str, str]] = {}
    for row in csv.DictReader(io.StringIO(text)):
        gsis = (row.get("gsis_id") or "").strip()
        if not gsis:
            continue
        fields = {
            "first_name": row.get("first_name") or row.get("common_first_name") or "",
            "last_name": row.get("last_name") or "",
            "college": row.get("college_name") or "",
            "college_conference": row.get("college_conference") or "",
            "draft_year": row.get("draft_year") or "",
            "draft_round": row.get("draft_round") or "",
            "draft_pick": row.get("draft_pick") or "",
            "draft_team": row.get("draft_team") or "",
            "height_in": row.get("height") or "",
            "weight_lb": row.get("weight") or "",
            "jersey": row.get("jersey_number") or "",
            "rookie_season": row.get("rookie_season") or "",
            "birth_year": _birth_year(row.get("birth_date") or ""),
            "headshot": row.get("headshot") or "",
        }
        out[gsis] = {k: v for k, v in fields.items() if v not in ("", "0")}
    return out
