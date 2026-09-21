"""Pins the blitz seeder's pure model — the half of the ladder the client now plays.

`ladder_blitz.py` mirrors `BotSolver.playBlitz` and `BlitzScoring.surplus`. Those Swift types are
pinned by `BallIQTests/BotBlitzRunTests.swift`; this is the Python half of the same
duplicate-and-pin arrangement, so a policy change in either language that the other does not share
fails a test instead of silently mis-calibrating `bot_skill`.
"""
from __future__ import annotations

from tools.ingest import ladder_blitz
from tools.ingest.ladder import RUNG_COUNT


def _pool() -> dict[str, list[dict]]:
    keep4 = [{"fmt": "keep4", "id": f"k{i}", "sport": "nfl", "diffs": [0.4] * 8,
              "keeps": [True] * 4 + [False] * 4, "contexts": None, "context": {"sport": "nfl"}}
             for i in range(4)]
    whoami = [{"fmt": "whoami", "id": f"w{i}", "sport": "nba",
               "diffs": [0.2, 0.35, 0.5, 0.65, 0.8, 0.9], "keeps": None,
               "contexts": None, "context": {"sport": "nba"}} for i in range(4)]
    journeyman = [{"fmt": "journeyman", "id": f"j{i}", "sport": "nfl",
                   "diffs": [1.0, 0.75, 0.5, 0.25, 0.0], "keeps": None,
                   "contexts": None, "context": {"sport": "nfl"}} for i in range(4)]
    return {"keep4": keep4, "whoami": whoami, "journeyman": journeyman}


# ── Duration is a variance dial (mirrors LadderBlitz / BotBlitzRun.swift) ───────

def test_duration_rises_with_rung_and_peaks_for_bosses():
    assert ladder_blitz.duration_for(1, False) == 60
    assert ladder_blitz.duration_for(ladder_blitz.ONE_MINUTE_MAX_RUNG, False) == 60
    assert ladder_blitz.duration_for(ladder_blitz.ONE_MINUTE_MAX_RUNG + 1, False) == 180
    assert ladder_blitz.duration_for(RUNG_COUNT, False) == 180
    assert ladder_blitz.duration_for(10, True) == 300


# ── Chance is rebased to exactly zero (mirrors BlitzScoring.surplus) ────────────

def test_surplus_rebases_chance_to_zero_and_keeps_losses():
    # A coin flip on a floor format is worth nothing...
    assert ladder_blitz.surplus(0.5, "keep4") == 0
    # ...perfect is one...
    assert ladder_blitz.surplus(1.0, "keep4") == 1.0
    # ...and worse than chance is negative rather than clamped, which is what stops a
    # guess on a short-par format being the correct way to play badly.
    assert ladder_blitz.surplus(0.0, "keep4") < 0
    # A floorless format is NOT rebased away: whoami has no chance floor, so half a board's
    # worth is half its value...
    assert ladder_blitz.surplus(0.5, "whoami") == 0.5
    # ...and an unsolved whoami board is 0, never a loss.
    assert ladder_blitz.surplus(0.0, "whoami") == 0


def test_pacing_fraction_is_monotone_and_clamped():
    xs = [ladder_blitz.pacing_fraction(s) for s in (0.0, 0.5, 1.0)]
    assert xs == sorted(xs, reverse=True), xs
    assert all(0.35 <= x <= 0.97 for x in xs), xs


# ── The curve has a lever (mirrors BotSolver.playBlitz) ─────────────────────────

def test_bot_skill_lowers_the_reference_players_win_rate():
    """If this goes flat the solver has no lever and `solve_bot_skill` returns whatever it
    started with — the failure the whole blitz move exists to fix."""
    pool = _pool()
    rates = [ladder_blitz.win_rate(pool, sk, 180, trials=60, seed=7) for sk in (0.05, 0.5, 1.0)]
    assert rates == sorted(rates, reverse=True), rates
    assert rates[0] - rates[-1] > 0.3, rates


def test_solver_lands_near_the_target(monkeypatch):
    # The solver bisects 16 times; keep the trial budget small so the suite stays fast.
    monkeypatch.setattr(ladder_blitz, "SOLVE_TRIALS", 40)
    pool = _pool()
    _skill, achieved = ladder_blitz.solve_bot_skill(pool, 0.5, 180)
    assert abs(achieved - 0.5) < 0.25, achieved


# ── What a seeded rung actually writes ─────────────────────────────────────────

def test_build_rungs_are_blitz_rungs_pinning_a_run_shape_not_a_board(monkeypatch):
    pool = _pool()
    roster = [{"id": f"bot{i}", "base_skill": i / (RUNG_COUNT - 1), "style": "consistent",
               "knowledge": None} for i in range(RUNG_COUNT)]
    # Solving is the expensive part and is covered above; this test is about the row shape.
    monkeypatch.setattr(ladder_blitz, "solve_bot_skill",
                        lambda pool, target, duration, knowledge=None: (0.5, target))
    rows = ladder_blitz.build_rungs(pool, roster)

    assert len(rows) == RUNG_COUNT
    assert all(r["mode"] == "blitz" for r in rows)
    # A blitz rung pins no puzzles row: `puzzle_id` must be the run shape, which is legal only
    # because migration 0030 drops the `puzzles` foreign key.
    assert all(r["puzzle_id"] == f"blitz-{r['time_limit_seconds']}s" for r in rows)
    assert all(r["time_limit_seconds"] in (60, 180, 300) for r in rows)
    assert all(r["time_limit_seconds"] == 300 for r in rows if r["is_boss"])


def test_trend_breaks_ignore_bosses_but_catch_a_flat_baseline():
    def row(rung, rate, boss=False):
        return {"rung": rung, "target_win_rate": rate, "is_boss": boss}

    # A correct ladder: the baseline descends, while a boss deliberately dips below the trend —
    # it would trip a naive literal five-rung check (rung 10 below rung 15) but must not be
    # reported, or every reseed with a boss would look broken.
    rows = [row(i, round(0.9 - i * 0.02, 3)) for i in range(1, 31)]
    rows[9] = row(10, 0.30, boss=True)
    assert ladder_blitz.trend_breaks(rows) == []

    # A genuinely flat baseline is still caught.
    assert ladder_blitz.trend_breaks([row(i, 0.5) for i in range(1, 31)])
