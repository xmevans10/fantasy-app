"""WTA sweep tests — the aggregation itself is shared with (and tested by) the ATP
provider; here we cover the WTA-specific wiring: the Sackmann WTA match-file shape
flows through the shared aggregator, and the loader round-trips the committed CSV
with source='tennis_wta'."""
from tools.ingest.providers import tennis_wta
from tools.ingest.providers.tennis_wta import _aggregate_year, load_seasons


def _match(winner, w_ioc, loser, l_ioc, rnd="R32", level="I"):
    return {"winner_name": winner, "winner_ioc": w_ioc,
            "loser_name": loser, "loser_ioc": l_ioc,
            "round": rnd, "tourney_level": level}


def _csv_text(rows):
    header = "winner_name,winner_ioc,loser_name,loser_ioc,round,tourney_level"
    lines = [header] + [f"{r['winner_name']},{r['winner_ioc']},{r['loser_name']},"
                        f"{r['loser_ioc']},{r['round']},{r['tourney_level']}" for r in rows]
    return "\n".join(lines)


def test_aggregates_wins_losses_titles_and_slams():
    rows = [
        _match("Steffi Graf", "GER", "Monica Seles", "YUG"),
        _match("Steffi Graf", "GER", "Gabriela Sabatini", "ARG", rnd="F", level="G"),  # slam title
        _match("Steffi Graf", "GER", "Martina Navratilova", "USA", rnd="F", level="P"),  # non-slam title
        _match("Monica Seles", "YUG", "Steffi Graf", "GER"),
    ]
    agg = _aggregate_year(1991, _csv_text(rows))
    graf = agg[("Steffi Graf", "GER")]
    assert graf["matches_won"] == 3 and graf["matches_lost"] == 1
    assert graf["titles"] == 2 and graf["grand_slams"] == 1
    seles = agg[("Monica Seles", "YUG")]
    assert seles["matches_won"] == 1 and seles["matches_lost"] == 1
    assert seles["titles"] == 0


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "tennis_wta_seasons.csv"
    csv_path.write_text(
        "name,country,season_year,matches_won,matches_lost,titles,grand_slams,headshot\n"
        "Steffi Graf,GER,1988,72,3,11,4,https://upload.wikimedia.org/graf.jpg\n",
        encoding="utf-8")
    monkeypatch.setattr(tennis_wta, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "tennis-steffi-graf-1988"
    assert s.sport == "tennis" and s.position == "Player"
    assert s.team_abbr == "GER"                       # country stands in for team
    assert s.stats == {"matches_won": 72.0, "matches_lost": 3.0, "titles": 11.0, "grand_slams": 4.0}
    assert s.source == "tennis_wta"
    assert s.headshot.endswith("graf.jpg")


def test_load_seasons_empty_when_sweep_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(tennis_wta, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []
