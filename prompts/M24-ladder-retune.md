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

## D1 — corrected: 2/8 *is* reachable, and that is not the reason to refuse it

**My first answer here was wrong and is corrected in place.** I claimed 4/8 was a structural
floor because Keep4 forces four keeps. Forcing four keeps sets where *chance* lands, not where
the format bottoms out. Measured — worst possible bot (skill 0.05), by board difficulty:

| board difficulty | worst bot scores | player wins |
|---|---|---|
| 0.25 (rung 1 today) | **5.3/8** | 97% |
| 0.35 | 4.0/8 | 98% |
| 0.45 | 2.9/8 | 99% |
| 0.55 | 2.2/8 | 100% |
| 0.70 | 1.5/8 | 100% |

So 2/8 is reachable. Two real reasons not to chase the number anyway:

1. **Below 4/8 the bot is playing worse than chance** — `hit_probability` has dropped under 0.5,
   so it is systematically making the wrong call. That is theme 5 from the other side: the result
   stops being about play. (Arguable counter, worth putting to him: a beginner isn't random
   either — they're *consistently* wrong in predictable ways, so a sub-chance bot may read as a
   bad player rather than a rigged one.)
2. **The number and the on-ramp are in direct conflict.** Getting to 2–4/8 needs a board at 0.45+
   difficulty. Rung 1's board is 0.25 *because it is rung 1*. You cannot have both an easy board
   and a bad bot: on an easy board even the worst possible bot scores 5.3/8.

**Decision:** keep the easy early boards, and read the ask as what it was a proxy for — Bronze
must be beatable. The retuned curve delivers that: **player wins 93.8–100% of Bronze duels**
(rungs 1–10 of the dry-run: .999 .999 .999 1.000 .988 .992 .984 .938 .989 .965). The literal 2–4/8 would cost
the on-ramp, and it is the on-ramp the number was asking for.

**Consequence to resolve (his call, flagged not decided).** At the bottom the solver pins at
minimum skill on rungs 1–6, so those six rungs separate on board difficulty alone (0.25 → 0.36)
and their player win rates sit flat at 0.99–1.00. That pinning is *correct behaviour*, not a
solver bug — it means "as weak as this board allows" — but six near-identical rungs is the flat
spot the ladder's own brief says to avoid. Options: fewer Bronze rungs, or start the board
curve nearer the 0.18 floor and climb faster. Not decided autonomously because it changes how
long the on-ramp is, which is a feel question rather than a measurable one.

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

- `TARGET_SCORE_START` / `TARGET_SCORE_END` as fractions of the board, floored at
  `FORMAT_SCORE_FLOOR` — which marks where *chance* sits (0.5 for keep4), not where the format
  bottoms out. See D1: below chance the bot is systematically wrong.
- `solve_bot_skill` bisects on mean simulated score instead of win rate.
- `win_rate` stays, no longer as the objective but as a **reported diagnostic**, so the
  progression is still visible and a regression is still catchable.
- `speed_adjusted`/`elapsed_fraction` drop out of the ladder comparable entirely.
- `time_limit_seconds` stops *tightening* per rung: the column is `not null check (> 0)` and
  `schema.sql` is held by another agent, so the format's full base is written and never scaled.
  It goes away once the client stops rendering a timer bar for ladder duels.

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

1. ✅ Full 30-rung dry-run against the live pool, win rates reported per rung.
2. ✅ `pytest tools/ingest/tests` green (484), including a test pinning the board-difficulty/bot-
   score relationship so nobody later "fixes" Bronze by tuning skill on an easy board.
3. ⛔ **Not reseeded, deliberately.** The curve has a flat bottom (rungs 1–6 pinned at minimum
   skill, win rates .99–1.00) and that is a product regression at the tier a new player meets
   first. Reseeding is one command once the Bronze shape is decided — see D1's open consequence.
4. ⏳ Dedup constraint + client timer removal: blocked on the M23 agents holding those files.
