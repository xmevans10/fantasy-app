# Playbook — Product & Technical Spec (single source of truth)

**Status date: 2026-07-12.** This document supersedes the status columns in
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

**Competitive glossary (source of truth for all UI copy on these surfaces — established
2026-07-13; "challenge" belongs exclusively to Versus):**
- **Leagues** — your weekly XP race. Every Monday 05:00 UTC the rollover places every
  rated player into a league (cohort) of up to 30. Every game finished that week — any
  format, ranked or not — earns League XP (`bump_weekly_xp`). Week ends: top `min(5, n/2)`
  move up, bottom `min(5, n/2)` move down, rest hold. No create/join/invite — placement is
  automatic; mid-week play does NOT place you (the RPC is a no-op without membership).
- **Versus (Challenges)** — a 1v1 duel. Challenge any player by username; both
  independently play the *same* daily Keep4 puzzle (pinned `puzzle_id`); higher score wins
  the day, ties go to the challenger. 24h to play or forfeit. Wins accumulate into a
  best-of-7 `versus_series` per (pair, sport).
- **Daily Draft** — Draft & Spin's daily competitive mode (renamed from "Today's
  Challenge" 2026-07-13). One sport per day, everyone gets the same starting spins, no
  rerolls; first completed run of the UTC day is the official score (local
  `DailyDraftStore` + server `daily_draft_scores`, both first-write-wins), replays are
  XP-only. Honest caveat: spins start identical, but pick divergence steers later rosters.

**Competitive education layer (shipped 2026-07-13):** each surface explains itself via a
shared `HowItWorksSheet` (`DesignSystem/HowItWorksSheet.swift`, generalized from
`ScoringDetailSheet`'s visual grammar) — `info.circle` on Leagues/Versus (auto-presents
once per feature via `shouldAutoPresent`), a "How it works" link on Daily Draft setup.
Zone math/legend/copy share one source (`LeagueRules` in `Cohort.swift` — cutoffs,
zone-per-rank, legend strings, `nextRollover`), so a 9-player cohort honestly reads
"Top 4". Coherence fixes landed with it: Versus rows show the live best-of-7 series
(batched `versus_series` fetch), forfeit lines say who didn't play + open rows show
hours-left, the Versus tab badges unplayed incoming challenges (foreground-refresh
stopgap until APNs), Friends-tab challenge failures surface inline, the Leagues recap
banner finally uses `prior_zone`, and the unplaced empty state counts down to the real
Monday 05:00 UTC rollover instead of claiming mid-week play gets you in. Screenshot
flags: `-screenshotLeaguesInfo`/`-screenshotVersusInfo`/`-screenshotDailyDraftInfo`
(combine with their tab flags), `-forcePriorZone promoted|relegated`,
`-forceLeagueCountdown`.

**Product feedback themes (distilled 2026-07-09 from the user's corrections across the
M5/M18 sessions — treat as standing direction, apply proactively to new work):**
1. **Best-surface parity.** K4C4's card is the quality bar ("our best feature"); every
   format's player display must match it — real headshot, team badge, and the player's
   FULL position-relevant stat line. Enforced by shared components, never per-format
   copies: `PlayerMediaBadges`, `PositionStatGrid`, `GameSetupScreen`.
2. **Per-game configuration, no global filters.** Every format opens with its own setup
   screen (sport + format options); the last choice persists as the app default.
3. **Casino-grade juice for arcade moments** — big type, marquee/glow/confetti/haptics,
   and no dead space on hero screens — always inside Prime Time tokens, never off-brand.
4. **Real randomness for arcade formats; determinism only for shared dailies.** RNG is
   injected so tests stay seeded.
5. **Outcomes must reward playing well.** Luck can flavor a result; it can never make
   skill mathematically irrelevant (the Draft & Spin scoring-audit lesson).
6. **Data maximalism with honesty.** Thin coverage gets fixed with real sources, wider
   sweeps and git crons — never by fabricating data, shipping photo-less players (M16),
   or quietly shrinking the game; hard ceilings get documented plainly.
7. **Position-scoped stat correctness.** A surface may only ever show a player's own
   position's stat family (`Sport.sliceForPosition` — the recurring bug class).

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
  treatment) + `nfl_players` (bio join: draft round, height, age); NBA is
  `espn_nba_pool`/`espn_nba` (853-player keyless ESPN star pool, ~1993–2026, primary since
  M7) **unioned with `hoopr_nba` (M18, 2026-07-09): a committed full-league sweep
  (`data/nba_hoopr_seasons.csv`, ~12,400 rows) of sportsdataverse hoopR's parquet
  republication of ESPN's own player-season averages — every player who appeared in a
  season (~530/season), 2002–present**, deduped by `player_id` with the live ESPN row
  winning (fresher mid-season); `nba_balldontlie` (needs `BALLDONTLIE_API_KEY`) and a
  curated `seed.py`/`data/nba_seed.csv` remain fallbacks when ESPN is unreachable;
  `mlb_stats` (keyless MLB Stats API, primary baseball source) driven by `mlb_pool`
  (2026-07-06: swept 1975–present stat-leaders across 19 hitting/pitching categories →
  3,298-player id pool, ≥3 top-50 category-seasons each, up from 23 hardcoded ids — live
  `player_seasons` baseball rows went 280 → 38,704; **M18 widened the sweep to
  1955–present → 4,362 ids**, filling the previously thin pre-1976 team-years) with
  `seed.py`/`data/baseball_seed.csv` as fallback. The id pools *and* the hoopR sweep CSV
  are refreshed weekly by
  [.github/workflows/discover-players.yml](../.github/workflows/discover-players.yml)
  (Sundays 10:00 UTC; pyespn + pyarrow live only there, never in the daily stdlib path),
  which commits the updated data files then upserts immediately so a newly-discovered
  player doesn't wait for the next daily `ingest.yml` run. **Soccer and tennis have a hard
  data-availability ceiling — verified three times (2026-07-08 twice, re-affirmed M18
  2026-07-09), do not re-investigate without a genuinely new candidate source:** soccer's
  only live provider (`api_football.py`, budget-limited leaderboard sweep) serves the top
  ~20 scorers/assists per league-season — never a full squad — and has no clean-sheets
  field, so GK/DF stay permanently hand-curated (`data/soccer_seed.csv`; FBref has the
  stat but no API and scraping-hostile ToS, football-data.org has no player-season stats,
  Understat is xG-only). Tennis is permanently seed-only (`data/tennis_seed.csv`) — Jeff
  Sackmann's `tennis_atp` repo (the canonical free bulk source) is gone and a live GitHub
  search found no maintained mirror. Consequence: "every team roster for all years" is
  achievable for NFL/NBA/MLB but **not** for soccer/tennis without a paid/different
  source; Draft & Spin's soccer formation and tennis 3-round shape are sized to this
  ceiling by design (see §8 M5 Phase D notes).
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
- `nba_fantasy` (season totals at DK-ish rates, 2026-07-07 — was per-game before): points ×1,
  rebounds ×1.2, assists ×1.5, steals ×3, blocks ×3, over TOTALS derived at ingest
  (`main.derive_nba_totals`: per-game average × games, baked into every NBA row's stats
  alongside the averages, career rows sum season totals). NBA now ranks by season-long
  production like every other sport; typical elite magnitude ~5,000, and the reveal shows
  grades at full 1-decimal precision with grouping (`PlayerSeason.gradeText`, all sports).

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

## 8. Milestone status (updated 2026-07-16)

| Milestone | Status |
|-----------|--------|
| M1–M4 core app, backend, social retention | ✅ shipped. M4's backend tables (`seasons`/`cohorts`/`versus_*`/`device_tokens`/`notification_settings`) were missing from production until 2026-07-05 despite the app-side feature being live the whole time — now applied, see below |
| M5 breadth/scoring | ✅ breadth shipped; monetization in progress — StoreKit 2 foundation + gating, server-validated entitlements (2026-07-07), and Over/Under + Draft & Spin + The Grid (2026-07-08) all shipped (see below); only the 8-week rating-season structure (Phase F) still open |
| M6 community fixes + hardening | ✅ shipped |
| M7 content scale + CI | ✅ shipped |
| M8 single-game grain | ✅ shipped |
| M9 raw-PPR scoring + polish | ✅ shipped |
| M10 era analysis + template unification | ✅ shipped — theme templates, era index, per-position columns, scoring-kind indicator (§4) |
| M11 production hardening | ✅ shipped; edge functions now actually deployed + cron-scheduled (2026-07-05, see §2) |
| M12 trust & safety | ✅ shipped; `is_admin`/review RLS applied live (2026-07-05) |
| M13 discovery & growth | ✅ shipped; `weekly_play_counts` RPC applied live (2026-07-05) |
| M14 accessibility & localization | ✅ shipped 2026-07-14/15 — VoiceOver + Dynamic Type, plus Spanish (`Localizable.xcstrings`, 429/435 translated; native-speaker review of the machine translation still a hand-off) |
| M15 analytics & content health | ✅ shipped; `events` table + RLS applied live (2026-07-05) |
| M16 headshot coverage | ✅ shipped (all 5 sports, 100% coverage) |
| M17 puzzle grain + community career creation | ✅ shipped, including the live catalog migration/backfill |
| M19 social layer (friends graph + public profiles) | ✅ shipped 2026-07-12; server side live-verified 16/16 (RLS negatives included); signed-in UI pass still needs two TestFlight accounts |
| M20 social follow-through | ✅ shipped 2026-07-12 — FRIENDS leaderboard scope on Leagues (`friend_profiles` RPC), onboarding username claim, friend-request push (deployed + chain verified), pg_net DB triggers for both notify webhooks |

**Release status (updated 2026-07-16):** **the app is LIVE on the App Store.** v1.0's
2026-07-05 review submission was approved (`READY_FOR_SALE`, confirmed via the ASC API
2026-07-16 — ASC name "Playbook: Sports Trivia", app record `6785275045`). **v1.1 (build 9,
cut from `main` @ `bbe5910`) was submitted for review 2026-07-16 20:15 UTC** and is
`WAITING_FOR_REVIEW`, release type `AFTER_APPROVAL` (goes live automatically on approval).
1.1 carries everything shipped since v1.0's late-June cut: Over/Under, Draft & Spin, The
Grid, Daily Draft + all weekly arcade leaderboards, the daily loop, friends/public profiles/
FRIENDS league scope, profile photo upload, team colors/historical franchises, single-game
grain content + creation, the big catalog expansion, Spanish, cold-launch disk cache, and
the 2026-07-16 audit fixes. TestFlight external-tester build link:
[prompts/HANDOFF-next-agent-2026-07-05.md](../prompts/HANDOFF-next-agent-2026-07-05.md).
Pipeline mechanics live in the `testflight-release` skill (now including the proven
end-to-end 1.1 submission flow and the persistent `tools/release/asc.py` REST helper).

**Open items / hand-offs**
1. ~~M5 monetization fully unstarted / M14 Spanish~~ — stale: M5 Phases A–E and M14 Spanish
   both shipped (see the table above). What remains of M5 is (a) the **user-side ASC setup**
   (Paid Applications agreement + creating the IAP products — hand-off 7 below) and (b) the
   **deferred Phase F rating seasons** (user scoping conversation first; see §9).
2. ~~**Per-format daily completion bug**~~ — fixed (shipped in the 2026-07-04 commit): the two
   Home cards now check `hasCompletedToday(_ card:)` backed by a per-day
   `completedCardsToday: Set<DailyCard>`; `hasPlayedToday` remains "played anything" and
   still drives streak/first-play XP. Covered by `ProgressRepositoryTests`.
3. ~~**No Leagues season/cohort exists yet in production**~~ — resolved: `weekly-cohort-rollover`
   fired on schedule Monday 2026-07-06 05:00 UTC and bootstrapped season 1 (active through
   2026-07-13 05:00 UTC, 1 cohort, 1 member — verified live via MCP 2026-07-07). No further
   action needed; it will keep rolling over weekly on its own.
4. ~~**`notify-versus-challenge`'s DB webhook isn't wired**~~ — resolved 2026-07-12: no
   dashboard step needed after all; a `pg_net` AFTER INSERT trigger
   (`versus_challenges_notify`, see schema.sql M20 section) now POSTs to the function
   directly. Same pattern wired for `notify-friend-request` (`friends_notify_request`) and
   verified live end-to-end (insert → trigger → function → `{"sent":1}`).
5. **Real APNs credentials don't exist yet** — push sends log instead of calling Apple until
   `APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_PRIVATE_KEY`/`APNS_BUNDLE_ID` are generated (Apple
   Developer portal) and set as Edge Function secrets. External hand-off.
6. Two pre-raw-PPR community rows (published before M9) keep their baked 0–100 grades by
   design (content immutability, §4) — cosmetic, optional to fix.
7. **M5 Phase B (`app-store-notifications`) is deployed but inert** — needs, all external
   hand-offs: the Paid Applications agreement (App Store Connect → Business), the Pro/pack
   products actually created in ASC, the production notifications URL pointed at this
   function, and `APPLE_ROOT_CA_PEM` (Apple's Root CA — G3, publicly published on Apple's PKI
   page) set as an Edge Function secret. Until then it 500s "not configured" by design rather
   than silently no-op-ing — verified live 2026-07-07.

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

**Shipped 2026-07-07 (M5 Phase A — StoreKit 2 foundation + gating):**
- `BallIQ/Store/`: `StoreProduct` (product ID catalog: `pro.monthly`/`pro.yearly`/
  `pack.draftspin`/`pack.grid`), `Entitlements` (pure derivation, locked by
  `EntitlementsTests`), `StoreService` (StoreKit 2 — products, purchase, restore,
  `Transaction.currentEntitlements`/`.updates` listener). `Products.storekit` attached to the
  scheme's Launch Action for Xcode-run simulator testing (see M5 hand-off note below re: CLI
  `simctl launch` limitations).
- `RepositoryContainer` mirrors `store.entitlements` into its own `@Published entitlements` —
  views read the container, never `StoreService` directly (repository-seam constraint).
- Existing live surfaces gated: Keep4 hard mode (`Keep4GameView`'s mode picker shows
  "Hard · Pro" and opens `PaywallView` instead of switching when locked), Browse archive
  (Home's row shows a PRO badge; tap opens the paywall), the sport filter (`SportFilterBar`
  shows a lock glyph on MLB/Soccer/Tennis chips for free users — NFL/NBA/All stay free).
  `PaywallView` (Prime Time style) is the one paywall every locked touchpoint routes through.
- **Known verification gap:** `xcrun simctl launch` (this repo's established CLI-only
  screenshot workflow, AGENTS.md §5) does not attach the scheme's `.storekit` config — only
  an actual Xcode Run does — so the paywall's product list can't be exercised end-to-end
  without either running via Xcode directly or a one-time user-approved pbxproj edit to link
  `StoreKitTest.framework` for an in-process `SKTestSession` (attempted, reverted — this repo
  forbids hand-editing the pbxproj without explicit sign-off). The gating logic itself
  (lock glyphs, paywall routing, `Entitlements` derivation) is fully verified via
  `EntitlementsTests` + simulator screenshots; only the live purchase button flow is unverified
  in this environment.

**Shipped 2026-07-07 (M5 Phase B — server-validated entitlements):**
- `public.entitlements` table (additive migration, applied live to `nhccgufqwndtoasdbkhc`):
  one row per (user, product), RLS own-read only — writes are service-role-only, so a client
  can never grant itself an entitlement.
- `supabase/functions/app-store-notifications` (deployed live, `verify_jwt: false` — matches
  the existing `notify-versus-challenge` precedent, since Apple's POST can't carry a Supabase
  JWT; the payload's own signature *is* the auth boundary): receives App Store Server
  Notifications V2, verifies the JWS's x5c certificate chain against a pinned trusted root
  (`APPLE_ROOT_CA_PEM` secret — not yet set, see hand-off H3 below), then upserts
  `entitlements` keyed by `appAccountToken` (our own uuid, set at purchase time via
  `Product.PurchaseOption.appAccountToken` — `StoreService.purchase` now threads the signed-in
  user's uuid through every purchase call so the webhook can attribute it).
- `supabase/functions/_shared/app_store_notifications.ts`: JWS decode + chain verification
  (`verifyAppleSignedPayload`) + pure entitlement-status derivation
  (`deriveEntitlementStatus`), locked by 9 Deno tests in `app_store_notifications.test.ts`
  using a self-generated root→intermediate→leaf fixture chain (proves chain-walking,
  root-pinning rejection, tampered-payload rejection, and rogue-key rejection all work
  end-to-end with real crypto — not mocked). Uses `@peculiar/x509` (MIT, via esm.sh, same
  import mechanism as the already-present `@supabase/supabase-js`) for X.509 parsing/chain
  verification — a deliberate, user-confirmed exception to this repo's "hand-rolled crypto,
  no external library" convention (see `apns.ts`'s own comment), because *verifying* a
  certificate chain is a meaningfully harder and higher-stakes undertaking than the ES256 JWT
  *signing* that convention was written for.
- `RemoteSync.pullEntitlements()` + `RepositoryContainer` now union the on-device StoreKit read
  (`store.entitlements`) with the server's verified table (`serverEntitlements`) on sign-in —
  either source proving entitlement is sufficient; neither is treated as more authoritative.
- **Scope note:** the "companion client-transaction verify via App Store Server API" belt (an
  app-initiated verify path, on top of the ASN webhook) from the original plan was not built —
  the webhook is the primary, standard mechanism and is fully implemented; the companion path
  would mostly matter for closing a narrow race-condition window and is a reasonable fast-follow,
  not a gap in the core design.
- **Verified live:** `POST /functions/v1/app-store-notifications` returns `500 {"error":"not
  configured"}` today (correct — `APPLE_ROOT_CA_PEM` isn't set yet per hand-off H3), confirming
  the function is deployed and reachable without crashing.

**Shipped 2026-07-08 (M5 Phase C — Over/Under):**
- `BallIQ/Models/OverUnder.swift`: `OverUnderRound` (real player-season stat vs. a jittered
  threshold — never exactly the true value), `OverUnderRoundGenerator` (client-side,
  deterministic per date+sport+index off the existing `PlayerSeasonCatalog`/`ScoringStat`
  catalog — no pipeline change, offline-capable via the catalog's existing bundled fallback),
  `OverUnderScoring` (combo multiplier, capped at 2× after a 10-streak), `LivesBank` (pure,
  clock-injected 3-lives/1-hour-regen mechanic). All locked by 18 new tests in
  `OverUnderTests.swift` (generator determinism, threshold-never-ties, bounds-respecting
  jitter, combo math, and — the brief's own called-out risk — full regen-timing coverage:
  no-regen-under-an-hour, partial-hour-carries-forward, caps-at-max-and-clears-timestamp).
- `SeededGenerator.stableHash` (previously private to `Keep4GameView`) promoted to a shared,
  reusable static method on `SeededGenerator` itself rather than duplicated — same
  deterministic-seeding tool now backs both Keep4's blind order and Over/Under's rounds.
- `BallIQ/Data/Repositories/OverUnderStore.swift`: UserDefaults-backed lives + per-sport high
  score, mirroring `LocalProgressRepository`'s shape.
- `BallIQ/Features/OverUnder/`: `OverUnderGameView` (swipe *and* tap Over/Under, mirroring
  Keep4's dual-input a11y pattern; live lives/score/combo header) + `OverUnderResultView`
  (hero score card, `RewardsRow`, and — when not Pro — an "unlimited lives" paywall upsell
  touchpoint). Wired into `GameFormat.all` (`isPlayable: true` now) and `HomeView`'s launch
  dispatch; `-screenshotOverUnder`/`-screenshotOverUnderResult` debug flags added.
- **Progression:** new `GameFormatKind.overUnder` case. First Over/Under session of a given day
  is ranked (via the existing `hasCompletedToday(puzzleID:)` check against a synthesized daily
  id); replays that day are XP-only — reuses the community `ranked: false` pattern rather than
  a parallel mechanism.
- **Discrepancy resolved:** the brief flagged a risk that `GameFormatKind` might need decode-
  tolerance work for old app builds reading synced progress with an unknown raw value. Traced
  the actual data flow first (AGENTS.md §3) — `GameFormatKind` is never decoded from any
  stored/remote source in this codebase (only ever constructed in Swift code and consumed for
  XP/rating computation or stringified for analytics); no decode-tolerance work was needed.
- **Verified live in simulator:** game screen (real catalog data — e.g. "T.J. Yeldon, JAX ·
  2016, RUSH TD 4, Over/Under") and the out-of-lives result screen (score 350, rewards row,
  confetti, Pro upsell row) — both screenshotted via the new debug flags.

**Shipped 2026-07-08 (M5 Phase D — Draft & Spin):**
- `BallIQ/Models/DraftSpin.swift`: `DraftSpinConstraint` (today's featured sport is seeded by
  date; lineup shape is fixed per sport — NFL QB/RB/WR/TE, baseball H/H/P, soccer GK/DF/FW/MF,
  reusing `Sport.positionStatFamilies`'s position vocabulary; NBA/tennis get 3 unslotted picks,
  since those sports' stats apply broadly regardless of position — same reasoning that table's
  own comment already documents), `DraftSpinSimulator` (pure, deterministic 17-week season sim
  seeded by date + the exact drafted lineup; `power(_:sport:)` derives a 0...1 "how good is this
  season" proxy by normalizing every stat the season has against `ScoringStat`'s own reference
  bounds — reusing the same fixed-scale normalization `ScoringRule` already uses rather than a
  parallel one). 13 tests in `DraftSpinTests.swift`, including a locked-value regression pinning
  one exact lineup+date+seed's output (wins/losses/points/outcome) so a future RNG/scoring
  refactor can't silently drift it.
- `BallIQ/Features/DraftSpin/`: `DraftSpinView` (spin → one-slot-at-a-time draft board, 3
  candidates per slot, tap to pick) → `DraftSpinResultView` (record/points hero, drafted
  lineup list, `RewardsRow`, share). `DraftSpinShareCardView` mirrors the M13
  `ShareCardView`/`PuzzlePreviewCardView` share-card pattern (Prime Time frame,
  `ImageRenderer`-backed `.rendered()`) rather than inventing a new one. Wired into
  `GameFormat.all` + `HomeView`'s launch dispatch; `-screenshotDraftSpin`/
  `-screenshotDraftSpinResult` debug flags added (auto-picks each slot's first candidate, since
  simctl can't tap through the draft board).
- **Decision applied: XP-only/unranked** (`complete(..., ranked: false)`, new
  `GameFormatKind.draftSpin` case) — the sim is luck-dominant by design, so it must never move
  the competitive ladder. Verified live: a completed session showed `Rating 1010 +0` (no
  movement) alongside `XP +100` and streak advancing normally.
- **Real bug caught and fixed during simulator verification, not left as a TODO:** the initial
  implementation fetched one generic top-300-by-season-year catalog pool per sport and filtered
  it client-side per position. Soccer's GK (7 rows) and DF (1 row) positions are so heavily
  outnumbered by FW (979) and MF (507) that they never survived the sort-and-truncate-to-300 —
  the GK/DF draft slots came up completely empty in the simulator (verified via screenshot,
  not assumed). Fixed by querying the catalog once per distinct position needed
  (`CatalogQuery(sport:positions:)`, already-existing infra) instead of one shared pool, so a
  rare position's own candidates are never crowded out by a common one. Re-verified live:
  the GK slot now shows 3 real candidates (Emiliano Martínez, Petr Čech, Thibaut Courtois).
  A defensive auto-skip for a genuinely empty slot (0 catalog rows for that position) was also
  added, though it shouldn't trigger for any sport in `DraftSpinConstraint.lineupSlots` today.
- `SeededGenerator.stableHash` (already promoted to shared in Phase C) backs Draft & Spin's
  sport-of-the-day pick, slot draws, and season sim seeding too — one deterministic-seeding
  tool for every daily-content generator in the app now.

**Shipped 2026-07-08 (M5 Phase E — The Grid, Pro-only):**
- **Pipeline (Python):** `tools/ingest/grid.py` — a 3x3 team x decade board, generated
  directly from the already-ingested `player_seasons` catalog (not a fresh nflverse pull —
  Grid's data need, team+decade slicing, is fully satisfied by that table). Same
  viability-gate philosophy as `generate.py`'s `_is_viable`: every one of the 9 cells must
  have >=1 real valid answer, or the whole day's grid for that sport is skipped rather than
  shipped broken. Rarity v1 is offline-deterministic (1-5 stars from the cell's own answer-pool
  size at generation time), per the brief's explicit scope-down from a live per-guess rarity
  table. 14 Python tests (`test_grid.py` + 2 in `test_upsert.py`), all against synthetic data.
  Wired into `main.py` as a standalone `--grid <sports>` flag (own early-return branch, same
  posture as `--write-themes` — never touches the scheduled nflverse gather pipeline).
- **Real bugs caught during live verification against the actual Supabase project, not left
  as TODOs:**
  1. `fetch_player_seasons` requested `limit=20000` but PostgREST silently caps a single
     response at its own configured max (Supabase's default: 1000 rows) regardless of the
     requested limit — NFL alone has ~14k rows. Worse, with no explicit `order=`, *which*
     1000-row slice came back wasn't even stable across calls, so the same (sport, date)
     could go from a fully viable grid to "no viable grid" between two runs purely by luck of
     which rows PostgREST happened to return. Fixed with real `Range`-header pagination +
     `order=id` for a stable row set; locked with 2 tests simulating a low server-side cap.
  2. Some NBA `player_seasons` rows have a blank `team_abbr` (unresolved provider data), which
     the generator was happy to pick as a real "row team" label (a Grid row reading "" in the
     UI). Fixed by excluding blank team_abbr from the candidate team set; locked with a test
     across 20 seeded dates.
  3. **Live re-verification after both fixes**, run twice back-to-back to confirm stability:
     NFL → `CLE/SEA/LA x 1990s/2010s/2020s`, NBA → `DET/DAL/MIN x 1990s/2000s/2010s` (no more
     blank team), baseball → `SD/LAD/SEA x 1970s/1980s/2010s`; soccer/tennis correctly skip
     (too sparse — tennis's `team_abbr` is actually a country code, not a club, so team-based
     slicing doesn't even conceptually apply there yet). 3 real puzzle rows upserted live to
     `nhccgufqwndtoasdbkhc`, confirmed via direct query.
- **Soccer/tennis Grid exclusion is a documented product decision, not a gap to close** (2026-07-08
  follow-up): live query confirmed soccer is functionally *one* decade — 2020s 1,484 rows,
  2010s 9, 2000s 1 — because API-Football's free tier only ever serves a rolling 2022-2024
  window (verified live, see `providers/api_football.py`'s header) and defenders/keepers are
  hand-curated-permanently (no clean-sheets field on that API). More sweeping adds *rows*,
  never *decades*, so the "team x decade" concept can't be made to work for soccer by waiting
  or by upgrading the API tier (~2 real decades even on a paid plan). The viability gate's
  auto-skip stays the intended long-term behavior; if a soccer Grid is ever wanted, the axis
  would need to become "team x season" (2022/23/24 — 258 teams, 3 seasons of live data
  already support that shape) rather than decade. Tennis is conceptually out either way — its
  `team_abbr` holds a country code, not a club.
- **Client (Swift):** `GridPuzzle` model (+`isCorrect` reusing WhoAmI's existing
  `AnswerMatcher` tolerant-match logic — case-insensitive, last-name, single-typo — rather
  than a second free-text matcher) with a decode test against the pipeline's real content
  shape. `PuzzleRepository.gridPuzzle(for:date:)` on both Local (no bundled fallback — Grid is
  Pro-only content that needs the live pipeline regardless, a deliberate v1 scope line) and
  Remote (same `fetch`/`pick` machinery as keep4/whoami, format="grid"). `GridGameView` (9-cell
  board, one guess per cell — decisions final, same posture as Keep4) → `GridResultView`.
  New `GameFormatKind.grid` (`ratingWeight: 2.0`, exceeding Who Am I?'s 1.6 exactly as
  `Progression.swift`'s own long-standing comment anticipated). Gated via
  `Entitlements.canPlayGrid()` (Pro or the Grid pack) at the Home launch point, opening the
  paywall otherwise. `-screenshotGrid`/`-screenshotGridResult` debug flags (the latter
  auto-answers every cell with its first valid answer, since simctl can't type into the guess
  field). 7 new Swift tests (`GridPuzzleTests.swift`).
- **Real bug caught in Swift too:** the game view resolved its *displayed* sport as
  `sportFilter.sport ?? .nfl` but fetched content using the raw `sportFilter` itself — under
  the default `.all` filter (no sport), the fetch pulled every sport's grid row and silently
  returned whichever sorted first alphabetically by id, while the header independently
  defaulted its label to "NFL legends". First screenshot caught it directly (header said NFL,
  board showed baseball's SD/LAD/SEA). Fixed by resolving one concrete `SportFilter` from the
  same displayed sport before fetching; re-verified live — board and header now agree.
- **Verified live end-to-end:** a full 9/9 session against the real NFL grid scored 1,100
  (900 base + 200 rarity bonus, matching the live puzzle's own rarity distribution exactly),
  awarded `Rating 1081 +38` (ranked, confirming `ratingWeight: 2.0` is actually being used) and
  `XP +275`, with the "IMMACULATE GRID" perfect-clear celebration firing.

**Shipped 2026-07-08 (M5 Phase C/D/E follow-up — Draft & Spin per-sport seasons + soccer/tennis
catalog depth):** built The Grid exposed two gaps in what Phases C-E shipped earlier the same
day; this follow-up addresses both.
- **Draft & Spin no longer hardcodes NFL's season shape onto every sport.**
  `DraftSpinSimulator.seasonShape(for:)` replaces the old flat `weekCount`/`championshipWins`/
  `playoffWins` constants with a per-sport table (NFL 17/12/9 unchanged; NBA 82/48/42; MLB
  162/91/81; soccer 38/24/19; tennis 70/42/35). Thresholds are matched by *tier probability*
  under a coin-flip week (NFL's real odds: champion tier ~7% of seasons, playoff tier ~50%) —
  not by copying NFL's win ratio, which would make e.g. an 82-game NBA champion tier
  probabilistically unreachable. `DraftSpinResult.Outcome.title(for:)` is now sport-parameterized
  too: NFL/NBA/MLB keep CHAMPION/MADE THE PLAYOFFS/MISSED THE PLAYOFFS; soccer gets WON THE
  LEAGUE/TOP FOUR/MID-TABLE; tennis gets YEAR-END No. 1/TOP 10 SEASON/TOUR GRIND. The NFL locked-
  value regression test (`DraftSpinTests.swift`) was left untouched and still passes exactly as
  before — proof the refactor didn't drift NFL's RNG output — plus a new locked-value test pins
  soccer's output too. All 203 Swift tests pass.
- **Soccer GK/DF and tennis seed CSVs expanded with real, individually-verified stat lines**
  (not bulk/approximate data — every row's appearances + relevant stat was confirmed against a
  primary Wikipedia career-statistics table before being added, several early candidate rows
  were dropped rather than shipped when only a partial stat line could be verified, e.g. clean
  sheets is rarely tabulated per-defender on Wikipedia even when appearances/goals are).
  Soccer GK: 7 → 21 rows (added Reina, van der Sar, Hart, Szczesny, Courtois, Raya seasons
  spanning 2006-2026, Premier League Golden Glove winners). Soccer DF: 1 → 2 rows (added John
  Terry's 2004-05 Chelsea season, the Premier League's clean-sheets/goals-conceded record
  season — still thin; defender clean-sheet data is inherently harder to source from Wikipedia
  than goalkeeper data, since it's usually reported as a team stat, not tabulated per-player).
  Tennis: 16 → 20 rows, including its **first women's rows ever** (Serena Williams 2002 —
  56-5, 8 titles, 3 slams; Iga Świątek 2022 — 67-9, 8 titles, 2 slams) plus Andy Murray 2016 and
  Carlos Alcaraz 2022. `tools/ingest/providers/api_football.py`'s `merge_with_seed()` last-name
  dedup guarantee re-checked against the larger seed — no new surname collisions introduced.
  **Scope note:** this fell short of an initial ~40-60 GK / ~20-30 DF / ~50-80 tennis target —
  that target assumed bulk sourcing would be available; in practice each row needed individual
  verification and many candidates (Cannavaro, Maldini, Xavi, Modrić, Graf, Barty) were dropped
  when a full stat line couldn't be confirmed. DF and tennis depth remain a good candidate for a
  dedicated follow-up pass against a proper stats database/API rather than more Wikipedia prose
  mining.
- **New health guard so this bug class can't recur silently:** `tools/ingest/health.py`'s
  `catalog_depth_report()` computes season-grain row counts per (sport, position) and flags any
  position a Draft & Spin lineup slot actually filters by (`DRAFT_SPIN_SLOT_POSITIONS`, hand-
  mirroring `DraftSpinConstraint.lineupSlots` since one side is Swift and the other Python) that
  has fewer than 3 rows — the exact threshold below which a slot can't deal 3 distinct daily
  candidates. Wired into `main.py`'s `build_rows()`, prints a `[health] WARNING` during ingest
  runs, and is now part of `content_health.json`'s `catalog_depth` array +
  `totals.draft_slot_positions_too_thin`. 5 new pytest cases in `test_health.py`.
- **Live re-verification (AGENTS.md §1):** re-queried `nhccgufqwndtoasdbkhc` after
  `--upsert --catalog` (65,774 catalog rows total upserted this push). Soccer GK: 7→21
  season rows (26 incl. 5 newly-unlocked career aggregates — expanding depth pushed Reina,
  Hart, Cech, Courtois, and Raya each past `career.py`'s "≥2 real seasons" threshold, so
  those players now also have a real career-aggregate puzzle row, a bonus this session didn't
  explicitly set out to produce). Soccer DF: 1→2 season rows (no career unlock yet — both
  players still have only 1 seed season each). Tennis: 16→20 season rows (23 total incl. the
  3 pre-existing Big-3 career rows, unaffected). These are point-in-time counts — the daily
  `soccer-sweep.yml`/`ingest.yml` jobs keep moving soccer's live FW/MF counts forward
  independent of this session's GK/DF/tennis seed work.
- **Real bug caught post-ship, not left as a TODO:** `Text("\(player.teamAbbr.uppercased()) ·
  \(player.seasonYear)")`-shaped code in `OverUnderGameView`/`DraftSpinView`/
  `DraftSpinResultView` rendered years like "2,023" instead of "2023" — SwiftUI's `Text(_:)`
  string-literal initializer infers `LocalizedStringKey`, which applies locale-aware
  thousands-grouping to any raw numeric interpolation, unlike a plain Swift `String`
  interpolation. `Keep4ResultView` had already independently worked around this exact bug
  (`String(format: "%02d", ...)`) — the 3 newer sites hadn't followed that precedent. Fixed by
  wrapping every season-year interpolation in `String(...)` first; re-verified live via
  screenshot (tennis lineup now reads "SRB · 2011", not "SRB · 2,011").
- **Real bug caught by the user, not left as a TODO: Over/Under showed position-mismatched
  stats** (e.g. an "Over/Under 3000 passing yards" round for a WR). Root cause traced (AGENTS.md
  §3): `nfl_nflverse.py` gives every NFL row the full flat stat dict regardless of position
  (a WR's `passing_yards` key exists, just zeroed), and `OverUnderRoundGenerator.round`
  (`OverUnder.swift`) filtered `ScoringStat.catalog(for: sport)` only by key-presence, never by
  position — the exact bug class `Sport.positionStatFamilies`/`sliceForPosition` was already
  built to prevent elsewhere (AGENTS.md §4), just never adopted here. Fixed by position-scoping
  candidate stats via `sport.sliceForPosition(...)` before the presence filter. Locked with a
  200-iteration regression test (`testStatSelectionNeverCrossesPosition`) and re-verified live
  (Donald Driver, GB 2001 → "REC 60", never a passing stat).
- **New: a minimum-relevance floor for gameplay pools** (Over/Under's pool, Draft & Spin's
  draft candidates) — both previously drew from an unranked/unfiltered catalog slice, so an
  obscure single-digit-production season could appear as readily as a star season. Added
  `PlayerRelevance.filter(_:sport:minimum:)` (`BallIQ/Models/PlayerRelevance.swift`), reusing
  the existing `DraftSpinSimulator.power(_:sport:)` signal (already generic across every sport)
  with a 0.15 floor — falls back to the unfiltered set when filtering would leave fewer than
  `minimum` candidates, the same graceful-degradation shape as `sliceForPosition`, so an
  already-thin position (soccer DF) never gets filtered to empty. Deliberately **not** applied
  inside `PlayerSeasonCatalog.search()` itself — the Create-flow catalog browser is meant to
  stay unconstrained (its own doc comment: "none of these constrain the final puzzle"); the
  floor only applies at the two arcade-format call sites. 6 new Swift tests across
  `PlayerRelevanceTests.swift` and `DraftSpinTests.swift`.
- **Card-metadata parity: Over/Under and Draft & Spin now show the same headshot + team-logo
  treatment as Keep4 cards**, per explicit user feedback that Keep4's card is "our best
  feature" and every gameplay card should match it. Extracted `PlayerHeadshotBadge`/
  `TeamLogoBadge` (`BallIQ/DesignSystem/PlayerMediaBadges.swift`) out of `Keep4CardView`'s
  previously-private computed properties (AGENTS.md §4 — one shared implementation instead of
  per-card copies); `Keep4CardView` itself now calls the shared components with identical visual
  output. Wired into `OverUnderGameView`'s round card header, `DraftSpinView`'s candidate rows,
  and `DraftSpinResultView`'s lineup list. Verified live via screenshot (Donald Driver's real
  headshot + Packers logo on Over/Under; Petr Čech/David Raya real headshots on Draft & Spin's
  GK slot).
- All 209 Swift tests pass after this follow-up round; full suite re-run live in the simulator
  after each fix, per AGENTS.md §7.

**Shipped 2026-07-08 (Draft & Spin redesign — blind roster picks):** per explicit user
feedback ("the draft and spin needs a major refactor... spin like a slot machine to give us a
LEAGUE, YEAR, and TEAM... stats are hidden and the user must select a player from the provided
roster"), replaced the old position-slotted draft (3 visible-stat candidates per QB/RB/WR/TE-
style slot) with a blind team/year roster pick. Scoped down from the original ask via 3
clarifying questions: **no new "league" concept** (dropped — NFL/NBA/MLB/tennis are already
one league each; adding real soccer competitions would need a new schema column with no
catalog support today, so this stays Year + Team only); **no roster-depth data expansion**
(ships against today's already-curated catalog per team-year, typically a handful of real
players, not a full 53-man roster — real names either way, just not exhaustive); **stats
reveal after the pick**, feeding the existing season simulator exactly as before, rather than
being a stats-free pure-trivia mode.
- `DraftSpinSlot` (`BallIQ/Models/DraftSpin.swift`) now carries `team`/`year` instead of
  `position`. `DraftSpinConstraint.rosterSlots(from:sport:date:)` replaces `slots(from:...)`:
  groups the pool by every real (team, year) combo it actually contains (never a guessed
  combo that might not exist), keeps only combos with a `PlayerRelevance`-passing candidate,
  sorts into a fixed order, then seed-shuffles and takes as many as the sport's slot count
  (`slotCounts`, same counts as the old per-sport position-slot lengths) — degrading
  gracefully to fewer slots when a sport/pool doesn't have that many distinct viable
  team-years, rather than crashing or repeating a roster. Sorting before the seeded shuffle
  matters: `Dictionary` iteration order isn't stable across runs, so shuffling straight off it
  would have silently broken the "same day → same spin on every install" determinism guarantee.
- `DraftSpinView`: header now reads "PICK FROM: `TEAM` · `YEAR`"; each roster row shows only
  headshot + name + position tag — no stat value, no team/year (redundant with the header) —
  genuinely blind. `DraftSpinResultView`'s lineup list is the reveal moment: now shows each
  picked player's real key stat (via the existing `ScoringStat.displayColumns` mechanism)
  alongside team/year, the first time that information appears anywhere in the flow.
- 8 new/rewritten Swift tests in `DraftSpinTests.swift` (determinism, candidates all match
  their slot's team/year, no repeated team-year combo across slots, graceful degradation on a
  thin catalog, empty-pool safety, relevance-floor fallback on an all-marginal roster). All
  211 Swift tests pass.
- **Verified live in the simulator:** NFL board showed "PICK FROM: KC · 2010" with Brodie
  Croyle as the (only) real roster candidate, no stats visible; the result screen revealed a
  real blind-drafted lineup (Tony Gonzalez 917 REC YDS, Tony McGee 148 REC YDS, Randy Moss
  1,233 REC YDS, Drew Bledsoe 4,359 PASS YDS) with real headshots, matching the intended
  spin → blind pick → reveal flow end to end.

**Shipped 2026-07-08 (Draft & Spin v2 — real per-sport formations + a "juicy" spin, plus two
correctness bugs the stress-test caught):** the roster-pick redesign above shipped with generic
per-sport slot *counts* (4/3/4/3/3), not real lineup shapes. Per explicit follow-up feedback,
replaced those with actual formations, added a slot-machine reveal animation, and — critically —
stress-tested all 5 sports live, which surfaced two real bugs that generic counts alone had
masked.
- **Real formations, grounded in live-verified depth (AGENTS.md §1 — checked before designing,
  not after):** NFL = QB, WR×2, RB×2, TE, FLEX(RB/WR/TE) — 7 slots, matching the user's own
  spec. NBA = "Starting 5" as G×2/F×2/C — the catalog only distinguishes G/F/C (no PG/SG/SF/PF
  split), so this is the truest realization of "Starting 5" the data can actually support, not
  a made-up simplification. Soccer = GK/DF×2/MF×3/FW×2 (8 slots, the largest formation the data
  can ever fill) — live-queried club-level depth shows only 2 clubs in the whole catalog
  (Chelsea, Liverpool) have ever had a real DF row at all, so a literal 11-man "Starting XI"
  is not achievable without fabricating data; unfillable roles (almost always DF) are skipped,
  not faked. Baseball ("figure it out") = 4 Hitters + 2 Pitchers — the catalog only has H/P
  granularity, no batting-order positions to build a literal lineup card from. Tennis ("figure
  it out") = kept the prior per-round independent-spin design (3 rounds, no team/lineup
  concept — verified live that a single country+year combo essentially never has >1 real
  player, so a one-roster "lineup" doesn't exist for tennis at all).
- **`DraftSpinConstraint.pickTeamYear`/`buildSlots`** (split out of the old single `rosterSlots`,
  which is now a convenience wrapper for tests/tennis): allocates each formation role's shown
  candidates with an explicit reservation count for remaining same-position slots, so an early
  slot can no longer greedily claim a whole position's pool and starve a later slot or FLEX —
  the first version of this allocation had exactly that bug, caught by a test with deliberately
  tight fixture depth before it ever reached a device.
- **Real bug caught only by stress-testing every sport live, not by unit tests alone:**
  `PlayerSeasonCatalog.fetchRemote` had no `order=` clause and no pagination, so a big-sport
  fetch (Draft & Spin, Over/Under) returned an arbitrary, possibly narrow slice regardless of
  the requested `limit` — the exact bug class already caught once in the Python Grid pipeline,
  just never ported to this Swift client. Verified live: NFL's LV/2000 has real QB:2/RB:5/WR:5/
  TE:2 depth, yet the app's fetched sample only ever surfaced 4 of NFL's 7 formation roles for
  it. Fixed with stable `order=id` plus real `Range`-header pagination in `SupabaseClient`
  (mirrors the pipeline's own fix), and Draft & Spin's requested pool raised from 400 to 2000.
- **Second bug, found by re-testing after the first fix:** even with a much better sample, a
  *sample* dense enough to correctly identify the best (team, year) is not necessarily dense
  enough to carry that team-year's *complete* roster — verified live: a sample correctly
  picked MLB's TOR/2011 as the day's best-filled combo, but the sample only carried a handful
  of its real 11 hitters/11 pitchers, so only 3 of 6 formation roles filled. Fixed by splitting
  the fetch into two phases: `pickTeamYear` runs against the broad sample (discovery only), then
  `DraftSpinView.load` re-fetches that exact (team, year)'s complete roster (bounded to one
  season across the sport, comfortably small) before `buildSlots` runs against the real thing.
- **New "juicy" slot-machine reveal** (`SpinRevealView.swift`): two decelerating reels (team,
  year) cycle through decoy values before locking onto the real spun combo, with haptic ticks
  and a scale/glow "LOCKED IN" landing — shown once per team-sport session, and re-shown each
  round for tennis (whose rounds each spin an independent country/year). Skips straight to the
  settled state under the `-screenshotDraftSpin*` debug flags so automated screenshots land
  reliably on the draft board/result rather than mid-animation.
- **Verified live across all 5 sports post-fix** (draft board + full result reveal, real data,
  zero placeholders beyond the pre-existing headshot-coverage gaps M16 already documents):
  NFL → DET/2020 7/7 slots filled (Stafford/Jones/Cephus/Johnson/Peterson/Hockenson, "MADE THE
  PLAYOFFS" 10-7, 224 pts); NBA → DET/2022 5/5 slots (Diallo/Cunningham/Grant/Stewart/Garza,
  "MISSED THE PLAYOFFS" 41-41, 1,221 pts); MLB → TOR/2011 6/6 slots; Soccer → ARS/2024 4/8 slots
  (GK/MF/MF/FW — DF correctly absent, Arsenal has no real DF row; Raya/Ødegaard/Trossard/Saka,
  "TOP FOUR" 23-15, 1,312 pts); Tennis → SRB/2021 3/3 rounds (Djokovic). 216 Swift tests pass.

**Shipped 2026-07-09 (M18 — Draft & Spin per-round mechanic + full-roster data coverage):**
the format's 4th and final mechanic iteration plus the data-depth work it exposed.

- **Mechanic (v3→v4, landed 2026-07-09 pre-M18-session, documented here):** *every round*
  spins its own (team, year) — not one spin for the whole lineup — with full player stats
  **visible** (both confirmed against a user-supplied reference recording, superseding the
  blind single-spin designs above); the second reel is an **exact single year**, not the
  reference app's 5-year era buckets (explicit user correction overriding the video).
  `DraftSpinConstraint.spinRound` discovers a viable combo per round from a broad sample
  (seeded by date + round index + reroll count; only combos with ≥1 candidate fitting a
  currently-open role are spinnable), one reroll per round; the round's complete roster is
  re-fetched for the exact (team, year) before display (`DraftSpinView.loadRoundRoster` —
  the sample-vs-complete-roster split that fixed the v2 bugs is load-bearing here too).
  Browse is position-tabbed/grouped with tap-to-expand extra stats; tap a highlighted
  lineup slot to assign; repeat until full, then the unchanged simulator/result flow runs.
- **Re-verified post era→year swap (M18 step 1):** all 215 Swift tests green, plus the live
  5-sport stress test (round-1 board + auto-played full result each): YEAR chip shows a
  real single year everywhere; reroll intact; soccer (BAŞ 2023 MF/FW) and tennis
  (TCH 1986 Lendl) still find viable combos post-swap.
- **NBA coverage (the milestone's headline): full league rosters 2002+, not just stars.**
  ESPN itself was a triple dead end for historical enumeration (verified live: the core
  season-roster endpoint returns the *current* roster for any year — the "1985 Cavs"
  contain Jarrett Allen; the athletes index only lists ~363 active players season-blind;
  stats.nba.com hangs from both this environment and CI). The working source:
  **sportsdataverse hoopR's data repo** republishes ESPN's player-season averages for
  every player who appeared, 2002→present, one parquet/season — the NBA equivalent of
  nflverse. New `providers/hoopr_nba.py` (refresh needs pyarrow, lazily imported — same
  optional-dep contract as pyespn; runtime reads the committed
  `data/nba_hoopr_seasons.csv` stdlib-only), pivoting hoopR's long rows through the exact
  same normalization as `espn_nba.parse_seasons` (shared `_norm_position`/`_attempted`,
  identical ts_pct derivation), static slug→abbr map that **fails loudly** on an unknown
  franchise slug, traded players resolved to their most-games real-team stint (or kept
  team-less when only a "Totals" line exists, matching the live ESPN path's convention).
  8 new pytest cases (`test_hoopr_nba.py`). **Live verified (before → after):** NBA season
  rows 8,199 → 13,152, distinct players 855 → 2,511, median team-year depth in the hoopR
  era ~13–17 players (was ~7–11 avg) = 6 G / 6 F / 3 C at the median vs the G/G/F/F/C
  formation — and the simulator board confirms it (NO 2020 round-1 showed 9 real guards
  incl. bench players, vs 3 the day before). Pre-2002 stays star-pool-only — hoopR has no
  earlier files; that's the documented floor, not an oversight.
- **NFL width: verified uniform, nothing to do** — 485–611 rows in every year 1999–2024
  (~16/team-year); 1999 is nflverse's hard floor (pre-1999 legends stay seed/career-only).
- **MLB width: pre-1976 team-years were thin** (a career-reachback artifact of the
  1975-start leader sweep: <6 players/team before 1969, vs ~23/team 1976+). `mlb_pool`'s
  sweep extended 1975→**1955** (now also its committed default, so the weekly
  discover-players.yml refresh can't silently regress the range): id pool 3,298 → 4,362.
  **Live verified (before → after):** baseball season rows 35,432 → 45,196, distinct
  players 3,280 → 4,333, catalog min year 1957 → 1939 (careers reach back); 1957 went
  1 row → 363 (22.7/team), 1965 59 → 509, 1970 192 → 556 — the pre-1976 era now matches
  modern-era depth (~23–26/team). Catalog upsert total this push: 82,608 rows.
- **Weekly freshness:** discover-players.yml now also regenerates + commits the hoopR
  sweep CSV (pip-installs pyarrow alongside pyespn — both stay out of requirements.txt so
  the daily ingest.yml path remains stdlib-only).
- **Still open (deliberately):** the reference video's pre-game setup screen (Roster
  Both-sides/Offense-only ・ Teams All/One-team-lock ・ Season-Variations On/Prime-only).
  Not built this session: the toggle *semantics* aren't derivable from the prompt's
  shorthand alone (and NFL "Both sides" is impossible with real data — the catalog has no
  defensive players at all), and this format's history is four rebuilds caused by exactly
  this kind of guessed intent. Needs the user to confirm what each toggle should do before
  it's built.

**Shipped 2026-07-09 (M18 follow-up — per-game setup screens, casino spin, true randomness,
scoring audit, second data wave):** same-day follow-up to four explicit user asks.

- **Per-game setup screens replace the Home sport chips.** `SportFilterBar` is gone from
  Home; every format now launches through a shared `GameSetupScreen` scaffold
  (`Features/Home/components/GameSetupScreen.swift`: format label, SPORT picker with the
  same Pro gating the chips had, format-specific `SetupOptionCard`/`SetupSegmentedControl`
  rows, one big start button). Draft & Spin gets the reference video's rows — TEAMS
  All/One-team (first assigned pick locks the franchise; later rounds spin fresh *years*
  of it, falling back to other teams only when its years are exhausted) and SEASON
  VARIATIONS On/Prime-only (Prime-only = each real player drafted at most once; excluded
  players are invisible to both spin viability and rosters) — plus an NFL-only ROSTER row
  honestly locked at "Offense only" (no defensive data exists). Over/Under and The Grid
  gained sport-picker setups (their sport used to silently come from the now-dead filter);
  Keep4/Who-Am-I launch through `DailyGameLaunchView` (setup → fetch that sport's daily →
  play). The chosen sport persists to `container.sportFilter` so Home's daily previews and
  rank widget follow the last sport actually played. This also closes the reported bug
  where the NFL chip + Draft & Spin produced a soccer session — Draft & Spin ignored the
  filter entirely (it used only its own sport-of-the-day rotation).
- **Casino-grade spin reveal** (`SpinRevealView` rewrite): chasing marquee lights framing
  two blockCard reels, rolling decoy transitions, **staggered stops** (team locks first,
  year holds five extra anticipation ticks), volt glow + overshoot pulse on lock, tilted
  "LOCKED IN" stamp, confetti burst, tap→commit→success haptic cadence. New
  `-screenshotDraftSpinReveal` flag freezes the settled state for verification.
- **Spins are truly random now** — explicit product decision replacing the launch design's
  date-seeded "same spin on every install" determinism. `spinRound` and
  `DraftSpinSimulator.simulate` take an injected `RandomNumberGenerator` (gameplay passes
  `SystemRandomNumberGenerator`, tests pass `SeededGenerator`), so reproducibility moved
  from the product into the tests where it belongs.
- **Scoring audit found a real bug: draft quality never affected the record.** The duel
  formula scaled the *opponent's* score by the player's own lineup power, so every season
  was a coin flip regardless of picks. Replaced with an explicit per-game
  `winProbability(power:)` (50% at `leagueBaselinePower` 0.40, ±9 pts of win chance per
  0.1 of lineup power, clamped 10–90%) — locked-value tests re-pinned, plus a
  distribution test asserting a far stronger lineup averages clearly more wins. Verified
  live: an auto-picked bench-heavy NBA lineup went 21-61 ("MISSED THE PLAYOFFS").
- **Second data wave ("we need a TON of data"):** MLB leader sweep widened again,
  1955→**1901** (now the committed default): id pool 4,362 → 7,109 — the Ruth/Cobb/
  Gehrig-era legends' full careers. **Tennis finally has a real bulk source**: new
  `providers/tennis_atp.py` aggregates Jeff Sackmann's `tennis_atp` dataset (via the
  `stakah/tennis_atp` GitHub snapshot — upstream is deleted; snapshot is frozen at 2018)
  into per-(player, season) lines (matches won/lost, titles, Grand Slam titles),
  1968–2018, ≥15 tour matches to qualify; every shipped row carries a real Wikipedia
  thumbnail resolved once per player (tennis-context-verified, so a same-named
  non-player's photo can never ship; photo-less players are dropped to keep the M16
  bundle guard true by construction). Committed as `data/tennis_atp_seasons.csv`; no cron
  needed — a frozen dataset can't drift; 2019+ keeps flowing from the curated seed, which
  wins any (player, year) collision. Soccer stays at its documented free-tier ceiling
  (the incremental league×season sweep cron already covers the whole reachable matrix).
- **Live verified after the wave's final push (107,404 catalog rows upserted):** baseball
  35,432 → 62,283 season rows / 3,280 → 6,304 players (min year 1957 → 1885); tennis
  20 → 3,925 season rows / 13 → 545 players (1968–2023) — a spun tennis round now deals a
  real multi-player country-year roster (verified in-sim: CRO 2018 → Cilic 19-8, Karlovic,
  Coric, real photos) where it previously always had exactly one hand-curated player;
  soccer 1,244 → 2,374 rows / 895 → 1,705 players (the daily sweep cron's own
  accumulation, landed by the same push). One Wikipedia-politeness lesson baked into the
  provider: burst-calling their REST API with no delay gets 429-throttled within ~20
  requests — `_WIKI_DELAY` (0.35s, cache-miss only) keeps the sweep legal.

**Shipped 2026-07-16 (post-backlog opportunity audit — flag-driven play-through of all 5
formats + every tab, cross-checked against live SQL):**
- **Draft & Spin instant-empty-result bug (real, production-reachable):** on a day whose
  sport-of-the-day is Pro-locked (3 of 5 days for free users), a guest with the "All" filter
  seeded the draft with the locked sport; `GameSetupScreen.correctLockedDefault`'s async
  snap-back to NFL landed mid-`startDraft`, splitting the draft across two sports (soccer
  slots vs NFL spin filters) so round 1 dead-ended into "MISSED THE PLAYOFFS · 0" with an
  empty YOUR LINEUP. Fixed three ways: entitlement-aware sport seeding in `load()`, Daily
  Draft forces the true `sportOfTheDay` at load (its setup screen previously displayed the
  wrong sport until Start), and the setup screen's sport binding is gated on `showingSetup`
  so no late write can mutate a running draft. **Open product call:** free users now hit the
  paywall starting Daily Draft on locked-sport days — coherent, but whether Daily Draft
  should instead bypass the sport gate (like the daily Keep4/WhoAmI, which are playable
  regardless of sport) is a user decision.
- **WhoAmI answer reveal shows the real player's photo** — resolved live from the catalog at
  reveal time via `WhoAmIAnswerPhoto` (exact normalized-name equality only, era-clue span
  disambiguation so e.g. Jaren Jackson Sr./Jr. can never swap faces, latest row's photo
  wins; silhouette kept when no confident match). The §9 Tier-3 note that the WhoAmI reveal
  placeholder was purely backlog #9's slice-width problem is now stale: the reveal reads
  photos the catalog already has.
- **Team-less (traded "TOT"/"2TM") season cards** no longer render a dangling " · 2021" —
  shared `CardLabel.dotJoined` replaces six drifting inline interpolations (285 NFL + 1,687
  NBA live rows are team-less by ingest design and reach Over/Under's arcade pool today).
- **Draft & Spin rosters drop position-less rows** (espn_nba stores "" when ESPN carries no
  position — all 11 live Eddy Curry seasons); such rows can never fill a slot and only
  rendered as an unplaceable row under a blank position tab.
- **Arcade leaderboard entry unified** — Grid's result screen had drifted to a bare capsule
  pill with no explainer while Over/Under had the full card row; one shared
  `ArcadeLeaderboardEntryRow` now serves both (es-localized caption included).
- 319 Swift / 217 Python tests green; every fix screenshot-verified on the affected state.

**Shipped 2026-07-17 (1.2 push-chain hardening, first session after the push gates cleared):**
- **notify-streak-risk timezone bug (production, hits every US user):** the "already played
  today" suppression compared the app's *local* `last_played_day` (written as a local-time
  "yyyy-MM-dd" — ProgressRepository.swift) against the **UTC** day. At 8pm US-Eastern the UTC
  calendar has already rolled to tomorrow, so the check never matched and any US-timezone user
  with a streak would get the streak-risk nag *every night even after playing*. Confirmed live:
  the 2026-07-17 00:00:04 UTC cron run (8:00pm ET) pushed to the registered device although
  that day's puzzles were done — a wrong push, but it also proved the full production chain
  (pg_cron → edge function → Vault APNs config → real APNs → device), i.e. 1.2's exit
  criterion's mechanics. Fix: per-device local day/hour math extracted to
  `_shared/localtime.ts` (5 locked Deno tests incl. the exact 8pm-ET regression case) and a
  `[streak-risk] checked=N sent=N` summary log so future runs are verifiable from logs alone.
  **Deploy is pending** — the session's MCP `deploy_edge_function` call was permission-blocked
  and the local supabase CLI is logged into the wrong account (known since 2026-06-29), so the
  fixed function is committed but production still runs the buggy version until a deploy is
  approved. Deno tests: `deno test --allow-env supabase/functions/_shared/`.
- **es catalog backfill:** 9 strings had shipped without Spanish (7 from the avatar-upload
  feature, "All depths"/"Try a different search, decade, or depth." from Browse) — all
  translated; 0 untranslated strings remain outside deliberate `shouldTranslate: false`
  brand terms (Daily Draft, PRO, K4C4, …).
- `.gitignore` now actually covers `tools/release/asc.py` (the docs already *described* it as
  gitignored, but it wasn't) and `client_*.apps.googleusercontent.com.plist`.
- 319 Swift / 217 Python / 23 Deno tests green.

## 9. Roadmap — remaining milestones + product backlog (PM audit 2026-07-09)

Full briefs live in `prompts/` (same self-contained format: goal, why-now, current state,
scope, key decisions, deliverables, verification, hand-offs).

### 9.0 Development priority order (user directive, 2026-07-12): fast, crisp, sturdy

**Performance first, then unbuilt features/functionality, then launch/polish.** This is the
standing sequencing rule for what to pick up next — it supersedes the P0–P3
impact-per-effort ordering below as the *sequencing* signal (work Tier 1 to done before
starting Tier 2, Tier 2 before Tier 3); the P0–P3 list below still holds the detailed
scope/rationale for each item, just re-grouped here by tier instead of by impact. Re-tier an
item only if you have new evidence it belongs elsewhere — don't re-litigate the grouping
from scratch each session.

> **Status 2026-07-16: all three tiers are exhausted** — every agent-buildable item below is
> shipped; the residue is user-gated. Sequencing now lives in **§9.1's version roadmap**
> (1.2 push → 1.3 monetization → 1.4 rating seasons → 1.5 content depth); the tier lists
> below remain as the scope/rationale record for each item.

**Tier 1 — Performance ("make it fast").** Cold-launch and in-session latency, across every
surface, not just the ones already flagged:
- Backlog #3, *cold-launch speed* — **✅ shipped 2026-07-13.** Root cause: Over/Under's (and
  Draft & Spin's) first card blocked on the sport-wide 2,000-row arcade sample — two *serial*
  1,000-row PostgREST pages, ~1.1 MB measured — cached in memory only, so every new app
  session repaid it (~15s on a phone radio). Fix: `DiskCache` (BallIQ/Data/DiskCache.swift)
  under `PlayerSeasonCatalog.draftSpinSample` (24h TTL) and `RemotePuzzleRepository.fetch`
  (fresh = written same UTC day, so a new day's `active_date` row is always refetched);
  layered memory → fresh disk → network (write-through) → stale disk on network failure →
  bundled fallback (never persisted, so an offline first launch can't poison the cache).
  Measured on-simulator 2026-07-13 (fresh install vs process-kill relaunch, timestamped
  debug logs): Over/Under 7.3s first-ever → **1.6s per-session (`disk hit (fresh)`)**;
  Keep4/WhoAmI/Grid ~1.8s → ~1.5s with `[puzzles] disk hit (today)`. All 5 formats audited;
  only the two arcade-sample consumers had the big gap. 248 Swift tests incl. 6 new
  `DiskCacheTests` (network-skip proven by request counting, not return values).
  **Re-verified 2026-07-14** (final-sprint Tier 1 gate): both suites green on the
  consolidated tree and a fresh simulator launch showed all three cache consumers
  serving from disk within the same second (`disk hit (today)` ×2, `disk hit (fresh)`).

**Tier 2 — Unbuilt features/functionality ("make it crisp").** Real gaps between what the
app claims to do and what actually works today:
- Backlog #1 (push notifications) — **agent-verifiable half CONFIRMED working 2026-07-14**:
  all 5 edge functions deployed/ACTIVE, all 4 cron jobs firing on schedule with 200s
  across 24h of logs (streak-risk hourly, versus-timeout q15min, season-end 3×/day,
  weekly rollover Mon 05:00), chain runs end-to-end in `[apns:stub]` log-only mode.
  Remaining is ALL user-side, one portal visit: (a) an APNs auth key — note the ASC API
  key in `tools/release/private_keys/` is a different key type and can NOT sign APNs
  JWTs; three `AuthKey_*.p8` files exist on disk (`6H8Y89UWX3` in ~/Downloads,
  `BCRQ7T7V6H`/`929CXQZ9B6` in ~/Documents/floppyduck — APNs keys are TEAM-wide, so any
  of these works IF the portal's Keys page shows it APNs-enabled on team 8K5ZVPCQ42);
  (b) enable Push Notifications capability on the `com.balliqfantasy.app` App ID (then an
  agent adds the missing `aps-environment` entitlement — deliberately not added before
  the capability exists, it would break archive signing); (c) set
  `APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_PRIVATE_KEY`/`APNS_BUNDLE_ID` as edge-function
  secrets — the local `supabase` CLI is logged into the WRONG account (re-confirmed
  2026-07-14), so either `supabase login` first or paste them in the dashboard
  (Edge Functions → Secrets). #5 (arcade leaderboards) **✅ shipped 2026-07-14** — see
  its entry below. **#2 (post-completion daily loop) and #4 (daily Draft & Spin
  challenge) shipped 2026-07-13; #6 (Leagues season bootstrap) confirmed already
  resolved live** — see their own entries below for detail.
- Backlog #7 (Phase F rating seasons) — **explicitly DEFERRED by the user 2026-07-14**
  ("defer", in response to the scoping ask). Still do not start from inference: the
  written scope remains three one-line mentions with no schema, no reset/decay decision,
  and no definition of "rewards". When the user re-opens it, run the scoping conversation
  first (questions logged 2026-07-12 in `prompts/HANDOFF-next-agent-2026-07-12c.md`).
- **Soccer data breadth (new 2026-07-12)** — ✅ shipped 2026-07-13. Migrated the
  genuinely multi-day local sequential sweep (~2 min/league-season × ~570 total) to
  `.github/workflows/espn-soccer-backfill.yml`, a `workflow_dispatch` matrix (one leg
  per league, `max-parallel: 6`). All 38 legs succeeded; the workflow's own
  `merge-and-upsert` job lost a `git push` race against concurrent commits during this
  session (its computed merge was correct — 7,156 rows — but the ephemeral runner's
  commit was never persisted), so the 38 already-computed artifacts were downloaded and
  the identical merge completed locally instead. One real gap caught in verification:
  the CI-computed partitions predated a `league` metadata column added mid-run by
  concurrent work, so the first live push had it empty for all new rows — backfilled
  from each artifact's own filename (no new network calls) and re-pushed through the
  full pipeline's real dedup path (not a raw `load_seasons()` push, which would have
  bypassed the merge's existing collision-exclusion against seed/transfermarkt soccer
  data). Confirmed live via direct SQL: real `league` values (e.g. "Brazil") on real
  rows. `tools/ingest/providers/espn_soccer.py` now also carries an `--out`/
  `--merge-dir` split (`merge_csvs`) purpose-built for this CI-matrix shape, reusable
  for any future multi-day provider backfill.
- **Share sheet + Keep4 scoring-info popover — ✅ verified working 2026-07-13, not a
  regression.** Both flags are consumed inside their host view, so they're silent no-ops
  standalone and must combine with the flag that navigates there: `-screenshotBrowse
  -screenshotShare` and `-screenshotGame -screenshotScoringInfo`. Both render correctly
  (screenshot-confirmed); combination rule now documented in `DebugLaunch.swift`. (The odd
  "T"/0-seasons archive item seen during verification is simulator-local stale UserDefaults
  — which survive `simctl uninstall` — not production data; both live tables checked clean.)
- M19/M20 TestFlight QA of signed-in social flows (friends, FRIENDS leaderboard, onboarding
  claim) — needs two real signed-in accounts, not directly agent-executable. **Checklist
  prepped 2026-07-14: `prompts/QA-testflight-social-flows.md`** (~25 min two-account pass,
  every step pass/fail observable, includes the Daily Draft/arcade board signed-in halves
  and the known-blocked items that must not be counted as failures).
- **Single-game content breadth + single-game/cross-sport creation (new 2026-07-15) —
  ✅ shipped**, per user directive "a puzzle is a puzzle... users should have full author
  powers based on our features." Single-game (`grain="game"`) content went from 3 NFL-only
  themes to 9 across NFL/MLB/NBA: two new NFL themes (TE explosion, QB rushing) reusing the
  existing nflverse weekly pull; a new MLB single-game provider
  (`providers/mlb_stats_games.py`, MLB Stats API `stats=gameLog`, bounded to the curated
  marquee player list — one call per player per season, so the full ~7,800-player pool
  isn't viable) with 2 themes; a new NBA single-game provider
  (`providers/hoopr_nba_games.py`, hoopR's `player_box` parquet, pre-filtered to "notable"
  games only so the committed sweep stays ~3MB instead of ~33MB) with 2 themes. A `gameDate`
  field (Python → JSON → Swift) now carries a pretty date label ("Apr 8") for non-NFL game
  cards, since NFL's "Wk W" label doesn't make sense for MLB/NBA. Browse gained a
  season/single-game/career depth filter (`GrainFilter`, mirrors the existing decade filter).
  Separately, single-game rows now reach the live `player_seasons` creation catalog too
  (previously excluded — "on-device grading isn't built for single games" — that's now
  false): 3 new nullable columns (`week`/`opponent`/`game_date`) on `player_seasons`,
  `catalog_rows()` stops filtering them out, `CatalogQuery.grain` replaces the old
  season/career-only boolean with a 3-way facet, `Keep4Theme.isCreatable` now accepts all
  three grains, and a new grain toggle in `CreateKeep4View`'s discovery section lets a
  creator scope search to season/game/career. Cross-sport puzzles were **already possible**
  before this change (Create's "Any sport" discovery filter + "Vibes" no-formula drag-rank
  scoring — confirmed via code read, not something built this session) — combined with the
  single-game catalog fix, a user can now build e.g. "greatest single games ever" mixing an
  NFL game, an NBA game, and an MLB game in one Vibes-scored puzzle. 217 Python + 312 Swift
  tests green; live-verified via screenshot (template-driven single-game NBA creation
  showing real "vs OKC · Nov 29" cards, correctly graded) and direct SQL (73,951 NFL +
  26,791 NBA + 18,792 baseball single-game rows live in `player_seasons`). One asymmetry to
  know about: NFL/MLB single-game content refreshes automatically via the existing daily
  cron (`.github/workflows/ingest.yml`) since both providers fetch live; NBA's committed
  `data/nba_hoopr_games.csv` sweep is a manual/occasional refresh (same established pattern
  as `hoopr_nba.py`'s season sweep) — the cron won't pick up new NBA games until someone
  reruns `python -m tools.ingest.providers.hoopr_nba_games`.

**Tier 3 — Launch/polish ("make it sturdy").** Everything else in the existing backlog,
plus a standing user directive added 2026-07-14: **team logos + colors wherever a team
appears, always via the shared systems (`TeamColors` etc.), never hardcoded per-view** —
audit/fix pass ✅ shipped same day: Grid board + recap team-abbr cells now render team
colors via a new shared `TeamAbbrChip` (DesignSystem/PlayerMediaBadges.swift), Draft &
Spin's in-draft TEAM chip tints from the landed team, Profile's favorite-team pill
carries the selected team's palette (298 tests green, Grid chips screenshot-verified;
`TeamLogoBadge`/ESPN-CDN logo system already existed — no gap). Deliberately skipped as
product-taste calls: recoloring SpinRevealView's volt "LOCKED IN" motif, share-card
lineup accent stripes, WhoAmI reveal (no structured teamAbbr in its content model).
Backlog items:
backlog #8 (defunct-franchise styling), #9 (widen historical headshot slices — note
2026-07-16: the WhoAmI answer-reveal half of the old "headshot placeholder" observation is
no longer this item; the reveal now resolves real photos from the catalog via
`WhoAmIAnswerPhoto`. What remains of #9 is pure catalog coverage width), #10 (M14 Spanish localization —
already well-scoped in `prompts/M14-accessibility-and-localization.md`; launch/growth-
motivated, not core functionality, hence Tier 3), #11 (content-drift guard). External,
non-agent hand-offs also live here: APNs key material (gates Tier 2's push item), Paid
Applications agreement + ASC in-app-purchase products (gates M5 Phase B).

| Milestone | Theme | One-line scope |
|-----------|-------|-----------------|
| **M5** | Monetization + breadth | StoreKit foundation + gating shipped; **Phase F 8-week rating seasons** is the unbuilt piece |
| **M14** | Accessibility & localization | VoiceOver shipped; first non-English locale (Spanish) is the remaining piece |

**Prioritized product backlog** (full-app audit against the §1 feedback themes; ordered by
expected retention/quality impact per unit of effort):

*P0 — the retention loop:*
1. **Push notifications end-to-end** — all infrastructure exists (manager, edge functions,
   cron); blocked only on real APNs key material (user hand-off, needs their Apple
   Developer account). Streak-save + "today's puzzle is live" pushes are the single
   biggest retention lever the app has already paid for but can't fire.
2. **Post-completion daily loop** — ✅ shipped 2026-07-13. Once both dailies are done,
   Home's daily section flips to a countdown-to-next-UTC-daily + streak-at-stake card
   (`HomeDailyLoop`/`DailyLoopCountdownCard`) with a "while you wait" nudge toward the
   arcade formats; the two completed cards stay tappable but dim to secondary. A failed
   puzzle load is never mistaken for "completed."
3. **Cold-launch speed: persist the arcade pools to disk** — the in-memory
   prefetch/caching added 2026-07-09 makes warm launches instant; a disk-backed cache
   (TTL ~1 day, like the pipeline's own .cache) would make the FIRST launch of a session
   instant too. Same shape for daily puzzles.

*P1 — engagement depth:*
4. **Daily Draft** (né "Daily Draft & Spin challenge") — ✅ shipped 2026-07-13, renamed
   same day per the competitive glossary ("challenge" belongs to Versus). A MODE row
   (Free Play / Daily Draft) on setup; free play is untouched (same system RNG), Daily
   Draft forces `sportOfTheDay` and seeds every spin from `DraftSpinConstraint
   .dailyDraftRoundGenerator` (day + round index) so every player gets the same
   round-by-round spins. No reroll. `DailyDraftStore` locks in only the day's first
   completion as the official score; replays are XP-only. **Leaderboard shipped too**
   (same day): `daily_draft_scores` + `submit_daily_draft_score` /
   `daily_draft_leaderboard` RPCs (first-write-wins server-side, mirroring the local
   store), fire-and-forget submit at finish + resubmit-on-sign-in for offline runs,
   board sheet off the result banner (`DailyDraftLeaderboardView`), and a Home entry
   via the daily-loop card's dedicated Daily Draft row.
5. **Arcade leaderboards** — ✅ shipped 2026-07-14 (Daily Draft's board shipped 07-13, see
   #4). `arcade_scores` (insert-only RLS like `events`, one row per finished run; the
   insert policy pins `week_start` to the current UTC week server-side so past/future
   weeks can't be posted into) + `arcade_leaderboard(p_game, p_sport, p_week)` RPC (top-50
   weekly best-per-user + caller's own ranked row, mirroring `daily_draft_leaderboard`).
   App side: `ArcadeLeaderboardRepository` + shared `ArcadeLeaderboardView`
   (Features/Arcade/) + `RepositoryContainer.submitArcadeScore` (fire-and-forget, silent
   no-op signed-out — no retry queue on purpose: a lost run is low-stakes, the next good
   run this week reposts). Over/Under posts EVERY finished run (each run is fresh); Grid
   posts only the day's ranked run (unranked replays of the same daily puzzle must not
   farm the board). Board sheet off both result views. Verified 2026-07-14: build + 298
   tests green, both result surfaces screenshot-confirmed, and a live insert→RPC→delete
   round trip returned rank 1 with the correct UTC week bucket.
6. **Leagues season bootstrap** — ✅ resolved on its own, confirmed live 2026-07-13. The
   07-05 handoff worried a manual trigger would be needed; instead `weekly-cohort-rollover`
   fired naturally on its Monday 05:00 UTC schedule with no intervention: season 1 ran
   2026-07-06→07-13 (closed), season 2 is active now (07-13→07-20) with a real cohort and
   members. Leagues has never actually shown an empty state in production.

*P2 — monetization (finish M5):*
7. **Phase F rating seasons** (8-week cycles, placement, end-of-season rewards) — the
   remaining M5 build; the paywall/entitlement rails it sells through are done.

*P3 — quality/polish:*
8. **Historical-era presentation** — ✅ shipped 2026-07-13. Real colors for every
   abbreviation the 1950–2001 NBA / 1970–1998 NFL catalogs can emit: 4 NFL +
   20 NBA franchise-continuity aliases to their current team (SYR→PHI, MNL→LAL,
   RAI→LV, WSB→WAS, etc.), 9 genuinely-defunct-with-no-successor teams got real
   Wikipedia-sourced colors. Also caught two real pre-existing bugs found in the same
   pass: `bref_nba.py`'s own abbreviation rewrite (`SAS`→`SA`, `WAS`→`WSH`) was never
   mirrored in `TeamColors`, so every 1977–2001 Spurs season (356 rows) and 1998–2001
   Wizards season (63 rows) was silently rendering fallback colors — fixed.
9. **Widen historical headshot slices** — ✅ code + regenerated CSVs shipped
   2026-07-13. `PHOTO_SLICE_PER_YEAR` widened 40→100 in both `bref_nba.py` and
   `nfl_history.py`; live re-resolution run and committed (NBA 662/1086 top-slice
   matched, NFL 344/870 — purely additive, only the headshot column changed).
   **`--upsert --catalog` run + verified live 2026-07-14** — done, but it took three
   attempts and surfaced two real pipeline bugs, both fixed: (1) `fetch_existing_catalog_ids`
   paged by Range/offset, which the doubled (~460k-row) table pushed past the server's
   statement timeout (57014), silently killing the first run mid-pipeline (the `| tail`
   pipe also masked the real exit code — don't pipe long pipeline runs) — replaced with
   keyset pagination (`order=id` + `id=gt.<last>`, regression-tested in `test_upsert.py`);
   (2) no composite index supported that query shape, so even keyset pages timed out —
   `player_seasons_sport_id_idx (sport, id)` added live + in schema.sql. The earlier runs'
   "~61k new rows" was a phantom of the same truncation bug: with correct paging the steady
   state is 194,679 closed rows all already stored + 37,430 always-resend (careers + 2026)
   = exactly the live 232,109. Historical headshots confirmed live (NBA 1950–2001:
   6,156/13,489 rows with headshots ≥ the CSVs' 6,084; NFL 1970–1998: 3,051 ≥ 2,788).
   Also done 2026-07-14 with user approval: the 231,685 stale bare-format duplicate rows
   deleted (table now exactly 232,109, 0 old-format) + `vacuum (analyze)` run.
10. **M14 Spanish localization** — ✅ shipped 2026-07-14. `BallIQ/Localizable.xcstrings`
    (Xcode 15+ String Catalog), 418/435 UI-chrome strings translated (neutral
    Latin-American Spanish, arcade-casual register); the 17 without an `es` value are
    deliberate `shouldTranslate: false` entries — format brand names (DRAFT & SPIN, THE
    GRID, Who am I?, Versus, PRO) that stay identical across locales, plus a couple of
    stylistic label fragments. Player names/team abbrs/league names/pipeline stat labels
    stay English (data, not chrome) per the M14 brief. `LocalizationTests` proves the
    catalog compiles into the bundle and actually resolves (not just that the file
    exists). 301 Swift tests green; `-AppleLanguages (es)` screenshot-verified on Home
    and Keep4 — full natural-Spanish coverage on both. Native-speaker review of the
    machine-translated strings remains a user hand-off before wide release.
11. **Content-drift guard** — ✅ already resolved, confirmed 2026-07-13. An earlier
    commit (`bc93f3e`, "Minigame fixes & polish...") already ran the bundle regen this
    item asked for — `test_content_drift.py` passes against the current committed
    `keep4_puzzles.json`, no action needed. Full `pytest tools/ingest/tests` still green.

### 9.1 Version roadmap (planned 2026-07-16, immediately after the 1.1 submission)

The tiered backlog above is exhausted (§9.0): everything agent-buildable is shipped, and
what's left is gated on user actions or user decisions. This roadmap re-cuts that residue —
plus the 2026-07-16 audit's open product calls — into shippable App Store versions, in
order. Convention: **[user]** = needs the user's account/portal/decision before an agent
can act; **[agent]** = buildable unattended once its [user] gates (if any) clear. Each
version ships only when both test suites are green and its own exit criterion is met.

**1.1.1 — reserved patch slot.** Only if 1.1's review rejects or a live regression surfaces
post-approval. No planned content; cut from `main` with the fix, same-day submission (the
pipeline is one command sequence now — see the `testflight-release` skill).

**1.2 — "It remembers you": push notifications + the retention loop's last mile.**
> **Gates CLEARED, verified 2026-07-16 evening:** the user provided a real APNs key
> (`F92WNG523G`, production-environment-scoped — sandbox pushes will NOT work with it,
> which is fine: TestFlight/App Store use production APNs) — functionally verified
> (production APNs accepts its provider token; probe returned `BadDeviceToken` for a fake
> device, i.e. auth OK). PUSH_NOTIFICATIONS is enabled on the App ID, the `aps-environment
> production` entitlement is in the app (shipped in build 9), all four `APNS_*` values are
> in Supabase Vault (`get_apns_config()` returns the complete config — byte-identical
> keypair to the verified key — so `apns.ts` is out of stub mode with no deploy needed),
> and a real device token registered 2026-07-16 17:13 UTC. **Push is live end-to-end**;
> the hourly streak-risk cron will send real pushes whenever one is due. Remaining 1.2
> work is only the items below.
- [user→agent] Resolve the two audit product calls: (a) should Daily Draft bypass the Pro
  sport gate on locked-sport days (like the daily Keep4/WhoAmI do) or keep paywalling at
  Start (current, safe default)? (b) onboarding copy still says "A fresh Keep4 and Who Am
  I? every day" — refresh to cover the four daily surfaces, or keep the two-daily framing?
- [user] Two-account TestFlight QA pass (`prompts/QA-testflight-social-flows.md`, ~25 min)
  — 1.2 is the right forcing function since pushes make the social flows fully testable.
- [user] Native-speaker pass over the Spanish catalog (418 machine-translated strings).
- Exit: a streak-risk push lands on a real device from the production cron chain.
  **Status 2026-07-17:** the 00:00:04 UTC cron run (8:00pm ET 07-16) sent a real push to the
  registered device — awaiting the user's confirmation it displayed. Caveat: that send was
  itself a manifestation of the local-vs-UTC-day suppression bug fixed the same session (see
  §8's 2026-07-17 entry); the fixed function still needs its deploy approved, after which the
  *correct* behavior is: push only on an evening the user hasn't played by 8pm local.

**1.3 — "Open the register": monetization switched on (M5 Phase B completion).**
Every rail exists (StoreKit 2 store, gating, paywall, server-validated entitlements,
deployed-but-inert `app-store-notifications` function). Nothing here is code-first; it's
ASC-first.
- [user] ~~Sign the Paid Applications agreement; create the four products~~ — **done,
  verified 2026-07-16**: all four exist in ASC (`Pro Monthly`/`Pro Yearly` in subscription
  group "Pro" id 22239725, both packs as IAPs 6791226005/6791225648) with product IDs
  exactly matching `StoreProduct`'s rawValues. All are `MISSING_METADATA` — still needed:
  **[user] price points** (a real product decision), then [agent] localized display
  copy + review screenshots + attach to a review submission.
- [agent] Set `APPLE_ROOT_CA_PEM` as an edge secret, point the production App Store Server
  Notifications URL at the function, sandbox-verify a purchase → webhook → `entitlements`
  row → client union end-to-end, and build the "companion client-transaction verify" belt
  (the documented fast-follow from Phase B's scope note) if the sandbox pass shows the race
  window matters.
- [agent] Paywall/pricing polish once real localized prices render (screenshot pass per
  AGENTS §5 — longest price strings, es locale).
- Exit: a sandbox Pro purchase unlocks hard mode/archive/sports on a second signed-in
  device via the server path alone (StoreKit store wiped).

**1.4 — "Seasons": M5 Phase F rating seasons — the deferred competitive spine.**
Explicitly deferred by the user 2026-07-14; do not start from inference.
- [user] The scoping conversation first — the open questions are already logged in
  `prompts/HANDOFF-next-agent-2026-07-12c.md` (cycle length/reset semantics, placement,
  what "rewards" concretely are, how seasons interact with the weekly leagues and the
  Pro entitlement it's meant to sell).
- [agent] Then: schema + RPCs following the `seasons`/`cohorts` and arcade-leaderboard
  precedents, season UI on Leagues/Profile, locked-value tests for placement/decay math.
- Exit: a full simulated 8-week cycle (clock-injected, unit-tested) plus a live season row
  visible in the app.

**1.5 — "Deep bench": content depth where the catalog is thinnest.**
All [agent], no gates — the release valve between user-gated versions; pull items forward
whenever a gate above stalls.
- Tennis daily/archive depth: the live archive holds exactly 2 tennis Keep4 themes today
  (audit observation) against 9,615 catalog rows — add themed slices (Grand-Slam eras,
  country cohorts) via the established themes.py pattern.
- Soccer league-cohort themes off the now-38-league catalog; more single-game themes for
  NBA/MLB now that the grain ships (the NBA hoopR games sweep needs its documented manual
  re-run to stay fresh).
- WhoAmI pool expansion (the curated entry list is the bottleneck for variety) + backlog
  #8 defunct-franchise styling, the last unshipped Tier-3 crumb.
- Exit: no sport's archive has fewer than ~6 themes; WhoAmI pool ≥ 2× current.

**Candidate pool (unscheduled — needs user appetite before any lands in a version):**
Home-screen widget (streak + daily countdown — pairs naturally with 1.2's pushes), App
Store product-page refresh (1.1's screenshots predate arcade formats/leaderboards),
Game Center achievements mirroring the XP system, iPad layout pass. None are commitments;
each is a conversation first.
