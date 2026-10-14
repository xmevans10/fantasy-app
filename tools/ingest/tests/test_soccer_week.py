"""Soccer Week Packs: round derivation, box-score rows, the readiness contract and the cohort.

All offline: hand-built fixtures in the shape ESPN's site API returns (verified live
2026-09-26 against eng.1 event 401879269).
"""
from __future__ import annotations

import datetime as dt
import random
import re

import pytest

from tools.ingest import curation, fresh_drop, pack, periods, readiness, weekly
from tools.ingest.baselines import compute_baselines
from tools.ingest.grade import BaselineTable
from tools.ingest.models import RawSeason
from tools.ingest.weekly import Game, WeekData

EPL = weekly.SOCCER_LEAGUES["eng.1"]
CLUBS = [f"C{i:02d}" for i in range(20)]


def _round(k: int, day: str, clubs=CLUBS) -> list[Game]:
    return [Game(id=f"{k}-{i}", date=day, home=clubs[i], away=clubs[i + 10], final=True)
            for i in range(10)]


# ── Rounds ────────────────────────────────────────────────────────────────────

def test_a_clean_season_is_ten_game_rounds_in_order():
    games = _round(1, "2026-08-22") + _round(2, "2026-08-29") + _round(3, "2026-09-05")
    rounds = weekly.soccer_rounds(games)
    assert list(rounds) == [1, 2, 3]
    assert all(len(gs) == 10 for gs in rounds.values())


def test_a_postponed_fixture_does_not_shift_the_next_round():
    """C00 v C10 is postponed out of round 2: both clubs fall one behind, and every later
    fixture of theirs must still land in its true round (the opponent's count carries it)."""
    r2 = [g for g in _round(2, "2026-08-29") if g.id != "2-0"]
    r3 = _round(3, "2026-09-05")
    rounds = weekly.soccer_rounds(_round(1, "2026-08-22") + r2 + r3)
    assert len(rounds[2]) == 9
    assert {g.id for g in rounds[3]} == {g.id for g in r3}


def test_a_rearranged_fixture_is_rehomed_to_the_round_it_was_played_in():
    """A fixture whose count says round 5 but was played inside round 4's weekend belongs to
    round 4's week, not to a round five days later."""
    games = []
    for k, day in enumerate(("2026-08-01", "2026-08-08", "2026-08-15", "2026-08-22",
                             "2026-08-29", "2026-09-05"), start=1):
        games += _round(k, day)
    # Round 4 is a Saturday-Sunday weekend, and two clubs play a brought-forward fixture on
    # its Sunday, so both run one fixture ahead of the schedule from then on.
    games = [Game(g.id, "2026-08-23", g.home, g.away, True) if g.id in ("4-8", "4-9") else g
             for g in games]
    extra = Game(id="x", date="2026-08-23", home=CLUBS[0], away=CLUBS[1], final=True)
    rounds = weekly.soccer_rounds(games + [extra])
    assert "x" in {g.id for g in rounds[4]}
    assert {g.id for g in rounds[5]} == {f"5-{i}" for i in range(10)}
    assert {g.id for g in rounds[6]} == {f"6-{i}" for i in range(10)}


def test_a_standalone_midweek_catch_up_belongs_to_no_round():
    games = _round(1, "2026-08-01") + _round(2, "2026-08-08") + _round(3, "2026-08-22")
    catch_up = Game(id="x", date="2026-08-13", home=CLUBS[0], away=CLUBS[1], final=True)
    rounds = weekly.soccer_rounds(games + [catch_up])
    assert all("x" not in {g.id for g in gs} for gs in rounds.values())


def test_closed_round_is_chosen_by_date_and_goes_stale(monkeypatch):
    games = _round(1, "2026-08-22") + _round(2, "2026-08-29")
    monkeypatch.setattr(weekly, "soccer_fixtures", lambda lg, season, through: [
        g for g in games if g.date <= through.isoformat()])
    assert weekly.soccer_closed_round(EPL, dt.date(2026, 8, 29)).key == "eng1-2027-wk01"
    period = weekly.soccer_closed_round(EPL, dt.date(2026, 9, 1))
    assert (period.key, period.label) == ("eng1-2027-wk02", "Premier League Matchweek 2")
    assert weekly.soccer_closed_round(EPL, dt.date(2026, 9, 20)) is None   # international break


def test_the_period_key_cools_down_as_a_league_scoped_kind():
    sl = curation.matchweek_slice("eng1", 2027, 5, "Premier League Matchweek 5")
    assert fresh_drop.theme_kind(f"fresh-soccer-{sl.key}-any") == "fresh-soccer-eng1-any"


def test_a_calendar_week_is_not_a_soccer_week():
    assert weekly.soccer_week(periods.closed_period("soccer", dt.date(2026, 9, 29))) is None


# ── Box-score rows ────────────────────────────────────────────────────────────

def _player(name, pid, *, starter, apps=1, goals=0, assists=0, kickoff="Substitute"):
    return {"starter": starter, "athlete": {"id": pid, "displayName": name},
            "position": {"name": kickoff},
            "stats": [{"name": "appearances", "value": apps}, {"name": "totalGoals", "value": goals},
                      {"name": "goalAssists", "value": assists},
                      {"name": "goalsConceded", "value": 0}]}


SUMMARY = {
    "header": {"league": {"slug": "eng.1"}, "competitions": [{
        "status": {"type": {"completed": True}},
        "competitors": [{"team": {"displayName": "Arsenal"}, "score": "2"},
                        {"team": {"displayName": "Chelsea"}, "score": "0"}]}]},
    "rosters": [
        {"team": {"displayName": "Arsenal"}, "roster": [
            _player("Keeper One", "1", starter=True, kickoff="Goalkeeper"),
            _player("Striker One", "2", starter=True, goals=2, kickoff="Forward"),
            _player("Late Sub", "3", starter=False),
            _player("Unused Sub", "4", starter=False, apps=0)]},
        {"team": {"displayName": "Chelsea"}, "roster": [
            _player("Their Keeper", "5", starter=True, kickoff="Goalkeeper")]},
    ],
}


def test_rows_score_one_match_honestly():
    from tools.ingest.providers.club_codes import resolve_code
    ars, che = resolve_code("Arsenal", country="England"), resolve_code("Chelsea", country="England")
    game = Game(id="1", date="2026-09-19", home=ars, away=che, final=True)
    rows = {r.name: r for r in weekly.soccer_rows(game, SUMMARY, 5, lambda n, t: None)}
    assert "Unused Sub" not in rows
    assert rows["Keeper One"].stats["clean_sheets"] == 1.0
    assert rows["Late Sub"].stats["clean_sheets"] == 0.0        # did not start
    assert rows["Their Keeper"].stats["clean_sheets"] == 0.0    # conceded two
    striker = rows["Striker One"]
    assert (striker.position, striker.stats["goals"], striker.team_abbr, striker.opponent) == \
        ("FW", 2.0, ars, che)
    assert rows["Late Sub"].position == "MF"                    # no catalog, no kickoff role
    assert (striker.week, striker.event_date, striker.game_date, striker.season_year) == \
        (5, "2026-09-19", "Sep 19", 2026)


def test_rows_take_photo_and_position_from_the_catalog():
    game = Game(id="1", date="2026-09-19", home="ARS", away="CHE", final=True)
    known = RawSeason(name="Late Sub", team_abbr="ARS", season_year=2026, sport="soccer",
                      position="DF", stats={}, headshot="https://img.example/late.jpg")
    rows = {r.name: r for r in weekly.soccer_rows(
        game, SUMMARY, 5, lambda n, t: known if n == "Late Sub" else None)}
    assert (rows["Late Sub"].position, rows["Late Sub"].headshot) == \
        ("DF", "https://img.example/late.jpg")


# ── Readiness and the cohort ──────────────────────────────────────────────────

def _week_rows(games: list[Game], per_side: int = 14) -> list[RawSeason]:
    rows = []
    for g in games:
        for team, opp in ((g.home, g.away), (g.away, g.home)):
            for i in range(per_side):
                rows.append(RawSeason(
                    name=f"{team} P{i}", team_abbr=team, season_year=2026, sport="soccer",
                    position=("GK", "DF", "MF", "FW")[i % 4],
                    stats={"appearances": 1.0, "goals": float(i % 3 == 0), "assists": 0.0,
                           "clean_sheets": 0.0},
                    headshot=f"https://img.example/{team}{i}.jpg", week=5, opponent=opp,
                    game_date="Sep 19", event_date=g.date))
    return rows


def test_a_complete_round_is_ready_and_a_missing_box_score_blocks():
    games = _round(5, "2026-09-19")
    period = weekly.soccer_period(EPL, 2027, 5, games)
    ready = readiness.evaluate("soccer", period, WeekData("soccer", games, _week_rows(games), "t"),
                               scorable=True)
    assert ready.status is readiness.Status.READY
    partial = [r for r in _week_rows(games) if r.team_abbr != games[0].home]
    blocked = readiness.evaluate("soccer", period, WeekData("soccer", games, partial, "t"),
                                 scorable=True)
    assert blocked.status is readiness.Status.BLOCKED and "COMPLETE" in blocked.reasons[0]


def test_a_lone_catch_up_fixture_is_not_a_week():
    games = _round(5, "2026-09-19")[:2]
    period = weekly.soccer_period(EPL, 2027, 5, games)
    verdict = readiness.evaluate("soccer", period,
                                 WeekData("soccer", games, _week_rows(games), "t"), scorable=True)
    assert verdict.status is readiness.Status.SKIP


def test_soccer_week_scales_are_ones_the_shipped_app_already_knows():
    """Grades are baked into the board, but the in-app formula sheet looks the scale up in
    ScoringRule.presets. No new scale: the two soccer presets every build has."""
    for spec in curation.SOCCER_GAME_POSITIONS.values():
        assert spec.scale in {"soccer_attacker_fantasy", "soccer_defender_fantasy"}
        assert spec.grain == "game"


@pytest.mark.parametrize("quirk", curation.SOCCER_GAME_QUIRKS, ids=lambda q: q.key)
def test_threshold_titles_say_n_plus(quirk):
    """'Fifteen-carry games' read as exactly fifteen (2026-09-26). Every numbered `gte` title
    reads N+, and never spells the number out."""
    for f in quirk.filters:
        if f.op == "gte" and f.value != 1 or re.search(r"\d", quirk.title):
            assert f"{f.value:g}+" in quirk.title, quirk.title
    assert not re.search(r"\b(one|two|three|four|five|ten)\b", quirk.title, re.I)


def test_a_league_without_divisions_fills_that_slot_with_a_second_position_board(monkeypatch):
    monkeypatch.setitem(fresh_drop.GAME_COHORTS, "soccer", ("soccer-games",))
    games = _round(5, "2026-09-19")
    rows = []
    for g in games:
        for team, opp in ((g.home, g.away), (g.away, g.home)):
            for i, pos in enumerate(("GK", "DF", "DF", "MF", "MF", "FW", "FW")):
                # Distinct totals everywhere, so no board is lost to a keep/cut tie.
                n = len(rows)
                rows.append(RawSeason(
                    name=f"{team} {pos}{i}", team_abbr=team, season_year=2026, sport="soccer",
                    position=pos, stats={"appearances": 1.0, "goals": float(n),
                                         "assists": 0.0, "clean_sheets": float(n % 2)},
                    headshot=f"https://img.example/{team}{i}.jpg", week=5, opponent=opp,
                    game_date="Sep 19", event_date=g.date))
    period = weekly.soccer_period(EPL, 2027, 5, games)
    cands = pack.build_candidates("soccer", period, rows, BaselineTable(compute_baselines(rows)),
                                  random.Random(0))
    division = {c.theme_key for c in cands if c.role == "division"}
    assert division and division <= {c.theme_key for c in cands if c.role == "position"}
    items = pack.assemble_pack(cands)
    assert pack.check_rules(items) == []
