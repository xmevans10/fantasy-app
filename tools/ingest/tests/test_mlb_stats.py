"""MLB Stats API parser tests — pure (no network), against a captured payload shape
(verified live against statsapi.mlb.com this session — see providers/mlb_stats.py)."""
from tools.ingest.providers import mlb_stats
from tools.ingest.providers.mlb_stats import (
    HEADSHOT_URL,
    _parse_avg,
    _parse_innings_pitched,
    fetch_by_ids,
    parse_seasons,
)


def _hitting_split(year, team_id, **stat_overrides):
    stat = {
        "plateAppearances": 696, "atBats": 570, "hits": 177, "doubles": 28, "triples": 0,
        "homeRuns": 62, "runs": 133, "rbi": 131, "baseOnBalls": 111, "stolenBases": 16,
        "avg": ".311", "obp": ".425", "slg": ".686", "ops": "1.111",
    }
    stat.update(stat_overrides)
    return {"season": str(year), "team": {"id": team_id}, "stat": stat}


def _pitching_split(year, team_id, **stat_overrides):
    stat = {
        "inningsPitched": "209.0", "wins": 15, "losses": 4, "saves": 0, "strikeOuts": 222,
        "baseOnBalls": 48, "earnedRuns": 61, "era": "2.63", "whip": "0.98",
    }
    stat.update(stat_overrides)
    return {"season": str(year), "team": {"id": team_id}, "stat": stat}


def _payload(splits):
    return {"stats": [{"splits": splits}]}


def test_parses_real_hitting_season():
    # Aaron Judge's real 2022 season (verified live against the actual API this session).
    rows = parse_seasons("Aaron Judge", _payload([_hitting_split(2022, 147)]), "hitting")
    assert len(rows) == 1
    s = rows[0]
    assert s.sport == "baseball" and s.position == "H" and s.team_abbr == "NYY"
    assert s.season_year == 2022
    assert s.stats["home_runs"] == 62
    assert s.stats["rbi"] == 131
    assert s.stats["avg"] == 0.311


def test_parses_real_pitching_season():
    rows = parse_seasons("Gerrit Cole", _payload([_pitching_split(2023, 147)]), "pitching")
    assert len(rows) == 1
    s = rows[0]
    assert s.position == "P"
    assert s.stats["wins"] == 15
    assert s.stats["strike_outs"] == 222
    assert s.stats["era"] == 2.63
    assert s.stats["innings_pitched"] == 209.0


def test_skips_rows_with_unknown_team_id():
    # A team id not in TEAM_ABBR (e.g. a defunct/all-star-team placeholder) must be dropped,
    # not silently attributed to the wrong franchise.
    rows = parse_seasons("Someone", _payload([_hitting_split(2022, 999999)]), "hitting")
    assert rows == []


def test_skips_zero_plate_appearance_rows():
    rows = parse_seasons("Bench Player", _payload([
        _hitting_split(2022, 147, plateAppearances=0)
    ]), "hitting")
    assert rows == []


def test_innings_pitched_thirds_not_decimal_tenths():
    # MLB's '.1'/'.2' suffix means 1/3 and 2/3 of an inning, NOT decimal tenths — a common
    # off-by-a-lot bug if parsed as a plain float.
    assert _parse_innings_pitched("178.1") == round(178 + 1 / 3, 3)
    assert _parse_innings_pitched("178.2") == round(178 + 2 / 3, 3)
    assert _parse_innings_pitched("178.0") == 178.0
    assert _parse_innings_pitched(None) == 0.0


def test_parse_avg_handles_no_data_placeholder():
    assert _parse_avg({"avg": ".311"}, "avg") == 0.311
    assert _parse_avg({"avg": ".---"}, "avg") == 0.0
    assert _parse_avg({}, "avg") == 0.0


def test_parse_seasons_attaches_headshot_to_every_row():
    # M16: fetch_by_ids builds one headshot URL per player id and passes it through to
    # every season row (MLB's CDN serves a current photo, not one per year).
    headshot = HEADSHOT_URL.format(id="592450")
    rows = parse_seasons(
        "Aaron Judge",
        _payload([_hitting_split(2021, 147), _hitting_split(2022, 147)]),
        "hitting",
        headshot,
    )
    assert len(rows) == 2
    assert all(r.headshot == headshot for r in rows)


def test_parse_seasons_defaults_to_no_headshot():
    rows = parse_seasons("Aaron Judge", _payload([_hitting_split(2022, 147)]), "hitting")
    assert rows[0].headshot == ""


def test_fetch_by_ids_skips_the_rate_limit_delay_on_a_cache_hit(monkeypatch):
    # The delay only exists to protect the live API — a warm-cache run (e.g. a same-day
    # re-run, or CI restoring last run's cache) shouldn't pay it at all.
    monkeypatch.setattr(mlb_stats, "fetch_json", lambda *a, **k: _payload([]))
    monkeypatch.setattr(mlb_stats, "is_cached", lambda *a, **k: True)
    slept = []
    monkeypatch.setattr(mlb_stats.time, "sleep", lambda s: slept.append(s))

    fetch_by_ids({"592450": "Aaron Judge"})

    assert slept == []


def test_fetch_by_ids_still_delays_on_a_real_fetch(monkeypatch):
    monkeypatch.setattr(mlb_stats, "fetch_json", lambda *a, **k: _payload([]))
    monkeypatch.setattr(mlb_stats, "is_cached", lambda *a, **k: False)
    slept = []
    monkeypatch.setattr(mlb_stats.time, "sleep", lambda s: slept.append(s))

    fetch_by_ids({"592450": "Aaron Judge"})

    assert len(slept) == 2   # one per group (hitting, pitching)
