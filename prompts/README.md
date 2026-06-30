# BallIQ — Milestone prompts (M3–M5)

Self-contained prompts to drive the next three milestones. Each file can be handed to a fresh
agent: it carries enough context to execute without prior conversation. Written in the Fable-5
spirit — **state the goal and success criteria; don't over-prescribe the steps.**

| Milestone | Theme | File | Status (2026-06-29) |
|-----------|-------|------|---------------------|
| **M3** | Real sports data pipeline (no more hardcoded content) | [M3-real-sports-data.md](M3-real-sports-data.md) | ✅ shipped |
| **M4** | Social retention — Leagues, Versus, Stats, Push | [M4-social-retention.md](M4-social-retention.md) | ⬜ pending (Leagues/Stats are placeholder tabs) |
| **M5** | Monetization + breadth — Pro/StoreKit, packs, formats | [M5-monetization-breadth.md](M5-monetization-breadth.md) | 🟧 breadth/scoring shipped; **monetization pending** |
| **M6** | Community fixes + backend hardening | [M6-community-fixes-hardening.md](M6-community-fixes-hardening.md) | 🟧 Task 1 + Phase A done (feed fix, daily determinism, grades 0–100, ESPN-keyless NBA, git init) |
| **M7** | Content scale + automation (CI, broad pulls, bounds) | [M7-content-scale-and-automation.md](M7-content-scale-and-automation.md) | ⬜ pending |
| **M8** | Single-game grading (net-new data model) | [M8-single-game-grading.md](M8-single-game-grading.md) | ⬜ pending |
| **M9** | Gameplay quality + UX polish | [M9-gameplay-quality-and-polish.md](M9-gameplay-quality-and-polish.md) | ⬜ pending |

Browse/Archive (expose the full daily pool) + the Profile build-out are being done inline this
session, so they have no prompt file. Recommended next order: **M7 (let the engine run) → M4/M9
(retention + polish) → M5 monetization → M8**.

---

## Shared context (current state as of M2)

**App:** BallIQ — native SwiftUI iOS sports-trivia game (iOS 17+, Xcode/Swift 5 language mode).
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
- **Formats today:** blind **Keep4/Cut4** (one card at a time, forced 4/4 tail, deterministic seeded order) + **Who Am I?** (progressive clues). Models: `Keep4Puzzle`, `WhoAmIPuzzle`, `PlayerSeason` (has a hidden `grade: Double` that defines the "true" ranking).
- **Design system "Prime Time":** bright-pop, heavy condensed type (Anton + Saira, OFL, runtime-registered), one dominant (electric blue) + sharp accent (volt), bold depth (`blockCard`/`cardSurface`), juice (`heroReveal`, confetti via vendored ConfettiSwiftUI). Rules in [DESIGN.md](../BallIQ/DesignSystem/DESIGN.md). New UI must use these tokens.

**Hard constraints for every milestone:**
- Keep all existing tests green; add tests for new pure logic.
- Don't break the repository seam — new data sources implement the existing async protocols.
- Match the Prime Time design system for any new UI.
- Secrets: only the public Supabase anon/publishable key ships (in gitignored `Supabase.plist`); never the `service_role` key. Provider API keys for data ingestion live **server-side**, never in the app.
- The agent cannot provision third-party accounts or enter the user's credentials — surface those as explicit hand-offs.
