# Playbook — Milestone prompts (M3–M17)

Self-contained prompts to drive milestones. Each file can be handed to a fresh
agent: it carries enough context to execute without prior conversation. Written in the Fable-5
spirit — **state the goal and success criteria; don't over-prescribe the steps.**

> **The living source of truth is [docs/BALLIQ_SPEC.md](../docs/BALLIQ_SPEC.md)** — product,
> architecture, scoring/parity rules, and current status. These prompt files are historical
> milestone briefs; the spec supersedes their status columns.

| Milestone | Theme | File | Status (2026-07-02) |
|-----------|-------|------|---------------------|
| **M3** | Real sports data pipeline (no more hardcoded content) | [M3-real-sports-data.md](M3-real-sports-data.md) | ✅ shipped |
| **M4** | Social retention — Leagues, Versus, Stats, Push | [M4-social-retention.md](M4-social-retention.md) | ✅ shipped (Leagues/Versus/Stats tabs + push manager in tree) |
| **M5** | Monetization + breadth — Pro/StoreKit, packs, formats | [M5-monetization-breadth.md](M5-monetization-breadth.md) | 🟧 breadth/scoring shipped; **monetization pending** |
| **M6** | Community fixes + backend hardening | [M6-community-fixes-hardening.md](M6-community-fixes-hardening.md) | ✅ shipped (feed fix, daily determinism, ESPN-keyless NBA) |
| **M7** | Content scale + automation (CI, broad pulls, bounds) | [M7-content-scale-and-automation.md](M7-content-scale-and-automation.md) | ✅ shipped (853-player NBA pool, 13+ themes, ingest.yml CI) |
| **M8** | Single-game grading (net-new data model) | [M8-single-game-grading.md](M8-single-game-grading.md) | ✅ shipped (game-grain themes + providers) |
| **M9** | Gameplay quality + UX polish | [M9-gameplay-quality-and-polish.md](M9-gameplay-quality-and-polish.md) | ✅ shipped (raw-PPR scoring, unified `nfl_fantasy`, description field) |
| **M10** | Era analysis + community/daily template unification | [M10-era-analysis-and-template-unification.md](M10-era-analysis-and-template-unification.md) | ✅ shipped: theme templates + era index + per-position columns + scoring-kind indicator (PPR/era/custom badges) all landed and tested 2026-07-02 |
| **M11** | Production hardening + automation close-out | [M11-production-hardening.md](M11-production-hardening.md) | ✅ shipped: per-format completion fixed, edge functions schedulable (`supabase/migrations/0001_...sql`, unapplied — hand-off), real APNs JWT signing, content-drift guard added (currently red on purpose — real drift found) |
| **M12** | Trust & safety — community moderation | [M12-trust-and-safety.md](M12-trust-and-safety.md) | ✅ shipped 2026-07-02: auto-hide trigger at 3 distinct reporters + `is_admin` review RLS (schema.sql M12 section, **unapplied — hand-off**) + in-app `ModerationQueueView` (restore/hide/remove) gated by `profiles.is_admin` |
| **M13** | Discovery & growth loop | [M13-discovery-and-growth.md](M13-discovery-and-growth.md) | ✅ shipped 2026-07-02: client-side text search (Browse themes+players, Community titles), pre-play share sheet with ScoringKind-badged preview card + daily deep-link fallback, This-Week trending sort (`weekly_play_counts` RPC in schema.sql, **unapplied — hand-off**; graceful fallback until applied) |
| **M14** | Accessibility & localization | [M14-accessibility-and-localization.md](M14-accessibility-and-localization.md) | 🟧 VoiceOver pass shipped (Keep4CardView/WhoAmIGameView/DailyGameCard); **Spanish localization untouched**, still a separate larger task |
| **M15** | Analytics & content health | [M15-analytics-and-content-health.md](M15-analytics-and-content-health.md) | ✅ shipped 2026-07-02: `events` table + insert-only RLS (schema.sql M15 section, **unapplied — hand-off**), `AnalyticsClient` + 8-event funnel vocabulary, `content_health.json` per ingest run, [docs/ANALYTICS.md](../docs/ANALYTICS.md) query set |
| **M16** | Headshot coverage — every player gets a real photo | [M16-headshot-coverage.md](M16-headshot-coverage.md) | ✅ shipped 2026-07-03: baseball headshots via MLB's image CDN (live `mlb_stats.py` + seed fallback keyed by `mlb_id`); soccer/tennis via curated Wikimedia Commons URLs added to `soccer_seed.csv`/`tennis_seed.csv`; all 5 sports at 100% coverage in the regenerated bundle, guarded by `test_headshot_coverage.py` (bundle) + `test_new_sports.py`/`test_mlb_stats.py` (provider) |
| **M17** | Puzzle grain (season/single-game/career) + community data parity | [M17-community-career-creation.md](M17-community-career-creation.md) | ✅ shipped 2026-07-04: the grain feature (2026-07-03) plus community career creation — `catalog_rows()` now includes career rows (`career`/`first_year`/`last_year`), `CatalogSeason` decodes them, `Keep4Theme.isCreatable` admits `grain=="career"`, `CreateKeep4View` scopes search to career-only when a career template is active and bakes the real grain at publish. Bundled fallback catalog stays season-only by design (career is live-catalog-only, per the file's own recommended decision). Live hand-off is done too (2026-07-04): `player_seasons` migration applied and `--upsert --catalog` re-run — production now has 21,927 season rows + 3,323 career rows (all headshot-complete), verified end-to-end in the simulator with real career search results |

**Start with [HANDOFF-next-agent-2026-07-04.md](HANDOFF-next-agent-2026-07-04.md)** — current
state, the DB-ops-execute-directly rule, which "unapplied — hand-off" schema.sql sections are now
easy to apply, and what's actually left (M5 monetization, M14 localization). It supersedes
[HANDOFF-fable-milestones.md](HANDOFF-fable-milestones.md), which is now stale (M12/M13/M15 shipped
their app-side work since it was written).

**Suggested sequencing** (not a hard dependency chain — each milestone is independently
scoped and shippable): **M12**'s remaining policy work first or in parallel — smallest,
self-contained, and its report UI is freshly verified working. **M5 monetization**
and **M13 discovery/growth** pair naturally (don't sell Pro into a feed nobody can search).
**M15 analytics** is most valuable *before* M5/M13 ship, so their impact is measurable —
consider pulling it earlier if resourcing allows. **M14**'s remaining localization work can run
in parallel with any of the above; it doesn't block or depend on the others.

See [docs/BALLIQ_SPEC.md §8](../docs/BALLIQ_SPEC.md) for further open-items / hand-offs detail,
and [HANDOFF-fable-milestones.md](HANDOFF-fable-milestones.md) for the up-to-date consolidated
version of this list.

---

## Shared context (current state as of M2)

**App:** Playbook — native SwiftUI iOS sports-trivia game (iOS 17+, Xcode/Swift 5 language mode).
Bundle id `com.balliqfantasy.app`. Hand-written `.xcodeproj` using **synchronized file groups** — new
`.swift` files and bundled resources auto-compile, **no pbxproj edits needed**; we avoid SPM (vendor
MIT source under `ThirdParty/` instead).

**Build/verify (do this constantly):**
- Build: `xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' -derivedDataPath build build`
- Test: same with `test`.
- Run/screenshot: `xcrun simctl install/launch com.balliqfantasy.app` then `xcrun simctl io booted screenshot`.
- Debug UI without taps: launch args `-screenshotGame` / `-screenshotResult` / `-screenshotWhoAmI[Result]` ([DebugLaunch.swift](../BallIQ/DebugLaunch.swift)).

**Architecture:**
- **Repository seam:** views read an `@MainActor RepositoryContainer` ([RepositoryContainer.swift](../BallIQ/RepositoryContainer.swift)) built via `RepositoryContainer.make(client:)`. It exposes `puzzles: PuzzleRepository` and publishes progression/rating; `complete(...)` records a finished game (XP/streak/rating) and pushes to the server.
- **Data protocols (async):** `PuzzleRepository`, `ProgressRepository`, `RatingRepository` in `BallIQ/Data/Repositories/` with `Local*` (UserDefaults/bundled JSON) and `Remote*`/sync impls. Pure rating math in [RatingEngine](../BallIQ/Models/Progression.swift); levels in `LevelCurve`.
- **Backend (M2):** `BallIQ/Backend/` — `SupabaseClient` (REST over URLSession, PostgREST + GoTrue, no SDK), `SupabaseConfig` (loads gitignored `Supabase.plist`), `AuthService` (Sign in with Apple), `RemoteSync` (local-first; pull on sign-in, push after games). Schema in [supabase/schema.sql](../supabase/schema.sql): `profiles, ratings, rating_history, progress, puzzles` with RLS. `puzzles.content` is jsonb in the same camelCase shape as the Codable models.
- **Formats today:** blind **Keep4/Cut4** (one card at a time, forced 4/4 tail, deterministic seeded order, Normal/Hard modes) + **Who Am I?** (6 progressive clues). Models: `Keep4Puzzle`, `WhoAmIPuzzle`, `PlayerSeason` (has a hidden `grade: Double` that defines the "true" ranking, plus a `ScoringKind` — PPR/era-adjusted/custom — that tells the player how that grade was produced).
- **Six tabs, all live (not stubs):** Home, Leagues (`CohortRepository`, weekly XP standings + promote/relegate), Versus (`VersusRepository`, 1v1 challenge series), Community (UGC feed + creation), Profile (ratings/tiers/Stats/auth/notifications). Browse (full unranked archive) hangs off Home. Push notifications (`PushNotificationManager` + `supabase/functions/`) exist but the edge-function cron jobs aren't scheduled yet and APNs delivery is stubbed — see spec §2/§8.
- **Design system "Prime Time":** bright-pop, heavy condensed type (Anton + Saira, OFL, runtime-registered), one dominant (electric blue) + sharp accent (volt), bold depth (`blockCard`/`cardSurface`), juice (`heroReveal`, confetti via vendored ConfettiSwiftUI). Rules in [DESIGN.md](../BallIQ/DesignSystem/DESIGN.md). New UI must use these tokens.

**Hard constraints for every milestone:**
- Keep all existing tests green; add tests for new pure logic.
- Don't break the repository seam — new data sources implement the existing async protocols.
- Match the Prime Time design system for any new UI.
- Secrets: only the public Supabase anon/publishable key ships (in gitignored `Supabase.plist`); never the `service_role` key. Provider API keys for data ingestion live **server-side**, never in the app.
- The agent cannot provision third-party accounts or enter the user's credentials — surface those as explicit hand-offs.
