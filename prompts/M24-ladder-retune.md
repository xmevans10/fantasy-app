# M24 — Retune the bot ladder on score, not on a clock

Three asks, one change. Decisions made autonomously under the `dev-taste` skill's §7 procedure;
each cites the rule that decided it, so they can be overruled on the reasoning rather than on
taste.

## The measurement that starts everything

Simulated 400 runs per rung through `ladder.simulate_performance` at each rung's live
`bot_skill` (2026-08-20):

| rung | tier | mode | bot scores | skill |
|---|---|---|---|---|
| 1 | bronze | keep4 | **4.9/8** | 0.243 |
| 3 | bronze | keep4 | 5.3/8 | 0.354 |
| 7 | bronze | keep4 | 6.6/8 | 0.692 |
| 8 | bronze | whoami | **5.6/6** | 0.495 |
| 10 | bronze | keep4 | 6.7/8 | 0.686 |
| 11 | silver | keep4 | 6.7/8 | 0.735 |

The ask was 2/8–4/8 through Bronze. The first opponent a new player ever meets scores 4.9/8, and
rung 8's Who Am I? bot answers 5.6 of 6 clues. Bronze is not an on-ramp; it is the same wall as
Silver with a different label.

## D1 — 2/8 is unreachable on Keep4, and faking it is the wrong trade

Keep4 forces exactly four keeps. A bot choosing at random therefore lands ~4/8 **by
construction** — chance *is* the floor, and rung 1's 4.9/8 already sits near it at skill 0.243.
Reaching 2/8 would require a bot that systematically picks the wrong card: anti-skill.

Decided against, on his own recorded rules:
- Theme 5 — "Luck can flavor a result; it can never make skill mathematically irrelevant." A bot
  tuned to lose is the same violation from the other side: the outcome stops being about play.
- Theme 6 — "hard ceilings get documented plainly." The 4/8 floor is a hard ceiling. Document it
  where someone will hit it, don't engineer around it.

**Decision:** 4/8 is the Bronze floor for Keep4, and rungs 1–3 are tuned to sit on it. The 2–4/8
band applies to formats where a low score is honestly reachable — Who Am I?, Journeyman and Grid
can all score zero. Recorded in `ladder.py` as a named constant with this reasoning attached.

## D2 — Bot clocks come out; the record disagrees, and here is the reconciliation

`HANDOFF-multiplayer.md` says the opposite of the ask, in as many words: *"A duel with no clock
has no tension, which is most of why the current one is dull"*, and lists the clock as lever 2 of
4 — *"this is where the timed mechanic lives."* No record anywhere of a decision to remove it.
Flagged rather than silently obeyed (`dev-taste` §8), and then reconciled, because both claims are
true about different things:

- Against **a human**, the clock is the whole mechanic. Two players who are never present at the
  same time have nothing else creating pressure. That is why M23's live race keeps it.
- Against **a bot**, there is no one to race. The bot's run is precomputed and replayed on a
  curve, so the clock isn't tension — it is a fourth difficulty lever that decides duels on how
  fast the player can *read eight cards*, not on whether they know ball. Theme 5 forbids exactly
  that.

**Decision:** ladder (bot) duels lose the clock. Human duels keep it. This also removes
`speed_adjusted` from the ladder's comparable, which invalidates every solved `bot_skill` — so
the retune below is not optional cleanup, it is required by the change.

## D3 — Deduplicate by constraint, not by inspection

Live: 165 board rows, 165 distinct puzzles, 0 reused. Clean — but by luck. The index is
`UNIQUE (rung, puzzle_id)`, which only stops **one** bot repeating a board; nothing prevents two
different bots being handed the same puzzle, and the next reseed could collide silently.

**Decision:** table-wide `UNIQUE (puzzle_id)` on `ladder_rung_boards` (`dev-taste` §3 — asked to
guarantee a property, add the mechanism that makes violating it fail loudly). Applies cleanly
against already-clean data.

---

## The retune

Replace the win-rate objective with a **score objective**, for all 30 rungs.

Today `bot_skill` is solved so that P(reference player at skill 0.75 beats the rung) follows a
0.90 → 0.30 curve. That number is invisible to the player and, with the clock gone, no longer
even well defined. A score target is legible — "Bronze bots get 4 or 5 of 8, Gold bots get 7" is
a sentence you can check against the game — and it is the unit the ask itself was written in.

- `TARGET_SCORE_START` / `TARGET_SCORE_END` as fractions of the board, per format, floored at the
  format's structural minimum (`FORMAT_SCORE_FLOOR` — 0.5 for keep4, 0.0 for the rest).
- `solve_bot_skill` bisects on mean simulated score instead of win rate.
- `win_rate` stays, no longer as the objective but as a **reported diagnostic**, so the
  progression is still visible and a regression is still catchable.
- `speed_adjusted`/`elapsed_fraction` drop out of the ladder comparable entirely.
- `time_limit_seconds` stops being written per rung.

## Work order and why it is split

`tools/ingest/ladder.py` and its tests are unowned and can be retuned immediately. The other two
pieces are blocked on the M23 agents holding those files, and will land after they report:

| piece | file | status |
|---|---|---|
| score-target calibration, clock lever removed | `tools/ingest/ladder.py` + tests | do now |
| `UNIQUE (puzzle_id)` + drop `time_limit_seconds` writes | `supabase/schema.sql` + migration | blocked (M23 Stream A) |
| ladder duel renders no timer bar | `BallIQ/Features/Versus/DuelSession.swift` | blocked (M23 Stream B) |
| ladder tests | `BallIQTests/` | blocked (M23 Stream C) |

## Exit bar

1. Re-simulated table showing Bronze bots in the 4–5/8 band (Keep4) and 2–4/8-equivalent on the
   formats that can reach it, with the resulting win rates reported alongside.
2. `pytest tools/ingest/tests` green, including a new test that pins the Keep4 floor so nobody
   later "fixes" Bronze by tuning skill below chance.
3. Reseeded rungs upserted, and the dedup constraint proven by a rejected duplicate insert.
