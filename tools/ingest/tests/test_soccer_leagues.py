"""The shared soccer competition table — the one place nation <-> division is resolved.

These guard the invariant the whole Nation -> League -> Club hierarchy rests on: a NATION can
hold several COMPETITIONS, the competition slug is the enforceable key, and the nation is
derived from it (never the other way round). Before this table existed, `player_seasons.league`
held only a country, so Bundesliga and 2. Bundesliga were literally the same value.
"""
from tools.ingest import soccer_leagues


def test_every_competition_row_has_a_slug_country_and_tier():
    rows = soccer_leagues.load()
    assert rows, "the committed competition table must not be empty"
    for r in rows:
        assert r["espn_slug"] and r["country"], r
        assert isinstance(r["tier"], int) and r["tier"] >= 1, r


def test_slugs_are_unique():
    slugs = [r["espn_slug"] for r in soccer_leagues.load()]
    assert len(slugs) == len(set(slugs))


def test_each_nation_has_exactly_one_top_flight():
    tops = [r for r in soccer_leagues.load() if r["tier"] == 1]
    countries = [r["country"] for r in tops]
    assert len(countries) == len(set(countries)), "a nation cannot have two tier-1 leagues"


def test_a_nations_divisions_share_its_nation_label_but_not_its_slug():
    # The exact fact that makes lower divisions expressible: same nation, different key.
    assert soccer_leagues.nation_for("ger.1") == "Germany"
    assert soccer_leagues.nation_for("ger.2") == "Germany"
    assert soccer_leagues.tier_for("ger.1") == 1
    assert soccer_leagues.tier_for("ger.2") == 2
    assert soccer_leagues.top_flight_slug("Germany") == "ger.1"


def test_unknown_slug_falls_back_to_itself_rather_than_an_empty_label():
    assert soccer_leagues.nation_for("zzz.9") == "zzz.9"
    assert soccer_leagues.tier_for("zzz.9") == 1
    assert soccer_leagues.top_flight_slug("Atlantis") is None


def test_default_sweep_is_top_flights_only():
    tier1 = soccer_leagues.slugs(tier=1)
    assert "ger.1" in tier1 and "ger.2" not in tier1
    assert len(tier1) < len(soccer_leagues.slugs())


# ── season_meta: the tolerance that the committed CSVs actually need ──────────────────

def test_season_meta_carries_both_nation_and_division():
    meta = soccer_leagues.season_meta({"league": "Germany", "competition": "ger.2"})
    assert meta == {"league": "Germany", "competition": "ger.2"}


def test_season_meta_derives_the_nation_when_only_the_division_is_known():
    # The competition is the stronger fact, so it wins — this is what keeps the two columns
    # from ever disagreeing on a row written by a sweep that only knew its slug.
    assert soccer_leagues.season_meta({"competition": "ger.2"}) == {
        "league": "Germany", "competition": "ger.2"}


def test_season_meta_tolerates_a_csv_written_before_either_column_existed():
    # Not hypothetical: the Transfermarkt CSV committed 2026-07-10 had neither column, which
    # is how ~75k production rows ended up carrying no nation at all.
    assert soccer_leagues.season_meta({"name": "Someone"}) == {}
    assert soccer_leagues.season_meta({"league": "", "competition": ""}) == {}


def test_season_meta_keeps_a_nation_only_row_working():
    assert soccer_leagues.season_meta({"league": "England"}) == {"league": "England"}
