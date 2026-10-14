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

import collections
import dataclasses
import datetime as dt
import functools
import time
from typing import Callable

from . import curation
from .models import RawSeason, slug
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


# ── Soccer (ESPN site API) ────────────────────────────────────────────────────
#
# A soccer week is a ROUND ("Premier League Matchweek 5"), not a calendar week: a round runs
# Friday to Monday, a midweek round Tuesday to Thursday, and a Mon-Sun window would cut the
# Monday game off one and staple it to the next. ESPN publishes no round number (the site API's
# events carry none and the core API's `weeks` list is empty for eng.1, checked 2026-09-26), so
# the round is DERIVED from the fixture list; see `soccer_rounds`.
#
# One pack per league per round. The period key carries the league so two leagues' packs never
# collide (`soccer-eng1-2027-wk05`), and keeps the `YYYY-wkNN` shape `fresh_drop.theme_kind`
# already strips, so "top performances" cools down across rounds the way NFL's does.

_ESPN_SOCCER = "https://site.api.espn.com/apis/site/v2/sports/soccer/{league}/{path}"
_SOCCER_EXCLUDED = ("STATUS_POSTPONED", "STATUS_CANCELED", "STATUS_ABANDONED", "STATUS_SUSPENDED")


@dataclasses.dataclass(frozen=True)
class SoccerLeague:
    slug: str            # ESPN competition slug, the same one soccer_leagues.csv keys on
    name: str            # what a board title calls it

    @property
    def code(self) -> str:
        """The league's prefix in a period key: 'eng.1' -> 'eng1'."""
        return self.slug.replace(".", "")


# The leagues that get Week Packs. Adding one is one line here, nothing else: the pack job runs
# every entry. Verified before shipping, per league, with
# `python -m tools.ingest.pack --sport soccer --league <slug> --replay-from ... --replay-to ...`.
# The Big-5 siblings would be SoccerLeague("esp.1", "LaLiga"), ("ger.1", "Bundesliga"),
# ("ita.1", "Serie A") and ("fra.1", "Ligue 1"); none has been replayed yet.
SOCCER_LEAGUES: dict[str, SoccerLeague] = {
    lg.slug: lg for lg in (SoccerLeague("eng.1", "Premier League"),)
}

# A round whose last match is further back than this is not "the round that just finished":
# it is an international break or the close season, and there is nothing new to pack.
SOCCER_STALE_DAYS = 10


def soccer_season_end(day: dt.date) -> int:
    """The season-END year `day` falls in (2026-09-19 -> 2027), the pipeline's soccer
    convention (see providers/espn_soccer.py)."""
    return day.year + (1 if day.month >= 7 else 0)


def _club_code(team: dict, country: str | None) -> str:
    """The catalog's code for an ESPN team, remembering ESPN's short name for titles
    (`shapes.DISPLAY_NAMES`)."""
    from .providers.club_codes import resolve_code
    from .shapes import DISPLAY_NAMES
    code = resolve_code(team["displayName"], country=country)
    DISPLAY_NAMES.setdefault(code, team.get("shortDisplayName") or team["displayName"])
    return code


def soccer_games(scoreboard: dict, day: str, country: str) -> list[Game]:
    """`day` is the date the scoreboard was requested for, as for NBA. Clubs are coded with
    `club_codes.resolve_code`, the same codes the catalog and the teams table use, so a board's
    team chips and colours resolve; ESPN's own abbreviations are a different vocabulary."""
    from .providers.club_codes import resolve_code
    out = []
    for e in scoreboard.get("events", []):
        comp = e["competitions"][0]
        status = comp.get("status", {}).get("type", {})
        sides = {c["homeAway"]: _club_code(c["team"], country) for c in comp["competitors"]}
        out.append(Game(id=str(e["id"]), date=day, home=sides.get("home", ""),
                        away=sides.get("away", ""), final=bool(status.get("completed")),
                        excluded=status.get("name") in _SOCCER_EXCLUDED))
    return out


def soccer_rounds(games: list[Game]) -> dict[int, list[Game]]:
    """Group a season's fixtures into rounds. Pure.

    Each club's k-th fixture by date is its round-k game, and a fixture takes the LARGER of its
    two clubs' counts. The larger, because a postponement only ever makes one club fall behind
    the schedule: its opponent's count is still the true round. Measured on eng.1, this alone
    puts 36 of 38 rounds at exactly ten games in both 2024-25 and 2025-26.

    The rest are rearranged fixtures (a cup-final weekend's games played weeks later, a
    brought-forward tie), which the count files under a round played on another date. So a
    round keeps only the fixtures within three days of its median date; a fixture that falls
    outside is re-homed to whichever round's window it was actually played in, or left out
    when it was a stand-alone midweek catch-up belonging to no round's window.
    """
    ordered = sorted(games, key=lambda g: (g.date, g.id))
    played: collections.Counter = collections.Counter()
    hint: dict[str, int] = {}
    for g in ordered:
        played[g.home] += 1
        played[g.away] += 1
        hint[g.id] = max(played[g.home], played[g.away])

    by_hint: dict[int, list[Game]] = collections.defaultdict(list)
    for g in ordered:
        by_hint[hint[g.id]].append(g)
    day = dt.date.fromisoformat
    rounds: dict[int, list[Game]] = {}
    strays: list[Game] = []
    for k, members in by_hint.items():
        middle = day(sorted(g.date for g in members)[len(members) // 2])
        rounds[k] = [g for g in members if abs((day(g.date) - middle).days) <= 3]
        strays += [g for g in members if abs((day(g.date) - middle).days) > 3]
    rounds = {k: gs for k, gs in rounds.items() if gs}
    span = lambda gs: (min(g.date for g in gs), max(g.date for g in gs))
    # Clubs running a fixture AHEAD of the schedule (a brought-forward tie) count one higher
    # for the rest of the season, so at the newest round their fixtures form a phantom round of
    # two, played on the real round's own dates. Smallest first, any round that sits wholly
    # inside a bigger round's window is that round.
    for k in sorted(rounds, key=lambda k: len(rounds[k])):
        lo, hi = span(rounds[k])
        host = next((j for j in rounds if j != k and len(rounds[j]) > len(rounds[k])
                     and span(rounds[j])[0] <= lo and hi <= span(rounds[j])[1]), None)
        if host is not None:
            rounds[host] += rounds.pop(k)
    windows = {k: span(gs) for k, gs in rounds.items()}
    for g in strays:
        home = next((k for k, (lo, hi) in sorted(windows.items()) if lo <= g.date <= hi), None)
        if home is not None:
            rounds[home].append(g)
    return {k: sorted(gs, key=lambda g: (g.date, g.id)) for k, gs in sorted(rounds.items())}


def _soccer_fetch(league: SoccerLeague, path: str, cache_key: str, ttl_hours: float,
                  settled: Callable[[dict], bool]) -> dict:
    """`fetch_json`, refetched once when the cached copy is not `settled`: a scoreboard or box
    score cached mid-match would otherwise be served as final data for its whole TTL."""
    from .providers.http import fetch_json
    url = _ESPN_SOCCER.format(league=league.slug, path=path)
    data = fetch_json(url, cache_key=cache_key, ttl_hours=ttl_hours)
    return data if settled(data) else fetch_json(url, cache_key=cache_key, ttl_hours=0)


def soccer_fixtures(league: SoccerLeague, season_end: int, through: dt.date) -> list[Game]:
    """Every league fixture of the season dated on or before `through`, from the season's
    match-day calendar plus one scoreboard per match day (the same two calls, and cache keys,
    providers/espn_soccer.py uses)."""
    from .providers.http import fetch_json
    from .soccer_leagues import nation_for
    current = season_end >= soccer_season_end(dt.date.today())
    calendar = fetch_json(
        _ESPN_SOCCER.format(league=league.slug, path=f"scoreboard?dates={season_end - 1}0701"),
        cache_key=f"espn_soccer_{league.slug}_{season_end}_calendar_weekly.json",
        ttl_hours=12 if current else 24 * 365)
    days = sorted({d[:10] for d in (calendar.get("leagues") or [{}])[0].get("calendar", [])})
    country = nation_for(league.slug)
    games: list[Game] = []
    for day in days:
        if day > through.isoformat():
            break
        stamp = day.replace("-", "")
        recent = (dt.date.today() - dt.date.fromisoformat(day)).days <= 7
        # A past day is settled once nothing on it is still waiting to be played.
        board = _soccer_fetch(
            league, f"scoreboard?dates={stamp}", f"espn_soccer_{league.slug}_{stamp}_events.json",
            1 if recent else 24 * 365,
            lambda b: day >= dt.date.today().isoformat() or all(
                g.final or g.excluded for g in soccer_games(b, day, country)))
        games += soccer_games(board, day, country)
    return games


def soccer_period(league: SoccerLeague, season_end: int, number: int,
                  games: list[Game]) -> Period:
    start, end = min(g.date for g in games), max(g.date for g in games)
    label = f"{league.name} Matchweek {number}"
    return Period(sport="soccer", key=f"{league.code}-{season_end}-wk{number:02d}", label=label,
                  start=start, end=end, season_year=season_end,
                  slice=curation.matchweek_slice(league.code, season_end, number, label))


def soccer_closed_round(league: SoccerLeague, today: dt.date) -> Period | None:
    """The round that most recently finished before `today`, or None between rounds.

    Chosen by DATE, not by status: a round whose last day has passed is closed even when a
    result is missing, so the readiness contract BLOCKs on it loudly (SETTLED) instead of this
    quietly falling back to a round that was already packed. Postponed fixtures never hold a
    round open (`Game.excluded`)."""
    season_end = soccer_season_end(today - dt.timedelta(days=1))
    rounds = soccer_rounds(soccer_fixtures(league, season_end, today))
    closed = [(k, gs) for k, gs in rounds.items()
              if max(g.date for g in gs) < today.isoformat()]
    if not closed:
        return None
    number, games = closed[-1]
    if (today - dt.date.fromisoformat(max(g.date for g in games))).days > SOCCER_STALE_DAYS:
        return None
    return soccer_period(league, season_end, number, games)


def soccer_round_periods(league: SoccerLeague, season_end: int) -> list[Period]:
    """Every round of a season with at least one fixture played, for replays."""
    rounds = soccer_rounds(soccer_fixtures(league, season_end, dt.date.today()))
    return [soccer_period(league, season_end, k, gs) for k, gs in rounds.items()]


_SOCCER_POSITIONS = {"G": "GK", "D": "DF", "M": "MF", "F": "FW"}


@functools.lru_cache(maxsize=1)
def _soccer_catalog() -> dict[tuple[str, str], RawSeason]:
    """The committed Transfermarkt sweep, latest season per (player, club) and per player.

    ESPN carries a soccer headshot for almost nobody (2 of the 32 players in one checked
    2026-27 match), so a week row takes the photo, and the position, the rest of the app
    already shows for that player. Those photos are the ones the headshot ledger already
    rehosted for the catalog, which is what lets `pack.apply_photos` keep them."""
    from .providers.transfermarkt_soccer import load_seasons
    out: dict[tuple[str, str], RawSeason] = {}
    for s in sorted(load_seasons(), key=lambda s: s.season_year):
        out[(slug(s.name), s.team_abbr)] = s
        out[(slug(s.name), "")] = s
    return out


def _catalog_match(name: str, team: str) -> RawSeason | None:
    catalog = _soccer_catalog()
    return catalog.get((slug(name), team)) or catalog.get((slug(name), ""))


def soccer_rows(game: Game, summary: dict, number: int,
                catalog: Callable[[str, str], RawSeason | None] = _catalog_match) -> list[RawSeason]:
    """Every player who got on the pitch in one final match. Pure given `catalog`.

    Clean sheet means STARTED a match his side did not concede in. ESPN's per-player
    `goalsConceded` counts only goals while that player was on (a starter subbed off at 2-0
    reads 0), and a substitute on for the last five minutes of a 1-0 has not kept anything."""
    from .providers.espn_soccer import _bucket_position
    from .providers.club_codes import resolve_code
    from .soccer_leagues import nation_for
    league = (summary.get("header", {}).get("league") or {}).get("slug", "")
    country = nation_for(league) if league else None
    conceded: dict[str, float] = {}
    for comp in summary.get("header", {}).get("competitions", [])[:1]:
        scores = {_club_code(c["team"], country): float(c.get("score") or 0)
                  for c in comp.get("competitors", [])}
        for team in scores:
            conceded[team] = sum(v for t, v in scores.items() if t != team)
    out: list[RawSeason] = []
    for roster in summary.get("rosters", []):
        team = _club_code(roster["team"], country)
        opponent = game.away if team == game.home else game.home
        for p in roster.get("roster", []):
            stats = {s["name"]: float(s.get("value") or 0) for s in p.get("stats", [])}
            athlete = p.get("athlete") or {}
            name = athlete.get("displayName", "")
            if not name or stats.get("appearances", 0) < 1:
                continue                      # an unused substitute
            known = catalog(name, team)
            kickoff = (p.get("position") or {}).get("name", "")
            position = (known.position if known else "") or (
                _bucket_position(kickoff) if p.get("starter") else "MF")
            out.append(RawSeason(
                name=name, team_abbr=team, season_year=int(game.date[:4]), sport="soccer",
                position=position,
                stats={"appearances": 1.0, "goals": stats.get("totalGoals", 0.0),
                       "assists": stats.get("goalAssists", 0.0),
                       "clean_sheets": float(bool(p.get("starter"))
                                             and conceded.get(team, 1.0) == 0),
                       "shots": stats.get("totalShots", 0.0),
                       "shots_on_target": stats.get("shotsOnTarget", 0.0),
                       "saves": stats.get("saves", 0.0)},
                source="espn_boxscore",
                headshot=(known.headshot if known else "")
                         or (athlete.get("headshot") or {}).get("href", ""),
                person_id=str(athlete.get("id", "")),
                week=number, opponent=opponent, game_date=_date_label(game.date),
                event_date=game.date,
                meta={"competition": league, "league": country or ""}))
    return out


def soccer_week(period: Period) -> WeekData | None:
    """One league round, parsed back out of the period key ('eng1-2027-wk05'). None for any
    other period shape, e.g. the rolling Mon-Sun week `periods.closed_period` gives soccer:
    a calendar week is not a soccer week, so that caller gets "no source" rather than a
    window that splits a round."""
    import re
    match = re.fullmatch(r"([a-z]+\d)-(\d{4})-wk(\d{2})", period.key)
    league = next((lg for lg in SOCCER_LEAGUES.values()
                   if match and lg.code == match.group(1)), None)
    if league is None:
        return None
    season_end, number = int(match.group(2)), int(match.group(3))
    games = soccer_rounds(soccer_fixtures(league, season_end,
                                          dt.date.fromisoformat(period.end))).get(number, [])
    rows: list[RawSeason] = []
    for game in games:
        if not game.final:
            continue
        summary = _soccer_fetch(
            league, f"summary?event={game.id}", f"espn_soccer_{league.slug}_match_{game.id}.json",
            24 * 365 * 5,
            lambda s: any(c.get("status", {}).get("type", {}).get("completed")
                          for c in s.get("header", {}).get("competitions", [])))
        rows += soccer_rows(game, summary, number)
        time.sleep(0.05)
    return WeekData("soccer", games, rows, "espn soccer scoreboard + summary")


SOURCES: dict[str, Callable[[Period], WeekData | None]] = {
    "nfl": nfl_week,
    "baseball": mlb_week,
    "nba": nba_week,
    "soccer": soccer_week,
}


def gather(sport: str, period: Period) -> WeekData | None:
    source = SOURCES.get(sport)
    return source(period) if source else None
