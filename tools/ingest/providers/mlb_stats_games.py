"""MLB single-game provider — real per-game logs from the public MLB Stats API
(`stats=gameLog`), one row per player-per-game, mirroring `nfl_nflverse_games.py`'s
single-game shape (RawSeason with `week`/`opponent` set so the rest of the pipeline
treats it as game grain). Reuses `mlb_stats.py`'s team/headshot lookups and numeric
parsers rather than duplicating them.

Bounded to a curated marquee player list (`main.MLB_LIVE_TARGETS`), not the full
~7,800-player pool `mlb_stats.py` pulls season data for — `stats=gameLog` needs one API
call PER PLAYER PER SEASON (no `yearByYear` equivalent for game logs), so pulling the
full season pool's history would be tens of thousands of requests. Verified live this
session against Aaron Judge (id 592450, 2022): 157 hitting-game rows, real box-score
fields (`hits`, `homeRuns`, `rbi`, ...).
"""
from __future__ import annotations

import datetime as dt
import time

from ..models import RawSeason
from .http import fetch_json, is_cached
from .mlb_stats import HEADSHOT_URL, TEAM_ABBR, _num, _parse_avg, _parse_innings_pitched

_GAMELOG = ("https://statsapi.mlb.com/api/v1/people/{id}/stats"
            "?stats=gameLog&group={group}&season={year}")

_RATE_DELAY = 0.2
# A past season's game log never changes; cache generously like mlb_stats.py's career pull.
_TTL_HOURS = 24.0 * 30


def _game_date_label(iso: str) -> str:
    """'2022-04-08' -> 'Apr 8' for the card subtitle (assemble.py's `content["gameDate"]`,
    PlayerSeason.swift's `subtitle`) — pre-formatted here so Swift needs no date parsing."""
    try:
        d = dt.date.fromisoformat(iso)
    except ValueError:
        return iso
    return f"{d.strftime('%b')} {d.day}"


def _opponent_abbr(split: dict) -> str:
    opp_id = (split.get("opponent") or {}).get("id")
    return TEAM_ABBR.get(opp_id, "")


def _hitting_game(name: str, split: dict, headshot: str, index: int) -> RawSeason | None:
    stat = split.get("stat", {})
    team_id = (split.get("team") or {}).get("id")
    year = split.get("season")
    if not year or team_id not in TEAM_ABBR:
        return None
    plate_appearances = _num(stat, "plateAppearances")
    if plate_appearances <= 0:
        return None
    return RawSeason(
        name=name,
        team_abbr=TEAM_ABBR[team_id],
        season_year=int(year),
        sport="baseball",
        position="H",
        stats={
            "plate_appearances": plate_appearances,
            "at_bats": _num(stat, "atBats"),
            "hits": _num(stat, "hits"),
            "doubles": _num(stat, "doubles"),
            "triples": _num(stat, "triples"),
            "home_runs": _num(stat, "homeRuns"),
            "runs": _num(stat, "runs"),
            "rbi": _num(stat, "rbi"),
            "base_on_balls": _num(stat, "baseOnBalls"),
            "stolen_bases": _num(stat, "stolenBases"),
        },
        source="mlb_stats_games",
        headshot=headshot,
        week=index,
        opponent=_opponent_abbr(split),
        game_date=_game_date_label(split.get("date") or ""),
    )


def _pitching_game(name: str, split: dict, headshot: str, index: int) -> RawSeason | None:
    stat = split.get("stat", {})
    team_id = (split.get("team") or {}).get("id")
    year = split.get("season")
    if not year or team_id not in TEAM_ABBR:
        return None
    innings_pitched = _parse_innings_pitched(stat.get("inningsPitched"))
    if innings_pitched <= 0:
        return None
    return RawSeason(
        name=name,
        team_abbr=TEAM_ABBR[team_id],
        season_year=int(year),
        sport="baseball",
        position="P",
        stats={
            "innings_pitched": innings_pitched,
            "wins": _num(stat, "wins"),
            "losses": _num(stat, "losses"),
            "saves": _num(stat, "saves"),
            "strike_outs": _num(stat, "strikeOuts"),
            "base_on_balls": _num(stat, "baseOnBalls"),
            "earned_runs": _num(stat, "earnedRuns"),
        },
        source="mlb_stats_games",
        headshot=headshot,
        week=index,
        opponent=_opponent_abbr(split),
        game_date=_game_date_label(split.get("date") or ""),
    )


def fetch_by_ids(id_to_name: dict[str, str], years: list[int]) -> list[RawSeason]:
    """Every regular-season game (hitting AND pitching) for each MLB person id, for each
    requested season year. A two-way player like Ohtani contributes rows to both pools."""
    out: list[RawSeason] = []
    for pid, name in id_to_name.items():
        headshot = HEADSHOT_URL.format(id=pid)
        for year in years:
            for group, parser in (("hitting", _hitting_game), ("pitching", _pitching_game)):
                cache_key = f"mlb_gamelog_{pid}_{group}_{year}.json"
                was_cached = is_cached(cache_key, _TTL_HOURS)
                try:
                    data = fetch_json(_GAMELOG.format(id=pid, group=group, year=year),
                                      cache_key=cache_key, ttl_hours=_TTL_HOURS)
                    splits = (data.get("stats") or [{}])[0].get("splits", [])
                    for i, split in enumerate(splits, start=1):
                        row = parser(name, split, headshot, i)
                        if row:
                            out.append(row)
                    if not was_cached:
                        time.sleep(_RATE_DELAY)
                except Exception as err:  # noqa: BLE001
                    print(f"[mlb-games] skipping id {pid} ({name}, {group}, {year}): {err}")
    return out
