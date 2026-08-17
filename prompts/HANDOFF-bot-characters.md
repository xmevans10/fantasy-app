# Handoff: bot characters, round two

Five tasks, each self-contained. **Task 1 is a correctness bug and blocks Task 2** — do it first.
The rest are independent and can run in parallel by different agents.

Read this whole preamble before starting any of them. It is the context you would otherwise
spend an hour rediscovering, and several items are traps that have already cost real time today.

---

## 0. Shared context — read once, applies to all five

### What this is

BallIQ is a **native SwiftUI iOS sports-trivia app**, live on the App Store, backed by Supabase.
`docs/BALLIQ_SPEC.md` is the living source of truth for product/architecture; `AGENTS.md` is how
to work here at the right quality bar; `CLAUDE.md` is project facts and credentials. Read
AGENTS.md §§3, 4, 5, 7, 9, 11 before writing code — they are short and they are the bar you
will be held to.

The work below continues a two-day push that rebuilt **Versus** (timed 1v1 duels) and added the
**bot ladder** (30 rungs of AI opponents). All of it is on branch `versus-rebuild`, four commits,
**uncommitted to `main` and unpushed to GitHub**. `1.5.0 build 29` is on TestFlight (internal
only). `1.4.2` is in App Store review — **do not cancel or re-attach that submission**; a cancel
also pulls every IAP out of review (see `.claude/skills/testflight-release/SKILL.md`).

### Build, test, run

```
# Build
xcodebuild -scheme BallIQ -project BallIQ.xcodeproj \
  -destination 'platform=iOS Simulator,id=448665F0-289F-47A6-BB48-8EFC0FB58A58' \
  -derivedDataPath build build

# Test (swap `build` for `test`; add -only-testing:BallIQTests/<Class> to narrow)
# Current baseline: 728 tests, 0 failures, 7 skipped.
# The 7 skips are PurchaseFlowTests on the iOS 26.5 runtime — documented in AGENTS.md §7.1,
# NOT a regression. Do not "fix" them.

# Deno tests for edge functions
deno test --allow-env supabase/functions/_shared/

# Run on device
xcrun simctl install <SIM> build/Build/Products/Debug-iphonesimulator/BallIQ.app
xcrun simctl launch <SIM> com.balliqfantasy.app -screenshotLadder
```

`BallIQ/DebugLaunch.swift` has launch flags for reaching screens non-interactively
(`-screenshotLadder`, `-screenshotVersus`, `-screenshotGrid`…). **Extend that pattern rather than
inventing a new hook** (AGENTS.md §10).

### Database

Project **`nhccgufqwndtoasdbkhc`** ("ballknowledge"). `list_projects` also returns a decoy
(`pyprjebfwqfdnfeliigo`) — never target it. Per CLAUDE.md you may **apply additive migrations and
merge-duplicate upserts directly**, without asking. Still ask before anything destructive
(`drop`, `delete`, `truncate`, revoking RLS).

- Schema changes: Supabase MCP `apply_migration`, **and** mirror the same statements into
  `supabase/schema.sql` in the same change so the file never drifts.
- Also write the migration to `supabase/migrations/00NN_<name>.sql` for the record.
- Edge functions: `set -a && . tools/ingest/.env && set +a && supabase functions deploy <name>
  --project-ref nhccgufqwndtoasdbkhc`. Works with Docker down; resolves `_shared/*.ts` itself.

### Design system — hard constraints

Tokens live in `BallIQ/DesignSystem/Theme.swift` + `Palette.swift`; the identity is documented in
`BallIQ/DesignSystem/DESIGN.md`. **Use tokens, never literal colours.**

- Dominant **accent** electric blue `#1E50FF` (`accentFill`/`accentText`/`accentBg`/`onAccent`);
  sharp **volt** lime `#C2F03A` (`voltFill`/`onVolt`) reserved for win moments.
- Semantic roles: `success` / `danger` / `warning` / `pro`, each with `Fill`/`Bg`/`Text`/`on*`.
- Surfaces: `appBackground`, `surface`, `surface0/1`, `surfaceMuted`, `cardSurface()`,
  `blockCard(fill:)` (ink outline + hard offset shadow), `Radius.card`/`.control`, `Hairline`.
- Type: `.hero(n)` and `FontName.condBlack`/`condBold` (Anton/Saira Condensed) for display,
  `.title`, `.heading`, `.bodyStrong`, `.body14`, `.label11`, `.label12`.
- Motion: `Motion.snap`/`.easeOut`, `heroReveal(n)` for staggered entrances, `Haptics.tap()`
  `.success()` `.reject()` `.commit()`, `Celebrate`/confetti for wins.
- **Versus's tint is `ink`** in the format-tile system. Do not introduce a new colour for any
  Versus/ladder surface.
- Bot colourways go through `BotPalette` (`amber/teal/electric/green/plum/gold`) which maps onto
  the tokens above — see `BallIQ/Features/Ladder/BotPortrait.swift`. **Never store or write a hex
  for a bot.**
- Team crests/colours: `TeamAbbrChip(sport:abbr:league:showLogo:)` and the `TeamIdentityIndex`
  system. Never hardcode a team colour or logo URL.
- Competitive glossary (spec, 2026-07-13): the word **"challenge"** belongs exclusively to
  Versus. The ladder uses **"rung"** and **"duel"**.

### Architecture you must not break

**The bot is solved on-device.** `BallIQ/Models/BotSolver.swift` runs the rung's real puzzle with
the rung's `bot_skill`, `seed` and the character's `BotStyle`, producing a `BotRun` whose `beats`
are replayed against the clock beside the player. There is **no server round trip during play**,
and that is the entire reason the ladder delivers a live-feeling opponent with no realtime
infrastructure. Do not add one.

**Difficulty is calibrated, not guessed.** `tools/ingest/ladder.py` models a *reference player*
(skill 0.75) against the bot on the real board and binary-searches the `bot_skill` that lands
P(player wins) on a designed curve (0.90 → 0.21 across the 30 rungs). It stores that as
`ladder_rungs.target_win_rate`.

**Python duplicates Swift, and a test pins them.** `ladder.py` re-implements `BotSolver`'s and
`BotStyle`'s formulas — the same duplicate-and-pin arrangement `grade.py`/`GradeFormula.swift`
live under. `BallIQTests/LadderCurveTests` replays every rung with the **real Swift solver** and
fails if the two disagree (worst drift today: 0.084, tolerance 0.10). **If you change a policy in
one language you must change it in the other, or that test goes red — which is the point.**

It also asserts two properties the curve exists to have:
- no rung sits on a board below difficulty **0.18** (below the floor, `hitProbability =
  skill^difficulty` is ~1 for everyone, the bot becomes flawless, and the rung is *harder* than
  the final boss — this is a bug that actually shipped);
- the curve descends across any five-rung window.

The test reads a fixture at
`/private/tmp/claude-501/.../scratchpad/ladder_fixture.json` and **skips** when absent, which is
the normal state on a fresh checkout. Regenerate it by dumping `ladder_rungs` (joined to
`bots.style`) plus each rung's `puzzles` row — see the test's own doc comment.

### Traps that have already cost time today

1. **Two Supabase decoders.** `JSONDecoder.supabase` sets `.convertFromSnakeCase`;
   `.supabaseExplicitKeys` does not. A model with explicit snake_case `CodingKeys` decoded
   through the former throws `keyNotFound`, and every call site wraps `select` in `try?`, so it
   silently becomes `[]`. **This hid the entire Versus tab for months.** Pinned by
   `BallIQTests/SupabaseDecoderTests`. Rule: explicit snake keys → `.supabaseExplicitKeys`;
   camelCase-only model → `.supabase`.
2. **`DiskCache` has no schema version.** A content or shape change stays invisible on device
   until the TTL expires and reads as a decode bug. Ladder content is now cached for **1 hour**
   (`LadderRepository.contentTTL`) for exactly this reason. If you add a cache, keep the TTL
   proportional to the payload — and version the key only for a shape a stale payload could not
   decode at all.
3. **`DebugLaunch` compiles out of Release** behind `#if DEBUG`, with a **mirrored block of inert
   constants** below it. Adding a flag to only the debug half builds fine and passes all 728
   tests, then **fails the Release archive**. Add to both halves.
4. **`Localizable.xcstrings` is a large generated catalog.** Do NOT hand-edit it surgically —
   that has broken builds. New `String(localized:)` strings fall back to English, which is fine;
   a catalog sync is Task 5.
5. **`git checkout <file>` reverts the whole file**, not just your last edit. It wiped an hour of
   work today. Use targeted edits.
6. **Backticks in a shell heredoc get expanded.** Use `<<'MSG'` (quoted) for commit messages.

### Verification bar

Every task is done when: the **Release-configuration build** succeeds (not just Debug), the full
test suite is green at 728+ with 0 failures, and you have **screenshotted the actual UI** in the
simulator — the outlier states, not just the happy one (AGENTS.md §5). Quantify every claim with
a real number, status code or diff (AGENTS.md §9). If a test in an area you didn't touch goes
red, find out *where* it's red before concluding anything (§7.1).

---

## Task 1 — A rung must not be replayable on the same board

**Priority: highest. This is a correctness bug, and Task 2 depends on it.**

### The problem

`ladder_rungs` has a single `puzzle_id`. Lose rung 7 and retry, and you get the identical board
with the answers already known — the score is meaningless and `ladder_attempts` (the corpus that
human ghost duels will later be built from) fills with poisoned rows. Every rung needs a **pool**
of boards, and a retry must serve one the player has not seen.

### Design

Add a child table rather than an array column, because each board needs its own seed and its own
verified difficulty:

```sql
create table public.ladder_rung_boards (
  rung             int  not null references public.ladder_rungs(rung) on delete cascade,
  ordinal          int  not null,               -- stable serve order
  puzzle_id        text not null references public.puzzles(id),
  board_difficulty double precision not null,
  seed             bigint not null,             -- per BOARD: the same bot must not replay an
                                                -- identical decision pattern on a new board
  primary key (rung, ordinal)
);
```

Also add `ladder_attempts.puzzle_id text` so "which boards has this player seen" is answerable.
`ladder_rungs.puzzle_id` stays as the pool's first board (ordinal 0) for backward compatibility
with any cached client.

**The pool must be difficulty-homogeneous.** A rung's difficulty is a promise; if board A is 0.25
and board B is 0.60, the rung is a different rung depending on which you get. Select each pool
within a tight tolerance (start at ±0.04) of the rung's target `board_difficulty`, and
**re-verify the win rate per board** — a board that lands outside ±0.08 of the rung's
`target_win_rate` at the rung's `bot_skill` does not belong in the pool.

Aim for **6 boards per rung**. Where the pool can't be filled (Grid is thin — see Task 4), fill
what you can and **fail loudly with a count**, don't silently ship a rung with two boards.

### Server-side selection

```sql
create or replace function public.next_ladder_board(p_rung int)
returns table (puzzle_id text, seed bigint, board_difficulty double precision)
```
`SECURITY DEFINER`. Returns the lowest-`ordinal` board in that rung the caller has **no
`ladder_attempts` row for**; if they have seen them all, the **least recently attempted**. Must
work for a signed-out caller (return ordinal 0) since the ladder is browsable signed out.

### Files

- `tools/ingest/ladder.py` — build and upsert pools; extend the printed table with a pool column.
- `supabase/migrations/00NN_ladder_board_pools.sql` + mirror into `supabase/schema.sql`.
- `BallIQ/Models/LadderRung.swift` — a `LadderBoard` model.
- `BallIQ/Data/Repositories/LadderRepository.swift` — call the RPC.
- `BallIQ/RepositoryContainer.swift` — `startLadderRung` uses the returned board + seed.
- `BallIQTests/LadderCurveTests.swift` — **verify every board in every pool**, not one per rung.

### Done when

- Every rung has ≥2 boards and you report the real distribution (`select rung, count(*) …`).
- Playing a rung, losing, and retrying serves a **different board** — verified in the simulator,
  with both board screenshots.
- `LadderCurveTests` passes across the whole pool.

---

## Task 2 — The encounter: live reactions and a real rematch

**Depends on Task 1** (a rematch needs a fresh board).

### The problem

Each bot has six authored voice lines in `bots.voice` — `intro`, `ahead`, `behind`, `win`,
`lose`, `playerPerfect`. **Only `intro` and the closing pair are wired.** `ahead` and `behind`
are written, stored, shipped, and never shown. And after a rung there is no way to play it again
without backing out to the roster.

### Product behaviour

**Reactions.** `DuelTimerBar` (`BallIQ/Features/Versus/DuelSession.swift`) already renders the
bot's live score off `LadderRunSession.botScore(after:)`. When the bot's score **crosses** the
player's — in either direction — surface that bot's `ahead` / `behind` line as a transient speech
bubble under the bar.

Constraints, all load-bearing:
- **At most 2 reactions per run**, and never within 8s of each other. The brief's own question is
  "how much character expression before it becomes distracting" — the answer on a 60-second timed
  board is: very little.
- Auto-dismiss after ~2.5s. Never blocks a tap; never covers the board or the current card.
- Respect `@Environment(\.accessibilityReduceMotion)` — fade only, no slide.
- Announce via `.accessibilityAnnouncement` rather than stealing focus.
- The bar must keep working unchanged for **human** duels, where `session.ladder` is nil.

You will need the player's live score in the bar. Each game view knows its own; pass it in
(`Keep4GameView` has `placement`, `GridGameView` has `solved`, `WhoAmIGameView` has
`revealedCount`). Prefer one shared optional parameter over three bespoke paths (AGENTS.md §4).

**Rematch.** On a ladder result, a `REMATCH` action beside `DONE` that immediately starts the
same rung on the **next unseen board**. Use `voice.rematch` if you add one (the column exists as
JSONB; adding a key is content, not schema). Losing should feel like an invitation — keep it on
`accentFill`, not `dangerFill`.

### Files

`BallIQ/Features/Versus/DuelSession.swift`, the three game views, `Keep4ResultView` /
`GridResultView` / `WhoAmIResultView`, `BallIQ/Features/Ladder/LadderView.swift`.

### Done when

Screenshots of a reaction firing mid-duel and of the rematch action; a rematch demonstrably
serves a different board; reduced-motion verified.

---

## Task 3 — Discovery: a real roster screen

### The problem

Stage 1 of the character brief is *browse a roster of visually distinct opponents*. Today the
only way to meet a character is to reach their rung, and the ladder list is a progression, not a
roster. Six characters exist with portraits, backstories, allegiances and styles — almost none of
it is reachable.

### Product behaviour

A **Roster** screen pushed from the ladder (and reachable from the Versus tab's ladder card).

- A grid of character cards, each using `BotPortrait` (`BallIQ/Features/Ladder/BotPortrait.swift`)
  in that bot's `BotPalette`.
- **Not yet encountered → silhouette**: portrait in `locked: true` form, name hidden, subtext
  replaced with "Rung N unlocks". Discovery is a reward.
- Tapping opens the same full-height character card the pre-duel briefing uses
  (`LadderBriefingSheet`) — **extract it, don't fork it**, and add a "your record" block.
- **Your record vs each bot**, from `ladder_attempts` joined to `ladder_rungs.bot_id`: played,
  won, best score, their best. Needs a small RPC or a view — `ladder_attempts` is own-read RLS.
- Empty state for a signed-out player: the roster still browses (content is world-readable), but
  the record block says sign in.

### Design

Cards in a 2-up `LazyVGrid`, `blockCard(fill:)` in the bot's palette for encountered characters
and `cardSurface()` for silhouettes. No new colours. Long names must not truncate the subtext —
check "The Archivist" and any 3-crest team row at the smallest width.

### Done when

Screenshots of the roster with a mix of unlocked and locked characters, the character card opened
from it, and the record block for a bot with attempts and one without.

---

## Task 4 — Lift the two ceilings the calibration ran into

Both are documented, measured, and currently limiting the ladder. Each is independent.

### 4a. The Grid pool is too thin at the top

Measured 2026-08-13 over the released pool: **54 of 106** Grid boards clear the 0.18 difficulty
floor; baseball's hardest board is **0.222**; 31 boards are *completely trivial* (every cell
1-star). Task 1 needs ~6 boards per rung at a matched difficulty, and Grid guards 9 rungs.

Deepen it with the existing pipeline — `python -m tools.ingest.main --grid <sports> --grid-days N`
(~45s/board on NFL; see the `grid-pool-depth` memory). Target: enough boards at difficulty ≥0.45
to fill every Grid rung's pool. Report before/after counts by sport and difficulty band. This is
an additive data push, explicitly blessed to run unattended (CLAUDE.md).

### 4b. Who Am I? cannot guard a hard rung

Its `performance` is a 7-value ladder that saturates at a clue-1 solve, and ties go to the player
(`LadderOutcome.playerWon`). At the reference skill the player solves on clue 1 ~75% of the time,
so **a perfect bot still loses ~73% of duels** — the format floors at a 0.733 win rate no matter
what `bot_skill` is. It is currently capped below rung 15 (`WHOAMI_MAX_RUNG` in `ladder.py`) for
exactly this reason, which costs the ladder a third of its mode variety.

Two candidate levers — **pick one, justify it with measurements, don't do both**:
1. Break Who Am I? duel ties on **elapsed time** (as human duels already do). Cheap; but the
   bot's pacing is synthetic, so racing it is racing a formula — argue why that is acceptable
   here or reject it.
2. Score Who Am I? duels on **points** rather than clue efficiency, so the difficulty multiplier
   (1.0 / 1.25 / 1.6) separates runs that currently tie. Changes the comparable, so it touches
   `LadderRunSession.verdictHits`, `ChallengeLink.whoAmIHits`, and `ladder.py`.

Either way: re-run the calibration, raise `WHOAMI_MAX_RUNG`, and show the new curve.

---

## Task 5 — Make it shippable

None of the above reaches a user until this is done.

1. **Sync the string catalog.** Two days of work added many `String(localized:)` strings that
   fall back to English. Regenerate `BallIQ/Localizable.xcstrings` properly (Xcode's own
   export/import, not hand edits — see trap 4). `BallIQTests/LocalizationTests` is a smoke test
   over known keys; extend it with two of the new ones.
2. **Route the trigger-driven pushes through the cadence guard.** `notify-versus-challenge`,
   `notify-versus-result` and `notify-friend-request` still call `sendApnsPush` directly, so they
   bypass `notification_log` and the daily cap entirely. Only the three *scheduled* slots go
   through `_shared/cadence.ts`'s `sendOnce`. `versus_challenge` is deliberately cap-exempt
   (`CAP_EXEMPT`) — keep that, but it should still be **logged**. `friend_request` should be
   capped like the rest.
3. **Verify the cadence live.** The 3-a-day cron went live 2026-08-13 and has never been observed
   with real traffic. Check `notification_log` for real rows, confirm no user exceeded
   `DAILY_PUSH_CAP = 3` in their local day, and confirm the once-per-category-per-day unique
   index is doing its job. Note: only **2 users** are reachable by push (4 device tokens, 9
   profiles) — say so plainly rather than reporting percentages of two people.
4. **Ship a TestFlight build.** Follow `.claude/skills/testflight-release/SKILL.md` exactly. Bump
   `CURRENT_PROJECT_VERSION`; `MARKETING_VERSION` is `1.5.0`. **Upload only — do not distribute
   to external groups** (that widening needs the user's explicit ask, AGENTS.md §8) and **do not
   touch the in-review `1.4.2` submission**. Archive in **Release** config, which is the only
   thing that catches the `DebugLaunch` class of bug (trap 3).

---

## Known-outstanding, not assigned to anyone

- **Zero human duels have ever completed.** Everything built assumes the loop works; it has never
  run end-to-end between two real accounts. Worth doing deliberately.
- **Phase 3 live duels stay deferred** — see `prompts/HANDOFF-multiplayer.md` for the argument
  (the app has zero third-party dependencies; adding one for Realtime loses to AGENTS.md §11).
- **Draft & Spin is not duelable** — `simulate()` uses a fresh `SystemRandomNumberGenerator`, so
  it needs a seeded rewrite before any duel on it is meaningful.
- **APNs stale-token pruning** — noted in `_shared/apns.ts`; a 410 Unregistered never prunes
  `device_tokens`.
