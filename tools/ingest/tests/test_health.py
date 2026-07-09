"""Content-health artifact (M15) — pool figures must match the pipeline's actual output."""
from tools.ingest import assemble, health
from tools.ingest.models import RawSeason
from tools.ingest.providers import seed
from tools.ingest.themes import KEEP4_THEMES

NBA_THEMES = [t for t in KEEP4_THEMES if t.sport == "nba"]


def test_pool_size_matches_grade_pool():
    seasons = seed.load_nba()
    for theme in NBA_THEMES:
        stats = health.theme_health(theme, seasons)
        assert stats["pool_size"] == len(assemble.grade_pool(theme, seasons))
        assert stats["pool_size"] <= theme.pool_cap


def test_exclusion_counts_partition_eligible():
    # eligible = excluded(min_stats) + excluded(filters) + rows grade_pool actually graded.
    # The graded rows then dedupe by person + cap, so pool_size <= the remainder.
    seasons = seed.load_nba()
    for theme in NBA_THEMES:
        stats = health.theme_health(theme, seasons)
        survivors = (stats["eligible_seasons"] - stats["excluded_by_min_stats"]
                     - stats["excluded_by_filters"])
        assert survivors >= stats["pool_size"]
        assert stats["excluded_by_min_stats"] >= 0
        assert stats["puzzle_capable"] == (stats["pool_size"] >= assemble.KEEP_COUNT)


def test_report_totals_and_built_counts():
    seasons = seed.load_nba()
    theme = NBA_THEMES[0]
    stats = [health.theme_health(theme, seasons)]
    built = {theme.key: len(assemble.build_keep4_rows(theme, seasons))}
    report = health.build_report(stats, built, whoami_count=7)
    assert report["totals"]["themes"] == 1
    assert report["totals"]["keep4_puzzles"] == built[theme.key]
    assert report["totals"]["whoami_puzzles"] == 7
    assert report["themes"][0]["puzzles_built"] == built[theme.key]
    assert "generated_at" in report


def test_write_report_round_trips(tmp_path):
    import json
    seasons = seed.load_nba()
    stats = [health.theme_health(t, seasons) for t in NBA_THEMES]
    report = health.build_report(stats, {}, whoami_count=0)
    out = tmp_path / "content_health.json"
    health.write_report(report, out)
    assert json.loads(out.read_text(encoding="utf-8")) == report


# ── catalog_depth_report — the exact bug class caught in M5 Phase D (soccer GK/DF draft
# slots empty, then stuck at 1 candidate) had zero automated coverage before this. ────────

def _season(sport: str, position: str, name: str = "P") -> RawSeason:
    return RawSeason(name=name, team_abbr="X", season_year=2020, sport=sport,
                     position=position, stats={})


def test_catalog_depth_covers_every_draft_spin_slot_position():
    rows = health.catalog_depth_report([])
    positions = {(r["sport"], r["position"]) for r in rows}
    assert positions == health.DRAFT_SPIN_SLOT_POSITIONS
    assert all(r["season_rows"] == 0 and not r["draft_slot_viable"] for r in rows)


def test_catalog_depth_flags_thin_positions_below_three():
    seasons = [_season("soccer", "DF", "A")]  # exactly the M5 Phase D bug: 1 real row
    rows = {r["position"]: r for r in health.catalog_depth_report(seasons)
           if r["sport"] == "soccer"}
    assert rows["DF"]["season_rows"] == 1
    assert not rows["DF"]["draft_slot_viable"]
    assert rows["FW"]["season_rows"] == 0


def test_catalog_depth_marks_three_or_more_as_viable():
    seasons = [_season("soccer", "GK", f"P{i}") for i in range(3)]
    gk = next(r for r in health.catalog_depth_report(seasons) if r["sport"] == "soccer" and r["position"] == "GK")
    assert gk["season_rows"] == 3
    assert gk["draft_slot_viable"]


def test_catalog_depth_excludes_career_and_game_grain_rows():
    career_row = RawSeason(name="C", team_abbr="X", season_year=2020, sport="nfl",
                           position="QB", stats={}, career=True)
    game_row = RawSeason(name="G", team_abbr="X", season_year=2020, sport="nfl",
                         position="QB", stats={}, week=3)
    rows = {r["position"]: r for r in health.catalog_depth_report([career_row, game_row])
           if r["sport"] == "nfl"}
    assert rows["QB"]["season_rows"] == 0


def test_build_report_surfaces_thin_position_total():
    report = health.build_report([], {}, whoami_count=0,
                                 catalog_depth=health.catalog_depth_report([]))
    assert report["totals"]["draft_slot_positions_too_thin"] == len(health.DRAFT_SPIN_SLOT_POSITIONS)
