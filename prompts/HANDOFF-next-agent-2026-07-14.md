# Handoff — last-breath MVP work (2026-07-14 final sprint, continued)

## Goal

Close out the last real gaps before BallIQ is fully launch-ready. Everything in this doc is
either agent-buildable now or has a concrete, named external hand-off — there is nothing
left that needs new product scoping (Phase F is explicitly deferred by the user, see below).

## Why now

The 2026-07-14 final-sprint session shipped Tier 1 (perf re-verified), all of Tier 2
(arcade leaderboards, push chain verified to its one real blocker, Phase F explicitly
deferred), and most of Tier 3 (team colors on every team surface, historical headshots,
content-drift guard). Two threads were still moving when that session ended: Spanish
localization was mid-flight in a background subagent, and APNs key material was still in
the user's hands ("I'll get the p8"). Read `docs/BALLIQ_SPEC.md` §9.0 first — it's current
as of commit `a537819` (pushed to `origin/main` same day) and is the source of truth for
what's actually shipped vs. remaining; this doc is the concrete next-steps list, not a
duplicate of it.

## Current state to build on

- **Repo**: `origin/main` is at commit `a537819` (verify with `git log --oneline -1`) —
  includes the arcade leaderboards, the team-color pass, and this session's spec updates.
  Working tree may still have **uncommitted Spanish-localization edits in flight** from a
  subagent dispatched right before this handoff was written — run `git status` first. If
  you see modified files under `BallIQ/DesignSystem/`, `BallIQ/Features/*/`,
  `BallIQ/Models/*.swift` with no corresponding commit, that's the localization pass;
  read what's there before assuming it's stale or redoing work.
- **Live Supabase** (`nhccgufqwndtoasdbkhc`): `player_seasons` is clean — exactly 232,109
  rows, 100% sport-prefixed ids, 0 old-format duplicates, vacuumed. A `(sport, id)`
  composite index exists so the ingest pipeline's existing-id fetch doesn't time out again.
  `arcade_scores` + `arcade_leaderboard` RPC are live and wired into Over/Under + Grid.
- **Push infra**: all 5 edge functions deployed/ACTIVE, all 4 cron jobs firing on schedule
  (confirmed via 24h of logs). Everything runs in `[apns:stub]` log-only mode pending real
  key material — this is the only remaining blocker on the retention loop.

## Scope

### 1. Finish / verify Spanish localization (M14, backlog #10)

Check whether the in-flight subagent pass landed a `Localizable.xcstrings` String Catalog
and Spanish translations. If it's incomplete or was never finished:
- Follow `prompts/M14-accessibility-and-localization.md` §3–4 (VoiceOver + Dynamic Type are
  **already shipped** — don't redo them, just the string-catalog + Spanish translation
  piece).
- Coverage priority if you have to triage: tabs, Home, onboarding, Keep4, Over/Under, Grid,
  result/rewards surfaces first — report exactly what's not yet covered rather than
  claiming full coverage.
- Player names / team abbreviations / league names / pipeline-sourced stat labels stay
  English (data, not UI chrome).
- Verify: build + full Swift suite green (baseline before this session's work started was
  298 tests), then `-AppleLanguages (es)` simulator launch + screenshot at least Home,
  Keep4, and one result screen to confirm strings actually resolve (not just that the
  catalog file exists).

### 2. Wire real APNs credentials (unblocks Tier 2's #1 push notifications)

The user is sourcing the APNs auth key (`.p8`) themselves. Once it's available:
- Confirm on the Apple Developer portal (Keys page, team `8K5ZVPCQ42`) that the key is
  APNs-enabled, and that the "Push Notifications" capability is turned on for the
  `com.balliqfantasy.app` App ID (a screenshot or the user's confirmation is enough — you
  can't check the portal yourself).
- Add the `aps-environment` entitlement to `BallIQ/BallIQ.entitlements` (currently only has
  `com.apple.developer.applesignin` — deliberately left off until the capability existed,
  since adding it earlier breaks archive signing).
- Set `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_PRIVATE_KEY` / `APNS_BUNDLE_ID` as Edge
  Function secrets. The local `supabase` CLI (`/opt/homebrew/bin/supabase`) is logged into
  the **wrong** account (`xanman1000's Project`, not `nhccgufqwndtoasdbkhc`) — either
  `supabase login` to the right account first, or have the user paste the four secrets into
  the Supabase dashboard (Edge Functions → Secrets) directly. Do not ask the user to paste
  the raw private key contents into chat — talk them through the dashboard paste instead.
  See `supabase/functions/_shared/apns.ts`'s own header comment for the exact hand-off shape.
- Verify: trigger one of the cron functions manually (e.g. `notify-streak-risk` via the
  Supabase dashboard's "Invoke" button, or wait for its hourly schedule) and check
  `get_logs(service: "edge-function")` — a real APNs call replaces the `[apns:stub]` log
  line. Full delivery to a device needs a **real signed device with a real APNs device
  token** registered in `device_tokens` — the simulator cannot receive real push, so final
  confirmation needs the user's own phone on the TestFlight build.

### 3. Cut a new TestFlight build

A lot has landed since the last build (arcade leaderboards, team colors, possibly Spanish).
Use the `testflight-release` skill (`.claude/skills/testflight-release/SKILL.md`) to
archive, sign, and upload — don't rebuild the manual cloud-signing workaround from scratch,
it's already documented there. Bump the build number; check the App Store Connect API for
the app's current review/release status first (it was submitted for full review as of
2026-07-05 per `docs/BALLIQ_SPEC.md` §8 — confirm whether it's still in review, was
approved, or needs a new submission before just uploading a build over it).

### 4. Hand the QA checklist to the user

`prompts/QA-testflight-social-flows.md` is ready — a ~25-minute two-account pass covering
friends, FRIENDS leaderboard, onboarding claim, Versus, and the new arcade/Daily Draft
boards. This needs two real signed-in TestFlight accounts; you can't run it yourself. Once
credentials/build are ready, just point the user at the file.

## Explicitly out of scope — do not build

- **Phase F rating seasons** (backlog #7) — the user said "defer" on 2026-07-14. Do not
  start from inference if it comes up again; the scoping questions are logged in
  `prompts/HANDOFF-next-agent-2026-07-12c.md` for whenever the user reopens it.
- **M5 Phase B monetization** — blocked entirely on the Paid Applications agreement +
  real IAP products in App Store Connect, both human-only actions in ASC's Business/
  Monetization sections. `app-store-notifications` is deployed and deliberately 500s
  "not configured" until `APPLE_ROOT_CA_PEM` is set — don't silence that, it's correct.
- Recoloring `SpinRevealView`'s volt "LOCKED IN" reveal motif, adding a team-color accent
  stripe to `DraftSpinResultView`'s share-card lineup lines, or adding team data to WhoAmI's
  content model — all flagged as deliberate product-taste calls during the 2026-07-14 color
  audit, not gaps to silently fix.

## Verification / success criteria

- Both test suites green after any change (`xcodebuild ... test` — 298+ Swift tests;
  `.venv/bin/python -m pytest tools/ingest/tests -q` — 198+ Python tests).
- Spanish: screenshot-confirmed under `-AppleLanguages (es)`.
- Push: a real (non-stub) APNs call visible in edge-function logs, ideally confirmed
  delivered to the user's own device.
- New TestFlight build actually installable and its version bump reflected in App Store
  Connect.

## Hand-offs (cannot be done by the agent)

- APNs key material confirmation on the Apple Developer portal (user in progress as of
  this handoff).
- Paid Applications agreement + IAP product creation in ASC (gates M5 Phase B — not part
  of this sprint's scope, just noting it's still the one fully-unstarted milestone).
- The two-account TestFlight QA pass itself (`prompts/QA-testflight-social-flows.md`).
- A native Spanish speaker's review of the machine/agent-translated strings, once shipped.
