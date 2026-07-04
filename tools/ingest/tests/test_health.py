"""Content-health artifact (M15) — pool figures must match the pipeline's actual output."""
from tools.ingest import assemble, health
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
