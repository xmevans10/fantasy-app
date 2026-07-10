"""Historical NFL sweep tests — pure parsing of the fantasydatapros yearly-file shape."""
from tools.ingest.providers import nfl_history
from tools.ingest.providers.nfl_history import load_seasons, parse_year

_HEADER = ("#,Player,Tm,Pos,Age,G,GS,Cmp,Att,Yds,Int,Att,Yds,Rec,Yds,Y/R,Fumbles,FumblesLost,"
           "PassingYds,PassingTD,PassingAtt,RushingYds,RushingTD,RushingAtt,ReceivingYds,"
           "ReceivingTD,FantasyPoints")


def _csv(rows):
    return "\n".join([_HEADER] + rows)


def test_parses_a_historical_rb_season():
    text = _csv(["0,O.J. Simpson,BUF,RB,28.0,14.0,14.0,0.0,0.0,0.0,0.0,329.0,1817.0,28.0,426.0,"
                 "15.21,7.0,0.0,0.0,0.0,0.0,1817.0,16.0,329.0,426.0,7.0,376.3"])
    rows = parse_year(1975, text)
    assert len(rows) == 1
    r = rows[0]
    assert r["name"] == "O.J. Simpson" and r["team_abbr"] == "BUF"
    assert r["season_year"] == 1975 and r["position"] == "RB"
    assert r["rushing_yards"] == 1817.0 and r["rushing_tds"] == 16.0
    assert r["carries"] == 329.0 and r["ypc"] == round(1817 / 329, 1)
    assert r["receiving_yards"] == 426.0 and r["receptions"] == 28.0
    assert r["games"] == 14


def test_filters_non_offense_and_fixes_pfr_abbrs():
    text = _csv([
        "0,Some Kicker,GNB,K,30.0,16.0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,120.0",
        "1,Brett Someone,GNB,QB,28.0,16.0,16.0,300.0,0.0,0.0,13.0,30.0,150.0,0.0,0.0,0.0,"
        "5.0,2.0,3900.0,33.0,520.0,150.0,2.0,30.0,0.0,0.0,310.0",
        "2,Traded Back,2TM,RB,26.0,15.0,8.0,0,0,0,0.0,200.0,800.0,20.0,150.0,7.5,3.0,1.0,"
        "0.0,0.0,0.0,800.0,6.0,200.0,150.0,1.0,180.0",
    ])
    rows = parse_year(1996, text)
    assert [r["position"] for r in rows] == ["QB", "RB"]     # kicker dropped
    assert rows[0]["team_abbr"] == "GB"                       # GNB → catalog GB
    assert rows[0]["completion_pct"] == round(100 * 300 / 520, 1)
    assert rows[1]["team_abbr"] == ""                         # 2TM → teamless


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "nfl_history_seasons.csv"
    csv_path.write_text(
        "name,team_abbr,season_year,position,games,passing_yards,passing_tds,interceptions,"
        "attempts,completions,completion_pct,carries,rushing_yards,rushing_tds,ypc,"
        "receptions,receiving_yards,receiving_tds,ypr,fantasy_points,headshot\n"
        "Walter Payton,CHI,1977,RB,14,0,0,0,0,0,0.0,339,1852,14,5.5,27,269,2,10.0,"
        "352.1,https://img/sweetness.jpg\n",
        encoding="utf-8")
    monkeypatch.setattr(nfl_history, "CSV_PATH", csv_path)
    seasons = load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.player_id == "walter-payton-1977"
    assert s.sport == "nfl" and s.source == "pfr" and s.position == "RB"
    assert s.stats["rushing_yards"] == 1852.0
    assert "fantasy_points" not in s.stats     # dataset convenience column, not a stat
    assert s.headshot.endswith("sweetness.jpg")


def test_load_seasons_empty_when_sweep_not_run(tmp_path, monkeypatch):
    monkeypatch.setattr(nfl_history, "CSV_PATH", tmp_path / "missing.csv")
    assert load_seasons() == []
