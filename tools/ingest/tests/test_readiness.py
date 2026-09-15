"""The weekly data contract: what makes a league-week good enough to mint a pack from."""
from __future__ import annotations

import datetime as dt

from tools.ingest import periods, readiness
from tools.ingest.models import RawSeason
from tools.ingest.readiness import Status
from tools.ingest.weekly import Game, WeekData

PERIOD = periods.rolling_week("baseball", dt.date(2026, 9, 15))


def _games(n, *, day="2026-09-13", final=True):
    return [Game(id=str(i), date=day, home=f"H{i}", away=f"A{i}", final=final) for i in range(n)]


def _rows(games, *, photo="https://x/p.png"):
    out = []
    for g in games:
        for team, opp in ((g.home, g.away), (g.away, g.home)):
            out.append(RawSeason(name=f"P {team}", team_abbr=team, season_year=2026,
                                 sport="baseball", position="H", stats={"hits": 1.0},
                                 headshot=photo, week=int(g.id), opponent=opp,
                                 event_date=g.date))
    return out


def _judge(games, rows, sport="baseball", scorable=True):
    return readiness.evaluate(sport, PERIOD, WeekData(sport, games, rows, "test"), scorable)


def test_a_sport_with_no_source_skips_and_says_so():
    v = readiness.evaluate("hockey", PERIOD, None, scorable=False)
    assert v.status is Status.SKIP and "SOURCED" in v.reasons[0]


def test_a_sport_with_no_single_game_scale_skips():
    v = _judge(_games(50), _rows(_games(50)), scorable=False)
    assert v.status is Status.SKIP and "SCORABLE" in v.reasons[0]


def test_a_short_week_skips_rather_than_minting_thin():
    games = _games(12)
    v = _judge(games, _rows(games))
    assert v.status is Status.SKIP and "A REAL WEEK" in v.reasons[0]


def test_a_complete_week_is_ready():
    games = _games(60)
    v = _judge(games, _rows(games))
    assert v.ready, v.summary()
    assert v.metrics["games_with_box_scores"] == 60


def test_an_unfinished_game_blocks():
    games = _games(60) + _games(1, final=False)
    v = _judge(games, _rows(games[:60]))
    assert v.status is Status.BLOCKED and any("SETTLED" in r for r in v.reasons)


def test_postponed_games_neither_block_nor_count():
    games = _games(60) + [Game(id="pp", date="2026-09-13", home="X", away="Y", final=False,
                               excluded=True)]
    v = _judge(games, _rows(games[:60]))
    assert v.ready, v.summary()
    assert v.metrics["excluded"] == 1


def test_a_game_missing_one_teams_box_score_blocks():
    """The schedule and the stats feed are posted by different jobs; the pack must not publish
    in the hours between them."""
    games = _games(60)
    rows = [r for r in _rows(games) if not (r.team_abbr == "A7")]
    v = _judge(games, rows)
    assert v.status is Status.BLOCKED and any("COMPLETE" in r for r in v.reasons)


def test_rows_that_stop_before_the_last_game_day_block():
    games = _games(59) + _games(1, day="2026-09-14")
    rows = _rows(games[:59])
    v = _judge(games, rows)
    assert v.status is Status.BLOCKED
    assert any("FRESH" in r for r in v.reasons)


def test_duplicate_player_lines_block():
    games = _games(60)
    rows = _rows(games)
    v = _judge(games, rows + rows[:1])
    assert v.status is Status.BLOCKED and any("appear twice" in r for r in v.reasons)


def test_a_feed_that_stopped_sending_photos_blocks():
    games = _games(60)
    v = _judge(games, _rows(games, photo=""))
    assert v.status is Status.BLOCKED and any("photo" in r for r in v.reasons)
