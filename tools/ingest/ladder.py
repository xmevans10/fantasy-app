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


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


# The highest rung Who Am I? may guard. See `mode_for` — this is a measured ceiling, not taste.
WHOAMI_MAX_RUNG = 14


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


def build_rungs(pool: list[Candidate], bots: list[dict]) -> list[dict]:
    by_mode: dict[str, list[Candidate]] = {}
    for c in pool:
        by_mode.setdefault(c.fmt, []).append(c)

    used: set[str] = set()
    recent_sports: list[str] = []
    rows: list[dict] = []

    for rung in range(1, RUNG_COUNT + 1):
        t = (rung - 1) / (RUNG_COUNT - 1)
        fmt = mode_for(rung)
        want_difficulty = max(BOARD_DIFFICULTY_FLOOR,
                              lerp(BOARD_DIFFICULTY_START, BOARD_DIFFICULTY_END, t))
        want_win = lerp(TARGET_WIN_RATE_START, TARGET_WIN_RATE_END, t)

        candidates = [c for c in by_mode.get(fmt, [])
                      if c.puzzle_id not in used and c.difficulty >= BOARD_DIFFICULTY_FLOOR]
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

        def rank(c: Candidate) -> tuple:
            # Unused-recently first, then nearest within the band.
            recency = recent_sports.index(c.sport) if c.sport in recent_sports else -1
            return (recency, abs(c.difficulty - want_difficulty))

        pick = min(band, key=rank)
        used.add(pick.puzzle_id)
        recent_sports = ([pick.sport] + recent_sports)[:4]

        # The character is chosen by ladder position, then the skill is solved **against that
        # character's style** — order matters, because style moves the win rate a given skill
        # produces. Solving first and assigning after would miscalibrate every non-baseline bot.
        band = min(len(bots) - 1, (rung - 1) * len(bots) // RUNG_COUNT)
        bot = sorted(bots, key=lambda b: b["base_skill"])[band]
        skill, achieved = solve_bot_skill(fmt, pick.diffs, want_win, pick.true_keeps,
                                          bot.get("style", "consistent"))
        is_boss = rung % BOSS_EVERY == 0
        if is_boss:
            # A boss is a step up on the same board, not a different kind of thing.
            skill = min(0.98, skill + 0.04)
            achieved = win_rate(fmt, pick.diffs, skill, true_keeps=pick.true_keeps,
                                bot_style=bot.get("style", "consistent"))

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
            "seed": (rung * 2654435761) % 9223372036854775807,
            "is_boss": is_boss,
            "board_difficulty": round(pick.difficulty, 3),
            "target_win_rate": round(achieved, 3),
        })
    return rows


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
                                 board_difficulty(fmt, content), diffs, keeps))
    return out


import datetime as _dt
TODAY = _dt.date.today().isoformat()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upsert", action="store_true", help="write the rungs to Supabase")
    ap.add_argument("--dry-run", action="store_true", help="print the curve, write nothing")
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

    rows = build_rungs(pool, bots)
    print(f"\n{'rung':>4} {'mode':6} {'sport':9} {'board_d':>7} {'skill':>6} {'winrate':>7} {'clock':>5} {'bot':>10}")
    for r in rows:
        print(f"{r['rung']:>4} {r['mode']:6} {r['sport']:9} {r['board_difficulty']:>7.3f} "
              f"{r['bot_skill']:>6.3f} {r['target_win_rate']:>7.3f} {r['time_limit_seconds']:>5} "
              f"{r['bot_id']:>10}"
              + ("  BOSS" if r["is_boss"] else ""))

    if args.upsert:
        body = json.dumps(rows).encode()
        req = urllib.request.Request(
            f"{url}/rest/v1/ladder_rungs?on_conflict=rung", data=body, method="POST",
            headers={"apikey": key, "Authorization": f"Bearer {key}",
                     "Content-Type": "application/json",
                     "Prefer": "resolution=merge-duplicates,return=minimal"})
        try:
            urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            # PostgREST puts the actual reason in the body; without this the failure is a bare
            # "400 Bad Request" and the rows silently stay stale.
            raise SystemExit(f"upsert failed {e.code}: {e.read().decode()[:500]}")
        print(f"\nupserted {len(rows)} rungs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
