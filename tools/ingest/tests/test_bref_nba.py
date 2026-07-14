"""Historical NBA sweep tests — pure parsing of the Basketball-Reference-derived dataset."""
from tools.ingest.providers import bref_nba
from tools.ingest.providers.bref_nba import load_seasons, parse_rows

_HEADER = "SeasonStart,PlayerName,Pos,Age,Tm,G,TS%,FG%,3P%,PTS,TRB,AST,STL,BLK"


def _csv(rows):
    return "\n".join([_HEADER] + rows)


def test_parses_a_historical_season_row():
    rows = parse_rows(_csv(['1987,Michael Jordan*,SG,23,CHI,82,56.20%,0.482,0.182,3041,430,377,236,125']))
    assert len(rows) == 1
    r = rows[0]
    assert r["name"] == "Michael Jordan"          # HOF star suffix stripped
    assert r["season_year"] == 1987 and r["team_abbr"] == "CHI"
    assert r["position"] == "G"                   # SG collapses to the catalog bucket
    assert r["ppg"] == round(3041 / 82, 1)
    assert r["ts_pct"] == 0.562                   # '56.20%' string form
    assert r["fg_pct"] == 0.482                   # fraction form


def test_year_window_and_min_games_filtering():
    rows = parse_rows(_csv([
        '1949,Old Timer,C,30,MNL,60,,0.40,,800,500,100,,',       # before window
        '2005,Modern Guy,PG,25,PHO,80,0.55,0.45,0.35,1500,300,600,100,20',  # hoopR territory
        '1990,Cameo Guy,SF,28,CHI,4,0.50,0.44,0.30,40,20,5,3,1',  # < MIN_GAMES
        '1990,Real Guy,SF,28,CHI,70,0.50,0.44,0.30,900,400,150,60,30',
    ]))
    assert [r["name"] for r in rows] == ["Real Guy"]


def test_traded_total_and_abbr_fixes_and_dual_positions():
    rows = parse_rows(_csv([
        '1995,Traded Guy,PF-C,30,TOT,75,0.52,0.47,0.10,700,500,100,50,60',
        '1995,Warrior Guy,PG,24,GSW,70,0.54,0.46,0.38,1200,250,500,120,10',
    ]))
    assert rows[0]["team_abbr"] == "" and rows[0]["position"] == "F"   # TOT → teamless, PF-C → F
    assert rows[1]["team_abbr"] == "GS"                                # BREF GSW → catalog GS


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "nba_bref_seasons.csv"
    csv_path.write_text(
        "name,team_abbr,season_year,position,games,ppg,rpg,apg,spg,bpg,fg_pct,fg3_pct,ts_pct,headshot\n"
        "Wilt Chamberlain,PHW,1962,C,80,50.4,25.7,2.4,0.0,0.0,0.506,0.0,0.536,https://img/wilt.jpg\n",
        encoding="utf-8")
    monkeypatch.setattr(bref_nba, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "nba-wilt-chamberlain-1962"
    assert s.sport == "nba" and s.source == "bref" and s.position == "C"
    assert s.stats["ppg"] == 50.4
    assert s.headshot.endswith("wilt.jpg")


def test_load_seasons_empty_when_sweep_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(bref_nba, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []


def test_photo_slice_widened_to_roughly_100_per_season():
    # Backlog #9: 40/season left deep-roster Draft & Spin rows silhouette-only even
    # though resolution is cheap/cached — locks the widened slice so it can't regress.
    assert bref_nba.PHOTO_SLICE_PER_YEAR >= 100
