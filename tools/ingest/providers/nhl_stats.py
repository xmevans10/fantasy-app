"""NHL full-history player-seasons — the league's own keyless stats API.

Hockey is the deepest-history sport in the catalog: `api.nhle.com/stats/rest/en` serves
complete league-wide season lines back to **1917-18**, the NHL's first season (verified
2026-09-03), which is further back than any other provider here reaches — nflverse starts
at 1999, the MLB sweep at 1955, hoopR at 2002.

Two endpoints, because a goalie and a skater share no stat at all:
  * `skater/summary` — goals/assists/points/+-/PIM/shots/TOI, `positionCode` C|L|R|D
  * `goalie/summary` — W/L/GAA/SV%/shutouts/saves, no position field (all are "G")

## Three things this API will do to you if you let it

1. **`limit` is capped at 100** regardless of what you ask for (500 and 1000 both return
   100), so every season is a paginated sweep — ~9 pages of skaters, ~1 of goalies.
2. **Old seasons carry real nulls, not zeros.** Stats the league did not record yet come back
   as `None` and are OMITTED from `stats` rather than written as 0 — a fabricated zero would
   grade a 1955 defenceman as if he had been on the ice for a hundred goals against, and
   §4's whole premise is that the grade is defensible against a reference site.

   Measured against the committed sweep (not quoted from the rulebook, which disagrees):
   `plus_minus` and `shots` both first appear in **1959-60**, `shooting_pct` in 1960-61, and
   `toi_per_game` in 1997-98. An earlier draft of this docstring claimed plus-minus started in
   1967-68 — the year the NHL made it an official statistic — but the API back-fills it to
   1959-60, and a consumer era-scoping a filter off the wrong year silently excludes eight
   real seasons. Trust the data here, not the rule change.
3. **A wrong team in a headshot URL silently yields the silo placeholder.** Mugs are keyed
   `/mugs/nhl/{seasonId}/{TEAM}/{playerId}.png` and asking for a team the player did not
   play for that season 302s to `default-skater.png` (md5 7ba18be8…, 11,875 bytes) with no
   error. `_resolve_mug` disables redirect-following and treats any non-200 as "no photo",
   which is the M16 contract: no photo, no row.

Coverage of those mugs is the pleasant surprise — spot-checked at the top of 1925-26,
1955-56, 1970-71, 1985-86, 2000-01 and 2023-24, every scoring leader has a real portrait,
so the no-photo rule costs almost nothing here.

Same split as `tennis_atp`/`hoopr_nba`: a network-heavy `refresh()` writing a committed CSV,
and a stdlib-only `load_seasons()` on the daily path. The current season is pulled live on
top of the CSV by `load_current_season()` (one season's worth of pages, ~10 requests) so an
in-progress year is fresh without re-sweeping a century every night.

Run:  python -m tools.ingest.providers.nhl_stats [--from 1917 --to 2026]
"""
from __future__ import annotations

import argparse
import csv
import datetime as _dt
import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from ..models import RawSeason
from .http import CACHE_DIR, fetch_json

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "nhl_seasons.csv"

_BASE = "https://api.nhle.com/stats/rest/en"
_MUG = "https://assets.nhle.com/mugs/nhl/{season}/{team}/{pid}.png"
_PAGE = 100          # hard server-side cap; asking for more still returns 100

FIRST_SEASON = 1917  # 1917-18, the NHL's first

# Games floors — low enough to keep a real short season (injury, call-up, a traded
# player's partial year) and high enough that a one-game cup of coffee doesn't become a
# card. Themes apply their own `min_stats` on top; this only bounds the committed CSV.
MIN_GAMES_SKATER = 20
MIN_GAMES_GOALIE = 10

CSV_FIELDS = [
    "name", "team_abbr", "teams_all", "season_year", "position", "headshot",
    # NHL `playerId` — the person key. Already fetched (it resolves the portrait below);
    # kept in the CSV so two same-name skaters stay two people downstream.
    "player_id",
    # skater
    "goals", "assists", "points", "plus_minus", "penalty_minutes", "shots",
    "shooting_pct", "points_per_game", "pp_points", "sh_points",
    "game_winning_goals", "toi_per_game",
    # goalie
    "wins", "losses", "ot_losses", "gaa", "save_pct", "shutouts", "saves",
    "shots_against", "goals_against", "games_started",
    # shared
    "games",
]

# API field -> our stat key. Values that come back None are dropped (see module docstring).
_SKATER_MAP = {
    "goals": "goals", "assists": "assists", "points": "points",
    "plusMinus": "plus_minus", "penaltyMinutes": "penalty_minutes", "shots": "shots",
    "shootingPct": "shooting_pct", "pointsPerGame": "points_per_game",
    "ppPoints": "pp_points", "shPoints": "sh_points",
    "gameWinningGoals": "game_winning_goals", "gamesPlayed": "games",
    "timeOnIcePerGame": "toi_per_game",
}
_GOALIE_MAP = {
    "wins": "wins", "losses": "losses", "otLosses": "ot_losses",
    "goalsAgainstAverage": "gaa", "savePct": "save_pct", "shutouts": "shutouts",
    "saves": "saves", "shotsAgainst": "shots_against", "goalsAgainst": "goals_against",
    "gamesPlayed": "games", "gamesStarted": "games_started",
}


def current_season_start() -> int:
    """The start year of the season now in progress. An NHL season spans two calendar
    years and opens in October, so anything before July belongs to the season that started
    the previous year. Computed from today rather than hardcoded, the same treatment
    `main.py` gives the nflverse year range, so this never goes stale."""
    today = _dt.date.today()
    return today.year if today.month >= 7 else today.year - 1


def season_id(year: int) -> str:
    """1985 -> '19851986'."""
    return f"{year}{year + 1}"


def _fetch_page(kind: str, season: str, start: int) -> dict:
    q = urllib.parse.quote(f"seasonId={season} and gameTypeId=2")
    url = f"{_BASE}/{kind}/summary?limit={_PAGE}&start={start}&cayenneExp={q}"
    return fetch_json(url, cache_key=f"nhl_{kind}_{season}_{start}.json",
                      ttl_hours=24 * 365)


def _fetch_season(kind: str, season: str) -> list[dict]:
    """Every row for one season, paged through the API's 100-row ceiling."""
    out: list[dict] = []
    start = 0
    while True:
        page = _fetch_page(kind, season, start)
        rows = page.get("data") or []
        out.extend(rows)
        total = int(page.get("total") or 0)
        start += _PAGE
        if start >= total or not rows:
            return out


def _stats(row: dict, mapping: dict[str, str]) -> dict[str, float]:
    """Map an API row onto our stat keys, dropping every null.

    Dropping rather than defaulting is the whole point: `plus_minus` absent means the stat
    did not exist that season, which is a different claim from `plus_minus == 0`."""
    stats: dict[str, float] = {}
    for api_key, our_key in mapping.items():
        value = row.get(api_key)
        if value is None:
            continue
        stats[our_key] = float(value)
    return stats


_MUG_LEDGER = CACHE_DIR / "nhl_mugs.json"


def _load_mug_ledger() -> dict[str, str]:
    """Previously-resolved portraits, `{player_id: url or ""}`.

    Resolution is one live HTTP call per player with no HTTP-level cache behind it (the CDN
    answers with an image, not JSON, so `fetch_json` cannot hold it), which made a re-sweep
    cost 6,218 requests even when every stat page was served from disk. A negative result is
    cached too — "this player has no portrait" is just as expensive to rediscover.
    """
    if not _MUG_LEDGER.exists():
        return {}
    try:
        return json.loads(_MUG_LEDGER.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _save_mug_ledger(ledger: dict[str, str]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    _MUG_LEDGER.write_text(json.dumps(ledger), encoding="utf-8")


def _resolve_mug(pid: int, season: str, teams: list[str]) -> str:
    """A real portrait URL for this player, or "" if the CDN only has the silo.

    Redirects are deliberately NOT followed: the CDN answers an unknown (season, team,
    player) triple with a 302 to `default-skater.png` rather than a 404, so following it
    would hand back a placeholder that looks like a successful fetch. Each team the player
    dressed for that season is tried, because a mid-season trade means only one of them is
    the key the CDN actually has.
    """
    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):  # noqa: ANN002, ANN003
            return None

    opener = urllib.request.build_opener(_NoRedirect)
    for team in teams:
        url = _MUG.format(season=season, team=team, pid=pid)
        req = urllib.request.Request(url, headers={"User-Agent": "balliq-ingest/1.0"})
        try:
            with opener.open(req, timeout=20) as resp:
                if resp.status == 200:
                    return url
        except (urllib.error.HTTPError, urllib.error.URLError, OSError):
            continue
    return ""


def _rows_for_season(year: int) -> list[dict]:
    """Both endpoints for one season, as CSV-shaped dicts (headshots not yet resolved)."""
    season = season_id(year)
    out: list[dict] = []
    for kind, mapping, floor in (("skater", _SKATER_MAP, MIN_GAMES_SKATER),
                                 ("goalie", _GOALIE_MAP, MIN_GAMES_GOALIE)):
        for api_row in _fetch_season(kind, season):
            stats = _stats(api_row, mapping)
            if stats.get("games", 0) < floor:
                continue
            teams = [t for t in (api_row.get("teamAbbrevs") or "").split(",") if t]
            if not teams:
                continue
            name = api_row.get("skaterFullName") or api_row.get("goalieFullName") or ""
            if not name:
                continue
            # TOI arrives in seconds per game; every display bound and the card label are
            # in minutes, which is the only unit a hockey fan reads it in.
            if "toi_per_game" in stats:
                stats["toi_per_game"] = round(stats["toi_per_game"] / 60.0, 2)
            row = {
                "name": name,
                "team_abbr": teams[0],
                "teams_all": "|".join(teams),
                "season_year": year,
                # Goalie rows carry no `positionCode` — every row from that endpoint is a
                # goalie by construction.
                "position": "G" if kind == "goalie" else (api_row.get("positionCode") or ""),
                "headshot": "",
                "_pid": api_row.get("playerId"),
            }
            row.update({k: stats.get(k, "") for k in CSV_FIELDS
                        if k not in ("name", "team_abbr", "teams_all", "season_year",
                                     "position", "headshot")})
            if not row["position"]:
                continue
            out.append(row)
    return out


def refresh(year_from: int = FIRST_SEASON, year_to: int | None = None) -> None:
    """Sweep every finished season in range and rewrite the committed CSV.

    The season `current_season_start()` names is never committed: it is either not yet
    started or in progress, and a part-season would sit on a Keep4 board beside complete
    ones as though a 30-game year were a real one. `load_current_season()` is the explicit,
    opt-in way to read it. (Same call `f1_ergast` makes via `_season_is_complete`, and
    `tennis_wta` makes by excluding its partial trailing year.)"""
    year_to = current_season_start() - 1 if year_to is None else year_to
    rows: list[dict] = []
    for year in range(year_from, year_to + 1):
        try:
            season_rows = _rows_for_season(year)
        except Exception as err:  # noqa: BLE001 — one bad season shouldn't sink the sweep
            print(f"[nhl] {year}: skipped ({err})")
            continue
        rows.extend(season_rows)
        print(f"[nhl] {year}-{str(year + 1)[2:]}: {len(season_rows)} player-seasons")

    # One mug lookup per PLAYER, not per player-season: the CDN serves the same portrait
    # for every season of a career (verified — Gretzky's 1979-80 EDM and 1998-99 NYR mugs
    # are byte-identical), so per-season lookups would be ~10x the requests for the same
    # answer. Keyed by the player's most recent season, which is the one most likely to
    # have a portrait on file.
    latest: dict[int, dict] = {}
    for row in rows:
        pid = row["_pid"]
        if pid is None:
            continue
        if pid not in latest or row["season_year"] > latest[pid]["season_year"]:
            latest[pid] = row
    ledger = _load_mug_ledger()
    todo = [pid for pid in latest if str(pid) not in ledger]
    print(f"[nhl] resolving portraits for {len(latest)} players "
          f"({len(ledger)} cached, {len(todo)} to fetch) …")
    for pid in todo:
        row = latest[pid]
        ledger[str(pid)] = _resolve_mug(pid, season_id(row["season_year"]),
                                        row["teams_all"].split("|"))
    if todo:
        _save_mug_ledger(ledger)
    mugs = {pid: ledger.get(str(pid), "") for pid in latest}
    matched = sum(1 for v in mugs.values() if v)
    print(f"[nhl] {matched}/{len(latest)} players have a real portrait")

    # M16 contract: no photo, no row.
    final = []
    for row in rows:
        pid_of = row["_pid"]
        shot = mugs.get(pid_of, "")
        if not shot:
            continue
        row = {k: v for k, v in row.items() if k != "_pid"}
        row["player_id"] = pid_of
        row["headshot"] = shot
        final.append(row)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(final)
    print(f"[nhl] wrote {len(final)} player-seasons → {CSV_PATH}")


def _to_raw(row: dict, source: str) -> RawSeason:
    stats = {}
    for key in CSV_FIELDS:
        if key in ("name", "team_abbr", "teams_all", "season_year", "position", "headshot"):
            continue
        raw = row.get(key, "")
        if raw == "" or raw is None:
            continue
        stats[key] = float(raw)
    meta = {}
    if (teams := row.get("teams_all", "")) and "|" in teams:
        # Kept so Journeyman can reconstruct a mid-season trade as two stints instead of
        # silently crediting the whole year to whichever club came first alphabetically.
        meta["teams_all"] = teams
    return RawSeason(
        name=row["name"],
        team_abbr=row["team_abbr"],
        season_year=int(row["season_year"]),
        sport="hockey",
        position=row["position"],
        stats=stats,
        source=source,
        headshot=row.get("headshot", ""),
        # `.get` so a CSV written before this column existed still loads; those rows fall
        # back to a name key until the next `refresh()`.
        person_id=str(row.get("player_id") or ""),
        meta=meta,
    )


def load_seasons() -> list[RawSeason]:
    """Historical NHL player-seasons from the committed CSV (stdlib-only; empty until the
    one-time `refresh()` has been run)."""
    if not CSV_PATH.exists():
        return []
    with CSV_PATH.open(encoding="utf-8") as f:
        return [_to_raw(row, "nhl_stats") for row in csv.DictReader(f)]


def load_current_season() -> list[RawSeason]:
    """Live pull of the season now in progress, to layer over the committed CSV.

    ~10 requests, which is why this can run on the daily path while a full sweep cannot.
    Portraits are resolved here too, so an in-progress season obeys the same no-photo-no-row
    rule as the historical file."""
    year = current_season_start()
    try:
        rows = _rows_for_season(year)
    except Exception as err:  # noqa: BLE001 — a live-pull failure must not sink the run
        print(f"[nhl] current season {year}: skipped ({err})")
        return []
    out: list[RawSeason] = []
    for row in rows:
        pid = row.pop("_pid", None)
        if pid is None:
            continue
        shot = _resolve_mug(pid, season_id(year), row["teams_all"].split("|"))
        if not shot:
            continue
        row["headshot"] = shot
        out.append(_to_raw(row, "nhl_stats_live"))
    print(f"[nhl] current season {year}: {len(out)} live player-seasons")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed NHL season sweep")
    ap.add_argument("--from", dest="year_from", type=int, default=FIRST_SEASON)
    ap.add_argument("--to", dest="year_to", type=int, default=None)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
