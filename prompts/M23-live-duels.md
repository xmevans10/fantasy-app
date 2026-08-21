# M23 — Live duels: Journeyman, first to solve wins

## 0. What already exists (do not rebuild it)

The ask was "two players shown the same puzzle, first to solve wins, best 4 of 7". Three of
those four clauses shipped already:

| clause | status |
|---|---|
| two players, **same puzzle** | ✅ `create_versus_challenge` pins one `puzzle_id` both sides play |
| **best 4 of 7** | ✅ `resolve_versus_challenge` completes a series at first-to-4 (7-played backstop); `VersusSeries.winTarget = 4` |
| Journeyman **duelable at all** | ✅ M22: `PuzzleFormat.journeyman` is in `allCases` (so it's in the duel picker), migration 0018 widened the server whitelist, `DuelBoard.journeyman` → `JourneymanGameView(duel:)`, `BotSolver.playJourneyman` for the ladder |
| **first to solve wins** | ❌ **this milestone** |

What's missing is the word *first*. Today a duel is **asynchronous**: each player has 24h to play
the same board alone, the higher `performance` (guess efficiency) wins, and elapsed time only
breaks a tie. The two are never on the board together and neither can see the other. That is the
"Phase 3 — live duels" item BALLIQ_SPEC.md §9.3 deliberately deferred, with a sanctioned approach
already written down: **poll one row every 1–2s**, no `supabase-swift`, no Realtime dependency
(AGENTS.md §11).

One honest caveat to carry into the work: **Journeyman duels have never actually been run.** M22
wired every seam and verified none of them against a live opponent. Treat the existing async
journeyman duel as unproven, not as working.

---

## 1. The game

- Both players open the challenge and hit **READY**. Neither board is visible until both are in.
- When the second player readies, the server stamps `live_started_at` — one shared start instant,
  so the clock is identical for both and neither gets a head start from a slow network.
- Both see the same career path at the same moment. Five guesses each, as in solo.
- **The first correct answer ends the game immediately** and takes the point. The loser's board
  closes with the verdict; they do not play on for a consolation score.
- A wrong guess does not end anything — it just burns one of your five.
- If you exhaust your five (or give up), you're out, but **the game stays open** until the
  opponent finishes or the clock expires: they can still win it by solving.
- Neither solves before the clock → **draw**. Advances no counter, exactly like the existing
  dead-heat rule.
- Series is unchanged: first to 4, backstop at 7 played.

**Opponent presence is the point.** A live duel where you can't see the other player is just an
async duel with extra steps, so the board shows their guess count ticking up in real time. It
shows *how many* guesses they've spent, never *what* they guessed — a wrong name is a hint, and
handing one player another's eliminations turns the race into a collaboration.

## 2. Why polling, and what it costs

`versus_live_state` is one row, ~120 bytes, polled at 1.5s by at most two clients for at most
`time_limit_seconds` (120 for Journeyman). That is ~80 requests per player per duel — cheap
enough that the alternative (a websocket dependency the app has spent its whole life avoiding)
buys nothing. If live duels ever get popular enough that this hurts, the fix is a longer interval
or Postgres `LISTEN`, not a client library.

The poll is also the **liveness detector**: a client that stops polling has backgrounded or died,
and the server-side clock resolves the duel regardless. Nothing depends on a client staying alive.

---

## 3. The wire contract (fixed here so the three work streams can't drift)

### Schema additions to `versus_challenges`

```sql
mode                  text not null default 'async'   -- 'async' | 'live'
challenger_ready_at   timestamptz
opponent_ready_at     timestamptz
live_started_at       timestamptz     -- stamped once, when the second player readies
challenger_solved     boolean
opponent_solved       boolean
challenger_guesses    int
opponent_guesses      int
```

### RPCs

```sql
-- Stamp my readiness; when both sides are ready, stamp live_started_at exactly once.
-- Returns the row's live state (same shape as versus_live_state).
mark_versus_ready(p_challenge_id bigint) returns jsonb

-- The poll. Never returns the answer or the opponent's guesses, only counts.
versus_live_state(p_challenge_id bigint) returns jsonb
-- { "mode", "live_started_at", "server_now", "time_limit_seconds", "status", "winner_id",
--   "me":  {"ready": bool, "guesses": int, "finished": bool, "solved": bool},
--   "them":{"ready": bool, "guesses": int, "finished": bool, "solved": bool} }

-- Report a guess count without finishing (so the opponent's strip can tick).
bump_versus_guesses(p_challenge_id bigint, p_guesses int) returns void

-- Finish. First correct solve resolves the whole challenge immediately.
submit_versus_live_result(p_challenge_id bigint, p_solved boolean, p_guesses int) returns void
```

Every one is `security definer`, participant-checked on `auth.uid()`, `for update`-locked, and
first-write-wins on its own side — the same posture `submit_versus_result` already documents.
Clock authority stays server-side: a solve arriving after `live_started_at + time_limit_seconds
+ 10s` grace scores as not-solved rather than being rejected.

### Swift types

```swift
struct LiveDuelState: Equatable {          // decoded from versus_live_state's jsonb
    struct Side: Equatable { let ready: Bool; let guesses: Int; let finished: Bool; let solved: Bool }
    let liveStartedAt: Date?
    let serverNow: Date
    let timeLimitSeconds: Int
    let status: String                      // 'pending' | 'completed' | 'forfeited'
    let winnerID: String?
    let me: Side
    let them: Side
    var bothReady: Bool { me.ready && them.ready }
    var deadline: Date? { liveStartedAt.map { $0.addingTimeInterval(TimeInterval(timeLimitSeconds)) } }
}
```

`PuzzleFormat` gains `var supportsLiveDuel: Bool` — **true for `.journeyman` only** in this
milestone. The plumbing is format-agnostic on purpose, but shipping one format's race first keeps
the blast radius honest, and Keep4/Grid/WhoAmI each need their own "what does progress mean"
answer before they earn a strip.

---

## 4. Work streams (disjoint file ownership)

### Stream A — server
**Owns:** the live migration (Supabase MCP) + `supabase/schema.sql`. No Swift.
Delivers the columns and all four RPCs above, each verified against live Postgres with real rows
(two throwaway auth users, a real challenge, both ready, both submit) — including the races:
simultaneous readies must stamp `live_started_at` once, and simultaneous solves must produce
exactly one winner.

### Stream B — client plumbing (format-agnostic)
**Owns:** `BallIQ/Features/Versus/LiveDuelSession.swift` (new), `LiveDuelLobbyView.swift` (new),
`OpponentProgressStrip.swift` (new), `BallIQ/Features/Versus/DuelSession.swift`,
`BallIQ/Data/Repositories/VersusRepository.swift`, `BallIQ/Models/VersusChallenge.swift`,
`BallIQ/Models/PuzzleFormat.swift`, `BallIQ/Features/Versus/VersusView.swift`.
Delivers the polling engine (start/stop with view lifecycle, backgrounding-safe, cancels on
resolve), the ready handshake + lobby, the opponent strip, and `LiveDuelState`.

### Stream C — Journeyman race + test suite
**Owns:** `BallIQ/Features/Journeyman/*`, `BallIQTests/*`.
Delivers `JourneymanGameView`'s live mode (strip, first-solve submit, immediate loss when the
opponent solves first), the result view's race verdict, and the tests: scoring/verdict purity,
`LiveDuelState` decode, lobby/board/verdict render gallery, and a `MockURLProtocol` two-client
simulation of a full race including both simultaneity cases.

## 5. Exit bar

1. `xcodebuild … test` green; `pytest tools/ingest/tests` untouched and green.
2. Every RPC exercised against live Postgres, including both simultaneity races.
3. A full simulated race in tests: ready → both boards open → one solves → other's board closes
   with a loss verdict → series counter advances.
4. Simulator screenshots: lobby (waiting on opponent), live board with the opponent strip mid-race,
   win verdict, loss-by-being-beaten verdict.
5. `PuzzleFormat.supportsLiveDuel` is true only for `.journeyman`, and the async path for every
   other format behaves exactly as before (pinned by the existing Versus tests still passing).
