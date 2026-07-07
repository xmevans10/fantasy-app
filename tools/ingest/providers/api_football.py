"""Soccer live provider — API-Football (api-sports.io), keyed via `API_FOOTBALL_KEY`.

Unlike NBA/MLB's two-phase "discover ids, then fetch full careers" design, this
provider's discovery *is* the stats fetch: `/players/top{scorers,assists}` returns each
league-season's top ~20 attackers with full season stat lines embedded in one request —
no separate per-player call needed. The curated league x season x kind matrix below
(~30 leagues/competitions x 4 seasons x 2 kinds) runs to a few hundred combos, well past
one day's 100-request budget — `sweep()` is deliberately incremental: each run covers up
to `max_requests` new combos (ordered by the priority the leagues are listed in) and
persists progress, so a several-day backfill via repeated scheduled runs is expected, not
a bug. Once the whole matrix is covered, re-runs are nearly free (already-covered combos
are skipped) until the free tier's allowed season window rolls forward next year.

Only covers attacking output (goals/assists/appearances) for FW/MF players — verified
this session that API-Football's player-statistics object has no clean-sheets field, so
there's no way to populate the `soccer-defenders` theme from this source. Defenders/
keepers stay on the hand-curated seed (see providers/seed.py) permanently, not just
until "a future pass."

Free tier also gates *which* seasons are queryable (confirmed live: asking for a decade-
old season returns `{"errors": {"plan": "Free plans do not have access to this season,
try from 2022 to 2024"}}`, HTTP 200 — a soft error, not a 4xx) — the allowed window
rolls forward over time, so `_season_window` is relative to today and out-of-window
combos are just skipped, mirroring nflverse's "skip on 404" handling elsewhere.

Run:  python -m tools.ingest.providers.api_football  [--max-requests 80]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

from ..models import RawSeason

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
POOL_PATH = DATA_DIR / "soccer_live.json"
PROGRESS_PATH = DATA_DIR / "api_football_progress.json"

_BASE = "https://v3.football.api-sports.io"

# Top leagues/competitions/countries, ordered by priority — the sweep works through
# this list in order and free-tier requests are scarce enough that anything near the
# bottom may take several days of runs to reach. Ids verified live against api-football's
# own /leagues catalog (not guessed).
LEAGUES = [
    # Big-5 Europe first.
    (39, "Premier League"), (140, "La Liga"), (78, "Bundesliga"), (135, "Serie A"),
    (61, "Ligue 1"),
    # Marquee international club competitions.
    (2, "UEFA Champions League"), (3, "UEFA Europa League"), (848, "UEFA Europa Conference League"),
    # Rest of top-flight Europe.
    (94, "Primeira Liga"), (88, "Eredivisie"), (144, "Jupiler Pro League"),
    (203, "Super Lig"), (179, "Premiership (Scotland)"), (40, "Championship (England)"),
    (207, "Super League (Switzerland)"), (218, "Bundesliga (Austria)"), (197, "Super League 1 (Greece)"),
    # Americas.
    (71, "Serie A (Brazil)"), (262, "Liga MX"), (253, "MLS"), (1032, "Copa de la Liga Profesional (Argentina)"),
    (13, "CONMEBOL Libertadores"), (11, "CONMEBOL Sudamericana"),
    # Asia / Middle East.
    (307, "Pro League (Saudi Arabia)"), (98, "J1 League (Japan)"), (169, "Super League (China)"),
    # Africa.
    (233, "Premier League (Egypt)"),
    # International tournaments — great puzzle fodder (Golden Boot winners etc).
    (1, "World Cup"), (4, "Euro Championship"), (9, "Copa America"), (6, "Africa Cup of Nations"),
    (22, "CONCACAF Gold Cup"),
]
KINDS = ["scorers", "assists"]

_POSITION_MAP = {"Attacker": "FW", "Midfielder": "MF", "Defender": "DF", "Goalkeeper": "GK"}


def _season_window(today: dt.date | None = None) -> list[int]:
    """Recent seasons to try — the free tier's actual allowed window shifts forward
    every year, so this is deliberately wider than what's likely allowed; anything
    outside the real window just comes back as a skippable soft error."""
    year = (today or dt.date.today()).year
    return list(range(year - 4, year))


def _require_key() -> str:
    import os
    key = os.getenv("API_FOOTBALL_KEY")
    if not key:
        raise RuntimeError("API_FOOTBALL_KEY must be set to sweep api-football")
    return key


def _short_code(team_name: str) -> str:
    """No abbreviation field on this endpoint's team object — derive a display-only
    short code (initials for multi-word names, else first 3 letters)."""
    words = [w for w in team_name.split() if w.isalpha()]
    if len(words) >= 2:
        return "".join(w[0] for w in words[:3]).upper()
    return team_name[:3].upper()


def _get(url: str, headers: dict[str, str]) -> tuple[dict, dict]:
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode("utf-8"))
        return body, dict(resp.headers)


def fetch_leaderboard(league_id: int, season: int, kind: str, key: str) -> list[RawSeason]:
    """One request → up to ~20 player-seasons with full stats embedded, or [] if this
    league/season/kind combo isn't in the free tier's current allowed window."""
    url = f"{_BASE}/players/top{kind}?league={league_id}&season={season}"
    body, _ = _get(url, {"x-apisports-key": key})
    if body.get("errors"):
        return []
    out: list[RawSeason] = []
    for entry in body.get("response", []):
        player = entry["player"]
        stats = (entry.get("statistics") or [None])[0]
        if not stats:
            continue
        games = stats.get("games") or {}
        goals = stats.get("goals") or {}
        appearances = games.get("appearences")  # sic — api-football's own field name
        if not appearances:
            continue
        position = _POSITION_MAP.get(games.get("position", ""), "FW")
        if position not in ("FW", "MF"):
            # A defender/keeper occasionally tops an assists chart (e.g. a set-piece
            # right-back) — but this source has no clean-sheets field, so a DF/GK row
            # from here would only ever compete in soccer-defenders on goals/assists
            # alone, ranking ahead of genuine clean-sheet specialists with 0 in the
            # one stat that theme is actually about. Drop rather than mis-rank.
            continue
        team_name = (stats.get("team") or {}).get("name", "")
        # player["name"] is initial-abbreviated ("E. Haaland") — firstname/lastname give
        # the actual full name.
        full_name = f"{player.get('firstname') or ''} {player.get('lastname') or ''}".strip()
        out.append(RawSeason(
            name=full_name or player["name"],
            team_abbr=_short_code(team_name),
            season_year=season,
            sport="soccer",
            position=position,
            stats={
                "appearances": float(appearances),
                "goals": float(goals.get("total") or 0),
                "assists": float(goals.get("assists") or 0),
            },
            source="api-football",
            headshot=player.get("photo", ""),
        ))
    return out


def _dedup_key(row: RawSeason) -> tuple[str, int, str]:
    return (row.name, row.season_year, row.team_abbr)


def load_pool() -> list[RawSeason]:
    """Read-only: the pipeline's regular runs load the committed sweep results, they
    never hit the network themselves (same split as mlb_pool/espn_nba_pool)."""
    if not POOL_PATH.exists():
        return []
    rows = json.loads(POOL_PATH.read_text())
    return [RawSeason(**r) for r in rows]


def merge_with_seed(live: list[RawSeason], seed_rows: list[RawSeason]) -> list[RawSeason]:
    """Live data supersedes a seed row covering the exact same player-season (a few of
    the hand-curated attacker rows land inside the live window); every seed row live
    can't produce at all (defenders/keepers — no clean-sheets source) always survives.

    Compares by (last name, season_year), not the full name or `_dedup_key` — seed's
    team_abbr is a hand-typed 3-letter club code ("MCI") vs live's name-derived one
    ("MC"), and api-football's firstname/lastname is the full legal name ("Karim Mostafa
    Benzema") vs this CSV's casual one ("Karim Benzema"); comparing either verbatim would
    never match, leaving the stale seed row to silently survive as a near-duplicate.
    Last name + season is a good enough key for this small, globally-recognizable seed
    set (false-collision risk would need an unrelated live attacker sharing a surname in
    the exact same season, which the current seed names don't run into)."""
    live_keys = {(r.name.split()[-1], r.season_year) for r in live}
    kept_seed = [r for r in seed_rows if (r.name.split()[-1], r.season_year) not in live_keys]
    return live + kept_seed


def _load_progress() -> set[str]:
    if not PROGRESS_PATH.exists():
        return set()
    return set(json.loads(PROGRESS_PATH.read_text()))


def sweep(max_requests: int = 95, *, sleep_seconds: float = 6.5) -> list[RawSeason]:
    """Fetch every not-yet-covered (league, season, kind) combo, up to `max_requests`
    calls, sleeping between calls to stay under the free tier's 10 req/min. Merges into
    the committed pool file and returns the full accumulated set."""
    key = _require_key()
    progress = _load_progress()
    accumulated = {_dedup_key(r): r for r in load_pool()}

    combos = [(lid, season, kind)
              for lid, _ in LEAGUES
              for season in _season_window()
              for kind in KINDS]
    todo = [c for c in combos if f"{c[0]}:{c[1]}:{c[2]}" not in progress]

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    def _persist() -> None:
        # Every request costs scarce daily quota — save after each one, not just at the
        # end, so a crash/interrupt mid-sweep doesn't throw away requests already spent.
        POOL_PATH.write_text(json.dumps([r.__dict__ for r in accumulated.values()], indent=2))
        PROGRESS_PATH.write_text(json.dumps(sorted(progress), indent=2))

    made = 0
    for league_id, season, kind in todo:
        if made >= max_requests:
            break
        combo_key = f"{league_id}:{season}:{kind}"
        try:
            rows = fetch_leaderboard(league_id, season, kind, key)
        except urllib.error.HTTPError as err:
            if err.code == 429:
                print(f"[api-football] rate-limited, stopping sweep early ({made} requests made)")
                break
            print(f"[api-football] {combo_key} failed ({err.code}), skipping")
            rows = []
        for row in rows:
            accumulated[_dedup_key(row)] = row
        progress.add(combo_key)
        made += 1
        _persist()
        if made < len(todo) and made < max_requests:
            time.sleep(sleep_seconds)

    result = list(accumulated.values())
    print(f"[api-football] {made} requests this run, {len(progress)}/{len(combos)} combos "
          f"covered, {len(result)} player-seasons in pool")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-requests", type=int, default=95)
    args = parser.parse_args()
    sweep(max_requests=args.max_requests)
