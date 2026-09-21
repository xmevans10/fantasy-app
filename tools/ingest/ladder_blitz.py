"""Seeds the bot ladder as **Puzzle Blitz rungs** — the model that replaces `ladder.py`'s
per-format curve.

Why the ladder moved
--------------------
Every per-format rung was fighting a floor its format could not get under, and the two floors
pointed opposite ways:

* **Keep4** forces a 4/4 split, so a deliberately bad sorter still scores about half the board.
  Measured over the live pool, no `bot_skill` could take the reference player's win rate below
  ~0.27, and on an easy board the floor was ~0.63 — which is why rungs 1-9 shipped at minimum
  skill and the player won 99.8% of them.
* **Who Am I?** scores on a 7-value clue ladder that saturates at a clue-1 solve, and ties go to
  the player, so a *perfect* bot still lost ~75% of duels. The format had to be capped below
  rung 18 and its rungs were flat spots wearing rung numbers.

A curve cannot descend through both. Blitz dissolves them, and not by tuning:

* ``BlitzScoring.surplus`` rebases every board so **chance is worth exactly zero** — that is the
  keep4 floor, priced out at the source.
* A run **aggregates several boards**, so no single format's scoring shape decides a rung.
* The clock **gates whether a new board is served**, so pace is paid for in board count. Blitz
  carries no speed multiplier on top, which also retires the comparable mismatch that made the
  old seeder disagree with `LadderOutcome` about how a duel is won.

Measured before any of this was built, sweeping bot skill against the reference player: a 180s
blitz spans a **1.000 -> 0.011** win rate. The lever works again, so this module solves for the
win rate directly — the thing a player actually experiences — rather than for a proxy score.

What a rung is now
------------------
A duration, a config, and a `bot_skill`. **No board pool**: a run draws fresh boards every
attempt, so the replay bug `ladder_rung_boards` existed to prevent cannot happen and the
pool-starvation work it needed is moot.

Over/Under is deliberately absent from the ladder's config. Its rounds are generated on-device
from a sampled catalog and have no stable row anywhere, so this seeder could not calibrate
against the boards a player would actually see. Calibrating on three formats and serving four
would be a promise the numbers do not back.

Usage
-----
    python -m tools.ingest.ladder_blitz --dry-run
    python -m tools.ingest.ladder_blitz --upsert
"""
from __future__ import annotations

import argparse
import json
import os
import random
import urllib.error
import urllib.request

from .ladder import (BOSS_EVERY, REFERENCE_PLAYER_SKILL, RUNG_COUNT, TODAY, decision_contexts,
                     hit_probability, keep4_card_difficulties, keep4_true_keeps,
                     simulate_performance, whoami_clue_difficulties)

# ── The curve ────────────────────────────────────────────────────────────────
#
# Back to a win-rate objective, and this time it is reachable. `ladder.py` moved to a score
# objective (M24) because win rate could not be hit through keep4's and whoami's floors; with
# those gone the honest target is the number the player lives: how often they beat this rung.
TARGET_WIN_RATE_START = 0.90     # rung 1
TARGET_WIN_RATE_END = 0.21       # rung 30

# Mirrors `SpeedMultiplier.par` and `BlitzFormat.parSeconds`.
PAR_SECONDS = {"keep4": 120.0, "whoami": 90.0, "journeyman": 120.0}
# Mirrors `BlitzFormat.chanceFloor`.
CHANCE_FLOOR = {"keep4": 0.5, "whoami": 0.0, "journeyman": 0.0}
# Mirrors `BlitzScoring`.
POINTS_PER_PAR_SECOND = 10.0
COMBO_STEP = 0.1
COMBO_CAP = 5
# Mirrors `BotSolver.paceVariance` / `pacingFraction`.
PACE_VARIANCE = 0.18

FORMATS = tuple(PAR_SECONDS)

# Mirrors `LadderBlitz`. Duration is a VARIANCE dial, not a difficulty one: a 60s run spans a
# 1.000 -> 0.278 win rate and a 180s run spans 1.000 -> 0.011, because at 60s a weak side cannot
# finish even one long board (keep4's par alone is 120s). So the bottom of the ladder, where the
# target sits above that floor, can afford a minute; everything else needs three; and a boss gets
# five, where the spread is tightest and the result is most nearly a statement about who knew more.
ONE_MINUTE_MAX_RUNG = 6


def duration_for(rung: int, is_boss: bool) -> int:
    if is_boss:
        return 300
    return 60 if rung <= ONE_MINUTE_MAX_RUNG else 180


def pacing_fraction(skill: float) -> float:
    """Mirrors `BotSolver.pacingFraction`."""
    return max(0.35, min(0.97, 1.05 - skill * 0.65))


# ── One run ──────────────────────────────────────────────────────────────────

def journeyman_guess_difficulties() -> list[float]:
    """Five guesses, hardest first — mirrors `BotSolver.playJourneyman`."""
    return [1 - i / 4 for i in range(5)]


def surplus(performance: float, fmt: str) -> float:
    """Mirrors `BlitzScoring.surplus`: chance rebased to exactly zero, losses kept."""
    floor = CHANCE_FLOOR[fmt]
    return min(1.0, max(-1.0, (performance - floor) / (1 - floor)))


def round_performance(board: dict, skill: float, rng: random.Random,
                      knowledge: dict | None) -> float:
    fmt = board["fmt"]
    if fmt == "journeyman":
        for i, d in enumerate(board["diffs"]):
            if rng.random() < hit_probability(skill, d, "consistent", i / 4,
                                              knowledge, board["context"]):
                return [1.0, 0.8, 0.6, 0.4, 0.2][i]
        return 0.0
    return simulate_performance(fmt, board["diffs"], skill, rng, board.get("keeps"),
                                "consistent", knowledge, board.get("contexts"))


def run_points(sequence: list[dict], skill: float, duration: float, rng: random.Random,
               knowledge: dict | None = None) -> int:
    """One blitz run's score. Mirrors `BotSolver.playBlitz` — the clock gates whether a NEW
    board starts and never reaches into one already in flight."""
    remaining, total, combo = duration, 0.0, 0
    for board in sequence:
        par = PAR_SECONDS[board["fmt"]]
        spend = par * pacing_fraction(skill) * rng.uniform(1 - PACE_VARIANCE, 1 + PACE_VARIANCE)
        if spend > remaining:
            break
        remaining -= spend
        value = surplus(round_performance(board, skill, rng, knowledge), board["fmt"])
        multiplier = 1.0 + min(max(combo, 0), COMBO_CAP) * COMBO_STEP if value > 0 else 1.0
        total += POINTS_PER_PAR_SECOND * par * value * multiplier
        # `cleared` in `BlitzScoring` terms: performance past the format's chance floor, which
        # is exactly `surplus > 0` — the rebase is what makes the two the same statement.
        combo = combo + 1 if value > 0 else 0
    return int(max(0.0, round(total)))


# ── Solving ──────────────────────────────────────────────────────────────────

TRIALS = 400
SOLVE_TRIALS = 250
SEQUENCE_LENGTH = 12        # more boards than any run can reach, so the clock is the only limit


def draw_sequence(pool: dict[str, list[dict]], rng: random.Random) -> list[dict]:
    """A run's boards. Both sides play the SAME sequence — a duel has to ask both players the
    same questions, and only how far each gets separates them."""
    formats = [f for f in FORMATS if pool.get(f)]
    return [rng.choice(pool[rng.choice(formats)]) for _ in range(SEQUENCE_LENGTH)]


def win_rate(pool: dict[str, list[dict]], bot_skill: float, duration: float,
             knowledge: dict | None = None, trials: int = TRIALS, seed: int = 12345) -> float:
    """P(reference player beats this bot over a blitz of this length). Ties to the player,
    matching `LadderOutcome.playerWon` with no clock term — blitz has none by design."""
    rng = random.Random(seed)
    wins = 0
    for _ in range(trials):
        sequence = draw_sequence(pool, rng)
        player = run_points(sequence, REFERENCE_PLAYER_SKILL, duration, rng)
        bot = run_points(sequence, bot_skill, duration, rng, knowledge)
        if player >= bot:
            wins += 1
    return wins / trials


def solve_bot_skill(pool: dict[str, list[dict]], target: float, duration: float,
                    knowledge: dict | None = None) -> tuple[float, float]:
    """Bisect the skill whose win rate lands on `target`.

    Win rate falls monotonically in bot skill, so a bisection is sound. Returns the skill and the
    rate actually measured — a miss is surfaced rather than hidden, the way `ladder.py`'s solver
    surfaces a format floor it cannot reach.
    """
    lo, hi = 0.05, 1.0
    best = (0.5, win_rate(pool, 0.5, duration, knowledge, trials=SOLVE_TRIALS))
    for _ in range(16):
        mid = (lo + hi) / 2
        rate = win_rate(pool, mid, duration, knowledge, trials=SOLVE_TRIALS)
        if abs(rate - target) < abs(best[1] - target):
            best = (mid, rate)
        if rate > target:      # player wins too often -> the bot must get better
            lo = mid
        else:
            hi = mid
    return best


# ── Content ──────────────────────────────────────────────────────────────────

def fetch_pool(url: str, key: str) -> dict[str, list[dict]]:
    """Every released board the ladder's blitz config can serve, pre-reduced to what the
    simulation needs. Over/Under is absent by design — see the module docstring."""
    out: dict[str, list[dict]] = {f: [] for f in FORMATS}
    for fmt in FORMATS:
        req = urllib.request.Request(
            f"{url}/rest/v1/puzzles?select=id,sport,content&format=eq.{fmt}"
            f"&active_date=lt.{TODAY}&active_date=not.is.null",
            headers={"apikey": key, "Authorization": f"Bearer {key}"})
        for row in json.load(urllib.request.urlopen(req)):
            content = row["content"]
            if fmt == "keep4":
                diffs, keeps = keep4_card_difficulties(content), keep4_true_keeps(content)
            elif fmt == "whoami":
                diffs, keeps = whoami_clue_difficulties(content), None
            else:
                diffs, keeps = journeyman_guess_difficulties(), None
            if not diffs:
                continue
            contexts = decision_contexts(fmt, row["sport"], content)
            out[fmt].append({
                "fmt": fmt, "id": row["id"], "sport": row["sport"],
                "diffs": diffs, "keeps": keeps,
                "contexts": contexts or None,
                "context": (contexts[0] if contexts else {"sport": row["sport"]}),
            })
    return out


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def build_rungs(pool: dict[str, list[dict]], bots: list[dict]) -> list[dict]:
    ordered = sorted(bots, key=lambda b: b["base_skill"])
    if len(ordered) < RUNG_COUNT:
        raise SystemExit(f"{len(ordered)} characters for {RUNG_COUNT} rungs — the ladder is 1:1")

    rows = []
    for rung in range(1, RUNG_COUNT + 1):
        bot = ordered[rung - 1]
        is_boss = rung % BOSS_EVERY == 0
        duration = duration_for(rung, is_boss)
        t = (rung - 1) / (RUNG_COUNT - 1)
        target = lerp(TARGET_WIN_RATE_START, TARGET_WIN_RATE_END, t)
        knowledge = bot.get("knowledge") or None
        skill, achieved = solve_bot_skill(pool, target, duration, knowledge)
        if is_boss:
            skill = min(1.0, skill + 0.04)
            achieved = win_rate(pool, skill, duration, knowledge)
        rows.append({
            "rung": rung,
            "tier": "bronze" if rung <= 10 else ("silver" if rung <= 20 else "gold"),
            "mode": "blitz",
            # A blitz run spans sports by design, so a rung has no single one. The column is
            # `not null`, so the ladder's own multi-sport config is stated as 'nfl' — the one
            # sport no entitlement gates — and the client reads the config, not this.
            "sport": "nfl",
            "puzzle_id": f"blitz-{duration}s",
            "bot_id": bot["id"],
            "bot_skill": round(skill, 3),
            "time_limit_seconds": duration,
            "seed": rung * 7919,
            "is_boss": is_boss,
            "board_difficulty": round(t, 3),
            "target_win_rate": round(achieved, 3),
        })
    return rows


def trend_breaks(rows: list[dict]) -> list[tuple[int, int]]:
    """Rungs five apart in the NON-BOSS sequence whose win rates do not descend.

    **Bosses are excluded, and that is not a fudge.** Every tenth rung takes a deliberate skill
    bump, so a boss is *supposed* to be harder than the trend line several rungs later — measuring
    it against the baseline reports a violation on a ladder that is behaving correctly. (The
    retired `LadderCurveTests` excluded them for the same reason.) What must hold is that the
    baseline descends, so this compares non-boss rungs five apart in the non-boss sequence.
    """
    trend = [r for r in rows if not r["is_boss"]]
    return [(trend[i]["rung"], trend[i + 5]["rung"])
            for i in range(max(0, len(trend) - 5))
            if trend[i]["target_win_rate"] <= trend[i + 5]["target_win_rate"]]


def upsert(url: str, key: str, rows: list[dict]) -> None:
    req = urllib.request.Request(
        f"{url}/rest/v1/ladder_rungs?on_conflict=rung", data=json.dumps(rows).encode(),
        method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}",
                 "Content-Type": "application/json",
                 "Prefer": "resolution=merge-duplicates,return=minimal"})
    try:
        urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"rung upsert failed {e.code}: {e.read().decode()[:500]}")
    print(f"upserted {len(rows)} blitz rungs")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--upsert", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise SystemExit("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY required (tools/ingest/.env)")

    req = urllib.request.Request(f"{url}/rest/v1/bots?select=id,base_skill,style,knowledge",
                                 headers={"apikey": key, "Authorization": f"Bearer {key}"})
    bots = json.load(urllib.request.urlopen(req))
    pool = fetch_pool(url, key)
    print("pool: " + ", ".join(f"{f} {len(v)}" for f, v in pool.items()))

    rows = build_rungs(pool, bots)
    print(f"\n{'rung':>4} {'secs':>5} {'skill':>6} {'winrate':>8} {'bot':>10}")
    for r in rows:
        print(f"{r['rung']:>4} {r['time_limit_seconds']:>5} {r['bot_skill']:>6.3f} "
              f"{r['target_win_rate']:>8.3f} {r['bot_id']:>10}"
              + ("  BOSS" if r["is_boss"] else ""))

    breaks = trend_breaks(rows)
    print(f"\nfive-rung-window violations: {len(breaks)} {breaks}")

    if args.upsert:
        upsert(url, key, rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
