"""Tests for the Journeyman pool builder + its daily picker. Synthetic catalog rows, no network.

The interesting surface here is small and entirely about honesty: does the run-length encoding
describe the career that actually happened, and do the gates reject the paths this pipeline
can't describe truthfully (an unnameable club, a hole where a spell should be, a career that
started before the catalog did)?
"""
import datetime as dt
import json

import pytest

from tools.ingest import daily_journeyman, journeyman, validate, whoami_pool
from tools.ingest.journeyman import ClubNames, JourneymanEntry, Stint

NO_CLUBS = ClubNames({}, {})


# Boards may only carry headshots from our own store — `validate` enforces it, so a
# fixture has to look like a real rehosted URL rather than a placeholder string.
_STORE_SHOT = "https://nhccgufqwndtoasdbkhc.supabase.co/storage/v1/object/public/player-headshots/nfl/test.jpg"


def _row(name, team, year, sport="nfl", league=None, headshot=_STORE_SHOT):
    return {"name": name, "team_abbr": team, "season_year": year, "sport": sport,
            "position": "QB", "league": league, "headshot": headshot,
            "stats": {"passing_yards": 4000.0}, "career": False}


def _entry(sport="nfl", canonical="Test Player", difficulty="medium", fame=0.5, stints=None):
    return JourneymanEntry(
        sport=sport, canonical=canonical, position="QB", headshot=_STORE_SHOT,
        stints=stints or [Stint("LAC", "Chargers", "", 2001, 2005),
                          Stint("NO", "Saints", "", 2006, 2020)],
        difficulty=difficulty, fame=fame)


# ── The run-length encoding ───────────────────────────────────────────────────

def test_consecutive_seasons_at_one_club_collapse_into_one_stint():
    rows = [_row("Drew Brees", "LAC", y) for y in range(2001, 2006)]
    rows += [_row("Drew Brees", "NO", y) for y in range(2006, 2021)]
    stints, unnameable = journeyman.build_stints("nfl", rows, NO_CLUBS)
    assert unnameable == 0
    assert [(s.team_name, s.first_year, s.last_year) for s in stints] == [
        ("Chargers", 2001, 2005), ("Saints", 2006, 2020)]


def test_a_return_spell_is_its_own_stint():
    """The whole point of the format — collapsing these would delete the giveaway."""
    rows = ([_row("P", "LAC", y) for y in (2001, 2002)]
            + [_row("P", "NO", y) for y in (2003, 2004)]
            + [_row("P", "LAC", y) for y in (2005, 2006)])
    stints, _ = journeyman.build_stints("nfl", rows, NO_CLUBS)
    assert [(s.team_abbr, s.first_year) for s in stints] == [("LAC", 2001), ("NO", 2003), ("LAC", 2005)]


def test_a_missed_season_inside_a_spell_does_not_split_it():
    """Peyton Manning missed 2011 with Indianapolis in the middle of nothing — a gap between
    two rows at the SAME club is a missed season, not a transfer."""
    rows = [_row("P", "IND", y) for y in (2008, 2009, 2010, 2012, 2013)]
    stints, _ = journeyman.build_stints("nfl", rows, NO_CLUBS)
    assert len(stints) == 1
    assert (stints[0].first_year, stints[0].last_year) == (2008, 2013)


def test_a_mid_season_trade_puts_the_year_in_both_stints():
    """Ordering the shared season alphabetically would encode SF → NYJ → SF → NYJ and invent a
    return spell; continuity ordering keeps it to the two spells that happened."""
    rows = [_row("P", "SF", 2019), _row("P", "SF", 2020), _row("P", "NYJ", 2020),
            _row("P", "NYJ", 2021)]
    stints, _ = journeyman.build_stints("nfl", rows, NO_CLUBS)
    assert [(s.team_abbr, s.first_year, s.last_year) for s in stints] == [
        ("SF", 2019, 2020), ("NYJ", 2020, 2021)]


def test_a_one_season_stop_between_two_spells_keeps_its_place():
    """A single year at one club, arrived-and-left, still lands between the spells around it."""
    rows = ([_row("P", "SF", y) for y in (2018, 2019)]
            + [_row("P", "NYJ", 2019)]
            + [_row("P", "GB", y) for y in (2020, 2021)])
    stints, _ = journeyman.build_stints("nfl", rows, NO_CLUBS)
    assert [s.team_abbr for s in stints] == ["SF", "NYJ", "GB"]


def test_exhibition_rosters_are_skipped_not_counted_as_unnameable():
    rows = [_row("P", "LAL", y, sport="nba") for y in (2018, 2019)]
    rows.append(_row("P", "LEB", 2019, sport="nba"))       # All-Star roster
    rows += [_row("P", "MIA", y, sport="nba") for y in (2020, 2021)]
    stints, unnameable = journeyman.build_stints("nba", rows, NO_CLUBS)
    assert unnameable == 0
    assert [s.team_abbr for s in stints] == ["LAL", "MIA"]


def test_an_ambiguous_or_empty_club_code_counts_as_unnameable():
    """`nba NO` named the Hornets and now names the Pelicans; an empty abbr names nothing."""
    rows = [_row("P", "NO", 2010, sport="nba"), _row("P", "", 2011, sport="nba")]
    stints, unnameable = journeyman.build_stints("nba", rows, NO_CLUBS)
    assert stints == []
    assert unnameable == 2


def test_soccer_stints_carry_the_country_for_the_crest_lookup():
    rows = [_row("P", "AJA", y, sport="soccer", league="Netherlands") for y in (2015, 2016)]
    stints, _ = journeyman.build_stints("soccer", rows, ClubNames({("AJA", "Netherlands"): "Ajax Amsterdam"}, {"AJA": "Ajax Amsterdam"}))
    assert stints[0].league == "Netherlands"
    assert stints[0].team_name == "Ajax Amsterdam"


# ── The honesty gates ─────────────────────────────────────────────────────────

def test_a_hole_in_the_path_is_rejected():
    """Three missing years between clubs means a spell this pipeline didn't see — the board
    would claim the player went straight from one club to the other."""
    good = [Stint("A", "A", "", 2010, 2013), Stint("B", "B", "", 2014, 2016)]
    holed = [Stint("A", "A", "", 2010, 2013), Stint("B", "B", "", 2017, 2019)]
    assert journeyman.contiguous(good)
    assert not journeyman.contiguous(holed)


def test_one_year_out_of_the_league_is_tolerated():
    assert journeyman.contiguous([Stint("A", "A", "", 2010, 2013), Stint("B", "B", "", 2015, 2016)])


def test_a_career_that_starts_before_coverage_is_rejected():
    stints = [Stint("A", "A", "", 1999, 2003), Stint("B", "B", "", 2004, 2008),
              Stint("C", "C", "", 2009, 2011)]
    assert not journeyman.qualifies("soccer", stints, 0, first_year=1999, floor=2014)
    assert journeyman.qualifies("soccer", stints, 0, first_year=2015, floor=2014)


def test_the_coverage_floor_is_measured_from_the_rows_not_assumed():
    """NFL defensive rows genuinely start in 1999 (0 defenders in 1998, 701 in 1999), so a
    defender who debuted in 1997 would get a board missing his first club entirely. The floor
    is derived so a provider backfill moves it on its own."""
    rows = []
    for year in range(1990, 2011):                       # offense: covered throughout
        rows += [_row(f"WR{i}", "SF", year) for i in range(40)]
        for r in rows[-40:]:
            r["position"] = "WR"
    for year in range(1999, 2011):                       # defense: nothing before 1999
        batch = [_row(f"CB{i}", "SF", year) for i in range(40)]
        for r in batch:
            r["position"] = "CB"
        rows += batch
    floors = journeyman.coverage_floors(rows)
    assert floors["CB"] == 2000                          # first covered year + the margin
    assert floors["WR"] == 1991


def test_a_partly_played_current_season_does_not_anchor_the_floor():
    """Soccer's in-progress season carries a few hundred rows against ~6,000 for a full one;
    treating that as the only covered year would floor everybody out."""
    rows = []
    for year in range(2015, 2027):
        batch = [_row(f"P{i}", "AJA", year, sport="soccer", league="Netherlands")
                 for i in range(100)]
        rows += batch
    rows += [_row(f"P{i}", "AJA", 2027, sport="soccer", league="Netherlands") for i in range(5)]
    assert journeyman.coverage_floors(rows)["QB"] == 2016


def test_a_null_league_row_does_not_split_a_spell():
    """Ronaldo's 2015 Real Madrid season carries no country label; keying the run on it showed
    "Real Madrid → Real Madrid → Real Madrid"."""
    rows = [_row("P", "RMA", 2013, sport="soccer", league="Spain"),
            _row("P", "RMA", 2014, sport="soccer", league="Spain"),
            _row("P", "RMA", 2015, sport="soccer", league=None),
            _row("P", "RMA", 2016, sport="soccer", league="Spain")]
    stints, _ = journeyman.build_stints("soccer", rows, ClubNames({("RMA", "Spain"): "Real Madrid"}, {"RMA": "Real Madrid"}))
    assert len(stints) == 1
    assert (stints[0].first_year, stints[0].last_year) == (2013, 2016)
    assert stints[0].league == "Spain"          # the run keeps the country it does have


def test_one_club_careers_and_unnameable_clubs_are_rejected():
    one = [Stint("A", "A", "", 2010, 2020)]
    assert not journeyman.qualifies("nfl", one, 0, first_year=2010)
    two = one + [Stint("B", "B", "", 2021, 2022)]
    assert journeyman.qualifies("nfl", two, 0, first_year=2010)
    assert not journeyman.qualifies("nfl", two, 1, first_year=2010)


def test_soccer_needs_three_clubs():
    two = [Stint("A", "A", "", 2010, 2013), Stint("B", "B", "", 2014, 2018)]
    assert not journeyman.qualifies("soccer", two, 0, first_year=2010)


def test_long_paths_truncate_to_the_most_recent_clubs():
    stints = [Stint(f"T{i}", f"Team {i}", "", 2000 + i, 2000 + i) for i in range(12)]
    shown, truncated = journeyman.truncate(stints)
    assert truncated
    assert len(shown) == journeyman.MAX_STINTS
    assert shown[-1].team_abbr == "T11"          # the end of the career is what fans remember


# ── Rows ──────────────────────────────────────────────────────────────────────

def test_build_row_matches_the_swift_content_shape():
    row = journeyman.build_row(_entry(canonical="Drew Brees"))
    assert row.format == "journeyman"
    assert row.id == "nfl-drew-brees-journeyman"
    assert row.content["id"] == row.id
    assert row.content["answer"] == {"canonical": "Drew Brees", "aliases": []}
    assert [s["order"] for s in row.content["stints"]] == [1, 2]
    assert row.content["stints"][0] == {"order": 1, "teamAbbr": "LAC", "teamName": "Chargers",
                                        "league": "", "firstYear": 2001, "lastYear": 2005}
    validate.validate(row)


def test_validate_rejects_an_out_of_order_or_repeated_path():
    backwards = journeyman.build_row(_entry(stints=[Stint("NO", "Saints", "", 2006, 2020),
                                                    Stint("LAC", "Chargers", "", 2001, 2005)]))
    with pytest.raises(ValueError, match="starts before"):
        validate.validate(backwards)

    repeated = journeyman.build_row(_entry(stints=[Stint("NO", "Saints", "", 2006, 2010),
                                                   Stint("NO", "Saints", "", 2011, 2020)]))
    with pytest.raises(ValueError, match="same club"):
        validate.validate(repeated)


def test_validate_rejects_a_one_club_board():
    with pytest.raises(ValueError, match="stints"):
        validate.validate(journeyman.build_row(_entry(stints=[Stint("NO", "Saints", "", 2006, 2020)])))


# ── The daily picker ──────────────────────────────────────────────────────────

def _pool():
    return [_entry(canonical=f"Player {i}", difficulty=["easy", "medium", "hard"][i % 3],
                   fame=1 - i / 10) for i in range(9)]


def test_never_served_entries_come_first_then_the_stalest():
    entries = _pool()
    served = {("nfl", entries[0].key): "2026-08-01"}
    pick = daily_journeyman.pick_lrs_entry(entries, served, dt.date(2026, 8, 19), "nfl")
    assert pick.key != entries[0].key

    all_served = {("nfl", e.key): "2026-08-10" for e in entries}
    all_served[("nfl", entries[3].key)] = "2026-01-02"
    pick = daily_journeyman.pick_lrs_entry(entries, all_served, dt.date(2026, 8, 19), "nfl")
    assert pick.key == entries[3].key


def test_the_tier_draw_restricts_the_pool_and_falls_back_when_empty():
    entries = _pool()
    pick = daily_journeyman.pick_lrs_entry(entries, {}, dt.date(2026, 8, 19), "nfl", tier="hard")
    assert pick.difficulty == "hard"
    only_easy = [e for e in entries if e.difficulty == "easy"]
    pick = daily_journeyman.pick_lrs_entry(only_easy, {}, dt.date(2026, 8, 19), "nfl", tier="hard")
    assert pick is not None and pick.difficulty == "easy"


def test_a_multi_day_batch_keeps_rotating():
    """`mint_batch` updates `last_served` as it goes, so day two can't re-pick day one's
    subject — the bug that would make a week of dailies one repeated board."""
    entries = _pool()
    targets = [(dt.date(2026, 8, 19) + dt.timedelta(days=i), "nfl") for i in range(5)]
    minted = daily_journeyman.mint_batch(entries, {}, targets)
    keys = [e.key for _, e, _ in minted]
    assert len(keys) == len(set(keys)) == 5


def test_the_dated_daily_row_is_a_separate_row_from_the_archival_copy():
    entry = _entry(canonical="Drew Brees")
    daily = daily_journeyman._finalize_row(dt.date(2026, 8, 19), entry)
    archival = journeyman.build_row(entry)
    assert daily.id != archival.id
    assert daily.id.endswith("-daily-20260819")
    assert daily.content["id"] == daily.id
    assert daily.active_date == "2026-08-19"
    assert archival.active_date is None
    validate.validate(daily)


def test_tier_draw_is_deterministic_per_day_and_sport():
    day = dt.date(2026, 8, 19)
    assert daily_journeyman.pick_tier(day, "nfl") == daily_journeyman.pick_tier(day, "nfl")
    tiers = {daily_journeyman.pick_tier(day + dt.timedelta(days=i), "nba") for i in range(40)}
    assert tiers == {"easy", "medium", "hard"}


def test_tennis_can_never_get_a_journeyman_daily():
    """Its `team_abbr` is a country code, not a club — see the SPORTS constant."""
    assert "tennis" not in daily_journeyman.SPORTS


# ── Pool file round-trip ──────────────────────────────────────────────────────

def test_pool_entries_round_trip_through_json(tmp_path):
    import json
    path = tmp_path / journeyman.POOL_FILE
    entries = _pool()
    path.write_text(json.dumps([journeyman.entry_to_json(e) for e in entries]), encoding="utf-8")
    loaded = journeyman.load_pool(path)
    assert loaded == entries


def test_select_fills_the_cap_even_when_a_tier_is_thin():
    entries = [_entry(canonical=f"P{i}", difficulty="easy", fame=1 - i / 100) for i in range(20)]
    picked = journeyman.select(entries, cap=10)
    assert len(picked) == 10
    assert picked[0].canonical == "P0"           # best-fame-first within the tier


# ── Era-aware franchise naming ────────────────────────────────────────────────

def test_a_reused_code_is_named_by_the_era_it_was_played_in():
    """The live pool's first draft said "Eddie George — Texans 1996": he played for the Houston
    Oilers, and the Texans didn't exist until 2002."""
    assert journeyman.stint_name("nfl", "HOU", 1996, NO_CLUBS) == ("Oilers", True)
    assert journeyman.stint_name("nfl", "HOU", 2010, NO_CLUBS) == ("Texans", False)
    assert journeyman.stint_name("baseball", "TB", 2005, NO_CLUBS) == ("Devil Rays", True)
    assert journeyman.stint_name("baseball", "TB", 2015, NO_CLUBS) == ("Rays", False)


def test_a_defunct_code_that_was_never_reused_is_not_historical():
    """`SD` still means the Chargers and ESPN still serves its crest — only codes a *different*
    franchise inherited need the crest suppressed."""
    assert journeyman.stint_name("nfl", "SD", 1995, NO_CLUBS) == ("Chargers", False)
    assert journeyman.stint_name("nba", "SEA", 1996, NO_CLUBS) == ("SuperSonics", False)


def test_a_rebrand_splits_one_code_into_the_two_clubs_fans_remember():
    rows = [_row("P", "HOU", 1996)] + [_row("P", "TEN", y) for y in (1997, 1998, 1999, 2000)]
    stints, _ = journeyman.build_stints("nfl", rows, NO_CLUBS)
    assert [(s.team_name, s.first_year, s.last_year) for s in stints] == [
        ("Oilers", 1996, 1998), ("Titans", 1999, 2000)]


def test_one_franchise_spelled_two_ways_stays_one_stint():
    """Charles Woodson's Oakland years arrive as both OAK and LV; keying the run on the code
    showed "Raiders → Raiders", a transfer to the club he was already at."""
    rows = ([_row("P", "OAK", y) for y in (1999, 2000)]
            + [_row("P", "LV", y) for y in (2001, 2002)])
    stints, _ = journeyman.build_stints("nfl", rows, NO_CLUBS)
    assert [(s.team_name, s.first_year, s.last_year) for s in stints] == [("Raiders", 1999, 2002)]


def test_historical_stints_are_flagged_in_the_row_for_the_client():
    entry = _entry(stints=[Stint("HOU", "Oilers", "", 1994, 1996, historical=True),
                           Stint("TEN", "Titans", "", 1999, 2003)])
    content = journeyman.build_row(entry).content
    assert content["stints"][0]["historical"] is True
    assert "historical" not in content["stints"][1]


# ── Soccer club naming is league-qualified ────────────────────────────────────

def test_a_shared_club_code_resolves_by_country_not_by_luck():
    """`DAL` is Deportivo Alavés in Spain and FC Dallas in MLS. The flat code→name map put
    Marcos Llorente at "FC Dallas 2017", a club he has never played for."""
    clubs = ClubNames({("DAL", "Spain"): "Deportivo Alavés", ("DAL", "USA (MLS)"): "FC Dallas"},
                      {})
    assert clubs.name("DAL", "Spain") == "Deportivo Alavés"
    assert clubs.name("DAL", "USA (MLS)") == "FC Dallas"


def test_an_ambiguous_code_with_no_country_is_unnameable():
    """Better to drop the subject than to guess which club a countryless row means."""
    clubs = ClubNames.build([
        {"sport": "soccer", "team_abbr": "DAL", "league": "Spain", "full_name": "Deportivo Alavés"},
        {"sport": "soccer", "team_abbr": "DAL", "league": "USA (MLS)", "full_name": "FC Dallas"},
        {"sport": "soccer", "team_abbr": "AJA", "league": "Netherlands", "full_name": "Ajax Amsterdam"},
    ])
    assert clubs.name("DAL", "") == ""
    assert clubs.name("AJA", "") == "Ajax Amsterdam"      # only one club carries this code


def test_a_soccer_subject_with_an_unnameable_club_is_dropped():
    clubs = ClubNames({("AJA", "Netherlands"): "Ajax Amsterdam"}, {"AJA": "Ajax Amsterdam"})
    rows = ([_row("P", "AJA", y, sport="soccer", league="Netherlands") for y in (2018, 2019)]
            + [_row("P", "DAL", y, sport="soccer", league="Spain") for y in (2020, 2021)])
    stints, unnameable = journeyman.build_stints("soccer", rows, clubs)
    assert unnameable == 2
    assert not journeyman.qualifies("soccer", stints, unnameable, 2018)


def test_soccer_debuts_need_more_clearance_than_us_sports():
    rows = []
    for year in range(2013, 2027):
        batch = [_row(f"P{i}", "AJA", year, sport="soccer", league="Netherlands")
                 for i in range(100)]
        rows += batch
    assert journeyman.coverage_floors(rows, margin=1)["QB"] == 2014
    assert journeyman.coverage_floors(
        rows, margin=journeyman.COVERAGE_MARGIN["soccer"])["QB"] == 2016


def test_a_code_a_famous_club_owns_is_not_handed_to_another_club():
    """`resolve_code` derives "POR" for both FC Porto and Portimonense; the `teams` sweep holds
    Portimonense under it and Porto not at all, so Luis Díaz's three Porto seasons went live as
    "Portimonense 2020-2022". The code is unusable until that's fixed upstream."""
    rows = [{"sport": "soccer", "team_abbr": "POR", "league": "Portugal",
             "full_name": "Portimonense"},
            {"sport": "soccer", "team_abbr": "LIV", "league": "England", "full_name": "Liverpool"},
            {"sport": "soccer", "team_abbr": "AJA", "league": "Netherlands",
             "full_name": "Ajax Amsterdam"}]
    assert journeyman.contested_club_codes(rows) == {("POR", "Portugal")}
    clubs = ClubNames.build(rows)
    assert clubs.name("POR", "Portugal") == ""       # unnameable, so the subject is dropped
    assert clubs.name("LIV", "England") == "Liverpool"


def test_an_uncontested_code_keeps_its_name_even_when_a_curated_club_shares_the_country():
    """The guard must not blanket-ban a country: Liverpool and Ajax are curated clubs sitting on
    their own codes, and dropping those would gut the pool to fix one collision."""
    rows = [{"sport": "soccer", "team_abbr": "LIV", "league": "England", "full_name": "Liverpool"},
            {"sport": "soccer", "team_abbr": "MUN", "league": "England",
             "full_name": "Manchester United"}]
    assert journeyman.contested_club_codes(rows) == set()


# ── Teasers ───────────────────────────────────────────────────────────────────

def _facts(**kw):
    from tools.ingest.models import WhoAmIEntry
    base = dict(sport="nfl", canonical="Test Player", aliases=[], position="Running back",
                first_year=2010, last_year=2018, teams=["Chargers", "Saints"],
                stat_line="8,000 rushing yards", jersey="21", fact="", seasons=9)
    base.update(kw)
    return WhoAmIEntry(**base)


def _stints(*spans):
    return [Stint(f"T{i}", f"Team {i}", "", lo, hi) for i, (lo, hi) in enumerate(spans)]


def test_a_teaser_is_a_fact_plus_a_jab():
    line = journeyman.build_teaser(_facts(), _stints((2010, 2014), (2015, 2018)),
                                   False, seed="test-player")
    # House style: the fact/jab separator is a comma, never an em-dash. A jab is a
    # grammatical continuation, so it stays lowercase after the comma.
    assert ", " in line and line.endswith(".")
    fact, jab = line.rsplit(", ", 1)
    assert fact and jab[0].islower()


def test_the_same_subject_always_gets_the_same_teaser():
    """An archive card that reworded itself on every pool regeneration would churn live content
    for nothing, and a board looked at yesterday should read the same today."""
    args = (_facts(), _stints((2010, 2014), (2015, 2018)), False)
    first = journeyman.build_teaser(*args, seed="stable")
    assert all(journeyman.build_teaser(*args, seed="stable") == first for _ in range(20))


def test_different_subjects_get_different_teasers():
    """The whole reason this moved into the minter: a client-side version can only joke about
    the shape, so 150 boards would share one small pool of lines."""
    lines = {journeyman.build_teaser(_facts(first_year=2000 + i, last_year=2008 + i),
                                     _stints((2000 + i, 2004 + i), (2005 + i, 2008 + i)),
                                     False, seed=f"player-{i}")
             for i in range(30)}
    assert len(lines) > 10


def test_a_teaser_never_uses_a_revealing_dimension():
    """A teaser hints; it must not solve. The dimensions that WOULD solve it — nickname, career
    stat line, draft slot, the teams themselves — all sit above the reveal cut or in the excluded
    family, so a subject carrying every fact still can't have them printed on the card."""
    from tools.ingest import whoami_clues
    rich = _facts(college="LSU", college_conference="SEC", height_in=72, weight_lb=210,
                  birth_year=1988, draft_year=2010, draft_round=1, draft_pick=3,
                  draft_team="Chargers", nickname="The Bus", accolades=["MVP"],
                  best_season={"year": 2014, "team": "Saints", "line": "1,500 yards"})
    lines = {journeyman.build_teaser(rich, _stints((2010, 2014), (2015, 2018)), False,
                                     seed=f"rich-{i}")
             for i in range(60)}
    for line in lines:
        for banned in ("The Bus", "MVP", "1,500", "8,000", "3rd", "Chargers", "Saints"):
            assert banned not in line, line
    # And the cut is a real filter, not an accident of which dimensions happened to fire: each
    # answer-shaped dimension is excluded BY the rule, either for revealing too much or for
    # being the board itself.
    by_key = {d.key: d for d in whoami_clues.DIMENSIONS}
    for key in ("nickname", "statLine", "bestSeason", "draftPick", "teams", "lastTeam"):
        d = by_key[key]
        excluded = d.reveal > journeyman.MAX_TEASER_REVEAL or d.family == "team"
        assert excluded, f"{key} could be printed on an archive card"


def test_a_jab_never_echoes_a_word_from_the_fact():
    """The live pool produced "Put together an 8-season career — with a tidy little career to
    show for it."; one repeated content word is all it takes to read as generated."""
    for shape, jabs in journeyman.TEASER_JABS.items():
        chosen = journeyman.pick_jab("Put together an 8-season career", list(jabs))
        assert "career" not in chosen or all("career" in j for j in jabs), (shape, chosen)


def test_every_shape_has_jabs_and_is_reachable():
    assert journeyman.teaser_shape(_stints(*[(2000 + i, 2000 + i) for i in range(6)]), False) == "journeyman"
    assert journeyman.teaser_shape(_stints((2000, 2012), (2013, 2015)), False) == "loyal"
    assert journeyman.teaser_shape(_stints((2000, 2002), (2003, 2005), (2006, 2008), (2009, 2011)), False) == "wanderer"
    assert journeyman.teaser_shape(_stints((2000, 2002), (2003, 2005)), True) == "truncated"
    assert journeyman.teaser_shape(_stints((2000, 2000), (2001, 2001), (2002, 2004)), False) == "brief"
    assert journeyman.teaser_shape(_stints((2000, 2003), (2004, 2007)), False) == "oneMove"
    assert journeyman.teaser_shape(_stints((2000, 2002), (2003, 2005), (2006, 2008)), False) == "short"
    assert set(journeyman.TEASER_JABS) >= {"journeyman", "loyal", "wanderer", "truncated",
                                           "brief", "short", "oneMove", "return"}


def test_only_a_two_club_career_may_claim_one_move():
    """"Made the one move count" was landing on three-club careers, which is two moves."""
    for shape, jabs in journeyman.TEASER_JABS.items():
        if shape == "oneMove":
            continue
        assert not any("one move" in j for j in jabs), shape


def test_a_returning_career_is_detected_by_club_name():
    stints = [Stint("A", "Raiders", "", 2000, 2002), Stint("B", "Packers", "", 2003, 2005),
              Stint("C", "Raiders", "", 2006, 2008)]
    assert journeyman.teaser_shape(stints, False) == "return"


def test_the_teaser_is_leak_checked_before_upsert():
    entry = _entry(canonical="Drew Brees")
    entry.teaser = "Played from 2001 to 2020 — and Brees never finished a lease."
    with pytest.raises(ValueError, match="leaks"):
        validate.validate(journeyman.build_row(entry))


def test_a_teaser_fits_the_card():
    """The card's title is two-ish lines of condensed black; the first draft produced a 96-char
    line, which is four lines of card for one gag."""
    facts = ["Broke in during the 1970s and last played in 1993", "Pitcher", "Debuted in 1974"]
    line = journeyman.fit(facts, list(journeyman.TEASER_JABS["brief"]), __import__("random").Random(0))
    assert len(line) <= journeyman.MAX_TEASER_CHARS, line


def test_a_teaser_spends_its_budget_on_the_longest_fact_that_fits():
    """Capping length must not collapse every card to "Pitcher — …": the point of the cap is to
    fit the card, not to throw away the most informative hint."""
    facts = ["Pitcher", "Debuted in 1974"]
    line = journeyman.fit(facts, ["and hardly a nomad"], __import__("random").Random(0))
    assert line.startswith("Debuted in 1974")


def test_an_unfittable_teaser_falls_back_to_the_shortest_rather_than_nothing():
    facts = ["A" * 200]
    line = journeyman.fit(facts, ["and hardly a nomad"], __import__("random").Random(0))
    assert line.endswith("and hardly a nomad.")


# ── Hints ─────────────────────────────────────────────────────────────────────

def _rich_facts(**kw):
    """A subject with every dimension populated, so the hint draw has the full space."""
    base = dict(college="Purdue", college_conference="Big Ten Conference", height_in=72,
                weight_lb=209, birth_year=1979, draft_year=2001, draft_round=2,
                draft_pick=32, draft_team="Chargers", nickname="Cool Brees",
                accolades=["Super Bowl MVP"], nationality="United States",
                best_season={"year": 2011, "team": "Saints", "line": "5,476 yards"},
                fame=0.9)
    base.update(kw)
    return _facts(**base)


def test_hints_climb_from_broad_to_specific():
    hints = journeyman.build_hints(_rich_facts(), seed="drew-brees")
    assert len(hints) == journeyman.HINT_COUNT
    assert [h.order for h in hints] == [1, 2, 3]
    by_dimension = {d.key: d for d in __import__(
        "tools.ingest.whoami_clues", fromlist=["DIMENSIONS"]).DIMENSIONS}
    reveals = [by_dimension[h.dimension].reveal for h in hints]
    assert reveals == sorted(reveals), reveals
    # A ladder, not three flavors of the same angle. A spread across families is a preference
    # (a thin subject may have to double up rather than drop a rung), a distinct dimension per
    # rung is not.
    assert len({h.dimension for h in hints}) == len(hints)
    assert len({by_dimension[h.dimension].family for h in hints}) >= 2


def test_a_hint_is_never_something_the_board_already_shows():
    """The career path is on screen the whole time — a hint that restates it takes points for
    information the player is looking at. Both halves: the club list AND the year span, which
    is arithmetic on the first and last cards ("debuted in 2010" for a board whose top row
    reads 2010-2014)."""
    for seed in [f"subject-{i}" for i in range(40)]:
        hints = journeyman.build_hints(_rich_facts(), seed=seed)
        for h in hints:
            assert h.dimension not in journeyman._HINT_EXCLUDED_DIMENSIONS, h
    assert {"teams", "firstTeam", "lastTeam", "league", "era", "debut", "finale",
            "longevity"} <= journeyman._HINT_EXCLUDED_DIMENSIONS


def test_the_same_subject_always_gets_the_same_hints():
    args = (_rich_facts(),)
    first = journeyman.build_hints(*args, seed="stable")
    assert all(journeyman.build_hints(*args, seed="stable") == first for _ in range(20))


def test_a_hint_never_gives_away_the_name():
    leaky = _rich_facts(canonical="Drew Brees", nickname="Brees", fact="Brees threw for 5,476")
    hints = journeyman.build_hints(leaky, seed="drew-brees")
    assert hints
    assert all("brees" not in h.text.lower() for h in hints), hints


def test_a_hint_never_repeats_the_free_teaser():
    facts = _rich_facts()
    teaser = journeyman.build_teaser(facts, _stints((2010, 2014), (2015, 2018)), False,
                                     seed="drew-brees")
    hints = journeyman.build_hints(facts, seed="drew-brees", teaser=teaser)
    assert all(h.text not in teaser for h in hints), (teaser, hints)


def test_a_thin_subject_gets_fewer_hints_rather_than_invented_ones():
    """Only NFL has a bio provider. A soccer or F1 subject draws from the catalog dimensions
    alone, and the honest answer is a shorter ladder."""
    thin = _facts(sport="soccer", position="Midfielder", jersey="", fact="", stat_line="")
    hints = journeyman.build_hints(thin, seed="thin")
    assert 0 < len(hints) <= journeyman.HINT_COUNT
    assert [h.order for h in hints] == list(range(1, len(hints) + 1))


def test_hints_ride_the_row_and_are_leak_checked_before_upsert():
    entry = _entry(canonical="Drew Brees")
    entry.hints = journeyman.build_hints(_rich_facts(), seed="drew-brees")
    row = journeyman.build_row(entry)
    assert row.content["hints"][0]["order"] == 1
    assert set(row.content["hints"][0]) == {"order", "label", "text", "dimension"}
    validate.validate(row)

    entry.hints = [journeyman.Hint(order=1, label="Nickname", text="Known as Brees",
                                   dimension="nickname")]
    with pytest.raises(ValueError, match="leaks"):
        validate.validate(journeyman.build_row(entry))


def test_hints_round_trip_through_the_pool_file(tmp_path):
    entry = _entry(canonical="Drew Brees")
    entry.hints = journeyman.build_hints(_rich_facts(), seed="drew-brees")
    path = tmp_path / journeyman.POOL_FILE
    path.write_text(__import__("json").dumps([journeyman.entry_to_json(entry)]))
    assert journeyman.load_pool(path)[0].hints == entry.hints


# ── The person join ───────────────────────────────────────────────────────────

def _jrow(team, year, position, person_id):
    """A catalog row for one of the two real NFL players named David Johnson."""
    return {"name": "David Johnson", "team_abbr": team, "season_year": year, "sport": "nfl",
            "position": position, "league": None, "headshot": _STORE_SHOT,
            "stats": {"carries": 100.0}, "career": False, "person_id": person_id}


_TE, _RB = "00-0027265", "00-0032187"
_BOTH_JOHNSONS = (
    [_jrow("PIT", y, "TE", _TE) for y in (2009, 2010, 2011, 2012, 2013)]
    + [_jrow("LAC", 2014, "TE", _TE), _jrow("PIT", 2016, "TE", _TE)]
    + [_jrow(t, y, "RB", _RB) for y, t in
       [(2015, "ARI"), (2016, "ARI"), (2017, "ARI"), (2018, "ARI"), (2019, "ARI"),
        (2020, "HOU"), (2021, "HOU"), (2022, "NO")]]
)


def _path_for(person_id):
    rows = [r for r in _BOTH_JOHNSONS
            if whoami_pool.person_key(r) == f"nfl:{person_id}"]
    stints, _ = journeyman.build_stints("nfl", rows, NO_CLUBS)
    return [s.team_name for s in stints]


def test_a_shared_name_does_not_weld_two_careers_into_one_path():
    # The exact board that shipped on 2026-08-29: seven clubs, in the order a chronological
    # merge of two men produces. Neither David Johnson ever had this career.
    merged, _ = journeyman.build_stints("nfl", _BOTH_JOHNSONS, NO_CLUBS)
    assert [s.team_name for s in merged] == [
        "Steelers", "Chargers", "Cardinals", "Steelers", "Cardinals", "Texans", "Saints"]

    # Grouped by person — which is what `build_entries` now does — each path is a real one.
    assert _path_for(_RB) == ["Cardinals", "Texans", "Saints"]
    assert _path_for(_TE) == ["Steelers", "Chargers", "Steelers"]


def test_person_key_falls_back_to_the_name_for_rows_with_no_provider_id():
    # Sweeps with no upstream id must still group, and must group the same way the ingest
    # side does (`RawSeason.person`) or the two grains stop joining entirely.
    anonymous = {"name": "Old Timer", "sport": "nfl", "person_id": None}
    assert whoami_pool.person_key(anonymous) == "nfl:name:old-timer"
    assert whoami_pool.person_key({**anonymous, "person_id": ""}) == "nfl:name:old-timer"
    assert whoami_pool.person_key({**anonymous, "person_id": "x1"}) == "nfl:x1"


def test_person_key_is_sport_scoped():
    # Two ids could collide across providers; the sport prefix is what keeps NFL gsis ids and
    # NBA athlete ids in separate namespaces.
    nfl = {"name": "A B", "sport": "nfl", "person_id": "123"}
    assert whoami_pool.person_key(nfl) != whoami_pool.person_key({**nfl, "sport": "nba"})


# ── The saved pool is what actually publishes ─────────────────────────────────
#
# `daily_journeyman` reads `data/journeyman_pool.json` and rotates through it. It does not
# rebuild a career from the catalog, so an identity fix upstream reaches the wire only when the
# pool file is regenerated. That gap is why the 2026-09-06 repair — which corrected live puzzle
# rows and fixed `build_candidates` — left two merged-person careers sitting in the pool, one
# mint away from being published again.

# The two the repair missed, pinned by the PATH each was minting rather than by name. The name
# is the wrong key: the live catalog holds one career row per name, keyed to one of the two
# person ids (verified 2026-09-11 — Derrick Johnson splits into DB `00-0023637` and LB
# `00-0023449`, C.J. Mosley into DT `00-0023624` and ILB `00-0031296`), so `qualify`'s
# shared-name rule never sees a duplicate and each name legitimately returns to the pool once
# the person key has separated the two men. What may never return is the welded path.
KNOWN_MERGED_PATHS = {
    # The Chiefs linebacker was drafted by Kansas City and never played for San Francisco or
    # Atlanta; those two seasons belong to a defensive back of the same name.
    ("nfl", "Derrick Johnson"): ["SF", "ATL", "KC", "LV"],
    # A defensive tackle (2005-2013) and a linebacker drafted nine years after him, end to end.
    ("nfl", "C.J. Mosley"): ["MIN", "NYJ", "CLE", "JAX", "DET", "BAL", "NYJ"],
}


def _saved_pool():
    from tools.ingest import main as ingest_main
    return journeyman.load_pool(ingest_main.DATA_DIR / journeyman.POOL_FILE)


def test_the_saved_pool_mints_none_of_the_known_merged_paths():
    """The file, not the generator. Fixing `build_candidates` and correcting the live puzzle rows
    both left this untouched, and this is the copy the nightly mint actually reads."""
    for entry in _saved_pool():
        expected = KNOWN_MERGED_PATHS.get((entry.sport, entry.canonical))
        if expected is None:
            continue
        assert [s.team_abbr for s in entry.stints] != expected, (
            f"{entry.canonical} is back in data/{journeyman.POOL_FILE} with the merged path "
            f"{expected}. That is two different players welded into one career — regenerate "
            "the pool from the person-keyed catalog rather than re-adding it.")


def test_a_merged_career_is_invisible_to_the_plausibility_heuristic():
    """Why provenance, and not another span check: both merges are dense and well inside
    `MAX_CAREER_SPAN`. This is the adjacent case that comment already concedes it cannot see."""
    for first, last, seasons in ((2005, 2018, 14), (2005, 2024, 20)):
        c = whoami_pool.Candidate(
            name="x", sport="nfl", person="nfl:1", position="LB", cohort_key="nfl|lb",
            first_year=first, last_year=last, seasons=seasons, teams=[], unnamed_teams=0,
            nationality="", leagues=set(), career_stats={}, best={}, active=False,
            score=0.0, peak_score=0.0, has_headshot=True)
        assert c.plausible_career, "the span/density gate would have caught this one"


def test_an_entry_carries_the_person_key_it_was_built_from():
    """Provenance has to come off the candidate the entry was assembled from, not be stamped on
    afterwards — otherwise it records nothing about how the career was actually joined."""
    subject = "00-0000001"
    # A second player at the same position, starting earlier: `coverage_floors` needs a covered
    # year before the subject's debut, or the subject is rejected as a career that began before
    # the catalog can describe it.
    seasons = [_row("Filler Guy", "SEA", y) for y in range(2000, 2021)]
    seasons += [{**_row("Real Subject", "LAC", y), "person_id": subject}
                for y in range(2005, 2011)]
    seasons += [{**_row("Real Subject", "NO", y), "person_id": subject}
                for y in range(2011, 2016)]
    career = [{"name": "Real Subject", "sport": "nfl", "position": "QB", "person_id": subject,
               "season_year": 2005, "first_year": 2005, "last_year": 2015, "career": True,
               "headshot": _STORE_SHOT, "stats": {"passing_yards": 40000.0}}]

    entries = journeyman.build_entries(career, seasons, NO_CLUBS, sport="nfl")
    assert [e.canonical for e in entries] == ["Real Subject"]
    assert entries[0].person == f"nfl:{subject}"
    journeyman.assert_person_keyed(entries, context="test")


def test_the_person_key_survives_the_pool_file(tmp_path):
    """Provenance is only worth anything if it is what gets written and read back."""
    path = tmp_path / journeyman.POOL_FILE
    entry = _entry()
    entry.person = "nfl:00-0032187"
    path.write_text(json.dumps([journeyman.entry_to_json(entry)]), encoding="utf-8")
    assert journeyman.load_pool(path)[0].person == "nfl:00-0032187"


def test_an_older_pool_file_still_loads_but_cannot_be_published():
    """Loading and publishing are deliberately different answers: you have to be able to read a
    stale pool to find out that it is stale."""
    stale = _entry(canonical="No Provenance")
    assert stale.person == ""
    assert journeyman.unverified([stale]) == [stale]
    with pytest.raises(journeyman.StalePoolError) as err:
        journeyman.assert_person_keyed([stale], context="test")
    assert "No Provenance" in str(err.value)
    assert "--write" in str(err.value), "the error has to say how to fix it"


def test_a_provenanced_pool_publishes():
    ok = _entry()
    ok.person = "nfl:00-0032187"
    journeyman.assert_person_keyed([ok], context="test")


def test_the_bundle_refuses_a_stale_pool():
    """The bundle is the publish a later regeneration can never correct — it is frozen into a
    shipped binary."""
    with pytest.raises(journeyman.StalePoolError):
        journeyman._write_bundle([_entry()])


def test_the_daily_mint_refuses_to_upsert_a_stale_pool(monkeypatch, capsys):
    monkeypatch.setattr(journeyman, "all_entries", lambda _: [_entry()])
    monkeypatch.setattr(daily_journeyman.ingest_main, "load_dotenv", lambda: None)
    monkeypatch.setattr("sys.argv", ["daily_journeyman", "--upsert"])
    with pytest.raises(journeyman.StalePoolError):
        daily_journeyman.main()


def test_a_dry_run_warns_about_a_stale_pool_rather_than_failing(monkeypatch, capsys):
    """A dry run publishes nothing, and refusing to print the pool would hide the very thing an
    operator is looking at it to check."""
    monkeypatch.setattr(journeyman, "all_entries", lambda _: [_entry()])
    monkeypatch.setattr(daily_journeyman.ingest_main, "load_dotenv", lambda: None)
    monkeypatch.setattr("sys.argv", ["daily_journeyman", "--dry-run"])
    daily_journeyman.main()
    assert "WARNING" in capsys.readouterr().out


def test_the_saved_pool_is_person_keyed_and_therefore_publishable():
    """The other half of the guard: it is not enough that the two bad boards are gone, the pool
    has to carry the provenance that proves how every career in it was assembled — otherwise the
    mint refuses it and there is no daily at all."""
    journeyman.assert_person_keyed(_saved_pool(), context="the checked-in pool")


def test_a_name_fallback_entry_is_reported_as_residual_risk(capsys):
    """Provenance is not a clean bill of health. Sweeps with no upstream id fall back to a name
    key, which groups careers exactly the way the merged ones were grouped, so a publish has to
    say how much of the pool is in that state rather than implying none of it is."""
    risky = _entry(sport="soccer", canonical="No Provider Id")
    risky.person = "soccer:name:no-provider-id"
    assert journeyman.name_keyed([risky]) == [risky]
    journeyman.report_residual_merge_risk([risky], context="test")
    out = capsys.readouterr().out
    assert "grouped by NAME" in out and "soccer" in out


def test_an_entry_keyed_on_a_provider_id_is_not_reported(capsys):
    solid = _entry()
    solid.person = "nfl:00-0032187"
    assert journeyman.name_keyed([solid]) == []
    journeyman.report_residual_merge_risk([solid], context="test")
    assert capsys.readouterr().out == ""
