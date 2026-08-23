# M25b — Finish the timer removal

The multiplier landed (`SpeedMultiplier`, applied centrally in `recordGameResult`) and the
in-game countdown bars are gone. What remains is every *other* place a clock still fails a player
or is still shown to one. Measured 2026-08-23, not recalled:

## Remaining surface

**Server — three lateness fail-states still live** (`supabase/schema.sql`):

| line | function | behaviour |
|---|---|---|
| 1015 | `submit_versus_result` | past `time_limit_seconds + 10`, the run scores **0** |
| 1280 | `submit_versus_live_result` | a late solve is **downgraded to not-solved** |
| 1360 | (live expiry path) | same deadline arithmetic |

**Client — four places still show or derive a clock:**

| file:line | what |
|---|---|
| `LadderView.swift:318` | a per-rung **"CLOCK"** stat on the rung card |
| `VersusView.swift:436` | the clock rendered on a challenge row |
| `VersusView.swift:590` | copy: "*N on the clock, each*" in the duel explainer |
| `LiveDuelLobbyView.swift:219` + `LiveDuelSession.secondsLeft` | still derives a countdown for hand-off |

**Never verified:** the M23 live duel has never been run in a simulator. Lobby, race, and all
four verdicts are covered by tests and by nothing else.

## What must NOT be removed

- **The 24h duel expiry** and the live-duel abandonment sweep. Those are *scheduling*, not
  gameplay: without them an unplayed challenge never resolves and a series stalls forever. They
  have no in-game countdown and no player ever races them.
- **`time_limit_seconds` the column.** It is `not null check (> 0)`. It stops being a deadline and
  becomes the **par time** the multiplier divides by. Renaming it is a migration for no gain;
  re-documenting it is the change.
- **`DuelSession.capturedAt`** and the bot's elapsed-driven beats. The ladder bot must keep
  playing alongside in real time — that is opponent presence, not a timer.

## The rule every stream is applying

A clock may **grade** a run. It may never **end** one. Anywhere a deadline currently produces a
zero, a forced finish, or a downgraded result, the run instead completes normally and simply
earns no speed bonus.

## Streams (disjoint file ownership)

| stream | owns | delivers |
|---|---|---|
| **A — server** | `supabase/schema.sql`, migrations, `supabase/functions/*` | the three fail-states removed, live-verified; decide what `notify-versus-result` does for live duels (it currently never fires — it triggers on `*_score`, which live duels don't write) |
| **B — client** | `BallIQ/Features/Versus/*`, `BallIQ/Features/Ladder/*` | the four clock surfaces removed, copy rewritten to describe the multiplier, dead clock helpers deleted |
| **C — tests** | `BallIQTests/*` | regression tests that no format can be ended by a clock, and the ladder tests M24 never got |

Simulator verification is **not** delegated — it needs A and B both landed, and is done last.

## Exit bar

1. `grep` finds no countdown rendered in any view, and no `secondsLeft`-driven finish.
2. No SQL path zeroes or downgrades a result for lateness; the 24h/abandonment sweeps still work,
   proven against live Postgres.
3. Full Swift + Python suites green.
4. A live duel run end-to-end in the simulator, screenshotted: lobby → race → win → loss.
