# M25 — Kill every timer; make the speed multiplier universal

## The instruction

> "All timers should be removed and the 'time multiplier' should just be universally applied to
> any time-sensitive game"

This supersedes M24 D2 (which removed the clock from *bot* duels only) and overrides
`HANDOFF-multiplayer.md`'s "a duel with no clock has no tension" for every format, because it
supplies the replacement tension: speed still pays, it just never *fails* you.

## What the multiplier already is

It exists and is already mirrored on both sides — `LadderOutcome.adjusted` in Swift,
`speed_adjusted` in `tools/ingest/ladder.py`:

```
adjusted = score × (1 + 0.20 × fractionOfClockRemaining)
```

Scaled **by** score rather than added to it, so "fast never rescues wrong" — a 0.4 run finishing
instantly is still ~0.4, not a win. That property is the reason this is the right mechanic to
generalise, and it must survive the change.

## The one design decision this needs

`fractionOfClockRemaining` presupposes a clock. Removing deadlines means the denominator becomes
a **par time**, not a limit:

- Finish under par → up to ×1.20.
- Finish at or over par → ×1.00. **Never a penalty, never a zero, never a forced finish.**
- Par per format, reusing the numbers already in the codebase as the natural values:
  Keep4 120s, Who Am I? 90s, Journeyman 120s, Grid 180s.

So the clock stops being a fail-state and becomes a scoring gradient. A player who takes ten
minutes still completes their game and still scores — they simply score the un-multiplied amount.
This is the whole point: the anxiety goes, the reward for knowing it cold stays.

## Surface — every timer, and what happens to it

| where | today | after |
|---|---|---|
| `DuelTimerBar` countdown (async human duel) | counts down, red under 10s, fires `onExpire` | countdown gone; bar keeps the "DUEL vs X" identity only |
| `DuelTimerBar` in a **ladder** duel | same countdown | countdown gone; the **bot's live score stays** — that is opponent presence, not a timer |
| `LiveDuelSession` deadline (M23 race) | shared countdown, board closes at zero | no player-facing countdown; the race ends when someone solves. Server keeps an expiry **only** as an abandonment sweep |
| `submit_versus_result` | scores 0 past the limit | no zeroing; late is just slow, and slow only costs multiplier |
| `submit_versus_live_result` | downgrades a late solve to not-solved | same removal — a solve is a solve |
| `ladder_rungs.time_limit_seconds` | difficulty lever, tightened per rung | par time for the multiplier, constant per format |

## Deliberately NOT removed

- **The 24h duel expiry.** That is a scheduling window, not a gameplay timer — without it an
  unplayed challenge never resolves and a series stalls forever. It has no in-game countdown.
- **The live-duel abandonment sweep.** Same reasoning: something has to close a duel where a
  player readied and walked away. It is server-side and invisible.
- **Daily rollover countdowns on Home.** Those count down to *content*, not to a fail-state.

## Consequence for M24's ladder calibration

M24 removed `speed_adjusted` from the ladder's comparable on the grounds that a bot duel isn't a
race. The multiplier now returns — but as a symmetric term applied to both sides, and the
calibration objective is **score**, not win rate, so the solved `bot_skill` values are unaffected.
The removal of the *tightening clock as a difficulty lever* stands; what returns is the scoring
gradient.

## Exit bar

1. No countdown renders anywhere in a game view; no game can force-finish on a clock.
2. One shared multiplier type used by every format — not four copies (AGENTS.md §4).
3. A slow run scores exactly its un-multiplied score, and a fast run scores at most ×1.20. Pinned
   by tests including the "fast never rescues wrong" property.
4. Server no longer zeroes or downgrades on lateness; verified against live Postgres.
5. Full Swift + Python suites green.
