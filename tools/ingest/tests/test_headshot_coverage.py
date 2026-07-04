"""Headshot-coverage regression guard (M16): catches "a sport shipped without photos"
regressions, mirroring test_content_drift.py's shape — load the SHIPPED bundled JSON
and assert on it directly, rather than re-deriving from providers (which could pass
while the bundle itself is stale, the exact M9-style failure mode this pattern guards
against elsewhere).

A failure here means either a real coverage regression (a provider/seed loader stopped
setting `headshot`) or a stale bundle — regenerate via
`python3 -m tools.ingest.main --write-fallback` and re-check before assuming the guard
itself is wrong.
"""
import json
from collections import defaultdict
from pathlib import Path

BUNDLE_PATH = Path(__file__).resolve().parents[3] / "BallIQ" / "Data" / "keep4_puzzles.json"


def _load_bundle() -> list[dict]:
    return json.loads(BUNDLE_PATH.read_text())


def test_every_player_season_has_a_headshot():
    bundle = _load_bundle()
    missing: list[str] = []
    seen: set[tuple] = set()
    for puzzle in bundle:
        sport = puzzle["sport"]
        for p in puzzle["players"]:
            key = (sport, p["name"], p.get("seasonYear"))
            if key in seen:
                continue
            seen.add(key)
            if not p.get("headshot"):
                missing.append(f"{sport}: {p['name']} ({p.get('seasonYear')})")
    assert not missing, (
        f"{len(missing)} player-season(s) shipped without a headshot: {missing}\n"
        "Backfill at the source (provider/seed loader), then regenerate the bundle "
        "(python3 -m tools.ingest.main --write-fallback) rather than hand-patching the JSON."
    )


def test_coverage_is_100_percent_per_sport():
    bundle = _load_bundle()
    total: dict[str, int] = defaultdict(int)
    has: dict[str, int] = defaultdict(int)
    seen: set[tuple] = set()
    for puzzle in bundle:
        sport = puzzle["sport"]
        for p in puzzle["players"]:
            key = (sport, p["name"], p.get("seasonYear"))
            if key in seen:
                continue
            seen.add(key)
            total[sport] += 1
            if p.get("headshot"):
                has[sport] += 1
    assert total, "bundle produced no player-seasons at all — pipeline regression"
    for sport, count in total.items():
        assert has[sport] == count, f"{sport}: {has[sport]}/{count} headshot coverage, expected 100%"
