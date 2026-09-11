"""Tests for the hockey and F1 niche-theme generator cohorts in curation.py.

Synthetic seasons only (no network) — see test_generate.py for the same style. These
cohorts exist so `generate.py`/`daily_puzzle.py` can mint niche themes for the two sports
beyond their handful of curated ones (see themes.py's hockey/F1 entries).
"""
from __future__ import annotations

from tools.ingest import assemble, curation, generate
from tools.ingest.models import RawSeason


def _skater(name, *, pos="C", team="TOR", year=2015, points=80.0, goals=35.0, assists=45.0,
           plus_minus=None, shots=None, games=78.0, headshot="h"):
    stats = {"points": points, "goals": goals, "assists": assists, "games": games}
    if plus_minus is not None:
        stats["plus_minus"] = plus_minus
    if shots is not None:
        stats["shots"] = shots
    return RawSeason(name=name, team_abbr=team, season_year=year, sport="hockey",
                     position=pos, stats=stats, headshot=headshot)


def _goalie(name, *, team="TOR", year=2015, wins=30.0, save_pct=0.920, gaa=2.20,
           shutouts=6.0, saves=1600.0, games=60.0, games_started=58.0, losses=15.0,
           headshot="h"):
    return RawSeason(name=name, team_abbr=team, season_year=year, sport="hockey",
                     position="G", stats={
                         "wins": wins, "save_pct": save_pct, "gaa": gaa,
                         "shutouts": shutouts, "saves": saves, "games": games,
                         "games_started": games_started, "losses": losses,
                     }, headshot=headshot)


def _driver(name, *, team="FERRARI", year=2015, wins=0.0, podiums=0.0, poles=0.0,
           top_tens=8.0, races=18.0, championships=0.0, dnfs=1.0, fastest_laps=None,
           headshot="h"):
    stats = {"wins": wins, "podiums": podiums, "poles": poles, "top_tens": top_tens,
             "races": races, "championships": championships, "dnfs": dnfs}
    if fastest_laps is not None:
        stats["fastest_laps"] = fastest_laps
    return RawSeason(name=name, team_abbr=team, season_year=year, sport="f1",
                     position="Driver", stats=stats, headshot=headshot)


# ── Registration ───────────────────────────────────────────────────────────────

def test_hockey_and_f1_cohorts_are_registered():
    for cohort, sport in [("hockey", "hockey"), ("hockey-goalies", "hockey"), ("f1", "f1")]:
        cfg = curation.SPORTS[cohort]
        assert cfg.sport == sport
        assert cfg.quirks, f"{cohort} has no quirks"
        assert cfg.slices, f"{cohort} has no slices"


def test_generated_keys_are_namespaced_by_sport():
    for cohort in ("hockey", "hockey-goalies", "f1"):
        cfg = curation.SPORTS[cohort]
        for t in generate._candidates(cfg):
            assert t.key.startswith(f"gen-{cfg.sport}-")
            assert t.sport == cfg.sport


def test_f1_is_modeled_as_a_single_position_cohort_like_tennis():
    f1 = curation.SPORTS["f1"]
    assert set(f1.positions) == {"Driver"}
    assert f1.positions["Driver"].position_set == frozenset({"Driver"})


# ── Constraint 1: skaters and goalies share no stat key except `games` ──────────

def test_hockey_skater_and_goalie_quirks_are_disjoint_stat_families():
    def stat_fields(quirks):
        fields = set()
        for q in quirks:
            fields |= {f.field for f in q.filters}
        return fields

    skater_fields = stat_fields(curation._HOCKEY_SKATER_QUIRKS)
    goalie_fields = stat_fields(curation._HOCKEY_GOALIE_QUIRKS)
    shared = skater_fields & goalie_fields
    assert shared <= {"games", "season_year"}, shared


def test_skater_and_goalie_cohorts_are_separate_sport_curation_entries():
    # Same shape as baseball/baseball-pitchers: one `SportCuration` can't express two
    # disjoint quirk lists for the same sport, so it's two dict entries.
    skaters = curation.SPORTS["hockey"]
    goalies = curation.SPORTS["hockey-goalies"]
    assert skaters.positions.keys() & goalies.positions.keys() == set()
    assert skaters.quirks is not goalies.quirks


# ── Constraint 2: absent-stat quirks are era-scoped ─────────────────────────────

def test_plus_minus_and_shots_quirks_carry_an_explicit_era_filter():
    for q in curation._HOCKEY_SKATER_QUIRKS:
        fields = {f.field for f in q.filters}
        if "plus_minus" in fields or "shots" in fields:
            assert "season_year" in fields, (
                f"{q.key} filters on a stat absent from old rows without an era guard")


def test_fastest_laps_quirk_is_scoped_to_its_modern_start_year():
    q = next(q for q in curation._F1_QUIRKS if
             any(f.field == "fastest_laps" for f in q.filters))
    year_filters = [f for f in q.filters if f.field == "season_year"]
    assert year_filters and year_filters[0].op == "gte" and year_filters[0].value >= 2004


# ── Constraint 3 (position scoping) ──────────────────────────────────────────────

def test_defenseman_point_quirk_is_scoped_off_the_forward_cohort():
    hockey = curation.SPORTS["hockey"]
    keys = {t.key for t in generate._candidates(hockey)}
    dman_only = [k for k in keys if "thirty-point-dman" in k]
    assert dman_only, "expected the D-scoped point quirk to still generate themes"
    assert all("-d-" in k for k in dman_only)


def test_forward_point_quirk_does_not_reach_the_defenseman_cohort():
    hockey = curation.SPORTS["hockey"]
    for t in generate._candidates(hockey):
        if "fifty-point" in t.key:
            assert "-d-" not in t.key


# ── Viability smoke tests (the actual bar: does it build a fair puzzle) ─────────

def test_hockey_forward_cohort_builds_a_viable_puzzle():
    # `points` is only the FILTER; the fantasy grade is goals/assists/plus_minus/shots, so
    # each of those has to vary too or every card ties for the same grade (found live: an
    # earlier draft of this fixture varied only `points`, which isn't in the scale at all,
    # and every "card" graded identically).
    seasons = [_skater(f"Forward {i}", goals=40 - i, assists=40 - i, points=80 - 2 * i,
                       plus_minus=20 + i, shots=260 - 2 * i, year=2018)
               for i in range(10)]
    cfg = curation.SPORTS["hockey"]
    spec = cfg.positions["FWD"]
    q = next(q for q in cfg.quirks if q.key == "fifty-point")
    theme = generate._theme("t", "50-point forward seasons", spec, q.filters,
                            sport="hockey", quirks=(q,))
    rows = assemble.build_keep4_rows(theme, seasons)
    assert rows and len(rows[0].content["players"]) == 8


def test_hockey_defenseman_cohort_builds_a_viable_puzzle():
    seasons = [_skater(f"Dman {i}", pos="D", goals=10, assists=30 - i, points=40 - i,
                       plus_minus=10, year=2016)
               for i in range(10)]
    cfg = curation.SPORTS["hockey"]
    spec = cfg.positions["D"]
    q = next(q for q in cfg.quirks if q.key == "thirty-point-dman")
    theme = generate._theme("t", "30-point defenseman seasons", spec, q.filters,
                            sport="hockey", quirks=(q,))
    rows = assemble.build_keep4_rows(theme, seasons)
    assert rows and len(rows[0].content["players"]) == 8


def test_hockey_goalie_cohort_builds_a_viable_puzzle():
    seasons = [_goalie(f"Goalie {i}", wins=40 - i, save_pct=0.925 - i * 0.001)
               for i in range(10)]
    cfg = curation.SPORTS["hockey-goalies"]
    spec = cfg.positions["G"]
    q = next(q for q in cfg.quirks if q.key == "winner")
    theme = generate._theme("t", "25-win goaltending seasons", spec, q.filters,
                            sport="hockey", quirks=(q,))
    rows = assemble.build_keep4_rows(theme, seasons)
    assert rows and len(rows[0].content["players"]) == 8


def test_f1_cohort_builds_a_viable_puzzle():
    seasons = [_driver(f"Driver {i}", wins=1, podiums=20 - i, poles=2, top_tens=15,
                       races=19, dnfs=2, year=2016)
               for i in range(10)]
    cfg = curation.SPORTS["f1"]
    spec = cfg.positions["Driver"]
    q = next(q for q in cfg.quirks if q.key == "podium-regular")
    theme = generate._theme("t", "Eight-podium driver seasons", spec, q.filters,
                            sport="f1", quirks=(q,))
    rows = assemble.build_keep4_rows(theme, seasons)
    assert rows and len(rows[0].content["players"]) == 8


def test_f1_pre_2004_seasons_are_excluded_from_the_fastest_laps_quirk():
    # No fastest_laps key at all on pre-2004 rows (Ergast has no such data), which must not
    # be conflated with a real zero.
    old = [_driver(f"Old {i}", year=1990, wins=1, podiums=6, top_tens=10) for i in range(10)]
    cfg = curation.SPORTS["f1"]
    spec = cfg.positions["Driver"]
    q = next(q for q in cfg.quirks if q.key == "fastest-hand")
    theme = generate._theme("t", q.title.format(pos=spec.label), spec, q.filters,
                            sport="f1", quirks=(q,))
    assert assemble.build_keep4_rows(theme, old) == []
