"""ESPN full-squad soccer sweep tests — pure aggregation over the module's per-match
box-score row shape (position bucketing/resolution + season totals with the
goals-conceded-derived clean-sheet count), no network, no pandas, no mocking."""
import csv

from tools.ingest.providers import club_codes, espn_soccer
from tools.ingest.providers.espn_soccer import (
    CSV_FIELDS, TEAM_IDENTITY_FIELDS, _aggregate_rows, _build_team_identity,
    _bucket_position, _resolve_positions, merge_csvs)


def _row(player, team="Inter Miami CF", season=2024, position="Forward",
         appearances=1, goals=0, assists=0, conceded=None, league="usa.1"):
    return {"player": player, "team": team, "season_end_year": season,
            "position": position, "appearances": appearances,
            "total_goals": goals, "goal_assists": assists,
            "goals_conceded": conceded, "league": league}


def test_bucket_position_maps_real_espn_labels_to_the_sport_convention():
    assert _bucket_position("Center Right Defender") == "DF"
    assert _bucket_position("Attacking Midfielder Right") == "MF"
    assert _bucket_position("Forward") == "FW"
    assert _bucket_position("Goalkeeper") == "GK"
    assert _bucket_position("Right Back") == "DF"
    assert _bucket_position("Striker") == "FW"
    assert _bucket_position("Left Wing") == "FW"


def test_bucket_position_falls_back_to_mf_for_no_signal():
    assert _bucket_position("Substitute") == "MF"
    assert _bucket_position("") == "MF"


def test_resolve_positions_picks_the_common_real_label_ignoring_substitute():
    resolved = _resolve_positions({
        "messi": ["Substitute", "Forward", "Forward", "Substitute"],
    })
    assert resolved["messi"] == "FW"


def test_resolve_positions_falls_back_to_substitute_pool_when_never_started():
    resolved = _resolve_positions({
        "benchwarmer": ["Substitute", "Substitute", "Substitute"],
    })
    assert resolved["benchwarmer"] == "MF"


def test_resolve_positions_handles_multiple_players_independently():
    resolved = _resolve_positions({
        "keeper": ["Goalkeeper", "Goalkeeper", "Substitute"],
        "back": ["Substitute", "Center Right Defender"],
    })
    assert resolved["keeper"] == "GK"
    assert resolved["back"] == "DF"


def test_aggregate_rows_sums_appearances_goals_assists_across_matches():
    rows = [
        _row("messi", goals=1, assists=1),
        _row("messi", goals=2, assists=0),
        _row("messi", goals=0, assists=1),
    ]
    totals, labels = _aggregate_rows(rows)
    key = ("messi", "Inter Miami CF", 2024, "usa.1")
    assert totals[key]["appearances"] == 3
    assert totals[key]["goals"] == 3
    assert totals[key]["assists"] == 2
    assert labels["messi"] == ["Forward", "Forward", "Forward"]


def test_aggregate_rows_derives_clean_sheets_from_zero_goals_conceded():
    rows = [
        _row("keeper", position="Goalkeeper", conceded=0),
        _row("keeper", position="Goalkeeper", conceded=2),
        _row("keeper", position="Goalkeeper", conceded=0),
    ]
    totals, _ = _aggregate_rows(rows)
    key = ("keeper", "Inter Miami CF", 2024, "usa.1")
    assert totals[key]["appearances"] == 3
    assert totals[key]["clean_sheets"] == 2


def test_aggregate_rows_skips_zero_or_none_appearance_rows_but_keeps_position_label():
    rows = [
        _row("benched", position="Substitute", appearances=0),
        _row("benched", position="Substitute", appearances=None),
        _row("benched", position="Forward", appearances=1, goals=1),
    ]
    totals, labels = _aggregate_rows(rows)
    key = ("benched", "Inter Miami CF", 2024, "usa.1")
    assert totals[key]["appearances"] == 1
    assert totals[key]["goals"] == 1
    # All three matches' position labels are recorded, even the two skipped-for-totals ones.
    assert labels["benched"] == ["Substitute", "Substitute", "Forward"]


def test_aggregate_rows_keys_by_name_team_and_season_separately():
    rows = [
        _row("mover", team="Club A", season=2023),
        _row("mover", team="Club B", season=2023),
        _row("mover", team="Club B", season=2024),
    ]
    totals, _ = _aggregate_rows(rows)
    assert len(totals) == 3
    assert totals[("mover", "Club A", 2023, "usa.1")]["appearances"] == 1
    assert totals[("mover", "Club B", 2023, "usa.1")]["appearances"] == 1
    assert totals[("mover", "Club B", 2024, "usa.1")]["appearances"] == 1


def test_aggregate_rows_does_not_merge_same_name_team_season_across_leagues():
    # Same name, same team display string, same season — but two different countries'
    # competitions (two matches each). Must stay as two distinct season totals, not one
    # merged total — the reason the aggregation key was widened to include league.
    rows = [
        _row("santos", team="Sporting", season=2024, league="por.1", goals=2),
        _row("santos", team="Sporting", season=2024, league="por.1", goals=1),
        _row("santos", team="Sporting", season=2024, league="usa.1", goals=1),
    ]
    totals, _ = _aggregate_rows(rows)
    assert len(totals) == 2
    assert totals[("santos", "Sporting", 2024, "por.1")]["appearances"] == 2
    assert totals[("santos", "Sporting", 2024, "por.1")]["goals"] == 3
    assert totals[("santos", "Sporting", 2024, "usa.1")]["appearances"] == 1
    assert totals[("santos", "Sporting", 2024, "usa.1")]["goals"] == 1


def _write_csv(path, rows):
    with path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)


def _row_dict(name, season_year, team_abbr):
    return {"name": name, "team_abbr": team_abbr, "season_year": season_year,
            "position": "FW", "appearances": 20, "goals": 5, "assists": 3,
            "clean_sheets": 0, "headshot": "https://example.com/x.jpg",
            "league": "England"}


def test_merge_csvs_combines_and_sorts_per_league_partitions(tmp_path):
    eng = tmp_path / "eng.1.csv"
    bra = tmp_path / "bra.1.csv"
    _write_csv(eng, [_row_dict("Zed Player", 2023, "ARS")])
    _write_csv(bra, [_row_dict("Amir Player", 2023, "FLA")])

    out = tmp_path / "merged.csv"
    merge_csvs([eng, bra], out)

    with out.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    assert [r["name"] for r in rows] == ["Amir Player", "Zed Player"]


def test_merge_csvs_sorts_by_name_then_season_then_team(tmp_path):
    a = tmp_path / "a.csv"
    b = tmp_path / "b.csv"
    _write_csv(a, [_row_dict("Same Name", 2024, "ZZZ")])
    _write_csv(b, [_row_dict("Same Name", 2023, "AAA")])

    out = tmp_path / "merged.csv"
    merge_csvs([a, b], out)

    with out.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    assert [r["season_year"] for r in rows] == ["2023", "2024"]


# ── club_codes wiring — the collision fix (BRO = Blackburn AND Brisbane Roar) ─────────

def test_espn_soccer_resolves_team_abbr_via_club_codes_not_a_local_short_code():
    # espn_soccer.py must no longer own its own _short_code call; it routes through the
    # shared club_codes module so it benefits from the curated + override layers too.
    assert not hasattr(espn_soccer, "_short_code")
    assert club_codes.resolve_code("Manchester City", country="England") == "MCI"


def test_previously_colliding_espn_team_names_now_resolve_distinctly():
    blackburn = club_codes.resolve_code("Blackburn Rovers", country="England")
    brisbane = club_codes.resolve_code("Brisbane Roar", country="Australia")
    assert blackburn != brisbane


def test_assert_globally_unique_passes_for_distinct_clubs():
    rows = [
        {"team_abbr": "MCI", "club_identity": "Manchester City", "league": "England"},
        {"team_abbr": "BAR", "club_identity": "Barcelona", "league": "Spain"},
    ]
    club_codes.assert_globally_unique(rows)  # must not raise


def test_assert_globally_unique_raises_on_a_real_collision():
    rows = [
        {"team_abbr": "BRO", "club_identity": "Blackburn Rovers", "league": "England"},
        {"team_abbr": "BRO", "club_identity": "Brisbane Roar", "league": "Australia"},
    ]
    try:
        club_codes.assert_globally_unique(rows)
    except ValueError as err:
        assert "BRO" in str(err)
    else:
        raise AssertionError("expected a ValueError for the collision")


# ── team/league identity capture (M-teams) ────────────────────────────────────────────

def _identity_row(team="Manchester City", espn_id="382",
                  logo_url="https://espn.example/mci.png", primary="6cabdd",
                  secondary="1c2c5b", league="eng.1"):
    return {"team": team, "espn_id": espn_id, "logo_url": logo_url,
            "primary_color": primary, "secondary_color": secondary, "league": league}


def test_build_team_identity_dedupes_and_prefixes_hex_colors_with_a_hash():
    rows = [_identity_row(), _identity_row()]
    identity = _build_team_identity(rows)
    assert len(identity) == 1
    row = identity[0]
    assert row["team_abbr"] == "MCI"
    assert row["league"] == "England"          # resolved from the ESPN slug via _LEAGUES
    assert row["full_name"] == "Manchester City"
    assert row["espn_id"] == "382"
    assert row["logo_url"] == "https://espn.example/mci.png"
    assert row["primary_color"] == "#6cabdd"
    assert row["secondary_color"] == "#1c2c5b"


def test_build_team_identity_fills_missing_fields_from_a_later_sighting():
    rows = [
        _identity_row(espn_id="", logo_url="", primary="", secondary=""),
        _identity_row(),   # a later match's summary has the full identity
    ]
    identity = _build_team_identity(rows)
    assert len(identity) == 1
    row = identity[0]
    assert row["espn_id"] == "382"
    assert row["logo_url"] == "https://espn.example/mci.png"
    assert row["primary_color"] == "#6cabdd"
    assert row["secondary_color"] == "#1c2c5b"


def test_build_team_identity_keeps_same_derived_code_distinct_across_leagues():
    # The exact collision this module already guards against for player rows (BRO =
    # Blackburn Rovers AND Brisbane Roar) — team identity rows must resolve just as
    # distinctly, via the same club_codes.resolve_code path.
    rows = [
        _identity_row(team="Blackburn Rovers", espn_id="", logo_url="",
                      primary="", secondary="", league="eng.1"),
        _identity_row(team="Brisbane Roar", espn_id="", logo_url="",
                      primary="", secondary="", league="aus.1"),
    ]
    identity = _build_team_identity(rows)
    codes = {(r["team_abbr"], r["league"]) for r in identity}
    assert len(identity) == 2
    assert ("BRO", "England") in codes
    assert ("BROA", "Australia") in codes


def test_load_team_identity_empty_when_refresh_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(espn_soccer, "TEAM_IDENTITY_CSV_PATH", tmp_path / "missing.csv")
    assert espn_soccer.load_team_identity() == []


def test_load_team_identity_round_trips_the_committed_csv_format(tmp_path, monkeypatch):
    csv_path = tmp_path / "soccer_team_identity.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as f:
        import csv as _csv
        w = _csv.DictWriter(f, fieldnames=TEAM_IDENTITY_FIELDS)
        w.writeheader()
        w.writerow({"team_abbr": "MCI", "league": "England", "full_name": "Manchester City",
                    "espn_id": "382", "logo_url": "https://espn.example/mci.png",
                    "primary_color": "#6cabdd", "secondary_color": "#1c2c5b"})
    monkeypatch.setattr(espn_soccer, "TEAM_IDENTITY_CSV_PATH", csv_path)

    identity = espn_soccer.load_team_identity()
    assert len(identity) == 1
    assert identity[0]["team_abbr"] == "MCI"
    assert identity[0]["primary_color"] == "#6cabdd"
