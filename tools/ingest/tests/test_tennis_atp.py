"""ATP sweep tests — pure aggregation over the Sackmann match-file shape, plus a loader
round-trip over the committed CSV format."""
from tools.ingest.providers import tennis_atp
from tools.ingest.providers.tennis_atp import _aggregate_year, load_seasons


def _match(winner, w_ioc, loser, l_ioc, rnd="R32", level="A"):
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
        _match("Ivan Lendl", "TCH", "John McEnroe", "USA"),
        _match("Ivan Lendl", "TCH", "Mats Wilander", "SWE", rnd="F", level="G"),  # slam title
        _match("Ivan Lendl", "TCH", "Boris Becker", "GER", rnd="F", level="M"),   # non-slam title
        _match("John McEnroe", "USA", "Ivan Lendl", "TCH"),
    ]
    agg = _aggregate_year(1986, _csv_text(rows))
    lendl = agg[("Ivan Lendl", "TCH")]
    assert lendl["matches_won"] == 3 and lendl["matches_lost"] == 1
    assert lendl["titles"] == 2 and lendl["grand_slams"] == 1
    mac = agg[("John McEnroe", "USA")]
    assert mac["matches_won"] == 1 and mac["matches_lost"] == 1
    assert mac["titles"] == 0


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "tennis_atp_seasons.csv"
    csv_path.write_text(
        "name,country,season_year,matches_won,matches_lost,titles,grand_slams,headshot\n"
        "Ivan Lendl,TCH,1986,74,6,9,2,https://upload.wikimedia.org/lendl.jpg\n",
        encoding="utf-8")
    monkeypatch.setattr(tennis_atp, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "ivan-lendl-1986"
    assert s.sport == "tennis" and s.position == "Player"
    assert s.team_abbr == "TCH"                       # country stands in for team
    assert s.stats == {"matches_won": 74.0, "matches_lost": 6.0, "titles": 9.0, "grand_slams": 2.0}
    assert s.headshot.endswith("lendl.jpg")


def test_load_seasons_empty_when_sweep_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(tennis_atp, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []
