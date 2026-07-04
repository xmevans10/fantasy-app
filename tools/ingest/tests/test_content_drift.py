"""Content-drift regression guard: catches "grade.py changed, keep4_puzzles.json wasn't
regenerated" (the M9 failure mode) by loading the SHIPPED bundled JSON, reverse-parsing its
display stat strings for a small set of golden players, and recomputing grade.py's grade()
to confirm it still matches the baked value within rounding tolerance.

Deliberately narrow: this is not test_grade.py's job of proving the formula is *correct*
(monotonic, defensible orderings) — it only proves the shipped artifact still agrees with
current code. A failure here means: regenerate BallIQ/Data/keep4_puzzles.json (or its Data/
siblings) via `python3 -m tools.ingest.main --write-fallback`, not "fix the formula."
"""
import json
from pathlib import Path

from tools.ingest.grade import grade

BUNDLE_PATH = Path(__file__).resolve().parents[3] / "BallIQ" / "Data" / "keep4_puzzles.json"

# Tolerance swallows StatLine display-rounding noise (dec1/int/comma_int formatting); a real
# formula/coefficient drift moves the grade by several points — see CeeDee Lamb below, whose
# 23.3-point gap is real drift caught while writing this test, well outside this band.
#
# Golden players are chosen to be "clean" for this theme's displayed columns: their card shows
# every stat that contributes to nfl_skill_ppr's grade (no incidental non-displayed rushing
# yards/TDs skewing the recompute — e.g. Antonio Brown 2015 was excluded from this set because
# his 28 rushing yards, real production but not a column this WR theme displays, would recompute
# 2.8 points low from display data alone and falsely read as drift).
TOLERANCE = 0.5

GOLDEN = [
    # (theme title, player name, season year, expected bundled grade)
    ("Elite WR receiving seasons", "Julio Jones", 2015, 371.1),   # exact match, no rushing stats
    ("Elite WR receiving seasons", "Randy Moss", 2007, 385.3),    # exact match, no rushing stats
    ("Elite WR receiving seasons", "CeeDee Lamb", 2023, 405.2),   # real drift: 23.3pt gap, expected to fail
]

# nfl_skill_ppr coefficients: receptions x1, receiving_yards x0.1, receiving_tds x6,
# rushing_yards x0.1, rushing_tds x6. This WR theme's columns never include rushing, but the
# mapping covers it anyway for robustness if this test is ever pointed at a theme that does.
_LABEL_TO_STAT = {
    "Rec": "receptions", "Rec Yds": "receiving_yards", "Rec TD": "receiving_tds",
    "Rush Yds": "rushing_yards", "Rush TD": "rushing_tds",
}


def _load_bundle() -> list[dict]:
    return json.loads(BUNDLE_PATH.read_text())


def _find_player(bundle: list[dict], theme: str, name: str, year: int) -> dict:
    for puzzle in bundle:
        if puzzle["theme"] != theme:
            continue
        for p in puzzle["players"]:
            if p["name"] == name and p["seasonYear"] == year:
                return p
    raise AssertionError(f"golden player not found in bundle: {name} {year} ({theme})")


def _numeric_stats(player: dict) -> dict[str, float]:
    out: dict[str, float] = {}
    for line in player["stats"]:
        stat_key = _LABEL_TO_STAT.get(line["label"])
        if stat_key:
            out[stat_key] = float(line["value"].replace(",", ""))
    return out


def test_bundled_wr_grades_match_current_formula():
    bundle = _load_bundle()
    for theme, name, year, expected_grade in GOLDEN:
        player = _find_player(bundle, theme, name, year)
        assert player["grade"] == expected_grade, (
            f"{name} {year}: golden expected_grade is stale — bundle now has "
            f"{player['grade']}; update GOLDEN in this test after confirming the bundle "
            f"regen was intentional."
        )
        stats = _numeric_stats(player)
        recomputed = grade(stats, "nfl_skill_ppr")
        diff = abs(recomputed - player["grade"])
        assert diff < TOLERANCE, (
            f"{name} {year}: bundled grade {player['grade']} vs recomputed {recomputed} "
            f"(diff {diff:.1f}) — grade.py and BallIQ/Data/keep4_puzzles.json have drifted. "
            f"Regenerate the bundle (python3 -m tools.ingest.main --write-fallback) and re-ship."
        )
