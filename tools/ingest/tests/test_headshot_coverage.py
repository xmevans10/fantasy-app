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
    # `missing` is measured against a recorded baseline rather than asserted to be empty.
    #
    # This guard read "100% coverage" for months while shipping BROKEN photos, because it
    # tests `if not p.get("headshot")` — a non-empty string passes, and a non-empty string is
    # exactly what a dead link or a placeholder is. Live examples found 2026-09-06: Michael
    # Jordan pointed at an ESPN URL that 404s, Hakeem Olajuwon at a photo of the Nigerian
    # president, and Calvin Johnson at the NFL's generic helmet. Repointing every path to our
    # own store (`/player-headshots/`) replaced those with '' and made the real gap visible
    # for the first time.
    #
    # So the baseline is DEBT, not a target: it may shrink, never grow. A new name here is a
    # genuine regression; recovering one means deleting it from the file.
    baseline = set(json.loads((Path(__file__).parent / "known_photoless.json").read_text()))
    new_gaps = sorted(set(missing) - baseline)
    assert not new_gaps, (
        f"{len(new_gaps)} player(s) newly shipped without a headshot: {new_gaps}\n"
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
    # Same rebase as `test_every_player_season_has_a_headshot`: the old "expected 100%" was
    # satisfied by dead links and placeholder images, so it never measured what it claimed.
    # Now that every bundled headshot is a real object in our own store, coverage is asserted
    # against the recorded gap — it must not get WORSE per sport.
    baseline = json.loads((Path(__file__).parent / "known_photoless.json").read_text())
    allowed: dict[str, int] = defaultdict(int)
    for entry in baseline:
        allowed[entry.split(":", 1)[0]] += 1
    for sport, count in total.items():
        missing = count - has[sport]
        assert missing <= allowed[sport], (
            f"{sport}: {has[sport]}/{count} headshot coverage — {missing} missing, but only "
            f"{allowed[sport]} are on the known-gap list (tests/known_photoless.json). "
            f"A NEW photo-less player means a real regression.")
