# BallIQ — Milestone 5 handoff: PPR scoring + "foil" card sparkle

> **✅ SHIPPED (2026-06-29).** Both tasks landed, plus a follow-on 0–100 display normalization. For
> how grading works *now*, read **[scoring-and-grading.md](scoring-and-grading.md)** — that is the
> live reference. This file is kept as the historical handoff that drove the work.

Hand this to a fresh agent. It assumes the repo as of 2026-06-29 (K4C4 visual + composable
creation work shipped; build + 49 Xcode tests green; `tools/ingest` py tests 16/16 green).

## Where things stand (don't re-derive)

- `fantasy-app` is **BallIQ**, a native SwiftUI iOS sports-trivia app (NOT the chess coach in the
  global `~/CLAUDE.md`). Toolchain: Xcode 26.5 / Swift 6.x, `SWIFT_VERSION = 5.0` in the project.
  Hand-written `.xcodeproj` (objectVersion 70) with **synchronized file groups** — new files under
  `BallIQ/` auto-compile, no pbxproj edits (one exception set exists for `Info.plist`).
- Build/test: `xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination 'id=5D066EE7-6D68-4CF5-B95B-FE582A8E0570' -derivedDataPath build test`
  (that UDID is a booted iPhone 15 / iOS 17.5 sim; fall back to any iOS 17+ sim).
- Screenshot non-interactively: `xcrun simctl spawn <sim> defaults write com.balliqfantasy.app hasOnboarded -bool YES`,
  then launch with a DEBUG arg: `-screenshotGame` (K4C4 card), `-screenshotResult` (score page),
  `-screenshotCreate` (creation builder). See `BallIQ/DebugLaunch.swift`.
- Supabase project `nhccgufqwndtoasdbkhc` ("ballknowledge"); a Supabase MCP is connected (use it for
  SQL/logs). `tools/ingest/.env` (gitignored) holds `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
  `BALLDONTLIE_API_KEY`. Pipeline: `python3 -m tools.ingest.main [--dry-run|--write-fallback|--catalog --upsert]`.
- Scoring today: composable `ScoringRule` (`BallIQ/Models/ScoringRule.swift`) with `.fixed(lo,hi)` and
  `.eraAdjusted` normalization; presets mirror the 6 `GradeFormula`/`tools/ingest/grade.py` scales,
  parity-locked by `BallIQTests/GradeFormulaTests.swift` + `ScoringRuleTests.swift`. `ScoringStat.swift`
  is the selectable-stat menu. Era baselines: `tools/ingest/baselines.py` → `BallIQ/Data/stat_baselines.json`
  (per sport:position:stat:year), loaded by `StatBaselines.swift`, exposed as `RepositoryContainer.baselines`.

## Task 1 (primary): switch grading to PPR fantasy points

**Why:** audit confirmed the `nfl_wr` scale (yards 60% + capped receptions/TDs) buries
reception/TD-heavy elite seasons. Evidence (catalog, current grade-rank vs PPR-rank of 40 WR seasons):
Antonio Brown 2018 #39→#26, Michael Thomas 2018 #37→#27, Tyreek Hill 2018 #30→#23. The DeAndre Hopkins
"above all cuts but cut" report was NOT a bug — top-4-by-grade Keep line; he was the top *cut*. PPR is
the fan-legible fix.

**Success criteria:** for a WR pool, the Keep/Cut split matches PPR fantasy ranking; the displayed
"grade" reads as fantasy points (e.g. ~330), which is more intuitive than 0–100; all tests green;
dailies regenerated.

**Approach (recommended):** add a raw-points normalization rather than min-max, so ranking is by true
fantasy points (only rank matters for Keep/Cut; the number shown becomes the points).
1. `ScoringRule.Normalization`: add `case points(perUnit: Double)` — contributes `value * perUnit`
   with no 0–100 clamp; `grade()` sums term contributions (skip the weight-normalize divide for points
   terms, or treat weight as the per-unit coefficient). Keep `.fixed`/`.eraAdjusted` working.
2. Add fantasy presets in `ScoringRule.presets` + a "Fantasy (PPR)" option in the create UI
   (`CreateKeep4View` preset chips):
   - NFL skill (WR/RB/TE): `receptions×1 + receiving_yards×0.1 + receiving_tds×6 + rushing_yards×0.1 + rushing_tds×6`.
   - NFL QB: `passing_yards×0.04 + passing_tds×4 + interceptions×(−2) + rushing_yards×0.1 + rushing_tds×6`.
   - NBA (DraftKings-ish, per-game, no TOV in data): `ppg×1 + rpg×1.2 + apg×1.5 + spg×3 + bpg×3`.
3. Mirror the same formulas in `tools/ingest/grade.py` (new `fantasy_points(stats, scale)` or a
   points-mode in the scales) and switch the daily themes in `tools/ingest/themes.py` to fantasy
   scoring. Update `GradeFormulaTests`/`ScoringRuleTests` + `tools/ingest/tests/test_grade.py` to the
   new expected orderings (the exact-value assertions like Henry 80.6 / Jordan 78.8 will change — set
   new locked values from a dry-run).
4. Regenerate + re-upsert dailies and catalog: `python3 -m tools.ingest.main --catalog --upsert` and
   `--write-fallback`. The card grade chip / score columns already show `Int(grade)`, so they'll show
   points with no UI change (consider a "PTS" label tweak in `Keep4CardView` gradeChip + result chips).
5. Decide: keep `.fixed`/era presets available for custom rules, or make PPR the default. Era-adjust
   still composes (era-normalize the points). Keep grades **baked at publish** for community puzzles.

## Task 2: Balatro-style "foil" sparkle on cards (tiny, fun)

The user wants a holographic/foil shimmer like Balatro's foil/holo cards on the K4C4 cards
(`BallIQ/Features/Keep4/Keep4CardView.swift`) — "doesn't have to be exact." There is **no good drop-in
SPM lib**, and the project deliberately avoids SPM (vendors MIT source under `ThirdParty/` instead — see
ConfettiSwiftUI). Two easy, no-dependency routes:
- **iOS 17 Metal shader (closest to Balatro):** a `.layerEffect`/`.colorEffect` Metal shader in
  `ShaderLibrary` producing an animated angular rainbow sweep masked to the card, driven by `TimelineView`
  (and/or CoreMotion device tilt for the "move it in the light" feel). Reference OSS to learn from:
  search GitHub for "SwiftUI holographic card" / "MeshGradient holographic" / Metal "iridescent" shaders.
- **Zero-shader fallback (works pre-17, dead simple):** an `AngularGradient` (rainbow) overlay clipped
  to the card with `.blendMode(.overlay)` + low opacity, its `angle`/offset driven by `CoreMotion`
  `CMMotionManager` roll/pitch. Gate behind Reduce Motion.
Apply tastefully — maybe only to the highest-graded card on the result reveal, or as a "rare/foil"
treatment, so it stays a sparkle, not noise. Respects the "Prime Time" system (`DESIGN.md`): one
orchestrated motion moment, gate on Reduce Motion.

## Task 3: backlog (smaller, pick up as capacity allows)

- **balldontlie throttle:** key is valid but the free tier returns HTTP 429; `tools/ingest/providers/nba_balldontlie.py`
  fires with no backoff. Add request rate-limiting (sleep/retry). NBA era baselines also need a broad
  per-season player pull (pipeline currently only fetches the curated seed targets), so NBA era-adjust
  is meaningful only after a wider fetch.
- **Per-card era sparkline:** tiny bar showing where a season sits in its position-year distribution
  (visualizes the era-adjust data already in `stat_baselines.json`).
- **Refresh `ShareCardView`** to match the new team-color card look.

## Guardrails
- Keep Swift↔Python grade parity (tests in both). Community `content` jsonb stays camelCase (plain
  JSONEncoder, not the snake-casing `.supabase` one). Don't ship `service_role` in the app.
- Verify visually with the screenshot flow above before claiming done; run both test suites.
