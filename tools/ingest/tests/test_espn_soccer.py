"""ESPN full-squad soccer sweep tests — pure aggregation over the module's per-match
box-score row shape (position bucketing/resolution + season totals with the
goals-conceded-derived clean-sheet count), no network, no pandas, no mocking."""
from tools.ingest.providers.espn_soccer import (
    _aggregate_rows, _bucket_position, _resolve_positions)


def _row(player, team="Inter Miami CF", season=2024, position="Forward",
         appearances=1, goals=0, assists=0, conceded=None):
    return {"player": player, "team": team, "season_end_year": season,
            "position": position, "appearances": appearances,
            "total_goals": goals, "goal_assists": assists,
            "goals_conceded": conceded}


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
    key = ("messi", "Inter Miami CF", 2024)
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
    key = ("keeper", "Inter Miami CF", 2024)
    assert totals[key]["appearances"] == 3
    assert totals[key]["clean_sheets"] == 2


def test_aggregate_rows_skips_zero_or_none_appearance_rows_but_keeps_position_label():
    rows = [
        _row("benched", position="Substitute", appearances=0),
        _row("benched", position="Substitute", appearances=None),
        _row("benched", position="Forward", appearances=1, goals=1),
    ]
    totals, labels = _aggregate_rows(rows)
    key = ("benched", "Inter Miami CF", 2024)
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
    assert totals[("mover", "Club A", 2023)]["appearances"] == 1
    assert totals[("mover", "Club B", 2023)]["appearances"] == 1
    assert totals[("mover", "Club B", 2024)]["appearances"] == 1
