# Handoff: multiplayer overhaul — timed duels + bot ladder

## Why this exists

Versus shipped as an async 1v1 and has produced **zero completed duels**. Live production, checked
2026-08-12:

| | |
|---|---|
| profiles | 9 (5 with a username) |
| friend edges | 1 |
| versus challenges ever created | 1 |
| outcome of that one | double no-show (`forfeited`) |
| completed duels | 0 |

At 9 accounts that is not a verdict on the design, but it does expose the structural flaw: the only
way into a duel is typing a specific person's username. Versus requires a social graph the app does
not have. The schema already says so out loud — `format_benchmarks()` is gated behind "≥20 distinct
players" with a comment citing *"4 profiles and 2 users who had ever finished a game."*

**The fix is not more Versus. It is opponents that exist without a social graph.**

## Pillars this plan is held to

- Reusable code is best.
- Keep it simple and snappy.
- If it seems obvious, that's probably the correct implementation.

These are load-bearing here, because the tempting version of this feature (realtime websockets,
presence, lobbies) violates all three. See "Live duels" below for why it is deferred rather than built.

## Scope decision: two modes, not three

- **Timed duel** — replaces the current async duel outright. Same puzzle, each side has a clock that
  starts when *they* open it. Async scheduling, synchronous pressure. A duel with no clock has no
  tension, which is most of why the current one is dull.
- **Live duel** — same wall-clock window, both players present. **Deferred.** Phase 3, gated on
  population.

Plus the **bot ladder**, which is not a consolation prize for having no players — see below.

## What already exists (reuse this, do not rebuild)

| Need | Existing thing | Location |
|---|---|---|
| Ghost duel vs. a recorded score | `ChallengeLink` — stateless, score embedded in the URL, no account needed | `BallIQ/Features/Share/ChallengeLink.swift` |
| Ghost duel result UI | `ChallengeResultBanner` — worked win/loss/tie, tie broken by points | `BallIQ/Features/Share/ChallengeResultBanner.swift` |
| Normalized score comparable | `performance: Double` 0...1, already computed by every mode | per-mode, see table below |
| Fetch a puzzle by id | `VersusRepository.keep4Puzzle(id:)` — generalize to `puzzle<T>(id:format:)` | `VersusRepository.swift:91` |
| Duel integration seam in a game view | `versusChallengeID` / `opponentUserID` params + `finish()` | `Keep4GameView.swift:11-22, 323-345` |
| Matchmaking pool | `cohort_members` — automatic, ~30 players by rating, weekly, no opt-in | `schema.sql:533-569` |
| Instant push on a duel event | pg_net DB trigger → Edge Function | `versus_challenges_notify`, `schema.sql:1238-1256` |
| Server-enforced "already played" | `submit_daily_draft_score`'s `on conflict do nothing` | `schema.sql:855-869` |

APNs credentials (`APNS_KEY_ID`/`TEAM_ID`/`PRIVATE_KEY`/`BUNDLE_ID`) are **set in Vault** and the
trigger is enabled. Push is not blocked on portal work; the spec §8 note saying otherwise is stale.

## Per-mode duelability

`performance` is the winner-deciding comparable in every case. Raw score is display only.

| Mode | `performance` | Deterministic? | Duelable |
|---|---|---|---|
| **Grid** | `solved/9` | yes — membership check + baked `rarityStars` | **easiest.** Already has a `ChallengeLink` path proving same-board score compare works |
| **Who Am I?** | clue-decay ratio | yes — clue order is baked content | **easy.** Needs an id-fetch helper and a `ChallengeLink` case; no scoring obstacle |
| **Keep4** | `correct/8` | yes — serve order seeded by `stableHash(puzzle.id)` | already wired |
| **Over/Under** | `correct/attempts` | rounds are seeded per `(sport, day, index)` — identical for all players | good *synchronous* fit, but no stable puzzle row; `ChallengeLink` excludes it over a stated pool-divergence risk that must be re-verified first |
| **Draft & Spin** | outcome map | **no** — `simulate()` uses a fresh `SystemRandomNumberGenerator` every run | hardest. Needs a seeded `simulate()` before any duel is meaningful |

Order of work: **Grid → Who Am I?**, then reassess. Do not start with Draft & Spin.

## Blocking schema gap

`versus_series` and `versus_challenges` have **no `format` column**, and the partial unique index is
`versus_series_pair_sport (user_a, user_b, sport) where status='active'`. A Grid duel between two
players who already have a Keep4 series in the same sport **will collide**. Adding `format` to both
tables and to that index is a prerequisite for any second mode.

---

## Phase 0 — correctness

Small, independent, no ordering constraints between them.

1. **Kill the pre-play exploit.** `createVersusChallenge` pins *today's daily row*
   (`RepositoryContainer.swift:659`), and nothing gates replay in the Versus path. Play your daily,
   learn the answer, then challenge and replay with perfect knowledge. Fix: pick the duel puzzle
   **server-side from the archive, excluding puzzles either side has a `game_results` row for.**
   This also unshackles duels from "today," which timed duels want anyway.
2. **Tiebreak on elapsed time, not on who asked.** `resolve_versus_challenge` currently awards ties
   to the challenger (`challenger_score >= opponent_score`), stacking a second structural edge on the
   first. `challenger_completed_at` / `opponent_completed_at` are already written and never read.
3. **Dedupe open challenges** — `create_versus_challenge` inserts unconditionally; N pending
   challenges against the same person on the same puzzle is a spam vector.
4. **Delete the `'active'` status.** Declared in `VersusChallenge`, branched on in `unplayedCount`
   and `statusLine`, never written by any RPC. It is also a latent trap: `versus-timeout` filters
   `status='pending'` only, so anything landing in `'active'` would never expire.
5. **Bound `recentResults`** — no `limit` on the completed/forfeited fetch.
6. **First-to-4, not all-seven.** Series completes at 7 *played*; a 4–0 lead still grinds three dead
   rubbers.
7. **Add the `format` column** (see above).

## Phase 1 — timed duels

- `time_limit_seconds` on the challenge; per-side `started_at` written server-side when a player
  opens the board; `submit_versus_result` validates `now() - started_at <= limit + grace`.
- Extend to Grid, then Who Am I?, via the `Keep4GameView` seam. Generalize
  `keep4Puzzle(id:)` → `puzzle<T>(id:format:)` rather than adding a per-format twin.
- **"Your opponent finished"** push via the existing pg_net trigger pattern. This is the engagement
  loop the async mode never had, and it is a schema trigger plus a payload builder.
- Extend `ChallengeLink` to Who Am I? — it is the accountless on-ramp and already carries the
  share funnel instrumentation.

## Phase 2 — the bot ladder

**This is the headline, not the fallback.** If bots make real decisions on real players rather than
rolling a number, the bot's run can be **replayed alongside the player in real time** — which
delivers the feeling of a live opponent with zero realtime infrastructure, at N=1, tonight.

It also generates the per-puzzle score corpus that human ghost duels need later, teaches the duel
format before anyone risks a real one, and is a progression system that needs nobody else online.

### Bots as skill-limited solvers

Skill `s ∈ [0,1]` sets the probability of getting each decision right, weighted by how hard that
specific decision is. A 0.35 bot fumbles close calls and nails obvious ones — exactly what a weak
human does.

| Mode | Policy | Difficulty signal |
|---|---|---|
| Keep4 | keep/cut each of 8 with `p = f(s, margin)` | margin between the two stat lines |
| Grid | fill cells from the real membership index | `rarityStars` per cell |
| Who Am I? | solve at clue *N*, distributed by skill | clue index already drives scoring |
| Over/Under | call each line with `p = f(s, closeness)` | distance from the real number |

Output is a real `performance` in `0...1`, so it drops into the same comparable as human duels.
Everything is seeded, so a rung is identical for every player: comparable, leaderboard-able,
speedrun-able. **The bot runs entirely on-device — no server round trip, no transport work.**

### Tables

```
bots            (id, name, avatar, tagline, base_skill, persona)
ladder_rungs    (rung, tier, mode, sport, puzzle_id, bot_id,
                 bot_skill, time_limit_seconds, seed)
ladder_progress (user_id, highest_rung)
ladder_attempts (user_id, rung, score, bot_score, won, elapsed_ms, created_at)
```

`ladder_attempts` doubles as the ghost-duel score corpus — no second migration later.

### Four difficulty levers, so the curve does not go flat

1. Bot skill, roughly 0.35 → 0.98
2. Clock, 120s → 45s (this is where the timed mechanic lives)
3. Puzzle difficulty — already tiered (Who Am I? by obscurity, Grid by archetype weight)
4. Mode mixing — later rungs stop being all-Keep4

Boss rungs every 10, mapped to the existing Bronze→Silver→Gold tiers shown on Home.

### Two rules

- **Label bots as bots.** Never dress one as a human. Honest, and beating "The Analyst" is a better
  story than beating `bot_47`.
- **XP and ladder rank only, never the solo rating.** Matches the existing rule in the Versus info
  sheet: *"Versus games never affect your rating."*

## Phase 3 — live duels (deferred, gated on population)

Do not build this yet, and specifically **do not add a websocket layer.**

The app has **zero third-party dependencies** — no `Package.swift`, no SPM, a hand-rolled ~260-line
URLSession REST client. Adding `supabase-swift` for Realtime would be the first dependency this
project has ever taken, for one feature. Hand-rolling Phoenix channels means JWT auth, join,
heartbeat, rejoin, and backoff — code you then own forever, landing in a testing blind spot, because
the project's only network seam is `MockURLProtocol`, which does not reliably intercept
`URLSessionWebSocketTask`. AGENTS.md §11's decision ladder (YAGNI → reuse → stdlib → native → existing
dependency → custom) rules against it on its own terms.

When it is time: a 60–90s duel shares exactly two things, a countdown and final scores. Both are one
row. Poll it every 1–2s. That is ~40 requests per player per match and ships in a day. Live opponent
*progress* is the only part that genuinely wants a socket, and it is a clean upgrade behind the same
interface.

Non-negotiable whatever the transport: **the clock is server-authoritative.** `started_at` set
server-side, submissions validated against `now() - started_at` with grace, and the answer never
shipped to the client before the buzzer.

Population mitigations when the time comes: a nightly **Prime Time** window to concentrate a small
player base into the same few minutes (already the design system's metaphor — see `DESIGN.md`), and
`cohort_members` as the ready-made matchmaking pool.

## Cold-start fixes worth doing regardless

- **`PublicProfileView`'s CHALLENGE is disabled when `profile.username == nil`** — a second
  bottleneck independent of the friends graph. Challenging should resolve a `user_id` directly;
  every entry point currently round-trips through a username string.
- **`ProfileShareCardView` has no URL at all.** The app's one "invite a stranger" surface renders a
  bare image — the recipient has nothing to tap and must type a username by hand.
- **Cohort standings rows are already `NavigationLink`s into a profile.** A duel entry point there is
  nearly free and reaches ~30 rating-matched players who never opted into anything.

## Constraints any implementation must respect

- **Competitive glossary (spec, established 2026-07-13):** the word *"challenge"* belongs exclusively
  to Versus. Draft & Spin's "Today's Challenge" was renamed to "Daily Draft" specifically to honour
  this. Do not introduce a third meaning — the ladder uses "rung"/"duel", not "challenge".
- **Versus's tint is `ink`** in the format-tile system. Do not introduce a new colour.
- **`ChallengeLink` is a distinct, lighter mechanic** from the Versus series — stateless, accountless,
  rides the share sheet from any result screen. Keep them distinguishable.
- AGENTS.md: verify against live Supabase, not the bundled `player_seasons.json` sample (§1); one
  shared table over N per-format branches (§4); screenshot outlier states (§5); quantify claims with
  a real count or status code (§9).

## Roadmap conflict — needs a decision

§9.3, the current live roadmap (drafted 2026-07-31), contains **no multiplayer item**. It sequences
*"growth/marketing and new engagement features ahead of further Grid-depth or monetization-funnel
work"*, with v1.6 "Grow" (marketing execution) and v1.7 "Engage" (widget, Game Center achievements,
iPad layout pass).

This plan is net-new scope against that. The defensible framing: Versus is the single largest
engagement feature already built and unfinished, so finishing it *is* the §9.3 directive rather than
competing with it. But that is a call to make explicitly, not to assume.

## Stale docs to fix along the way

- `docs/PRIVACY.md` claims data powers "Versus matchmaking" — **no matchmaking has ever existed**,
  only direct username challenges.
- Spec §8 says the `notify-versus-challenge` webhook needs manual dashboard setup — it is live via a
  pg_net trigger, and APNs credentials are in Vault.
- Spec §1 line 65 calls the Versus badge a stopgap "until APNs" — APNs is configured.
