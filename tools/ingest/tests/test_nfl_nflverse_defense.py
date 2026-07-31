"""nflverse defensive-seasons provider tests — position_group filtering, stat-key
extraction against the source's real column shape, and the `def_interceptions` naming
(must never collide with offensive `interceptions`). Mocks `fetch_text` rather than
hitting the network, matching test_weekly_refresh.py's pattern for the sibling
nfl_nflverse.py provider."""
from tools.ingest.models import slug
from tools.ingest.providers import nfl_nflverse, nfl_nflverse_defense

_HEADER = (
    "player_id,player_name,player_display_name,position,position_group,headshot_url,"
    "season_type,recent_team,games,def_tackles_solo,def_tackles_with_assist,"
    "def_tackle_assists,def_tackles_for_loss,def_tackles_for_loss_yards,"
    "def_fumbles_forced,def_sacks,def_sack_yards,def_qb_hits,def_interceptions,"
    "def_interception_yards,def_pass_defended,def_tds,def_fumbles,def_safeties,"
    "fumble_recovery_own,fumble_recovery_yards_own,fumble_recovery_opp,"
    "fumble_recovery_yards_opp,fumble_recovery_tds,interceptions,passing_interceptions\n"
)


def _row(player_id="00-0031040", name="Khalil Mack", position="OLB", position_group="LB",
         season_type="REG", team="OAK", games=16, tackles_solo=48, tackles_with_assist=6,
         tackle_assists=19, tfl=14, tfl_yards=40, forced_fumbles=5, sacks=11, sack_yards=70,
         qb_hits=26, ints=1, int_yards=0, pd=3, tds=1, own_fumbles=0, safeties=0,
         fum_rec_own=0, fum_rec_own_yards=0, fum_rec_opp=3, fum_rec_opp_yards=12,
         fum_rec_tds=0, off_interceptions="", off_passing_interceptions=""):
    return (
        f"{player_id},{name},{name},{position},{position_group},"
        f"https://example.com/{player_id}.png,{season_type},{team},{games},"
        f"{tackles_solo},{tackles_with_assist},{tackle_assists},{tfl},{tfl_yards},"
        f"{forced_fumbles},{sacks},{sack_yards},{qb_hits},{ints},{int_yards},{pd},{tds},"
        f"{own_fumbles},{safeties},{fum_rec_own},{fum_rec_own_yards},{fum_rec_opp},"
        f"{fum_rec_opp_yards},{fum_rec_tds},{off_interceptions},{off_passing_interceptions}\n"
    )


def _csv(*rows: str) -> str:
    return _HEADER + "".join(rows)


def test_fetch_year_keeps_only_defensive_position_groups(monkeypatch):
    text = _csv(
        _row(player_id="00-0031040", name="Khalil Mack", position="OLB", position_group="LB"),
        _row(player_id="00-0033000", name="Some Corner", position="CB", position_group="DB"),
        _row(player_id="00-0034000", name="Some Tackle", position="DT", position_group="DL"),
        # Offense and special-teams rows must be excluded.
        _row(player_id="00-0035000", name="Some Kicker", position="K", position_group="SPEC"),
        _row(player_id="00-0036000", name="Some QB", position="QB", position_group="QB"),
    )
    monkeypatch.setattr(nfl_nflverse_defense, "fetch_text", lambda *a, **k: text)
    seasons = nfl_nflverse_defense.fetch_year(2016)
    names = {s.name for s in seasons}
    assert names == {"Khalil Mack", "Some Corner", "Some Tackle"}


def test_fetch_year_drops_non_regular_season_rows(monkeypatch):
    text = _csv(_row(season_type="POST"))
    monkeypatch.setattr(nfl_nflverse_defense, "fetch_text", lambda *a, **k: text)
    assert nfl_nflverse_defense.fetch_year(2016) == []


def test_khalil_mack_2016_stat_line(monkeypatch):
    # Real 2016 Defensive Player of the Year season row shape.
    text = _csv(_row())
    monkeypatch.setattr(nfl_nflverse_defense, "fetch_text", lambda *a, **k: text)
    seasons = nfl_nflverse_defense.fetch_year(2016)
    assert len(seasons) == 1
    s = seasons[0]
    assert s.name == "Khalil Mack"
    assert s.position == "OLB"
    assert s.sport == "nfl"
    assert s.source == "nflverse"
    assert s.team_abbr == "OAK"
    assert s.headshot == "https://example.com/00-0031040.png"
    assert s.meta["gsis_id"] == "00-0031040"
    assert s.stats["games"] == 16.0
    assert s.stats["tackles_solo"] == 48.0
    assert s.stats["tackles_combined"] == 54.0        # 48 solo + 6 def_tackles_with_assist
    assert s.stats["tackles_for_loss"] == 14.0
    assert s.stats["sacks"] == 11.0
    assert s.stats["qb_hits"] == 26.0
    assert s.stats["def_interceptions"] == 1.0
    assert s.stats["passes_defended"] == 3.0
    assert s.stats["forced_fumbles"] == 5.0
    # def_fumbles (own fumbles, not recoveries) is 0 for this row; the real 3 recoveries
    # live in fumble_recovery_own/opp, which fumble_recoveries sums instead.
    assert s.stats["fumble_recoveries"] == 3.0
    assert s.stats["defensive_tds"] == 1.0
    assert s.stats["safeties"] == 0.0


def test_def_fumbles_is_not_fumble_recoveries(monkeypatch):
    # A row where the defender himself fumbled (def_fumbles=2) but never recovered
    # anything (fumble_recovery_own/opp both 0) must NOT show up as a recovery.
    text = _csv(_row(player_id="00-0099999", name="Butter Fingers",
                     own_fumbles=2, fum_rec_own=0, fum_rec_opp=0))
    monkeypatch.setattr(nfl_nflverse_defense, "fetch_text", lambda *a, **k: text)
    s = nfl_nflverse_defense.fetch_year(2016)[0]
    assert s.stats["fumble_recoveries"] == 0.0
    assert "def_fumbles" not in s.stats   # raw source key never leaks into the stat dict


def test_def_interceptions_key_does_not_collide_with_offensive_interceptions():
    # Same stat vocabulary a QB row would use for a completely different concept
    # (passes thrown that got picked off) — the defensive key must be distinct.
    assert "def_interceptions" != "interceptions"


def test_stat_dict_never_uses_bare_interceptions_key(monkeypatch):
    text = _csv(_row())
    monkeypatch.setattr(nfl_nflverse_defense, "fetch_text", lambda *a, **k: text)
    s = nfl_nflverse_defense.fetch_year(2016)[0]
    assert "interceptions" not in s.stats
    assert s.stats["def_interceptions"] == 1.0


def test_player_id_does_not_collide_with_a_different_offensive_player(monkeypatch):
    def_text = _csv(_row(player_id="00-0031040", name="Khalil Mack"))
    off_text = ("player_id,player_display_name,player_name,position,recent_team,"
                "season_type,games,passing_yards,passing_tds,interceptions,attempts,"
                "completions,carries,rushing_yards,rushing_tds,receptions,targets,"
                "receiving_yards,receiving_tds,headshot_url\n"
                "00-0019596,Tom Brady,Tom Brady,QB,NE,REG,16,4000,30,8,500,300,10,20,0,"
                "0,0,0,0,https://example.com/brady.png\n")
    monkeypatch.setattr(nfl_nflverse_defense, "fetch_text", lambda *a, **k: def_text)
    monkeypatch.setattr(nfl_nflverse, "fetch_text", lambda *a, **k: off_text)
    def_seasons = nfl_nflverse_defense.fetch_year(2016)
    off_seasons = nfl_nflverse.fetch_year(2016)
    def_ids = {s.player_id for s in def_seasons}
    off_ids = {s.player_id for s in off_seasons}
    assert def_ids.isdisjoint(off_ids)
    assert f"nfl-{slug('Khalil Mack')}-2016" in def_ids
    assert f"nfl-{slug('Tom Brady')}-2016" in off_ids


def test_fetch_years_skips_a_failing_year(monkeypatch, capsys):
    def fake_fetch_year(year, **kwargs):
        if year == 2000:
            raise RuntimeError("boom")
        return []

    monkeypatch.setattr(nfl_nflverse_defense, "fetch_year", fake_fetch_year)
    out = nfl_nflverse_defense.fetch_years([1999, 2000, 2001])
    assert out == []
    assert "skipping 2000" in capsys.readouterr().out


def test_pre_1999_years_are_empty():
    assert nfl_nflverse_defense.fetch_year(1998) == []
