# Handoff — continue BallIQ development (2026-07-12)

You are the **orchestrator agent** for the BallIQ repo (`/Users/xanderevans/Documents/fantasy-app`).
Read `CLAUDE.md`, `AGENTS.md`, and skim `docs/BALLIQ_SPEC.md` §7 (verification playbook)
before doing anything. This document tells you (1) exactly where the repo stands, (2) the
orchestration method that has worked well here, and (3) the prioritized backlog.

## 0. FIRST ACTION — commit the working tree

The tree holds three complete, verified, **uncommitted** bodies of work (all tests green:
236 Swift / 181 Python at handoff). Commit them as three separate commits before touching
anything else, roughly:

1. **Minigame fixes & polish** — `DraftSpinResultView` (simplified header + foil top-season
   card), `GridGameView`/`GridResultView` (LazyVGrid cell-rendering bugfix + board recap),
   `WhoAmIResultView` (answer card restyle), `GameSetupScreen` (Pro-gate bypass fix),
   `keep4_puzzles.json` / `player_seasons.json` / `stat_baselines.json` (regenerated bundles).
2. **Ingest: tennis full coverage + incremental catalog** — `tools/ingest/providers/tennis_recent.py`
   + `tennis_wta.py` + their tests + both CSVs, `main.py` (wiring + `filter_new_catalog_rows`),
   `upsert.py` (`fetch_existing_catalog_ids`), `.github/workflows/ingest.yml` (`--catalog` flag),
   `content_health.json`.
3. **M19 social layer** — `supabase/schema.sql` (friends + `public_profile` RPC, already
   applied live), `SocialRepository.swift`, `RepositoryContainer.swift`, everything under
   `Features/Friends/` and the new `Features/Profile/` files, both new test files.

Push with the PAT from root `.env`, never `gh`'s OAuth token (workflow-scope rejection —
see CLAUDE.md for the exact command shape).

## 1. State of the world

- **App**: SwiftUI iOS, 5 minigames (Keep4, WhoAmI, Draft & Spin, The Grid, Over/Under),
  all sport-generic across NFL/NBA/MLB/soccer/tennis. v1.0 on TestFlight + in App Store review.
- **DB** (Supabase `nhccgufqwndtoasdbkhc` — NEVER the decoy project, see CLAUDE.md):
  `player_seasons` fully synced with the pipeline: nfl 26k, nba 24k, baseball 62k,
  soccer 72.9k, tennis 8.5k season rows + careers. Daily cron ingests with `--upsert --catalog`.
- **M19 social (just shipped, needs live verification)**: `friends` table + RLS,
  `public_profile` security-definer RPC, `SocialRepository`, `PublicProfileView` (shared
  nav target), identity claim/editor on Profile, `FriendsView` hub, tappable usernames in
  Leagues/Community/Versus. **Not yet visually verified signed-in** — simulator has no
  authed session. First QA task: two TestFlight accounts exercising claim → request →
  accept → challenge.
- Task-relevant quirks already solved once — don't rediscover: manual signing for TestFlight
  uploads (CLAUDE.md), `xcrun simctl launch` doesn't attach `.storekit` configs,
  `DebugLaunch.swift` screenshot flags are the UI-verification path.

## 2. Orchestration method (this is the "same subagent approach" — follow it)

The pattern that worked: **orchestrator owns everything shared; subagents own disjoint
files; nobody overlaps.**

1. **Recon yourself first.** Read the actual views/repos/schema you're about to change.
   Plans written without reading files produce agents that guess.
2. **Orchestrator does the shared plumbing before dispatching**: DB migrations (apply via
   Supabase MCP `apply_migration`, then mirror the identical DDL into `supabase/schema.sql`
   in the same change), `RepositoryContainer.swift` edits (its `client` is `private` —
   extensions in other files cannot reach it, so all container seams must be edited in-file),
   and any view that multiple agents will navigate to (e.g. `PublicProfileView` last time).
   Build once to prove the foundation compiles before agents start.
3. **Dispatch 2 (max 3) Sonnet subagents in parallel** (`Agent` tool, `model: "sonnet"`,
   background). Each agent's brief must contain:
   - **Exact file ownership**: "You own files X, Y, new files under Z. Do NOT touch any
     other file — another agent is working in this tree concurrently." Ownership sets must
     be provably disjoint, including tests.
   - **The API contract**: paste the actual signatures of container/repository methods they
     call (don't make them grep for it).
   - **Design-system vocabulary**: `cardSurface()`, `blockCard(fill:)`, `heroReveal(n)`,
     `PrimePressStyle()`, `Color.accentFill/onAccent/textMuted/...`, `FontName.condBlack`,
     `.label11/.label12/.heading/.title`, `Haptics.*`. Point them at a concrete existing
     view to mirror (e.g. "match `VersusView`'s sign-in-gate → loading → empty → list shape").
   - **Verification bar**: build with `xcodebuild -project BallIQ.xcodeproj -scheme BallIQ
     -destination 'generic/platform=iOS Simulator' build` using **their own
     `-derivedDataPath` (e.g. `/tmp/build-agent-<name>`)** — two agents sharing DerivedData
     caused a transient failure last time; run the full test suite; report what they verified
     vs. assumed. Tell them NOT to install/launch on the simulator (orchestrator does
     integration screenshots to avoid fighting over the booted device).
   - Repo facts they can't infer: the pbxproj uses `PBXFileSystemSynchronizedRootGroup`, so
     **new Swift files under `BallIQ/`/`BallIQTests/` are auto-included — never edit the
     pbxproj**; views read `RepositoryContainer` only, never services/clients directly;
     match surrounding comment density.
4. **Integration pass is yours**: full build, full test suite
   (`-destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5'`), then simulator
   screenshots via the `DebugLaunch` flags (`-screenshotProfile`, `-screenshotGrid`, …
   — see `DebugLaunch.swift` for the full list; add flags for new surfaces). Read the
   screenshots — a blank region is a finding (that's how the Grid bug was caught).
5. **Report honestly**: what's verified vs. what needs a human/TestFlight pass.

## 3. Backlog (prioritized)

1. **Live-verify M19 social** with two signed-in accounts (TestFlight or two simulators
   with real Apple/Google sign-in): claim username, friend request both directions,
   accept/decline, challenge-from-friends, public profiles from Leagues/Community/Versus.
   Fix whatever falls out.
2. **Social follow-through** (good 2-agent split: server/push vs. app UI):
   - Friend-request push notification (extend the deployed Edge Functions; APNs secrets
     still unset — sends log until then, that's fine).
   - Friends leaderboard: "FRIENDS" scope on Leagues using accepted edges + `public_profile`
     ratings; consider avatar in Versus rows.
   - Onboarding: prompt username claim at sign-in, not just buried in Profile.
3. **Soccer data gap** (user green-light needed on approach, research already done):
   `JaseZiv/worldfootballR_data` GitHub mirror, `fb_big5_advanced_season_stats/*.rds` —
   Big-5 leagues 2017/18–2024/25 incl. keeper/defense stats. One-time `.rds`→CSV conversion
   (`pyreadr`), then a provider mirroring `tennis_wta.py`'s committed-CSV shape. Adds real
   clean-sheet/GK depth. FBref live scraping is against their ToS — don't wire `soccerdata`.
4. **M14 Spanish localization** — untouched milestone, pure app-code, parallelizes well
   across agents by feature folder.
5. **M5 Phase F** — 8-week rating seasons (see BALLIQ_SPEC §8 open items).
6. Housekeeping: `notify-versus-challenge` DB webhook still unwired (dashboard-only step);
   APNs credentials still external hand-off; two pre-M9 community rows keep legacy grades
   (by design, ignore).

## 4. Non-negotiable guardrails

- Supabase writes: additive migrations + merge-duplicate upserts are fair game to run
  directly; destructive ops (drop/delete/truncate/RLS revocation) require explicit user OK.
- `supabase/schema.sql` must never drift from production — every live migration lands in
  the same change.
- Don't hand-edit `BallIQ.xcodeproj/project.pbxproj`.
- Content immutability: never re-grade published community puzzles.
- Verify with the real app (simulator screenshots), not just the test suite, for anything
  with a UI surface.
