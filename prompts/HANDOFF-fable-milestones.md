# Playbook — Fable 5 handoff: M5, M12, M13, M15

**Read this whole file first.** It's the one-stop briefing for the four remaining "hard"
milestones — the ones that need real product/architecture judgment, not just wiring. Six smaller,
well-scoped fixes (per-format completion, edge-function scheduling + APNs, a content-drift test
guard, the community report button, Browse filters, a VoiceOver pass) already shipped in the same
session this handoff was written from; this file assumes that work is done and current.

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard
> constraints (repository seam, Prime Time design system, secrets handling). That context is not
> repeated here.

## What just shipped (read before touching any of the four tasks below)

- **Per-format daily completion** is fixed. `RepositoryContainer.hasCompletedToday(_ card: DailyCard, date:)`
  now exists (`DailyCard` enum: `.keep4`/`.whoAmI`); `HomeView`'s two cards track independently.
  `hasPlayedToday()` still exists unchanged and still drives streak/first-play XP — don't confuse
  the two when touching progression code.
- **The five `supabase/functions/` edge functions are schedulable.** `supabase/migrations/0001_schedule_edge_functions.sql`
  exists (idempotent `cron.unschedule`+`cron.schedule` per function) but has **not been applied** —
  it still has `<PROJECT_URL>`/`<SERVICE_ROLE_OR_ANON_KEY>` placeholders. **The Supabase MCP tools
  in this environment are currently unauthorized/disconnected** — if any of the four tasks below
  need to apply a migration, create a table, or otherwise touch the live project, that's a hand-off
  to the user (tell them to authorize the Supabase connector, or run the SQL by hand), not
  something to work around.
- **APNs push delivery is for-real implemented** (`supabase/functions/_shared/apns.ts`): ES256 JWT
  signing via Web Crypto, token caching, real `fetch` delivery to `api.push.apple.com`. Only the
  real `.p8` key is a hand-off. If M5's entitlement flow or any push-notification-adjacent M13 work
  needs to send a push, this plumbing already exists — don't rebuild it.
- **A real content-drift bug was caught and is currently landing red on purpose**:
  `tools/ingest/tests/test_content_drift.py::test_bundled_wr_grades_match_current_formula` fails
  because the bundled `keep4_puzzles.json`'s "Elite WR receiving seasons" theme has drifted from
  the current `grade.py` formula (CeeDee Lamb 2023 is 23.3 points off). **This is a known, tracked,
  pre-existing issue — not something any of these four tasks broke.** Regenerating the bundle
  (`python3 -m tools.ingest.main --write-fallback`) is out of scope for all four tasks below; don't
  fix it as a drive-by unless the user asks.
- **Community reporting has a working UI now** — directly relevant to M12 below, read that
  section's status note before starting.
- **Browse has decade/position filter chips now** — directly relevant to M13 below.
- **VoiceOver labeling landed** on `Keep4CardView`, `WhoAmIGameView`, `DailyGameCard`. Two items
  were explicitly left undone and flagged, not silently skipped: a live Accessibility Inspector
  walkthrough (environment had no unlocked display to drive it), and hiding the confetti
  celebration from VoiceOver (the vendored `ThirdParty/ConfettiSwiftUI` has no accessibility hooks
  to hang that off safely). Full Spanish localization was never in scope — it's a separate,
  larger, still-untouched task if the user wants it later.
- All 105 Swift tests, 53/54 Python tests (1 expected failure, see above), 8/8 Deno tests pass as
  of this handoff.

## The four tasks

Each has a full, detailed brief already written — **don't duplicate that content here, read the
file.** This section is the orchestration layer: what each one is in one paragraph, how they
relate to each other, and the order to tackle them in.

### 1. [M5 — Monetization + breadth](M5-monetization-breadth.md)
StoreKit 2 Pro subscription + format packs with server-validated entitlements, three new game
formats (Over/Under, Draft & Spin, The Grid) built from scratch on the existing rating/XP/design
pipeline, and an 8-week season structure with soft-reset + cosmetic rewards. This is the only one
of the four with a **real hand-off dependency the user must complete first**: App Store Connect
product configuration, the paid-apps agreement, and App Store Server Notifications endpoint setup
are all outside any agent's reach. Start the buildable parts (StoreKit 2 client code against a
local `.storekit` config, the three formats, season math) without waiting on those — they're
independently verifiable in the simulator — but flag the live-product wiring as blocked until the
user completes the App Store Connect side.

### 2. [M12 — Trust & safety](M12-trust-and-safety.md) *(scope narrowed since it was written — read the status note at the top of that file)*
The report **UI** shipped in the prior session (overflow icon on every Community card + both game
views, reason picker, confirmation). What's left is purely the **policy half**: an auto-hide
threshold once a puzzle crosses N reports, and a minimal review surface so a hidden puzzle is
visible to *someone* — nothing currently reads `community_reports` back out. This is the smallest
and most self-contained of the four; good candidate to do first or in parallel with anything else.

### 3. [M13 — Discovery & growth](M13-discovery-and-growth.md) *(current-state note updated — Browse now has decade/position filter pills; that is NOT text search)*
Real text search (title + player name) across Browse and Community — genuinely absent today, not
just under-scoped. Plus a pre-play puzzle-sharing flow (share the puzzle itself via
`balliq://play/<id>` with a preview card carrying its `ScoringKind` badge, not just a completed
result) and a recency-aware trending sort to replace the current all-time `play_count` ordering.
No blocking hand-offs — fully buildable and verifiable with the simulator and
`xcrun simctl openurl` for deep-link testing.

### 4. [M15 — Analytics & content health](M15-analytics-and-content-health.md)
A first-party event pipeline (an `events` table, RLS, a thin `AnalyticsClient` mirroring the
existing `SupabaseClient` shape — no third-party SDK, matching the app's hand-rolled-everything
convention) plus a content-health artifact from the ingest pipeline. No blocking hand-offs for the
first-party path. **Sequencing note carried over from the original brief:** this has the most
value landing *before or alongside* M5/M13, not after — you can't judge a Pro conversion rate or a
search feature's impact without a baseline. If picking one task to front-load, this is the
strongest case for going first despite being listed last.

## Recommended sequencing

Not a hard dependency chain — each task is independently scoped and its own file stands alone.
But if sequencing at all:

1. **M12** first or in parallel with anything — smallest, most self-contained, and the report UI
   it builds on is freshly verified working.
2. **M15** early — its whole value proposition is measuring the other two before/as they ship.
3. **M5** and **M13** pair naturally and are the largest — don't sell a Pro tier into a feed nobody
   can search, and don't build search infrastructure without knowing whether it's used (M15 again).
4. **M5** has the one real external hand-off (App Store Connect) — start its buildable parts
   immediately rather than blocking the whole milestone on that, per its own file's guidance.

## Cross-cutting constraints for all four

- **Supabase MCP is currently unauthorized in this environment.** Any schema change, RLS policy,
  migration application, or new table needs the user to either authorize the connector or run SQL
  by hand. Write and review the SQL; don't pretend it's been applied.
- **Keep all six-fix-session tests green** (`xcodebuild ... test`, `pytest tools/ingest/tests -q`,
  `deno test supabase/functions/_shared/apns.test.ts --allow-env`) — the one expected exception is
  `test_content_drift.py`'s pre-existing red failure described above; don't "fix" it by loosening
  the guard's tolerance, and don't let a new failure hide behind it.
- **Match the Prime Time design system** for any new UI (`BallIQ/DesignSystem/DESIGN.md`) — reuse
  existing components (`PrimeSegmentedControl`, `DailyGameCard`'s `secondaryAction` pattern,
  `ReportReasonDialog`-style shared modifiers) before inventing new ones.
- **The agent cannot provision third-party accounts** (App Store Connect, Apple Developer, a real
  APNs/Supabase project) or enter the user's credentials — surface those as explicit, named
  hand-offs per task, the way each milestone file's own "Hand-offs" section already does.
