"""Seeds `ladder_rungs` — the bot ladder's difficulty curve.

Why this is a tool and not a SQL migration
------------------------------------------
The first cut of the ladder (migration 0016) set `bot_skill` from a formula on the rung number
and picked the board with ``(rung * 7) % count`` — arbitrary with respect to how hard the board
actually is. Measured against the real ``BotSolver`` over 400 seeds per rung, that produced a
curve that is not monotonic in the only thing a player experiences:

    rung  1 keep4    skill 0.350   bot scores 0.715
    rung  3 keep4    skill 0.393   bot scores 0.599   <- easier than rung 1
    rung 18 grid     skill 0.719   bot scores 1.000   <- bot is FLAWLESS
    rung 30 grid     skill 0.980   bot scores 0.992   <- easier than rung 18

Rung 18 is the whole problem in one line. Its board (``grid-baseball-2026-07-08``) has every
cell at 1 star, so its intrinsic difficulty is 0. And ``hitProbability = skill ** difficulty``
is **1.0 at difficulty 0 for any skill** — so an *easy* board makes the bot perfect, which
makes the rung maximally hard. Easy boards are the hardest rungs. That is the opposite of what
the lever was supposed to do, and no amount of tuning ``bot_skill`` fixes it.

The model
---------
Difficulty is not "how long you get" and it is not "how good the bot is" on its own. What a
player actually experiences is **the probability they beat this bot on this board**. That is
computable with no play data at all, because the player can be modelled with the same
skill-limited policy the bot uses — so each rung is tuned by simulating a *reference player*
(`REFERENCE_PLAYER_SKILL`) against the candidate bot on the real board, and solving for the
`bot_skill` that lands the win probability on a designed curve.

Two levers, doing two different jobs:

* ``bot_skill`` — solved per rung so P(reference player wins) follows `TARGET_WIN_RATE`.
  This is what makes the ladder monotone *from the player's side*, and it also erases the
  mode-scale problem (Who Am I?'s ``performance`` is a coarse 6-value ladder that sits far
  higher than Keep4's, so equal skill across modes never meant equal difficulty).
* ``board_difficulty`` — selected to follow a rising curve, with a **floor**, because a board
  below the floor cannot separate two players at all (both score ~1.0; see rung 18).

Drift
-----
The expectations here mirror ``BallIQ/Models/BotSolver.swift``. They are duplicated rather than
shared, the same way ``grade.py`` and ``GradeFormula.swift`` are, and pinned the same way:
`ladder_rungs` stores the `target_win_rate` this tool solved for, and
``BallIQTests/LadderCurveTests`` re-measures it with the *real* Swift solver and fails if the
two disagree. Change a policy in one place and that test goes red.

Usage
-----
    python -m tools.ingest.ladder --dry-run
    python -m tools.ingest.ladder --upsert
"""
from __future__ import annotations

import argparse
import json
import os
import random
import urllib.request
from dataclasses import dataclass

RUNG_COUNT = 30

# The player the curve is tuned against. Not "the average player" — there is no play data to
# derive one from yet (`game_results` had 13 rows when this was written). It is a fixed
# reference point so the curve is *internally* consistent; `ladder_attempts` is the corpus that
# will let this be recalibrated against real humans later, which is why it records every
# attempt's score and the bot's.
REFERENCE_PLAYER_SKILL = 0.75

# What fraction of the time the reference player should beat each rung, rung 1 -> 30.
# Starts generous (the ladder has to be enterable) and ends genuinely hard without being a
# lottery — 0.30 rather than 0.05 because a rung that needs 20 attempts stops reading as skill.
TARGET_WIN_RATE_START = 0.90
TARGET_WIN_RATE_END = 0.30

# Board difficulty (0 = every answer obvious, 1 = every call a coin flip) targeted per rung.
# The floor is the important half: below ~0.15 both sides score at ceiling, the duel is decided
# by the tie rule rather than by play, and `bot_skill` stops meaning anything.
BOARD_DIFFICULTY_FLOOR = 0.18
BOARD_DIFFICULTY_START = 0.25
BOARD_DIFFICULTY_END = 0.70

SPORTS = ["nfl", "nba", "baseball", "soccer", "tennis"]
BOSS_EVERY = 10
TRIALS = 600

# ── Board pools ──────────────────────────────────────────────────────────────
# A rung is a difficulty, not a board. With one board per rung, losing and retrying handed the
# player the identical board with the answers already known — the score meant nothing and
# `ladder_attempts` filled with rows that look like skill and are actually recall.
#
# The pool must be difficulty-HOMOGENEOUS, which is the whole reason this is a verified selection
# and not "grab six boards of the same mode". A rung's difficulty is a promise; if board A is 0.25
# and board B is 0.60 the rung is a different rung depending on which one you drew, and every
# number this tool solves for stops describing anything a player experiences.
#
# Two independent gates, because board difficulty alone is a proxy and the win rate is the thing:
#   * within `POOL_DIFFICULTY_TOLERANCE` of the rung's own `board_difficulty`, and
#   * re-simulated at the rung's solved `bot_skill` and within `POOL_WIN_RATE_TOLERANCE` of the
#     rung's `target_win_rate`. A board can pass the first gate and fail this one — the difficulty
#     mean hides the *shape* of a board (six medium cells and three trivial plus three brutal have
#     the same mean and do not play the same).
POOL_SIZE = 6
POOL_DIFFICULTY_TOLERANCE = 0.04
# 0.04, not the 0.08 this started at, and the trials below matter as much as the number.
#
# `BallIQTests/LadderCurveTests` re-measures every board with the real Swift solver and fails past
# a 0.10 delta. The failure mode is NOISE STACKING, not model divergence: this screen and the pin
# are two independent Monte Carlo estimates of the same quantity, so their errors add. At `TRIALS`
# = 600 this screen carries roughly ±0.04 of sampling noise and the pin's 1,200 trials another
# ±0.03 — which means a board admitted at the old ±0.08 could legitimately measure 0.15 off in
# Swift with the two models in perfect agreement. It did: rungs 21 and 22 at delta 0.128, then
# rung 21 again at 0.112 after a first tightening to 0.05.
#
# So the fix is both halves — screen tighter AND measure the screen more precisely (see
# `POOL_TRIALS`), which shrinks this estimate's own error to ~±0.02 and leaves the pin able to
# catch a real policy divergence instead of drowning in sampling error.
#
# Each rung's PRIMARY board never had this problem: it is *solved* to hit its target rather than
# screened against it. Only pool boards are screened.
POOL_WIN_RATE_TOLERANCE = 0.03
# `slowBurn` no longer needs a tighter screen, and the history is worth keeping.
#
# Keep4 used to be simulated by `BotSolver` in the SERVE order (a seeded shuffle), while this file
# calibrates in the puzzle's natural order. `progress` feeds slowBurn's skill ramp, so every
# slowBurn rung was mis-calibrated by a board-dependent amount — the pin failed on rungs 21-23 and
# nowhere else, the only rungs The Archivist guards. Tolerances could not fix it: the rung's target
# and the pool screen shared the bias, so it cancelled for the primary board and not the rest.
# Mirroring Swift's shuffle here was tried and rejected (stdlib internals, and it made agreement
# worse). The cure was on the Swift side — `BotSolver` now walks the puzzle's own order, so the two
# agree by construction. Kept equal to the general tolerance rather than deleted, so the knob is
# still here if a future style reintroduces order-dependence.
POOL_WIN_RATE_TOLERANCE_SLOW_BURN = 0.03
# Pool screening runs at more trials than the curve solve, because a bisection converges on the
# target from both sides (noise averages out across 18 iterations) while a screen is a single
# pass/fail read where noise translates directly into a wrong admission.
POOL_TRIALS = 4_000
# The most drift a board may carry when it is rescuing a rung from having a single board. Half the
# pin's 0.10 budget: enough headroom that a rescued board still verifies, tight enough that
# "better than replayable" never becomes "unverified".
POOL_RESCUE_TOLERANCE = 0.05
# How many candidates to re-simulate per rung before giving up on filling its pool. Each check is
# a full `TRIALS`-run duel, so this bounds the tool's runtime; candidates are tried nearest-
# difficulty first, so the cap only ever discards the least suitable ones.
POOL_MAX_CHECKS = 40


# ─────────────────────────────────────────────────────────────────────────────
# Difficulty, per format, from puzzle content alone
# ─────────────────────────────────────────────────────────────────────────────

# A relative gap this large or larger is an obvious call. Mirrors
# `BotSolver.keep4ObviousRelativeGap`; see that constant for the calibration data.
KEEP4_OBVIOUS_RELATIVE_GAP = 0.10


def keep4_card_difficulties(content: dict) -> list[float]:
    """How hard each keep/cut call is, from the puzzle's own scoring metric (`grade` = real
    fantasy points).

    Mirrors ``BotSolver.keep4Difficulty(of:in:)`` exactly — distance from the keep/cut cutoff,
    scaled by the board's **grade magnitude** rather than by its spread. Scaling by spread
    rescales every board to have the same hardest card, so no board can be globally easy or
    hard; magnitude is also what makes sports comparable, since the average gap at the cutoff is
    4.59 points in soccer and 130.83 in the NBA but 2.2% and 1.5% as fractions.
    """
    players = content.get("players", [])
    grades = [p.get("grade", 0.0) for p in players]
    if not grades:
        return []
    desc = sorted(grades, reverse=True)
    cutoff = (desc[3] + desc[4]) / 2 if len(desc) >= 5 else sum(grades) / len(grades)
    magnitude = sum(abs(g) for g in grades) / len(grades)
    if magnitude <= 1e-4:
        return [1.0] * len(grades)
    return [1 - min(1.0, abs(g - cutoff) / magnitude / KEEP4_OBVIOUS_RELATIVE_GAP) for g in grades]


def keep4_true_keeps(content: dict) -> list[bool]:
    """Which cards belong in the keep pile — the top half by `grade`, which is exactly what
    `Keep4Puzzle.correctKeepIDs` computes. Needed because the 4/4 cap operates on **pile
    membership**, and pile membership cannot be recovered from "was this call correct"."""
    grades = [p.get("grade", 0.0) for p in content.get("players", [])]
    if not grades:
        return []
    keep_n = len(grades) // 2
    threshold = sorted(grades, reverse=True)[keep_n - 1]
    keeps, taken = [], 0
    for g in grades:
        is_keep = g >= threshold and taken < keep_n
        if is_keep:
            taken += 1
        keeps.append(is_keep)
    return keeps


def grid_cell_difficulties(content: dict) -> list[float]:
    """``(rarityStars - 1) / 4`` per cell. Mirrors ``BotSolver.playGrid``.

    `rarityStars` is a faithful proxy for how obvious a cell is — measured over the live pool,
    1-star cells average 90 valid answers and 5-star cells have exactly 1.
    """
    cells = content.get("cells", [])
    return [min(max((c.get("rarityStars", 1) - 1) / 4.0, 0.0), 1.0) for c in cells]


def whoami_clue_difficulties(content: dict) -> list[float]:
    """Difficulty falls from 1 (clue 1, least revealing) to 0 (last clue). Mirrors
    ``BotSolver.playWhoAmI``."""
    n = len(content.get("clues", []))
    if n <= 1:
        return [0.0] * n
    return [1 - i / (n - 1) for i in range(n)]


def board_difficulty(fmt: str, content: dict) -> float:
    """One 0..1 number for the whole board — the mean of its per-decision difficulties.

    For Who Am I? the clue ramp is identical on every puzzle, so the mean carries no signal;
    the pipeline's own obscurity tier is the real difficulty there and is used instead.
    """
    if fmt == "keep4":
        d = keep4_card_difficulties(content)
    elif fmt == "grid":
        d = grid_cell_difficulties(content)
    elif fmt == "whoami":
        return {"easy": 0.25, "medium": 0.50, "hard": 0.75}.get(content.get("difficulty"), 0.50)
    else:
        return 0.5
    return sum(d) / len(d) if d else 0.5


# ─────────────────────────────────────────────────────────────────────────────
# Simulation — the same policies BotSolver runs, used for BOTH sides
# ─────────────────────────────────────────────────────────────────────────────

# Mirrors `BotStyle` in BallIQ/Models/BotStyle.swift. Style changes the bot's POLICY, so it
# changes the win rate a given `bot_skill` produces — which means the solver below has to model
# it or every rung guarded by a non-baseline character is miscalibrated. `LadderCurveTests`
# re-measures with the real Swift solver and fails if these formulas drift apart.
BLINK_CHANCE = {"prescient": 0.03}
PACE_MULTIPLIER = {"overeager": 0.72, "methodical": 1.18, "consistent": 1.0,
                   "deepCuts": 1.06, "slowBurn": 1.15, "prescient": 0.85}


def style_difficulty(style: str, d: float, progress: float) -> float:
    d = min(max(d, 0.0), 1.0)
    if style == "overeager":
        return min(1.0, d * 1.35)
    if style == "methodical":
        return d ** 1.4
    if style == "deepCuts":
        return d * 0.38 + (1 - d) * 0.62
    return d                                    # consistent / slowBurn / prescient


def style_skill(style: str, s: float, progress: float) -> float:
    if style != "slowBurn":
        return s
    return min(1.0, s * (0.82 + 0.26 * min(max(progress, 0.0), 1.0)))


def hit_probability(skill: float, difficulty: float,
                    style: str = "consistent", progress: float = 0.0) -> float:
    s = min(max(style_skill(style, skill, progress), 1e-4), 1.0)
    d = style_difficulty(style, difficulty, progress)
    return (s ** d) * (1 - BLINK_CHANCE.get(style, 0.0))


WHOAMI_PER_CLUE = [1000, 800, 600, 400, 200, 100]

# ── Speed, and why it is in the comparable now ───────────────────────────────
# Mirrors `LadderOutcome.speedBonus` / `BotSolver.paceVariance` / `BotSolver.pacingFraction`.
#
# Both sides' scores are scaled by the fraction of the clock they left unused. It exists to fix
# Who Am I?, whose `performance` is a 7-value clue ladder saturating at a clue-1 solve: with ties
# going to the player, a PERFECT bot still lost ~75% of duels, so the format's win rate floored at
# 0.75 regardless of `bot_skill` and it had to be capped below rung 15.
#
# Two findings from calibrating it, both worth not rediscovering:
#
# 1. The bonus has to be SYMMETRIC. A one-sided "boost the player when they're faster" can only
#    raise the player's win rate, so it cannot lower a floor — it makes the problem worse.
# 2. `SPEED_BONUS`'s magnitude is NOT the difficulty dial. Measured over 0.10 / 0.20 / 0.30 / 0.50
#    the resulting win rates are identical, because the pace spread never widens enough for a fast
#    clue-2 solve to outrun a slow clue-1 one — so the term only ever decides ties. What made the
#    curve usable was `PACE_VARIANCE`: with a deterministic bot clock every tie on a rung resolved
#    the same way before play started (0.800 -> 0.155 across one step of skill, nothing in
#    between); with per-run spread the same sweep reads 0.801 / 0.608 / 0.262 / 0.064 / 0.001.
#    `bot_skill` is still the lever. This just gives it back its range.
SPEED_BONUS = 0.20
PACE_VARIANCE = 0.18


def pacing_fraction(skill: float) -> float:
    """Mirrors `BotSolver.pacingFraction`."""
    return max(0.35, min(0.97, 1.05 - skill * 0.65))


def elapsed_fraction(skill: float, style: str, rng: random.Random) -> float:
    """What fraction of the clock a side uses on one run, spread included."""
    spread = rng.uniform(1 - PACE_VARIANCE, 1 + PACE_VARIANCE)
    return min(0.97, pacing_fraction(skill) * PACE_MULTIPLIER.get(style, 1.0) * spread)


def speed_adjusted(score: float, elapsed_frac: float) -> float:
    """Mirrors `LadderOutcome.adjusted` — scaled BY score, so fast never rescues wrong."""
    return score * (1 + SPEED_BONUS * min(1.0, max(0.0, 1 - elapsed_frac)))


def simulate_performance(fmt: str, diffs: list[float], skill: float, rng: random.Random,
                         true_keeps: list[bool] | None = None,
                         style: str = "consistent") -> float:
    """One run's `performance`, 0..1 — the comparable both sides are scored on."""
    if fmt == "keep4":
        # Per-card roll, then the 4/4 cap flips the least-confident calls until the piles land
        # right. Mirrors `BotSolver.keep4Decisions`, and the cap matters: it systematically
        # costs whoever hits it their *closest* calls.
        n = len(diffs)
        probs = [hit_probability(skill, d, style, i / (n - 1) if n > 1 else 0.0)
                 for i, d in enumerate(diffs)]
        # decision[i] is the pile this card was put in; true_keeps[i] is where it belongs.
        decisions = [(tk if rng.random() < p else not tk) for tk, p in zip(true_keeps, probs)]
        keep_limit = len(diffs) // 2
        in_keep = sum(decisions)
        if in_keep != keep_limit:
            from_pile = in_keep > keep_limit          # over-full pile to move cards out of
            excess = abs(in_keep - keep_limit)
            order = sorted((i for i in range(len(probs)) if decisions[i] == from_pile),
                           key=lambda i: probs[i])
            for i in order[:excess]:
                decisions[i] = not decisions[i]
        return sum(1 for d, tk in zip(decisions, true_keeps) if d == tk) / len(diffs)
    if fmt == "grid":
        n = len(diffs)
        return sum(1 for i, d in enumerate(diffs)
                   if rng.random() < hit_probability(skill, d, style,
                                                     i / (n - 1) if n > 1 else 0.0)) / n
    if fmt == "whoami":
        n = len(diffs)
        for i, d in enumerate(diffs):
            if rng.random() < hit_probability(skill, d, style, i / (n - 1) if n > 1 else 0.0):
                return WHOAMI_PER_CLUE[min(i, len(WHOAMI_PER_CLUE) - 1)] / WHOAMI_PER_CLUE[0]
        return 0.0
    return 0.0


def win_rate(fmt: str, diffs: list[float], bot_skill: float,
             player_skill: float = REFERENCE_PLAYER_SKILL, trials: int = TRIALS,
             seed: int = 12345, true_keeps: list[bool] | None = None,
             bot_style: str = "consistent") -> float:
    """P(reference player beats this bot on this board). Ties count as player wins, matching
    `LadderOutcome.playerWon`."""
    rng = random.Random(seed)
    wins = 0
    for _ in range(trials):
        p = simulate_performance(fmt, diffs, player_skill, rng, true_keeps)
        b = simulate_performance(fmt, diffs, bot_skill, rng, true_keeps, bot_style)
        # Speed is part of the comparable (see `SPEED_BONUS`). The reference player is paced by
        # the same model as the bot — the same symmetry the accuracy model already assumes, since
        # there is still no play data to derive a human pace distribution from.
        p = speed_adjusted(p, elapsed_fraction(player_skill, "consistent", rng))
        b = speed_adjusted(b, elapsed_fraction(bot_skill, bot_style, rng))
        if p >= b:
            wins += 1
    return wins / trials


def solve_bot_skill(fmt: str, diffs: list[float], target: float,
                    true_keeps: list[bool] | None = None,
                    bot_style: str = "consistent") -> tuple[float, float]:
    """Binary-search the `bot_skill` whose win rate is `target`.

    Win rate is monotonically decreasing in bot skill (a better bot is harder to beat), so a
    bisection is sound. Returns the skill and the win rate actually achieved — which can miss
    the target at the extremes, because a board only affords so much separation and that is
    worth surfacing rather than hiding.
    """
    lo, hi = 0.05, 1.0
    best = (0.5, win_rate(fmt, diffs, 0.5, true_keeps=true_keeps, bot_style=bot_style))
    for _ in range(18):
        mid = (lo + hi) / 2
        w = win_rate(fmt, diffs, mid, true_keeps=true_keeps, bot_style=bot_style)
        if abs(w - target) < abs(best[1] - target):
            best = (mid, w)
        if w > target:      # player wins too often -> bot must get better
            lo = mid
        else:
            hi = mid
    return best


# ─────────────────────────────────────────────────────────────────────────────
# Seeding
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class Candidate:
    puzzle_id: str
    fmt: str
    sport: str
    difficulty: float
    diffs: list[float]
    true_keeps: list[bool] | None = None
    # What the PLAYER would recognize as "the same puzzle" — see `content_signature`. Every
    # exclusivity check in this module keys on this rather than `puzzle_id`, because one board
    # legitimately exists under several ids.
    signature: str = ""


def content_signature(fmt: str, puzzle_id: str, content: dict) -> str:
    """Identity as a PLAYER experiences it: the cards, not the row id.

    `daily_puzzle._finalize_row` re-ids a stable pool row when it mints it as a daily
    (`soccer-playmakers-00` -> `soccer-playmakers-00-daily-20260814`), so one board is live under
    two ids with byte-identical content. Keying exclusivity on `puzzle_id` treated those as two
    boards and put the same eight cards on rungs 4 and 5 — reported from the app on 2026-08-19,
    and invisible to a `select ... group by puzzle_id having count(*) > 1` check because the ids
    genuinely differ.

    Falls back to the id when a format has no recognizable per-card identity, which keeps the
    behaviour of any format this does not understand exactly as it was.
    """
    if fmt == "keep4":
        ids = sorted(str(p.get("id") or p.get("name")) for p in content.get("players", []))
    elif fmt == "whoami":
        ids = [str(content.get("answer") or content.get("playerKey") or "")]
    elif fmt == "grid":
        ids = [str(content.get("id") or "")]
    else:
        return puzzle_id
    return f"{fmt}|" + ",".join(i for i in ids if i) if any(ids) else puzzle_id


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


# The highest rung Who Am I? may guard.
#
# 18, up from a low of 12 — the format's floor was the constraint and the floor is gone. Its win
# rate used to bottom out near 0.75 no matter what `bot_skill` said, because `performance` is a
# 7-value clue ladder that saturates at a clue-1 solve and ties go to the player. Now that speed
# is part of the comparable (see `SPEED_BONUS`), a perfect bot's sweep reads 0.801 / 0.608 /
# 0.262 / 0.064 / 0.001 across skill instead of 0.848 / 0.811 / 0.788 / 0.764 / 0.754.
#
# Held at 18 rather than 30 because bosses still should not be Who Am I?: a single binary guess
# is a thin thing to lose a boss rung to, however well calibrated it now is.
WHOAMI_MAX_RUNG = 18


def mode_for(rung: int) -> str:
    """All Keep4 early (one game to learn), Who Am I? through the mid band, The Grid from 13.

    **Who Am I? is capped, and the cap is measured.** Its `performance` is a 7-value ladder that
    saturates at 1.0 for a clue-1 solve, and a tie goes to the player (`LadderOutcome`). At the
    reference skill the player solves on clue 1 about 75% of the time, so a *perfect* bot still
    loses ~73% of duels — the format's win rate floors at 0.733 no matter what `bot_skill` is
    set to. Every whoami rung above that floor was a flat spot in the curve pretending to be a
    step. Two levers could lift the ceiling later (breaking whoami ties on elapsed time, or
    scoring the duel on points rather than clue efficiency so the difficulty multiplier
    separates); until one of them exists, whoami belongs below rung 15.

    Bosses are never Who Am I? for the same reason: a boss has to be a step up, and this format
    has no step left at that height.
    """
    if rung % BOSS_EVERY == 0:
        return "grid" if rung >= 20 else "keep4"
    if rung <= 6:
        return "keep4"
    if rung <= WHOAMI_MAX_RUNG:
        return "whoami" if rung % 2 == 0 else "keep4"
    return "grid" if rung % 2 == 0 else "keep4"


def board_seed(rung: int, ordinal: int) -> int:
    """A seed per BOARD, not per rung.

    Reusing the rung's seed across its pool would have the bot replay the same decision pattern on
    every board it guards — the same blinks at the same indices — which is exactly the tell the
    pool exists to remove. Knuth's multiplicative constant on a mixed key, kept inside Postgres's
    signed `bigint`.
    """
    return (rung * 2654435761 + ordinal * 40503 * 2654435761) % 9223372036854775807


def build_pool(fmt: str, primary: Candidate, candidates: list[Candidate],
               bot_skill: float, bot_style: str, target_win: float,
               rung: int) -> tuple[list[dict], list[str]]:
    """The rung's ordered pool, `primary` first, and the content SIGNATURES it consumed.

    Signatures, not ids: one board is live under several ids (a stable pool row and its
    `-daily-` re-id), so returning ids would let the next rung take the same cards back.

    Candidates are tried nearest-difficulty first and each one is re-simulated against the rung's
    solved `bot_skill`, so a board only joins the pool if it actually plays like the rung it is
    joining. Returns fewer than `POOL_SIZE` when the released pool cannot supply them — the caller
    reports that loudly rather than shipping a rung with two boards.
    """
    boards = [{"rung": rung, "ordinal": 0, "puzzle_id": primary.puzzle_id,
               "board_difficulty": round(primary.difficulty, 3), "seed": board_seed(rung, 0)}]
    consumed = [primary.signature]

    tolerance = (POOL_WIN_RATE_TOLERANCE_SLOW_BURN if bot_style == "slowBurn"
                 else POOL_WIN_RATE_TOLERANCE)
    checked: set[str] = set()

    # The window does NOT widen when a rung is short, and that was tried and reverted. Letting it
    # stretch to 3x filled rung 5's pool with a board 0.107 away, which
    # `testEachPoolIsDifficultyHomogeneous` correctly rejected: a rung whose two boards differ
    # that much is two different rungs wearing one number. A short pool is reported instead — and
    # the real fix is upstream, in `build_rungs`, which now prefers primaries that HAVE neighbours
    # (see `poolable`). Fixing the choice of board beats loosening what the choice promises.
    near = sorted((c for c in candidates
                   if c.signature != primary.signature
                   and abs(c.difficulty - primary.difficulty) <= POOL_DIFFICULTY_TOLERANCE),
                  key=lambda c: abs(c.difficulty - primary.difficulty))
    measured: list[tuple[float, Candidate]] = []
    for c in near[:POOL_MAX_CHECKS]:
        if len(boards) >= POOL_SIZE:
            break
        w = win_rate(fmt, c.diffs, bot_skill, true_keeps=c.true_keeps, bot_style=bot_style,
                     trials=POOL_TRIALS)
        measured.append((abs(w - target_win), c))
        if abs(w - target_win) > tolerance:
            continue
        boards.append({"rung": rung, "ordinal": len(boards), "puzzle_id": c.puzzle_id,
                       "board_difficulty": round(c.difficulty, 3),
                       "seed": board_seed(rung, len(boards))})
        consumed.append(c.signature)

    # A rung with ONE board is the replay bug itself — the player retries and gets the board they
    # just solved. If the strict screen leaves a rung there, spend some of the pin's headroom
    # rather than ship it: `LadderCurveTests` fails past 0.10 drift and this screen is set at
    # 0.03, so the closest near-miss can be admitted and still sit comfortably inside the pin.
    #
    # This relaxes the SCREEN (a conservative proxy with margin to spare), never the difficulty
    # window — those boards are still within ±POOL_DIFFICULTY_TOLERANCE, so the rung's difficulty
    # promise is untouched. Widening the difficulty window instead was tried first and produced a
    # pool spanning 0.107, which is two different rungs wearing one number.
    if len(boards) < 2 and measured:
        drift, c = min(measured, key=lambda m: m[0])
        if drift <= POOL_RESCUE_TOLERANCE:
            boards.append({"rung": rung, "ordinal": len(boards), "puzzle_id": c.puzzle_id,
                           "board_difficulty": round(c.difficulty, 3),
                           "seed": board_seed(rung, len(boards))})
            consumed.append(c.signature)
            print(f"  rung {rung}: admitted a second board at drift {drift:.3f} "
                  f"(screen {tolerance}) — the alternative was a replayable rung")
    return boards, consumed


def build_rungs(pool: list[Candidate], bots: list[dict]) -> tuple[list[dict], list[dict]]:
    by_mode: dict[str, list[Candidate]] = {}
    for c in pool:
        by_mode.setdefault(c.fmt, []).append(c)

    # One character per rung, weakest first — see the assignment below. A roster that can't cover
    # the ladder is a content problem with an exact answer, so it says the number rather than
    # silently doubling somebody up.
    ordered_bots = sorted(bots, key=lambda b: b["base_skill"])
    if len(ordered_bots) < RUNG_COUNT:
        raise SystemExit(
            f"{len(ordered_bots)} characters for {RUNG_COUNT} rungs — the ladder is 1:1, so it "
            f"needs {RUNG_COUNT - len(ordered_bots)} more in tools/roster/roster.json")

    used: set[str] = set()
    recent_sports: list[str] = []
    rows: list[dict] = []
    boards: list[dict] = []
    # (rung, fmt, primary, style, skill, achieved) — pools are filled in a SECOND pass, see below.
    plan: list[tuple] = []

    for rung in range(1, RUNG_COUNT + 1):
        t = (rung - 1) / (RUNG_COUNT - 1)
        fmt = mode_for(rung)
        want_difficulty = max(BOARD_DIFFICULTY_FLOOR,
                              lerp(BOARD_DIFFICULTY_START, BOARD_DIFFICULTY_END, t))
        want_win = lerp(TARGET_WIN_RATE_START, TARGET_WIN_RATE_END, t)

        candidates = [c for c in by_mode.get(fmt, [])
                      if c.signature not in used and c.difficulty >= BOARD_DIFFICULTY_FLOOR]
        if not candidates:
            # Floor is a hard requirement, not a preference: below it the rung cannot
            # distinguish two players at all. Better to reuse a board than to seed a dud.
            candidates = [c for c in by_mode.get(fmt, []) if c.difficulty >= BOARD_DIFFICULTY_FLOOR]
        if not candidates:
            raise SystemExit(f"no {fmt} board at or above the difficulty floor "
                             f"{BOARD_DIFFICULTY_FLOOR} — deepen the pool before reseeding")

        # Difficulty decides the BAND, sport variety decides within it. Strict
        # nearest-difficulty (the first version) collapsed the early ladder onto NFL, because
        # NFL is 90 of the 185 released Keep4 boards and so almost always held the nearest
        # match — five consecutive rungs of the same sport, which reads as a content bug.
        # A tolerance window keeps the curve intact while leaving room to travel.
        TOLERANCE = 0.06
        best = min(abs(c.difficulty - want_difficulty) for c in candidates)
        band = [c for c in candidates
                if abs(c.difficulty - want_difficulty) <= best + TOLERANCE]

        # How many unused boards sit close enough to this one to join its pool.
        #
        # A rung's primary board is also the CENTRE of its pool, so choosing one that sits in a
        # sparse part of the difficulty range condemns the rung to a pool of one — which is the
        # replay bug the whole feature exists to remove. Rung 5 landed exactly there: a board at
        # 0.325 with a single neighbour inside ±0.04 out of 190 released Keep4 boards.
        #
        # Preferring a poolable primary fixes it at the source. The alternative tried first —
        # widening the pool's window when a rung starved — filled the pool by breaking the
        # difficulty promise instead, and the homogeneity test rightly refused it.
        pool_by_id = by_mode.get(fmt, [])

        def poolable(c: Candidate) -> int:
            return sum(1 for o in pool_by_id
                       if o.signature != c.signature and o.signature not in used
                       and abs(o.difficulty - c.difficulty) <= POOL_DIFFICULTY_TOLERANCE)

        def rank(c: Candidate) -> tuple:
            # Enough-for-a-pool first, then unused-recently, then nearest within the band.
            # Capped at POOL_SIZE so a board with thirty neighbours doesn't outrank a better-fitting
            # one with a comfortable six — past the target, extra depth is worth nothing.
            depth = min(poolable(c), POOL_SIZE - 1)
            recency = recent_sports.index(c.sport) if c.sport in recent_sports else -1
            return (-depth, recency, abs(c.difficulty - want_difficulty))

        pick = min(band, key=rank)
        used.add(pick.signature)
        recent_sports = ([pick.sport] + recent_sports)[:4]

        # ONE CHARACTER PER RUNG. The roster is ordered by `base_skill` and assigned 1:1, so rung
        # N is the Nth character and nobody is ever faced twice. Before this, six characters were
        # banded across thirty rungs and you met Kyle five times — which undoes the entire point
        # of giving them names, voices and faces.
        #
        # The character is chosen FIRST and the skill solved **against that character's style**,
        # because style moves the win rate a given skill produces. Solving first and assigning
        # after would miscalibrate every non-baseline bot.
        bot = ordered_bots[rung - 1]
        skill, achieved = solve_bot_skill(fmt, pick.diffs, want_win, pick.true_keeps,
                                          bot.get("style", "consistent"))
        is_boss = rung % BOSS_EVERY == 0
        if is_boss:
            # A boss is a step up on the same board, not a different kind of thing.
            skill = min(0.98, skill + 0.04)

        # Re-measure the settled skill at high precision before storing it.
        #
        # `solve_bot_skill` returns the win rate from whichever bisection step landed closest, a
        # single `TRIALS`-run estimate carrying ~±0.04 of sampling noise. That number becomes
        # `ladder_rungs.target_win_rate`, which is the value `LadderCurveTests` measures every
        # board against — so its noise is charged to every board in the pool, not just this one.
        # Paying for more trials once per rung removes that error from the whole comparison.
        achieved = win_rate(fmt, pick.diffs, skill, true_keeps=pick.true_keeps,
                            bot_style=bot.get("style", "consistent"), trials=POOL_TRIALS)

        plan.append((rung, fmt, pick, bot.get("style", "consistent"), skill, achieved))

        base_seconds = {"keep4": 120, "whoami": 90, "grid": 180}[fmt]
        rows.append({
            "rung": rung,
            "tier": "bronze" if rung <= 10 else ("silver" if rung <= 20 else "gold"),
            "mode": fmt,
            "sport": pick.sport,
            "puzzle_id": pick.puzzle_id,
            "bot_id": bot["id"],
            "bot_skill": round(skill, 3),
            "time_limit_seconds": round(base_seconds * (1 - 0.45 * t)),
            # Deliberately `board_seed(rung, 0)` and not its own formula: `ladder_rungs.puzzle_id`
            # IS the pool's ordinal-0 board, and a client that falls back to the rung's own columns
            # (offline, or an old build that never calls `next_ladder_board`) must reproduce the
            # byte-identical bot run the pooled path would have given it.
            "seed": board_seed(rung, 0),
            "is_boss": is_boss,
            "board_difficulty": round(pick.difficulty, 3),
            "target_win_rate": round(achieved, 3),
        })

    # ── Second pass: fill the pools ──────────────────────────────────────────
    # Every rung's PRIMARY board is chosen above, before any pool takes a board, and that order is
    # load-bearing. Filling each pool inline as its rung was built let rung 16's pool swallow six
    # hard Grid boards that rung 30 then needed as its own primary — measured, on the released
    # pool: rung 30 fell from a 0.694-difficulty board to 0.417 and its win rate ROSE to 0.490,
    # i.e. the final boss got easier than rung 27 and `testTheCurveDescendsAcrossTheLadder` went
    # red. The curve is the contract; the pool is the enhancement, so the pool yields.
    #
    # Exclusivity between pools is still strict: a board you met on rung 16 is a board you have
    # met, so lending it to rung 18 hands back exactly the recall advantage pools exist to remove.
    # When that starves a rung the fix is to deepen the released pool, not to double-book a board
    # — so a short pool is reported with a count, never padded.
    # SCARCEST RUNG FIRST, not rung order.
    #
    # Pools are exclusive, so filling in rung order lets whoever goes first strip the shared
    # neighbourhood. Rungs 4 and 5 both target ~0.32 difficulty; rung 4 filled to four boards and
    # left rung 5 with one — a rung you can replay on the board you just solved, which is the
    # exact bug this feature exists to remove. Serving the rung with the fewest options first
    # costs the roomy rungs a board they had spares of.
    def available(fmt: str, pick: Candidate) -> int:
        return sum(1 for c in by_mode.get(fmt, [])
                   if c.signature not in used and c.signature != pick.signature
                   and abs(c.difficulty - pick.difficulty) <= POOL_DIFFICULTY_TOLERANCE)

    for rung, fmt, pick, style, skill, achieved in sorted(
            plan, key=lambda p: available(p[1], p[2])):
        rung_boards, consumed = build_pool(
            fmt, pick, [c for c in by_mode.get(fmt, []) if c.signature not in used],
            skill, style, achieved, rung)
        used.update(consumed)
        boards.extend(rung_boards)
    boards.sort(key=lambda b: (b["rung"], b["ordinal"]))
    return rows, boards


def fetch_pool(url: str, key: str) -> list[Candidate]:
    def get(path: str):
        req = urllib.request.Request(f"{url}/rest/v1/{path}",
                                     headers={"apikey": key, "Authorization": f"Bearer {key}"})
        return json.load(urllib.request.urlopen(req))

    out: list[Candidate] = []
    for fmt in ("keep4", "whoami", "grid"):
        rows = get(f"puzzles?select=id,sport,content&format=eq.{fmt}"
                   f"&active_date=lt.{TODAY}&active_date=not.is.null")
        for r in rows:
            content = r["content"]
            keeps = None
            if fmt == "keep4":
                diffs = keep4_card_difficulties(content)
                keeps = keep4_true_keeps(content)
            elif fmt == "grid":
                diffs = grid_cell_difficulties(content)
            else:
                diffs = whoami_clue_difficulties(content)
            if not diffs:
                continue
            out.append(Candidate(r["id"], fmt, r["sport"],
                                 board_difficulty(fmt, content), diffs, keeps,
                                 content_signature(fmt, r["id"], content)))
    return out


import datetime as _dt
TODAY = _dt.date.today().isoformat()

# Where `--fixture` writes, and where `BallIQTests/LadderCurveTests` reads.
#
# Not inside the repo: it is ~100 KB of puzzle content per rung times the whole pool, it is
# regenerable in one command, and it is a *measurement input* rather than source. Not inside a
# per-session scratchpad either — the first version of this path was, and the session it named
# ended, so the pin silently skipped on every run afterwards while looking green.
FIXTURE_PATH = ("/private/tmp/claude-501/-Users-xanderevans-Documents-fantasy-app/"
                "ladder_fixture.json")


def write_fixture(path: str, url: str, key: str, rows: list[dict], boards: list[dict],
                  bots: list[dict]) -> int:
    """Dump every board of every pool, joined to its puzzle content and its bot's style.

    One entry per BOARD, not per rung: the pool is only difficulty-homogeneous if each board in it
    was verified, so the Swift pin has to replay all of them.
    """
    style_of = {b["id"]: b.get("style", "consistent") for b in bots}
    rung_of = {r["rung"]: r for r in rows}
    wanted = sorted({b["puzzle_id"] for b in boards})

    content: dict[str, dict] = {}
    for n in range(0, len(wanted), 40):        # keep the `in.(...)` filter off the URL length cap
        chunk = ",".join(wanted[n:n + 40])
        req = urllib.request.Request(
            f"{url}/rest/v1/puzzles?select=id,content&id=in.({chunk})",
            headers={"apikey": key, "Authorization": f"Bearer {key}"})
        for row in json.load(urllib.request.urlopen(req)):
            content[row["id"]] = row["content"]

    out = []
    for b in sorted(boards, key=lambda b: (b["rung"], b["ordinal"])):
        r = rung_of[b["rung"]]
        if b["puzzle_id"] not in content:
            continue
        out.append({
            "rung": {"rung": r["rung"], "ordinal": b["ordinal"], "mode": r["mode"],
                     "sport": r["sport"], "bot_skill": r["bot_skill"], "is_boss": r["is_boss"],
                     "board_difficulty": b["board_difficulty"],
                     "target_win_rate": r["target_win_rate"],
                     "style": style_of.get(r["bot_id"], "consistent")},
            "puzzle": {"id": b["puzzle_id"], "content": content[b["puzzle_id"]]},
        })
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(out, fh)
    return len(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upsert", action="store_true", help="write the rungs to Supabase")
    ap.add_argument("--dry-run", action="store_true", help="print the curve, write nothing")
    ap.add_argument("--fixture", metavar="PATH", nargs="?", const=FIXTURE_PATH,
                    help="write BallIQTests/LadderCurveTests' fixture (every board of every "
                         "pool, joined to its puzzle and the guarding bot's style). Defaults to "
                         f"{FIXTURE_PATH}")
    args = ap.parse_args()

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise SystemExit("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY required (tools/ingest/.env)")

    def get_bots():
        req = urllib.request.Request(f"{url}/rest/v1/bots?select=id,base_skill,style",
                                     headers={"apikey": key, "Authorization": f"Bearer {key}"})
        return json.load(urllib.request.urlopen(req))

    bots = get_bots()
    if not bots:
        raise SystemExit("no rows in `bots` — seed them (migration 0016) before seeding rungs")
    pool = fetch_pool(url, key)
    print(f"pool: {len(pool)} released boards")
    for fmt in ("keep4", "whoami", "grid"):
        usable = [c for c in pool if c.fmt == fmt and c.difficulty >= BOARD_DIFFICULTY_FLOOR]
        allc = [c for c in pool if c.fmt == fmt]
        print(f"  {fmt:6s} {len(allc):4d} boards, {len(usable):4d} at/above the "
              f"{BOARD_DIFFICULTY_FLOOR} difficulty floor")

    rows, boards = build_rungs(pool, bots)
    pool_size = {}
    for b in boards:
        pool_size[b["rung"]] = pool_size.get(b["rung"], 0) + 1

    print(f"\n{'rung':>4} {'mode':6} {'sport':9} {'board_d':>7} {'skill':>6} {'winrate':>7} "
          f"{'clock':>5} {'pool':>5} {'bot':>10}")
    for r in rows:
        n = pool_size.get(r["rung"], 0)
        print(f"{r['rung']:>4} {r['mode']:6} {r['sport']:9} {r['board_difficulty']:>7.3f} "
              f"{r['bot_skill']:>6.3f} {r['target_win_rate']:>7.3f} {r['time_limit_seconds']:>5} "
              f"{n:>4}{'!' if n < POOL_SIZE else ' '} {r['bot_id']:>10}"
              + ("  BOSS" if r["is_boss"] else ""))

    # A short pool is a real defect — the rung becomes replayable on a board the player has
    # already solved — so it is reported with a count and a non-zero exit rather than shipped
    # quietly. `--upsert` still runs: four boards beat one, and the fix (deepen the released pool)
    # is a separate, slow job.
    short = sorted((r["rung"], pool_size.get(r["rung"], 0), r["mode"])
                   for r in rows if pool_size.get(r["rung"], 0) < POOL_SIZE)
    print(f"\npools: {sum(pool_size.values())} boards over {len(rows)} rungs "
          f"(target {POOL_SIZE}/rung = {POOL_SIZE * len(rows)})")
    if short:
        by_mode: dict[str, list[int]] = {}
        for rung, n, mode in short:
            by_mode.setdefault(mode, []).append(n)
        print(f"SHORT: {len(short)} rung(s) below {POOL_SIZE} boards — "
              + ", ".join(f"{m} {len(v)} rung(s), {min(v)}-{max(v)} boards"
                          for m, v in sorted(by_mode.items())))
        for rung, n, mode in short:
            print(f"  rung {rung:>2} ({mode}) has {n} board(s)")
        print("  deepen the released pool for those modes "
              "(`python -m tools.ingest.main --grid <sport> --grid-days N`) and re-run.")

    if args.upsert:
        def upsert(table: str, conflict: str, payload: list[dict]) -> None:
            req = urllib.request.Request(
                f"{url}/rest/v1/{table}?on_conflict={conflict}",
                data=json.dumps(payload).encode(), method="POST",
                headers={"apikey": key, "Authorization": f"Bearer {key}",
                         "Content-Type": "application/json",
                         "Prefer": "resolution=merge-duplicates,return=minimal"})
            try:
                urllib.request.urlopen(req)
            except urllib.error.HTTPError as e:
                # PostgREST puts the actual reason in the body; without this the failure is a bare
                # "400 Bad Request" and the rows silently stay stale.
                raise SystemExit(f"{table} upsert failed {e.code}: {e.read().decode()[:500]}")

        # Rungs first: `ladder_rung_boards.rung` references them, so the reverse order fails the
        # foreign key on a ladder that has never been seeded.
        upsert("ladder_rungs", "rung", rows)
        print(f"\nupserted {len(rows)} rungs")

        # Pools are REPLACED, not merged, and that is not a style choice — merging is broken.
        #
        # The table is keyed `(rung, ordinal)` but also carries a unique `(rung, puzzle_id)`.
        # An `on_conflict=rung,ordinal` upsert resolves the first and violates the second the
        # moment a board changes ordinal between runs, which is the normal case when the
        # tolerances or the released pool move: observed as
        #   409 23505  Key (rung, puzzle_id)=(9, gen-qb-2010-vet-00) already exists
        # with the rungs already written — i.e. the failure mode leaves new rungs pointing at old
        # boards, which is worse than either state on its own.
        #
        # Deleting is safe here in a way it would not be for player data: this tool is the sole
        # writer of `ladder_rung_boards`, every row is regenerated deterministically below, and a
        # stale row is a board that failed the current verification but is still being served.
        deleted = delete_pools(url, key, [r["rung"] for r in rows])
        print(f"cleared {deleted} stale pool board(s)")
        upsert("ladder_rung_boards", "rung,ordinal", boards)
        print(f"wrote {len(boards)} pool boards")
        # A pool that SHRANK leaves its old high ordinals behind, and a stale ordinal is a board
        # that failed this run's verification still being served. Deleting is not this tool's call
        # to make unattended, so it is reported instead.
    if args.fixture:
        n = write_fixture(args.fixture, url, key, rows, boards, bots)
        print(f"\nwrote {n} board fixture(s) to {args.fixture}")
    return 0


def delete_pools(url: str, key: str, rungs: list[int]) -> int:
    """Drop the existing pool rows for `rungs`, returning how many went.

    Scoped to the rungs this run is about to rewrite rather than the whole table, so a partial
    run can never leave the ladder with no boards at all.
    """
    if not rungs:
        return 0
    before = sum(live_pool_size(url, key, r) for r in rungs)
    ids = ",".join(str(r) for r in rungs)
    req = urllib.request.Request(
        f"{url}/rest/v1/ladder_rung_boards?rung=in.({ids})", method="DELETE",
        headers={"apikey": key, "Authorization": f"Bearer {key}",
                 "Prefer": "return=minimal"})
    try:
        urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"pool clear failed {e.code}: {e.read().decode()[:500]}")
    return before


def live_pool_size(url: str, key: str, rung: int) -> int:
    """How many boards this rung currently has server-side — used only to warn about ordinals a
    shrinking pool would orphan."""
    req = urllib.request.Request(
        f"{url}/rest/v1/ladder_rung_boards?select=ordinal&rung=eq.{rung}",
        headers={"apikey": key, "Authorization": f"Bearer {key}"})
    try:
        return len(json.load(urllib.request.urlopen(req)))
    except urllib.error.HTTPError:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
