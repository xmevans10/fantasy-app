# BallIQ / "Playbook: Sports Trivia" — commercial takeover brief (2026-07-27)

You are taking over a **live App Store iOS app** whose goal is now explicitly commercial
success. Treat `main` as production.

This brief is deliberately different from the previous handoffs. Those were feature plans.
This one starts from a measurement of the business, because that measurement says the
constraint is **not** features.

## 0. Orientation — read these first, in this order

1. `CLAUDE.md` — project facts + standing permissions (Supabase MCP, GitHub PAT).
2. `AGENTS.md` — *how* to work here. §1 ("verify against the live system, not the artifact")
   is the rule that produced every finding below; the docs were confidently wrong twice.
3. `docs/BALLIQ_SPEC.md` — living source of truth. §9.1 is the version roadmap, §9.2 the Grid.
4. Your memory directory — `schema-index-drift`, `supabase-decode-gotcha`,
   `asc-first-iap-submission`, `simulator-defaults-cache` will each save you an hour.

## 1. State as of this handoff (all verified live, 2026-07-27)

- **HEAD `30a4ce2`**, pushed, tree clean. Remote `github.com/xmevans10/fantasy-app`.
- **Green baseline: Swift 406, pytest 341.** Re-verify before claiming done.
- **1.2 build 15 is `WAITING_FOR_REVIEW`** (submitted 13:26 UTC today). It carries the v2 Grid
  decoder, symmetric axes, `RemoteImage`, and the random/practice Grid.
- Live Supabase project is **`nhccgufqwndtoasdbkhc`**. `list_projects` returns a decoy
  (`pyprjebfwqfdnfeliigo`) — never target it.

## 2. The two facts that define the business

### 2.1 The app cannot take money. It never could.

All four products are **`READY_TO_SUBMIT`** — meaning created, priced, localized, and
**never submitted for review**:

```
com.balliqfantasy.app.pro.monthly     READY_TO_SUBMIT
com.balliqfantasy.app.pro.yearly      READY_TO_SUBMIT
com.balliqfantasy.app.pack.draftspin  READY_TO_SUBMIT
com.balliqfantasy.app.pack.grid       READY_TO_SUBMIT
```

`entitlements` has **0 rows**. Not "few sales" — *zero possible sales*. The app has been live
since 2026-07-16 with a fully built paywall in front of products that don't exist in
production StoreKit. Every rail behind it (StoreKit 2, server validation, webhook, gating)
is finished and tested. The register is built and the door is locked.

**This is `[user]`-only and it is two clicks of ASC UI.** The REST API cannot do it: a first
non-consumable must be attached to a version submission through the web UI
(`FIRST_NON_CONSUMABLE_MUST_BE_SUBMITTED_ON_VERSION`). Steps are already written up in
`prompts/ASC-MONETIZATION-SUBMISSION.md` and §9.1's 1.3 entry.

**Nothing else in this document generates a dollar until this is done.** If you can only get
the user to do one thing, make it this.

### 2.2 The app has no users.

Every analytics event ever recorded, by distinct user:

| event | events | distinct users |
|---|---|---|
| game_started | 647 | **3** |
| game_completed | 234 | **2** |
| community_puzzle_played | 38 | 1 |
| onboarding_completed | 26 | 2 |
| sign_in_completed | 8 | 3 |
| share_tapped | 6 | 1 |
| puzzle_published | 1 | 1 |

4 profiles, 1 arcade score, 1 device token, 0 grid guesses. Eleven days on the App Store.

**Treat these numbers as developer activity, not usage.** A chunk of today's `game_started`
rows are my own simulator launches. The 647→234 "completion rate" is not a product signal at
this N — do not build a retention theory on it.

The honest read: the analytics *pipeline* works and has only ever measured its own authors.

## 3. What this means for what you should build

The previous roadmap declared the agent-buildable backlog exhausted, and it was right. The
temptation is to keep deepening content (Grid parity Tier 1–3, more themes, more sports).
**Resist it.** That work optimizes a funnel with no traffic, in front of a register that
doesn't open. It will feel productive and change nothing.

Ordered by expected commercial value:

### Phase 0 — unblock revenue `[user]`, ~15 minutes
1. Submit the four IAPs via ASC UI (§2.1). Attach to a version submission.
2. Set the production App Store Server Notifications V2 URL to the `app-store-notifications`
   function (App Information → App Store Server Notifications). No API endpoint exists (404).
3. After build 15 is approved: **re-enable the Grid cron** (see §4.1 — this is a live
   obligation, not a nice-to-have).

### Phase 1 — instrument the money `[agent]`, no gates
**There is no paywall event.** Not `paywall_viewed`, not `paywall_dismissed`, not
`purchase_attempted`, not `purchase_failed`. When Phase 0 lands, you will have a live store
and *zero* visibility into who sees the paywall, from which surface, and where they drop.

This is the highest-value agent work available, and it is unblocked right now:
- Add paywall funnel events (`paywall_viewed` with the trigger surface, `plan_selected`,
  `purchase_attempted`, `purchase_completed`, `purchase_failed` with reason).
  `PaywallView` already knows its trigger context — every `showPaywall = true` site passes
  through a gate that knows *why*.
- The `events` table + `container.track(...)` pipeline already works. This is plumbing, not
  architecture.
- Exit: you can answer "of users who hit a Pro gate, how many open the paywall, and how many
  reach the purchase sheet" from SQL.

### Phase 2 — distribution `[user]` + `[agent]` prep
Zero installs in 11 days is not a conversion problem, it's an awareness problem. An agent
cannot post, advertise, or do PR. It *can* prepare everything that gets acted on:
- ASO is the only free lever. The product page was refreshed 2026-07-17; nothing has measured
  whether it converts. Prepare A/B-able variants of subtitle/keywords/screenshots.
- The share card already exists (`share_tapped` fires) — it is the only organic loop in the
  product. 6 taps ever. Worth making the shared artifact good enough to actually spread
  (Immaculate Grid's emoji grid is the reference; the Grid result already builds one).
- **Ask the user what distribution they're willing to do.** This is a real conversation, not
  an agent task. Their answer determines whether Phase 2 is ASO-only or something bigger.

### Phase 3 — fix what real data exposes `[agent]`
Only meaningful *after* Phase 0–2 produce non-developer traffic. Then the existing backlog
(§9.2 Grid parity, content depth) becomes prioritizable against evidence instead of taste.

Note specifically: §9.2 Tier 1 item 3 ("crowd rarity should drive scoring") is documented as
"the data is already flowing." **It is not** — `grid_guesses` has 0 rows, because there is no
crowd. That item is unbuildable until traffic exists and should sit *below* awards axes and
career-grain stats, which work identically at any scale.

## 4. Live obligations you are inheriting

### 4.1 🔴 The daily Grid mint is PAUSED and must be turned back on
`ingest.yml`'s cron runs `--grid ... --upsert` from `main` at 09:00 UTC daily. `main` now
carries the v2 generator, whose non-classic archetypes the shipped 1.2 build 14 client cannot
decode ("No Grid today"), and minted boards are immutable for their day. The step is
commented out (commit `138c4a2`) because the next scheduled run would have broken live users.

**Until someone uncomments it, no new Grid boards are minted for any sport.** Clients fall
back to the modulo pick over existing rows — safe, but degrading. Re-enable the moment build
15 is approved. The commented line already includes `baseball`.

### 4.2 `bump_weekly_xp` lets any signed-in user set their own XP
```sql
update cohort_members set weekly_xp = weekly_xp + amount where user_id = auth.uid()
```
`SECURITY DEFINER`, no cap, no server-side derivation. Anon is safe (`auth.uid()` scoping), so
half the Supabase advisor warning is a false positive — but any authenticated user can POST
`{"amount": 999999}` to `/rest/v1/rpc/bump_weekly_xp` and top the weekly cohort board.
Low impact today (9 cohort members); real once Leagues has players. **Do not fix by revoking
EXECUTE** — the app calls this legitimately. It needs server-side derivation or a clamp to the
maximum a single game can award.

### 4.3 `puzzles` has no index beyond its primary key
Every puzzle fetch is a sequential scan. Harmless at 178 rows (3 ms). It is a **precondition
for the Grid backfill**, not an optimization — deepening the pool makes it linear over rows
carrying up to 109 KB of content each. Create it *with* the backfill, and update
`supabase/schema.sql` in the same change (CLAUDE.md's drift rule).

### 4.4 Ten Supabase advisor warnings are false positives
`handle_new_user`, `bump_play_count`, `auto_hide_reported_puzzle`, and the two webhook
functions all return type `trigger`. PostgREST cannot expose trigger-returning functions as
RPC. Don't spend a day "hardening" them.

## 5. Grid content state (for whoever picks up §9.2)

Boards ever minted: nfl 13, nba 12, tennis 12, **soccer 3, baseball 1**.

Baseball's drought was a **config omission, not a data problem** — it was simply missing from
the cron's sport list. It has the richest team×team space of any sport: all 435 of its
C(30,2) club pairs share 5+ players. Soccer's *ragged* gaps are genuine viability failures
(only 1,545 of its 19,989 player-sharing pairs share 5+), which is why `max_attempts` is 500.

Tennis has **5** viable team pairs total — its "teams" are countries and players don't switch
nationality. That independently confirms excluding tennis from `TEAM_MOBILE_SPORTS`.

The backfill is the cheap win here: `run_grid` already mints per `(sport, date)`, so running
it over a wide date range gives hundreds of boards per sport with one generator and no new
architecture. Gated on 4.1.

## 6. Working style the user has asked for

- **Act, don't ask.** Make the call, then report what you did and why. They have said this
  repeatedly and meant it.
- **Simple is always better.** Said verbatim this session after I over-engineered a fix.
- **Verify against the live system.** Both of this session's biggest findings (products never
  submitted; `grid_guesses` empty) contradicted a confident written claim in the repo's own
  docs. Check the database and the API, not the markdown.
- Report failures plainly. If tests fail, say so with the output.

## 7. Landmines I hit this session

- `JSONDecoder.supabase` uses snake_case key decoding. Puzzle **content** is camelCase — use
  the plain `contentDecoder`. Using the shared one fails silently and looks like an empty pool.
- A **cancelled** ASC review submission goes `COMPLETE`, not `UNRESOLVED_ISSUES`, so you must
  `POST` a *new* `reviewSubmission` — the exact opposite of the rejection path. Both flows are
  now documented in the `testflight-release` skill.
- Apple allows **one open review submission per app**. You cannot cut a new version while one
  is queued; you either wait or cancel (and cancelling resets its place in the queue).
- Unquoted `--include=*.py` in zsh silently matches nothing and makes a grep-based dead-code
  sweep report *everything* as unused. Use an AST pass; `scratchpad/deadcode.py` has one.
- Don't delete "unused" code without checking for a retention note. `curation.name_regex` and
  `name_title` look dead and are deliberately kept — `generate.py` documents `NAME_VARIANTS`
  as retained for a future WhoAmI generator.
