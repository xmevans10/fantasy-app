"""Tests for the daily Who Am I? picker (pure — no network, no Supabase)."""
import datetime as dt

from tools.ingest.daily_whoami import mint_batch, pick_lrs_entry, player_key
from tools.ingest.models import WhoAmIEntry

TODAY = dt.date(2026, 1, 1)


def _entry(canonical: str, sport: str = "nfl") -> WhoAmIEntry:
    return WhoAmIEntry(sport=sport, canonical=canonical, aliases=[], position="WR",
                       first_year=2000, last_year=2010, teams=["SF"],
                       stat_line="1,000 yards", jersey="80", fact=f"Fact about {canonical}")


def test_pick_prefers_a_never_served_entry_over_any_served_one():
    entries = [_entry("Served Player"), _entry("Fresh Player")]
    last_served = {("nfl", player_key(entries[0])): "2025-12-31"}
    pick = pick_lrs_entry(entries, last_served, TODAY, "nfl")
    assert pick.canonical == "Fresh Player"


def test_pick_prefers_the_least_recently_served_once_all_have_cycled():
    entries = [_entry("Recent"), _entry("Stale"), _entry("Stalest")]
    last_served = {
        ("nfl", player_key(entries[0])): "2025-12-30",
        ("nfl", player_key(entries[1])): "2025-12-01",
        ("nfl", player_key(entries[2])): "2025-11-01",
    }
    pick = pick_lrs_entry(entries, last_served, TODAY, "nfl")
    assert pick.canonical == "Stalest"


def test_pick_is_deterministic_for_the_same_date_and_sport():
    entries = [_entry(f"Player {i}") for i in range(20)]
    a = pick_lrs_entry(entries, {}, TODAY, "nfl")
    b = pick_lrs_entry(entries, {}, TODAY, "nfl")
    assert a.canonical == b.canonical


def test_pick_only_considers_the_requested_sport():
    entries = [_entry("Football Player", sport="nfl"), _entry("Hoops Player", sport="nba")]
    pick = pick_lrs_entry(entries, {}, TODAY, "nba")
    assert pick.canonical == "Hoops Player"


def test_pick_returns_none_for_a_sport_with_no_entries():
    assert pick_lrs_entry([_entry("Someone", sport="nfl")], {}, TODAY, "tennis") is None


def test_mint_batch_rotates_within_a_batch_instead_of_repicking_the_stalest():
    entries = [_entry(f"Player {i}") for i in range(3)]
    dates = [TODAY + dt.timedelta(days=i) for i in range(3)]
    minted = mint_batch(entries, {}, [(d, "nfl") for d in dates])
    picked = [entry.canonical for _, entry, _ in minted]
    assert len(minted) == 3
    assert len(set(picked)) == 3   # a 3-day batch over a 3-entry pool uses each exactly once


def test_mint_batch_cycles_gracefully_when_the_pool_is_smaller_than_the_batch():
    entries = [_entry("Only A"), _entry("Only B")]
    dates = [TODAY + dt.timedelta(days=i) for i in range(5)]
    minted = mint_batch(entries, {}, [(d, "nfl") for d in dates])
    assert len(minted) == 5   # never hard-fails on exhaustion, unlike Keep4's novelty gate
    picked = [entry.canonical for _, entry, _ in minted]
    # No entry repeats before every other entry has been served (true LRS rotation).
    assert picked[0] != picked[1] and picked[2] != picked[3]


def test_minted_row_is_dated_and_id_suffixed_without_touching_the_archival_id_stem():
    minted = mint_batch([_entry("Jerry Rice")], {}, [(TODAY, "nfl")])
    _, entry, row = minted[0]
    assert row.active_date == "2026-01-01"
    assert row.id == "nfl-whoami-jerry-rice-daily-20260101"
    assert row.content["id"] == row.id
    assert row.format == "whoami"
