# Playbook — Product & Technical Spec (single source of truth)

**Status date: 2026-07-06.** This document supersedes the status columns in
[prompts/README.md](../prompts/README.md); the prompt files remain as historical milestone
briefs. Update THIS file when behavior, contracts, or status change. For a narrative account of
what changed most recently (DB hand-offs, TestFlight, App Store submission), see
[prompts/HANDOFF-next-agent-2026-07-05.md](../prompts/HANDOFF-next-agent-2026-07-05.md).

---

## 1. Product

**Playbook** is a native SwiftUI iOS sports-trivia game (iOS 17+, bundle id
`com.balliqfantasy.app`): "prove you know ball" by ranking real player-seasons.

**Shipped formats**
- **Keep4/Cut4 ("K4C4")** — 8 real player-season cards served one at a time in a
  deterministic blind order; the player keeps 4 and cuts 4; the hidden per-card `grade`
  (raw fantasy points) defines the true top-4. Normal and Hard (stats hidden) modes.
- **Who Am I?** — progressive-clue mystery player (6 ordered clues: era, position, teams,
  stat line, fact, jersey); earlier solves score more, wrong guesses cost 100.

**Surfaces (6 tabs, all live — none are stubs):** Home (daily games, streak, sport filter,
rank), Leagues (weekly XP cohorts via `CohortRepository`/`Cohort.swift` — standings,
promote/relegate, season countdown), Versus (1v1 challenges via `VersusRepository`/
`VersusChallenge.swift` — series score, 24h expiry, push-notified), Community (UGC feed +
creation, `CommunityPuzzleRepository`), Profile (tiers, per-sport ratings, Stats push-in,
Sign in with Apple/Google, `NotificationSettings`). Browse (full unranked archive) hangs off
Home, not a tab.

**Progression:** per-sport Elo-ish rating (`RatingEngine`, ranked daily games only) with
tiers (Bronze→…), XP/levels (`LevelCurve`), day streak. Community/archive/versus play is
unranked (XP only).

## 2. Architecture

- **App:** SwiftUI, hand-written `.xcodeproj` with **synchronized file groups** (new files
  and bundled resources auto-compile — never edit pbxproj). No SPM; MIT deps vendored under
  `BallIQ/ThirdParty/` (ConfettiSwiftUI).
- **Repository seam:** views depend on `@MainActor RepositoryContainer`
  ([RepositoryContainer.swift](../BallIQ/RepositoryContainer.swift)) exposing async protocol
  repos (`PuzzleRepository`, `ProgressRepository`, `RatingRepository`, community/versus/cohort
  repos). `Local*` impls read UserDefaults + bundled JSON; `Remote*`/sync impls layer Supabase.
  `complete(...)` records a finished game (XP/streak/rating) and pushes to the server.
- **Backend:** `BallIQ/Backend/` — hand-rolled `SupabaseClient` (PostgREST + GoTrue over
  URLSession, no SDK), `SupabaseConfig` (gitignored `Supabase.plist`, anon key only),
  `AuthService` (Sign in with Apple + Google via OAuth browser session), `RemoteSync`
  (local-first: pull on sign-in, push after games), `PushNotificationManager` (APNs device
  token registration → `profiles.push_token`).
  Schema: [supabase/schema.sql](../supabase/schema.sql) — `profiles, ratings, rating_history,
  progress, puzzles, player_seasons, community_puzzles (+plays/reports), versus_challenges,
  cohorts/seasons` with RLS. `puzzles.content` is jsonb in the exact camelCase shape the
  Swift Codable models decode.
- **Edge functions** ([supabase/functions/](../supabase/functions/), Deno): server-side jobs
  the client can't do itself — `weekly-cohort-rollover` (closes/opens Leagues seasons),
  `versus-timeout` (forfeits expired 24h challenges via `resolve_versus_challenge` RPC),
  `notify-streak-risk`, `notify-season-end`, `notify-versus-challenge` (push copy, call
  `_shared/apns.ts`). **Deployed and scheduled as of 2026-07-05**: all five are live on
  Supabase; the four cron-driven ones (`weekly-cohort-rollover` Mondays 05:00 UTC,
  `versus-timeout` every 15 min, `notify-streak-risk` hourly, `notify-season-end` 3x/day) show
  `active: true` in `cron.job`. `notify-versus-challenge` is deployed but its DB webhook trigger
  (Database → Webhooks on `versus_challenges` INSERT) still needs manual setup in the Supabase
  dashboard — no API path found for that. `apns.ts`'s `sendApnsPush` is still stubbed pending a
  real APNs key (`APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_PRIVATE_KEY`/`APNS_BUNDLE_ID` as Edge
  Function secrets) — until then it logs instead of sending. No Leagues season/cohort exists
  yet either — `weekly-cohort-rollover` bootstraps one on first run, which hasn't happened; it
  fires naturally next Monday, or needs an explicit user go-ahead to trigger sooner (it
  mutates real rating-based cohort assignments for every rated user, not a no-op).
- **Design system "Prime Time"** ([DESIGN.md](../BallIQ/DesignSystem/DESIGN.md)): arcade-pop ×
  sports-broadcast. Anton + Saira (OFL, runtime-registered), electric-blue dominant + volt
  accent, ink outlines + hard ledge shadows (`cardSurface`/`blockCard`), one orchestrated
  `heroReveal` per screen, confetti celebrations, Reduce Motion respected everywhere.
  Shared controls in [Components.swift](../BallIQ/DesignSystem/Components.swift):
  `PrimeSegmentedControl`, `EmptyStateView`, `PrimePressStyle`, `.ctaLabel()`.

## 3. Data pipeline (`tools/ingest/`, Python 3.11+, stdlib-only at runtime)

```
python3 -m tools.ingest.main [--dry-run] [--write-fallback] [--write-themes]
                              [--upsert] [--catalog]
                              [--backfill N] [--nfl-years Y...] [--game-years Y...]
```

- **Providers** (`providers/`, shared 24h on-disk cache in `.cache/`, MLB careers cached a
  week — see `mlb_stats.py`):
  `nfl_nflverse` (season aggregates, 1999–present, year range **computed from today's date**
  in `main.py` so it never goes stale — `fetch_years` skips any year not yet published) +
  `nfl_nflverse_games` (weekly grain, bounded by `--game-years`, same dynamic-year
  treatment) + `nfl_players` (bio join: draft round, height, age); `espn_nba_pool`/`espn_nba`
  (853-player keyless ESPN pool, ~1993–2026, the **primary** NBA source since M7) with
  `nba_balldontlie` (needs `BALLDONTLIE_API_KEY`) and a curated `seed.py`/`data/nba_seed.csv`
  as fallbacks when ESPN is unreachable; `mlb_stats` (keyless MLB Stats API, primary baseball
  source) driven by `mlb_pool` (2026-07-06: swept 1975–present stat-leaders across 19
  hitting/pitching categories → **3,298-player id pool**, ≥3 top-50 category-seasons each,
  up from 23 hardcoded ids — live `player_seasons` baseball rows went 280 → 38,704) with
  `seed.py`/`data/baseball_seed.csv` as fallback. Both pools are refreshed weekly by
  [.github/workflows/discover-players.yml](../.github/workflows/discover-players.yml)
  (Sundays 10:00 UTC), which commits the updated id-map JSON then upserts immediately so a
  newly-discovered player doesn't wait for the next daily `ingest.yml` run. **Soccer and
  tennis are seed-only** (`data/soccer_seed.csv`/`data/tennis_seed.csv`, curated from
  well-documented record seasons, 17/19 live rows respectively) — no reachable keyless
  historical source found (Jeff Sackmann's ATP dataset 404s from this environment); see
  `tools/ingest/README.md` for what was tried.
- **Themes** (`themes.py` `KEEP4_THEMES`): the ONE template shape — sport, grade `scale`,
  positions, `min_stats` floors, on-card `columns` (stat/label/fmt), `pool_cap`, `grain`
  (season|game), `era_adjusted`. 24 curated themes today (18 NFL/NBA + 2 each for baseball,
  soccer, tennis, added 2026-07-03). `columns[].fmt` now also includes `dec3`/`dec2`
  (3/2-decimal rate stats like baseball AVG/OPS/ERA — `pct1`/`dec1` alone read wrong for
  those), mirrored in `Keep4Theme.format` and `ScoringStat.Fmt` on the Swift side.
- **Niche-theme generator** (`generate.py` + `curation.py`): auto-generates additional
  bio/era-quirk themes per position (undrafted, day-3 steals, first-round, sub-6-foot,
  towering, age-33+, under-24 — see `curation.QUIRKS`) crossed with decades, keeping only
  themes with a viable pool (`_is_viable`). All generated themes grade on the same fantasy
  scales as the curated ones (§4) — none are custom/vibes-based.
- **Assembly** (`assemble.py`): filter → grade → dedupe by person → top `pool_cap` →
  contiguous 8-season windows clustered in grade with a clean keep/cut boundary → rows in
  the app's camelCase shape. Cross-position NFL themes slice card columns per position
  (`columns_for`) so a WR card never reads "Pass Yds 0".
- **Baselines** (`baselines.py`): per-(sport, position, year) stat distributions over
  qualified seasons, incl. the `fantasy_total` pseudo-stat era-adjustment depends on (§4).
  `era_analysis.py` is a standalone validation script (not part of the pipeline run) that
  produced the era-index sanity checks in §4.
- **Artifacts baked into the app bundle** (regenerated by `--write-fallback`):
  `keep4_puzzles.json`, `whoami_puzzles.json` (offline daily fallback),
  `player_seasons.json` (creation catalog fallback), `stat_baselines.json` (era baselines),
  `keep4_themes.json` (theme templates — see §5).
- **CI:** [.github/workflows/ingest.yml](../.github/workflows/ingest.yml) — `pytest` on every
  push touching `tools/ingest/**`; on a daily 09:00 UTC cron (or manual
  `workflow_dispatch`), also runs `--backfill 30 --upsert` against the live Supabase project
  (secrets: `BALLDONTLIE_API_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`). The
  scheduled run does **not** pass `--catalog` or `--write-fallback` — those stay manual.

## 4. Scoring & grading — the sacred invariants

**The grade IS raw fantasy points.** No 0–100 min-max display normalization (that legacy
path survives only as opt-in `ScoringRule.displayScale`). Cards show the number with a
"PTS" unit ("SCORE" for custom 0–100 rules).

**Scoring-kind indicator (`ScoringKind`, `Models/ScoringKind.swift`):** every K4C4 surface
tells the player how the hidden ranking was produced — `ppr` (objective fantasy totals,
bolt/accent-blue), `era` (era-adjusted totals, clock/pro-purple), `custom` (author's own
weighted rule, quote-bubble/warm-orange). Puzzle cards (`DailyGameCard`) carry the badge;
the `Keep4GameView` header shows a tinted explainer chip before the first card. Resolution
(`Keep4Puzzle.scoringKind(themes:)`): a baked `content.scoring` value (written at community
publish via `ScoringKind(rule:)`) wins; otherwise the theme title is matched against the
bundled export for `eraAdjusted`; everything else — all other daily themes, generated niche
themes, and legacy community rows — is `ppr`. The community feed reads the badge cheaply via
`scoring:content->>scoring` and shows warm-styled cards + author username (world-readable
`profiles`, same pattern as Versus); the share deep link resolves the author too
(`CommunityPuzzleRepository.load` → `Loaded.keep4(_, author:)`). Locked by
`ScoringKindTests`; visual variants rendered by `ScoringGalleryTests` (writes
`scoring_gallery.png` to the app tmp dir).

**Scoring-formula explainer (2026-07-07):** the pre-game chip is now a button opening
`ScoringDetailSheet` (`Features/Keep4/ScoringDetailSheet.swift`) — the actual point table
(`ScoringBreakdown` reads `ScoringRule.presets`, never re-hardcoded copy), an era-index card
for `.era`, a warm "no formula" panel for vibes, and an honest provenance footnote per scale
(full-PPR = real industry standard; NBA = "DraftKings-style, simplified"; soccer =
"FPL-inspired"; tennis + era index = BallIQ's own). Formula resolution: baked `content.scale`
(now written by `assemble.py` AND at community publish — backfilled across live `puzzles`
2026-07-07) → theme-title match → sport-default formulas with a hedged footnote (legacy
community NFL rows may be Half-PPR/Standard). Locked by `ScoringBreakdownTests` (including
"every bundled theme scale resolves"); screenshot flag `-screenshotScoringInfo`. Fixing this
surfaced a deep-link bug: `ContentView`'s fullScreenCover closures captured stale sibling
state, so link-opened community puzzles presented with `communityID` nil (plays unlogged,
author uncredited) — presentation context now travels inside the cover item (`LinkedPlay`).

Scales (`grade.py` `_FANTASY`, mirrored byte-for-byte by `GradeFormula.swift` and
`ScoringRule.presets`):
- `nfl_fantasy` (the unified any-position axis): pass yds ×0.04, pass TD ×4, INT ×−2,
  rec ×1, rec yds ×0.1, rec TD ×6, rush yds ×0.1, rush TD ×6.
- `nfl_skill_ppr`, `nfl_qb_fantasy` — subsets for single-position themes; `*_game` variants
  reuse the same coefficients at game grain.
- `nba_fantasy` (per-game, DK-ish): PPG ×1, RPG ×1.2, APG ×1.5, SPG ×3, BPG ×3.

**Parity rule:** any scoring change lands in `grade.py` + `GradeFormula.swift` +
`ScoringRule.swift` together, with locked-value tests in all three
(`test_grade.py` / `GradeFormulaTests` / `ScoringRuleTests` — identical numbers).

**Content immutability:** baked/published puzzles carry their grades in `content`.
Community rows are never re-graded. Daily pipeline rows are pipeline-owned and are
overwritten wholesale by a regeneration+upsert (that is the sanctioned way scoring changes
reach shipped content). Codable model changes must be additive/optional
(`PlayerSeason.headshot` pattern).

### Era-adjusted scoring (M10)

`.eraPoints`: the season's raw fantasy total × a **single per-(sport, position, year)
volume index** — NOT per-stat multipliers:

    index = globalMean(fantasy_total) / eraMean(fantasy_total, year)

where `fantasy_total` is a pseudo-stat emitted by `baselines.py` into
`stat_baselines.json`: the distribution of unified fantasy totals over **qualified**
seasons (games ≥ 10 NFL / ≥ 40 NBA) per (sport, position, year), and globalMean is the
count-weighted mean across years. The qualified population is essential — raw recorder
means are diluted by cameo seasons and by recorder-count growth, which flips the index's
story. Era row missing or `count < 8` (`ScoringRule.minBaselineSamples` ==
`grade.MIN_ERA_SAMPLES`) → 1.0 (raw). Both sides compute this from the same artifact:
Python `grade.era_index`/`grade_era` ≡ Swift `ScoringRule.eraTotalIndex` (locked
cross-language tests share one fixture: index 1.25 / 0.8333…, grades 335.0 / 223.3).

**Baseline hygiene:** `compute_baselines` is season-grain only — game-grain rows (weekly
data) must never enter season distributions. (A pre-M10 bug did exactly that, silently
poisoning 2009+ baselines: a 2015 WR receiving-yards "mean" of 85 over 1,900 "recorders"
that were actually single games. Fixed 2026-07-02.)

**Why a total index, not per-stat** (validated by `tools/ingest/era_analysis.py` over the
full 13,208-season catalog):
- A total index is a monotonic rescale inside each position-year — it can NEVER reorder two
  same-position same-year seasons. Per-stat recorder-mean ratios are noisy for secondary
  stats and re-weight stat mixes unpredictably.
- The NFL indices tell the true volume story: QB index 1.32 (1999) → ~0.85 (2014–23 passing
  boom); WR nearly flat; TE 1.2s in the early 2000s. Sanity set: Rich Gannon 2002 adjusts
  UP (305→318) while Mahomes 2022 adjusts DOWN (411→365); Marvin Harrison 2002 ≈ flat.
- **Known limitation — NBA pre-~2002 is survivorship-biased**: the ESPN pool only carries
  stars for early years, inflating era means, so 90s legends would wrongly adjust *down*
  (Jordan '96 52.9→49.2). Era adjustment therefore ships **NFL-only** as a daily theme
  (`nfl-total-fantasy-era`); the creator toggle exists for both sports but the analysis
  documents the NBA caveat. Fixing it requires a full-league historical NBA source.

Selected index table (fantasy-total, globalMean/eraMean; >1 = scarcer era):

| Year | NFL QB | NFL RB | NFL WR | NFL TE |
|------|--------|--------|--------|--------|
| 1999 | 1.32 | 1.03 | 1.02 | 1.27 |
| 2002 | 1.04 | 0.95 | 1.00 | 1.22 |
| 2006 | 1.24 | 0.92 | 0.98 | 1.04 |
| 2012 | 0.96 | 1.12 | 1.00 | 0.90 |
| 2015 | 0.83 | 1.04 | 1.00 | 0.94 |
| 2020 | 0.86 | 1.03 | 0.96 | 1.02 |
| 2023 | 0.95 | 1.01 | 1.05 | 1.02 |

Raw points remain the default everywhere; era-adjust is an explicit mode (theme flag
pipeline-side, "Era-adjust scoring" toggle in the creation scoring card).

## 5. Community ↔ daily template unification (M10)

One template definition, consumed by both sides:

- `themes.py` exports `KEEP4_THEMES` → **`BallIQ/Data/keep4_themes.json`**
  (`--write-themes`, also part of `--write-fallback`). Camel-case rows: key, title, sport,
  scale, positions, minStats, columns[{stat,label,fmt}], poolCap, grain, eraAdjusted.
- Swift `Keep4Theme` decodes the bundle; `CreateKeep4View` offers season-grain themes as
  **creation starting points**: picking one sets the exact scoring rule
  (`ScoringRule.preset(theme.scale)`), the era flag, the discovery position filters, and —
  critically — the published card's stat columns via `Keep4Theme.cardStats` (a byte-parity
  port of `format_columns`/`_fmt_value`, including per-position slicing). A community
  puzzle built from a theme is indistinguishable in content shape from that theme's dailies.
  Any manual scoring change (preset chip, sport switch, era toggle mismatch) leaves the
  template; free-form creation still derives columns from the first 3 scoring terms.
- **Anti-drift locks:** `test_export_themes.py` asserts the bundled JSON equals
  `export_themes()` (fails if themes.py changes without `--write-themes`);
  `Keep4ThemeTests` mirrors the same locked rows/values from the Swift side.

## 6. Content lifecycle

- **Daily rows:** deterministic ids (`<theme-key>-<variant>`); client picks the day's puzzle
  by index over the pool; `active_date` is archival. Regeneration+upsert overwrites them.
- **Community rows:** author-owned (`community_puzzles`, RLS), grade baked at publish from
  the author's rule, deep link `balliq://play/<id>`, plays logged for Popular sort.
  Unranked. Never re-graded (rows published before raw-PPR keep 0–100 grades forever; the
  scoring-kind fallback (§4) at least labels them "SCORE" instead of a misleading "PTS").
- **Offline:** bundled fallbacks serve when Supabase is unreachable; local-first progress
  always works signed-out.

## 7. Verification playbook

- Swift: `xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination
  'platform=iOS Simulator,name=iPhone 15,OS=17.5' -derivedDataPath build test`
- Python: `python3 -m venv /tmp/balliq-venv && /tmp/balliq-venv/bin/pip install pytest &&
  /tmp/balliq-venv/bin/python -m pytest tools/ingest/tests/ -q`
- Screenshots: `xcrun simctl install/launch booted com.balliqfantasy.app
  [-screenshotGame|-screenshotResult|-screenshotWhoAmI[Result]|-screenshotCreate|
  -screenshotStats|-screenshotLeagues|-screenshotVersus|-screenshotCommunity|
  -screenshotBrowse]` then `xcrun simctl io booted screenshot out.png`
  ([DebugLaunch.swift](../BallIQ/DebugLaunch.swift)). Quit Xcode before driving the
  simulator (its auto-reinstall kills the app mid-session). For view states a single
  screenshot can't reach (e.g. every scoring-kind badge variant), render with
  `ImageRenderer` inside a hosted XCTest instead — see `ScoringGalleryTests`.
- Era analysis (findings in §4): `python3 -m tools.ingest.era_analysis`.

## 8. Milestone status (2026-07-05)

| Milestone | Status |
|-----------|--------|
| M1–M4 core app, backend, social retention | ✅ shipped. M4's backend tables (`seasons`/`cohorts`/`versus_*`/`device_tokens`/`notification_settings`) were missing from production until 2026-07-05 despite the app-side feature being live the whole time — now applied, see below |
| M5 breadth/scoring | ✅ breadth shipped; **monetization (Pro/StoreKit) not started — no code exists yet** |
| M6 community fixes + hardening | ✅ shipped |
| M7 content scale + CI | ✅ shipped |
| M8 single-game grain | ✅ shipped |
| M9 raw-PPR scoring + polish | ✅ shipped |
| M10 era analysis + template unification | ✅ shipped — theme templates, era index, per-position columns, scoring-kind indicator (§4) |
| M11 production hardening | ✅ shipped; edge functions now actually deployed + cron-scheduled (2026-07-05, see §2) |
| M12 trust & safety | ✅ shipped; `is_admin`/review RLS applied live (2026-07-05) |
| M13 discovery & growth | ✅ shipped; `weekly_play_counts` RPC applied live (2026-07-05) |
| M14 accessibility & localization | 🟧 VoiceOver shipped; **Spanish localization untouched** |
| M15 analytics & content health | ✅ shipped; `events` table + RLS applied live (2026-07-05) |
| M16 headshot coverage | ✅ shipped (all 5 sports, 100% coverage) |
| M17 puzzle grain + community career creation | ✅ shipped, including the live catalog migration/backfill |

**Release status (new as of 2026-07-05):** a TestFlight build is live for external testers
(join link in [prompts/HANDOFF-next-agent-2026-07-05.md](../prompts/HANDOFF-next-agent-2026-07-05.md)),
and the app has been submitted for full App Store review. See that handoff and `CLAUDE.md`'s
"App Store Connect / TestFlight" section for the release pipeline mechanics — don't rebuild the
manual-signing workaround from scratch, it's already documented.

**Open items / hand-offs**
1. **M5 monetization (Pro/StoreKit)** is the only fully-unstarted milestone. **M14** Spanish
   localization is the other real gap. Both are pure app-code, independently scoped — see §9.
2. ~~**Per-format daily completion bug**~~ — fixed (shipped in the 2026-07-04 commit): the two
   Home cards now check `hasCompletedToday(_ card:)` backed by a per-day
   `completedCardsToday: Set<DailyCard>`; `hasPlayedToday` remains "played anything" and
   still drives streak/first-play XP. Covered by `ProgressRepositoryTests`.
3. **No Leagues season/cohort exists yet in production** — `weekly-cohort-rollover` bootstraps
   one on first run; it hasn't been triggered (mutates real user rating/cohort state, so it
   needs an explicit go-ahead rather than being treated as a no-op). Fires naturally next
   Monday 05:00 UTC either way.
4. **`notify-versus-challenge`'s DB webhook isn't wired** (Database → Webhooks in the Supabase
   dashboard — no API path found for this step). The function is deployed and correct; nothing
   calls it yet.
5. **Real APNs credentials don't exist yet** — push sends log instead of calling Apple until
   `APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_PRIVATE_KEY`/`APNS_BUNDLE_ID` are generated (Apple
   Developer portal) and set as Edge Function secrets. External hand-off.
6. Two pre-raw-PPR community rows (published before M9) keep their baked 0–100 grades by
   design (content immutability, §4) — cosmetic, optional to fix.

**Shipped 2026-07-06 (data coverage + card-template hardening):**
- Baseball catalog broadened via `mlb_pool` (§3): 280 → 38,704 live rows. NFL/NBA/MLB year
  ranges now computed from today's date instead of hardcoded literals (§3) — was silently
  missing the 2024 NFL season. New weekly `discover-players.yml` keeps the NBA/MLB pools
  growing without manual re-runs.
- Fixed a cross-position stat-column bug: a free-form (Vibes or custom-rule) Keep4 puzzle
  mixing positions in one pool baked the sport's generic top-3 stats onto every card
  regardless of the season's actual position (a QB card reading "Rec Yds 0 / Rec TD 0 / Rec
  0"). `Sport.positionStatFamilies` is now the one shared table both the daily pipeline's
  theme-column slicing (`Keep4Theme.columns(for:)`) and free-form creation
  (`ScoringStat.displayColumns`) draw from — covers NFL QB/RB/WR/TE, baseball H/P, and soccer
  GK/DF/FW/MF. Covered by `ScoringStatTests`.
- Fixed `DailyGameCard`'s header band (the Home/Browse/Community "puzzle brief" row): a long
  badge string (era-adjusted's badge is ~3x PPR's) starved the format-name label of width
  down to a bare "…". Header is now two rows — format name never compresses; badges scroll
  instead of truncating — a template every sport/scoring-kind shares without per-case tuning.
  Also fixed the sport-name badge (Soccer/Tennis) not being forced uppercase like every other
  chip in that row (NFL/NBA/MLB happened to already be all-caps strings, masking the bug).
- Per-sport ESPN team-logo resolution (`Sport.teamLogoURL`) and per-sport fantasy-badge copy
  (tennis reads "POINTS"/résumé copy, not fabricated "fantasy points" language) shipped
  earlier the same day — see git history for detail.

## 9. Roadmap — remaining milestones

Full briefs live in `prompts/` (same self-contained format: goal, why-now, current state,
scope, key decisions, deliverables, verification, hand-offs).

| Milestone | Theme | One-line scope |
|-----------|-------|-----------------|
| **M5** | Monetization + breadth | Pro/StoreKit, format packs, 3 new formats, seasons (spec exists, unstarted) |
| **M14** | Accessibility & localization | VoiceOver shipped; first non-English locale (Spanish) is the remaining piece |

Every other previously-planned milestone (M11–M13, M15–M17) has shipped, app-side and
backend both — see the table in §8. These two are what's actually left to build.
