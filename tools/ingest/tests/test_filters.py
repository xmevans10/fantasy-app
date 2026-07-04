"""Tests for the declarative niche-filter system + game-grain model bits."""
from tools.ingest.models import RawSeason
from tools.ingest.themes import Filter, field_value


def _season(**kw):
    base = dict(name="Ted Ginn", team_abbr="MIA", season_year=2015, sport="nfl",
                position="WR", stats={"receiving_yards": 700.0})
    base.update(kw)
    return RawSeason(**base)


def test_first_name_falls_back_to_split_when_no_meta():
    s = _season(name="Barry Sanders")
    assert field_value(s, "first_name") == "Barry"
    assert field_value(s, "last_name") == "Sanders"


def test_first_name_prefers_meta():
    s = _season(name="A.J. Brown", meta={"first_name": "Arthur"})
    assert field_value(s, "first_name") == "Arthur"


def test_decade_is_derived():
    assert field_value(_season(season_year=2007), "decade") == 2000
    assert field_value(_season(season_year=2019), "decade") == 2010


def test_eq_is_case_insensitive_and_numeric_aware():
    s = _season(meta={"first_name": "Ted", "draft_round": "1"})
    assert Filter("first_name", "eq", "ted").matches(s)
    assert Filter("draft_round", "eq", 1).matches(s)        # "1" == 1
    assert not Filter("first_name", "eq", "Joe").matches(s)


def test_exists_true_and_false():
    drafted = _season(meta={"draft_round": "3"})
    undrafted = _season(meta={})
    assert Filter("draft_round", "exists", True).matches(drafted)
    assert not Filter("draft_round", "exists", True).matches(undrafted)
    assert Filter("draft_round", "exists", False).matches(undrafted)


def test_numeric_ops_coerce_strings():
    s = _season(meta={"height_in": "71", "age": "34"})
    assert Filter("height_in", "lte", 71).matches(s)
    assert not Filter("height_in", "gte", 77).matches(s)
    assert Filter("age", "range", (33, 40)).matches(s)


def test_regex_matches_name_variants():
    f = Filter("first_name", "regex", "^(mike|michael)$")
    assert f.matches(_season(name="Michael Thomas"))
    assert f.matches(_season(name="Mike Evans"))
    assert not f.matches(_season(name="Marcus Allen"))


def test_missing_field_does_not_match_value_ops():
    s = _season(meta={})            # no college
    assert not Filter("college", "eq", "LSU").matches(s)
    assert not Filter("height_in", "gte", 70).matches(s)


def test_game_grain_player_id_is_distinct_from_season():
    season = _season(season_year=2007)
    game = _season(season_year=2007, week=12, opponent="DEN")
    assert season.player_id == "ted-ginn-2007"
    assert game.player_id == "ted-ginn-2007-wk12"
    assert season.player_id != game.player_id
