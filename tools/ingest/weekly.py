"""One league-week of real box scores, per sport: the input a Week Pack is built from.

A pack claims to be about "the week", so its source has to be the WHOLE league's week, never a
sample of it. That rules out the committed game sweeps this pipeline already has for NBA and MLB
(hoopR keeps only "notable" games; the MLB game logs cover a marquee list), because "top
performances" drawn from either would quietly leave most of the league out and still read as
complete. Every source here instead pairs the league's own SCHEDULE for the window with every
final game's box score, so `readiness.py` can check the one against the other.

    WeekData.games  what the schedule says happened (id, day, teams, final or not)
    WeekData.rows   one RawSeason per player per game, game grain, `event_date` set

A sport with no entry in SOURCES has no such pull yet; `gather` returns None and readiness
reports exactly that rather than minting from something thinner.

All sources are stdlib-only and keyless, like the rest of the daily pipeline.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import time
from typing import Callable

from .models import RawSeason
from .periods import Period


@dataclasses.dataclass(frozen=True)
class Game:
    id: str
    date: str            # ISO, the league's local calendar day
    home: str
    away: str
    final: bool
    # Postponed, cancelled or suspended: not part of this week's box scores, and never a
    # reason to hold the week open (a suspended game finishes days later under a new date).
    excluded: bool = False


@dataclasses.dataclass
class WeekData:
    sport: str
    games: list[Game]
    rows: list[RawSeason]
    source: str


def _days(period: Period) -> list[dt.date]:
    start, end = dt.date.fromisoformat(period.start), dt.date.fromisoformat(period.end)
    return [start + dt.timedelta(days=i) for i in range((end - start).days + 1)]


def _date_label(iso: str) -> str:
    d = dt.date.fromisoformat(iso)
    return f"{d.strftime('%b')} {d.day}"


# ── NFL (nflverse) ────────────────────────────────────────────────────────────

def nfl_week(period: Period) -> WeekData:
    from . import main as ingest_main
    from .providers import nfl_nflverse_games, nfl_nflverse_schedule as sched
    schedule = sched.fetch_rows()
    week = int(period.key.rsplit("wk", 1)[1])
    games = [Game(id=r.get("game_id") or f"{r.get('away_team')}@{r.get('home_team')}",
                  date=(r.get("gameday") or "").strip(),
                  home=(r.get("home_team") or "").strip(), away=(r.get("away_team") or "").strip(),
                  final=sched._is_final(r))
             for r in sched.regular_season(schedule, period.season_year)
             if sched._int(r.get("week")) == week]
    rows = [r for r in nfl_nflverse_games.fetch_years([period.season_year])
            if r.week == week and r.season_year == period.season_year]
    ingest_main.merge_nfl_bio(rows)       # bio quirks (draft round, height, age) need this
    return WeekData("nfl", games, rows, "nflverse stats_player_week + schedules")


# ── MLB (statsapi.mlb.com) ────────────────────────────────────────────────────

_MLB_SCHEDULE = ("https://statsapi.mlb.com/api/v1/schedule?sportId=1&gameType=R"
                 "&startDate={start}&endDate={end}")
_MLB_BOX = "https://statsapi.mlb.com/api/v1/game/{pk}/boxscore"
_MLB_EXCLUDED = ("Postponed", "Cancelled", "Suspended")


def mlb_games(schedule: dict) -> list[Game]:
    from .providers.mlb_stats import TEAM_ABBR
    out = []
    for day in schedule.get("dates", []):
        for g in day.get("games", []):
            status = g.get("status", {})
            detailed = status.get("detailedState", "")
            out.append(Game(
                id=str(g["gamePk"]), date=g.get("officialDate") or day.get("date", ""),
                home=TEAM_ABBR.get(g["teams"]["home"]["team"]["id"], ""),
                away=TEAM_ABBR.get(g["teams"]["away"]["team"]["id"], ""),
                final=status.get("abstractGameState") == "Final" and not detailed.startswith(_MLB_EXCLUDED),
                excluded=detailed.startswith(_MLB_EXCLUDED)))
    return out


def mlb_rows(game: Game, box: dict, season: int) -> list[RawSeason]:
    """Every hitter and pitcher line in one final box score, through the SAME parsers the
    game-log provider uses (the box score and the game log share stat keys), so a week board
    and the catalog can never disagree about what a hit or an inning is."""
    from .providers.mlb_stats import HEADSHOT_URL
    from .providers.mlb_stats_games import _hitting_game, _pitching_game
    out: list[RawSeason] = []
    for side, other in (("home", "away"), ("away", "home")):
        team = box["teams"][side]
        opp_id = box["teams"][other]["team"]["id"]
        for player in team.get("players", {}).values():
            person = player.get("person", {})
            name, pid = person.get("fullName", ""), person.get("id")
            if not name or pid is None:
                continue
            base = {"team": {"id": team["team"]["id"]}, "season": season, "date": game.date,
                    "opponent": {"id": opp_id}}
            # The game id, not a per-player sequence, keeps ids distinct across a doubleheader.
            index = int(game.id)
            stats = player.get("stats", {})
            for group, parser in (("batting", _hitting_game), ("pitching", _pitching_game)):
                if stats.get(group):
                    row = parser(name, {**base, "stat": stats[group]}, HEADSHOT_URL.format(id=pid), index)
                    if row:
                        out.append(dataclasses.replace(row, source="mlb_boxscore",
                                                       person_id=str(pid)))
    return out


def mlb_week(period: Period) -> WeekData:
    from .providers.http import fetch_json
    schedule = fetch_json(_MLB_SCHEDULE.format(start=period.start, end=period.end),
                          cache_key=f"mlb_schedule_{period.start}_{period.end}.json", ttl_hours=3)
    games = mlb_games(schedule)
    rows: list[RawSeason] = []
    for game in games:
        if not game.final:
            continue
        box = fetch_json(_MLB_BOX.format(pk=game.id), cache_key=f"mlb_box_{game.id}.json",
                         ttl_hours=24 * 7)
        rows += mlb_rows(game, box, int(game.date[:4]))
        time.sleep(0.05)
    return WeekData("baseball", games, rows, "statsapi schedule + boxscore")


# ── NBA (ESPN site API) ───────────────────────────────────────────────────────

_ESPN_NBA = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/{path}"
_ESPN_EXCLUDED = ("STATUS_POSTPONED", "STATUS_CANCELED", "STATUS_SUSPENDED")


def nba_games(scoreboard: dict, day: str) -> list[Game]:
    """`day` is the date the scoreboard was requested for, which is the US local day. The
    event's own `date` is UTC and rolls a 7:30pm ET tip into tomorrow."""
    out = []
    for e in scoreboard.get("events", []):
        if (e.get("season") or {}).get("type") != 2:           # regular season only
            continue
        comp = e["competitions"][0]
        status = comp.get("status", {}).get("type", {})
        sides = {c["homeAway"]: c["team"]["abbreviation"] for c in comp["competitors"]}
        out.append(Game(id=str(e["id"]), date=day, home=sides.get("home", ""),
                        away=sides.get("away", ""), final=bool(status.get("completed")),
                        excluded=status.get("name") in _ESPN_EXCLUDED))
    return out


def _made(value: str) -> float:
    try:
        return float(str(value).split("-", 1)[0])
    except ValueError:
        return 0.0


def nba_rows(game: Game, summary: dict, season: int) -> list[RawSeason]:
    from .providers.espn_nba import _HEADSHOT, _norm_position
    teams = summary.get("boxscore", {}).get("players", [])
    abbrs = [t["team"]["abbreviation"] for t in teams]
    out: list[RawSeason] = []
    for t in teams:
        team = t["team"]["abbreviation"]
        opponent = next((a for a in abbrs if a != team), "")
        for block in t.get("statistics", []):
            keys = block.get("keys", [])
            for a in block.get("athletes", []):
                if a.get("didNotPlay") or not a.get("stats"):
                    continue
                values = dict(zip(keys, a["stats"]))
                athlete = a.get("athlete", {})
                position = _norm_position((athlete.get("position") or {}).get("abbreviation", ""))
                if not position:
                    continue
                num = lambda k: float(values.get(k) or 0) if str(values.get(k, "")).lstrip("-").isdigit() else 0.0
                out.append(RawSeason(
                    name=athlete.get("displayName", ""), team_abbr=team, season_year=season,
                    sport="nba", position=position,
                    stats={"points": num("points"), "rebounds": num("rebounds"),
                           "assists": num("assists"), "steals": num("steals"),
                           "blocks": num("blocks"),
                           "field_goals_made": _made(values.get("fieldGoalsMade-fieldGoalsAttempted", ""))},
                    source="espn_boxscore",
                    headshot=(athlete.get("headshot") or {}).get("href")
                             or _HEADSHOT.format(id=athlete.get("id", "")),
                    week=int(game.id[-5:]), opponent=opponent,
                    game_date=_date_label(game.date), event_date=game.date,
                    person_id=str(athlete.get("id", ""))))
    return out


def nba_week(period: Period) -> WeekData:
    from .providers.http import fetch_json
    games: list[Game] = []
    rows: list[RawSeason] = []
    for day in _days(period):
        stamp = day.strftime("%Y%m%d")
        board = fetch_json(_ESPN_NBA.format(path=f"scoreboard?dates={stamp}"),
                           cache_key=f"espn_nba_scoreboard_{stamp}.json", ttl_hours=3)
        season = int((board.get("season") or {}).get("year") or day.year)
        for game in nba_games(board, day.isoformat()):
            games.append(game)
            if not game.final:
                continue
            summary = fetch_json(_ESPN_NBA.format(path=f"summary?event={game.id}"),
                                 cache_key=f"espn_nba_summary_{game.id}.json", ttl_hours=24 * 7)
            rows += nba_rows(game, summary, season)
            time.sleep(0.1)
    return WeekData("nba", games, rows, "espn scoreboard + summary")


SOURCES: dict[str, Callable[[Period], WeekData]] = {
    "nfl": nfl_week,
    "baseball": mlb_week,
    "nba": nba_week,
}


def gather(sport: str, period: Period) -> WeekData | None:
    source = SOURCES.get(sport)
    return source(period) if source else None
