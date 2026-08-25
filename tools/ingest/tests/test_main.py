"""Tests for main.py's catalog assembly. Season, career, AND single-game rows all reach
the catalog — every grain is creatable in the app."""
import datetime as dt
from unittest.mock import patch

from tools.ingest import main

from tools.ingest.main import catalog_rows, filter_new_catalog_rows, merge_nfl_bio
from tools.ingest.models import RawSeason


def _season(name, **kw):
    base = dict(name=name, team_abbr="X", season_year=2015, sport="nfl",
                position="WR", stats={"receiving_yards": 1000.0})
    base.update(kw)
    return RawSeason(**base)


def test_catalog_includes_game_grain_rows():
    # Single-game rows reach the catalog too (as of the single-game-creation change) —
    # a puzzle is a puzzle regardless of grain, so search needs a real single-game pool.
    rows = [
        _season("Season Guy"),
        _season("Game Guy", week=12, opponent="DEN", game_date="Nov 24"),
    ]
    out = catalog_rows(rows)
    by_name = {r["name"]: r for r in out}
    assert set(by_name) == {"Season Guy", "Game Guy"}
    assert by_name["Season Guy"]["week"] is None
    assert by_name["Season Guy"]["opponent"] is None
    assert by_name["Season Guy"]["game_date"] is None
    assert by_name["Game Guy"]["week"] == 12
    assert by_name["Game Guy"]["opponent"] == "DEN"
    assert by_name["Game Guy"]["game_date"] == "Nov 24"


def test_catalog_includes_career_grain_rows():
    # M17: career creation needs a real career pool to search, so career rows now reach
    # the catalog alongside season rows — flagged via "career" so the client can scope a
    # career template's search to career-only (never mixing season + career in one pool).
    rows = [
        _season("Season Guy"),
        _season("Career Guy", career=True, meta={"first_year": "2015", "last_year": "2023"}),
    ]
    out = catalog_rows(rows)
    by_name = {r["name"]: r for r in out}
    assert set(by_name) == {"Season Guy", "Career Guy"}
    assert by_name["Season Guy"]["career"] is False
    assert by_name["Season Guy"]["first_year"] is None
    assert by_name["Career Guy"]["career"] is True
    assert by_name["Career Guy"]["first_year"] == 2015
    assert by_name["Career Guy"]["last_year"] == 2023


def test_catalog_carries_headshot_through():
    rows = [_season("Headshot Guy", headshot="https://example.com/p.jpg")]
    out = catalog_rows(rows)
    assert out[0]["headshot"] == "https://example.com/p.jpg"


def test_catalog_carries_league_through_when_present_in_meta():
    # Only espn_soccer.py populates meta["league"]; other providers never set it.
    rows = [
        _season("Prem Guy", sport="soccer", position="MF", meta={"league": "England"}),
        _season("No League Guy", sport="soccer", position="MF"),
    ]
    out = catalog_rows(rows)
    by_name = {r["name"]: r for r in out}
    assert by_name["Prem Guy"]["league"] == "England"
    assert by_name["No League Guy"]["league"] is None


def test_catalog_does_not_collide_same_name_across_sports():
    # Regression for the live bug (found 2026-07-14): NFL RB Chris Johnson's real 2009
    # season (2,006 rushing yards) was silently overwritten in Supabase by MLB Chris
    # Johnson's 2009 Astros season — both hashed to the bare id "chris-johnson-2009"
    # before `RawSeason.player_id` was sport-prefixed. Same name, same year, different
    # sport must now produce two distinct catalog rows, not one clobbering the other.
    rows = [
        _season("Chris Johnson", sport="nfl", position="RB",
                stats={"rushing_yards": 2006.0}),
        _season("Chris Johnson", sport="baseball", position="H",
                stats={"hits": 180.0}),
    ]
    out = catalog_rows(rows)
    assert len(out) == 2
    ids = {r["id"] for r in out}
    assert ids == {"nfl-chris-johnson-2015", "baseball-chris-johnson-2015"}
    by_sport = {r["sport"]: r for r in out}
    assert by_sport["nfl"]["stats"]["rushing_yards"] == 2006.0
    assert by_sport["baseball"]["stats"]["hits"] == 180.0


def test_merge_nfl_bio_backfills_missing_headshot_from_registry():
    # Reproduces the real-world gap: a legend's season row has no headshot_url (common for
    # older/retired seasons), but the all-time players.csv registry has one.
    legend = _season("Priest Holmes", headshot="", meta={"gsis_id": "00-0007661"})
    with patch("tools.ingest.main.nfl_players.load_bio", return_value={
        "00-0007661": {"headshot": "https://static.www.nfl.com/legends/priest-holmes.png",
                       "college": "Texas"},
    }):
        merge_nfl_bio([legend])
    assert legend.headshot == "https://static.www.nfl.com/legends/priest-holmes.png"
    assert legend.meta["college"] == "Texas"
    assert "headshot" not in legend.meta   # popped — it's a fallback URL, not a filter dimension


def test_merge_nfl_bio_does_not_override_an_existing_headshot():
    current = _season("Active Guy", headshot="https://cdn.example/current.png",
                       meta={"gsis_id": "00-0000001"})
    with patch("tools.ingest.main.nfl_players.load_bio", return_value={
        "00-0000001": {"headshot": "https://static.www.nfl.com/stale.png"},
    }):
        merge_nfl_bio([current])
    assert current.headshot == "https://cdn.example/current.png"


def test_filter_new_catalog_rows_treats_game_rows_as_always_skippable():
    # A single-game row from THIS year's in-progress season must still be treated as
    # "closed" (skip-eligible once stored) — unlike a season aggregate for the current
    # year, a final box score never changes after the fact.
    import datetime as dt

    current_year = dt.date.today().year
    rows = catalog_rows([
        _season("Current Season Guy", season_year=current_year, sport="nfl"),
        _season("Current Game Guy", season_year=current_year, sport="nfl", week=3, opponent="KC"),
    ])
    with patch("tools.ingest.upsert.fetch_existing_catalog_ids",
               return_value={f"nfl-current-game-guy-{current_year}-wk03"}), \
         patch("tools.ingest.upsert.fetch_catalog_ids_missing", return_value=set()):
        out = filter_new_catalog_rows(rows)
    names = {r["name"] for r in out}
    # The season row is always resent (current year, still growing); the game row was
    # already stored, so it's skipped even though it shares the same in-progress year.
    assert names == {"Current Season Guy"}


def test_filter_new_catalog_rows_resends_a_stored_row_missing_its_competition():
    # The 2026-07-26 case: ~75k soccer rows were stored from a CSV that predated the
    # `competition` column, so they sat unfilterable. A closed season is normally skipped
    # forever once stored — this is what lets the relabel actually reach the DB.
    rows = catalog_rows([
        _season("Labelled Guy", sport="soccer", season_year=2019, position="MF",
                meta={"league": "Germany", "competition": "ger.1"}),
    ])
    stored = {"soccer-labelled-guy-2019"}
    with patch("tools.ingest.upsert.fetch_existing_catalog_ids", return_value=stored), \
         patch("tools.ingest.upsert.fetch_catalog_ids_missing", return_value=stored):
        out = filter_new_catalog_rows(rows)
    assert {r["name"] for r in out} == {"Labelled Guy"}


def test_filter_new_catalog_rows_still_skips_a_stored_row_that_is_already_complete():
    rows = catalog_rows([
        _season("Complete Guy", sport="soccer", season_year=2019, position="MF",
                meta={"league": "Germany", "competition": "ger.1"}),
    ])
    stored = {"soccer-complete-guy-2019"}
    with patch("tools.ingest.upsert.fetch_existing_catalog_ids", return_value=stored), \
         patch("tools.ingest.upsert.fetch_catalog_ids_missing", return_value=set()):
        out = filter_new_catalog_rows(rows)
    assert out == []


def test_filter_new_catalog_rows_never_queries_a_column_no_row_can_fill():
    # NFL rows carry no competition, so the pipeline must not pay for (or depend on) a
    # missing-competition fetch that would match every NFL row in the table.
    rows = catalog_rows([_season("Plain Guy", season_year=2015, sport="nfl")])
    queried: list[str] = []

    def _record(sport, column, *a, **kw):
        queried.append(column)
        return set()

    with patch("tools.ingest.upsert.fetch_existing_catalog_ids", return_value=set()), \
         patch("tools.ingest.upsert.fetch_catalog_ids_missing", side_effect=_record):
        filter_new_catalog_rows(rows)
    assert queried == []


# ── Archival active_date stamping ────────────────────────────────────────────────

def test_assign_active_dates_never_lands_on_a_day_a_device_could_call_today():
    """Archival stamping must clear today AND yesterday.

    Device offsets span UTC-12…UTC+14, so the moment the runner's clock rolls over, devices
    to its west are still on the previous calendar day. At the old offset-1 the archive row
    landed on that live "today" — and `RemotePuzzleRepository.pick` takes the FIRST row whose
    active_date matches, over a pool ordered by id, so a stable pool row (`…-00`) beat the
    day's real mint (`…-daily-20260817`) and was served as the daily under a TODAY badge.
    """
    from tools.ingest.assemble import PuzzleRow
    rows = [PuzzleRow(id=f"r{i}", sport="nfl", format="keep4", content={}) for i in range(90)]
    main.assign_active_dates(rows, backfill_days=30)
    today = dt.date.today()
    stamped = {row.active_date for row in rows}
    assert today.isoformat() not in stamped
    assert (today - dt.timedelta(days=1)).isoformat() not in stamped
    # Still a contiguous 30-day archive window, just shifted back off the live days.
    assert stamped == {(today - dt.timedelta(days=d)).isoformat() for d in range(2, 32)}


# --- headshot ledger ------------------------------------------------------------------
# Regression cover for the 2026-08-25 finding: 46,936 NFL rows (35% of the sport) were
# hotlinked back to the league's faceless-helmet graphic despite 83,580 already being
# rehosted, because the ingest pipeline wrote raw CDN URLs over a cleanup pass that only
# ever ran afterwards.

_HELMET = "https://static.www.nfl.com/image/private/f_auto,q_auto/league/gk8uzafftvq11sz4f2gn"
_REAL = "https://static.www.nfl.com/image/upload/f_auto,q_auto/league/realphoto"
_STORAGE = "https://x.supabase.co/storage/v1/object/public/player-headshots/nfl/real.png"
_LEDGER = {_HELMET: "", _REAL: _STORAGE}


def test_apply_headshot_ledger_clears_placeholders_and_repoints_real_photos():
    rows = catalog_rows([
        _season("Helmet Guy", season_year=2015, headshot=_HELMET),
        _season("Real Guy", season_year=2016, headshot=_REAL),
        _season("Unknown Guy", season_year=2017, headshot="https://cdn.example/new.png"),
    ])
    counts = main.apply_headshot_ledger(rows, ledger=_LEDGER)

    by_name = {r["name"]: r for r in rows}
    assert by_name["Helmet Guy"]["headshot"] == ""          # -> initials monogram
    assert by_name["Real Guy"]["headshot"] == _STORAGE
    # Never seen before: left alone rather than guessed at.
    assert by_name["Unknown Guy"]["headshot"] == "https://cdn.example/new.png"
    assert counts == {"repointed": 1, "cleared": 1, "unknown": 1}


def test_ledger_cleared_row_is_not_then_resent_as_improvable():
    # The actual regression loop. A repointed placeholder is stored as '', which
    # `fetch_catalog_ids_missing` reports as *missing*, so the filter used to call the row
    # "improvable" and hand the helmet URL straight back. Applying the ledger FIRST makes
    # the row's headshot falsy, so it is no longer fillable and drops out of the resend.
    rows = catalog_rows([_season("Helmet Guy", season_year=2015, headshot=_HELMET)])
    stored = {"nfl-helmet-guy-2015"}

    main.apply_headshot_ledger(rows, ledger=_LEDGER)
    with patch("tools.ingest.upsert.fetch_existing_catalog_ids", return_value=stored), \
         patch("tools.ingest.upsert.fetch_catalog_ids_missing", return_value=stored):
        out = filter_new_catalog_rows(rows)

    assert out == [], "a ledger-cleared placeholder must not be resent to the catalog"


def test_ledger_applied_after_the_filter_would_still_resend_the_helmet():
    # Guards the ordering itself: same inputs, wrong order, bug reappears. If this ever
    # starts failing, the call in main() has been moved below filter_new_catalog_rows().
    rows = catalog_rows([_season("Helmet Guy", season_year=2015, headshot=_HELMET)])
    stored = {"nfl-helmet-guy-2015"}

    with patch("tools.ingest.upsert.fetch_existing_catalog_ids", return_value=stored), \
         patch("tools.ingest.upsert.fetch_catalog_ids_missing", return_value=stored):
        out = filter_new_catalog_rows(rows)

    assert len(out) == 1 and out[0]["headshot"] == _HELMET
