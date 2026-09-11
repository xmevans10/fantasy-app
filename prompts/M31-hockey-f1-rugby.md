# M31 — Three new sports: hockey, F1, rugby

> **Status 2026-09-03 — hockey and F1 in progress; rugby deferred on the user's call.**
> Phase 0 (shared plumbing), Phase 1 (NHL provider), Phase 2 (F1 provider) and the ingest/
> backend wiring are done and verified: 626 Python tests and 922 Swift tests green, the Grid
> membership-index migration applied live to `nhccgufqwndtoasdbkhc`. The committed sweeps
> (`data/nhl_seasons.csv`, `data/f1_seasons.csv`) were still running when this was written —
> until they land, `load_seasons()` returns `[]` and both sports render honest empty states.
> **Landed since:** both sweeps (`nhl_seasons.csv` 39,533 rows 1917-2025 with 6,213/6,218
> players carrying a real portrait; `f1_seasons.csv` 2,557 rows 1950-2025), the scoped
> catalog push (47,317 rows live, **zero** photo-less or team-less), and the measured
> `DraftSpin.fantasyAnchors` that replaced the provisional ones.
>
> **Also landed:** hockey + F1 crests (33/33 and 86/164) and `teams`/`leagues` upserts, Grid
> axis membership + cached index for both, Who Am I? and Journeyman pools AND dailies, a week
> of Grid boards each, and on-device verification of every surface.
>
> **[2026-09-05, later] Keep4 dailies are now live too — all four formats ship for both
> sports** (Keep4 2, Who Am I? 2, Journeyman 2, Grid 7 apiece). The full-gather path was
> bypassed rather than waited on: a hockey or F1 theme filters on `sport`, so the other five
> sports' rows cannot affect either candidate space, and driving `daily_puzzle`'s own
> `build_candidates`/`mint_batch`/`upsert` over a season pool loaded from the two committed
> CSVs mints them with zero network. Notably the picks came out as GENERATED niche themes
> (`gen-f1-driver-1980-williams-plain-01`, `gen2-hockey-g-all-rarely-beaten-wall-01`), which is
> end-to-end proof that the new `curation.SPORTS` cohorts feed the daily mint, not just the
> theme catalogue.
>
> *(historical)* **Still outstanding:** (a) the **Keep4 daily mint** — the manual `daily_puzzle` run was
> stopped after 24 minutes stalled inside the multi-sport gather (SSL handshakes, no cache
> writes, nothing upserted, so no partial state). **The same code is healthy in CI**: the last
> 12 scheduled `daily-puzzle.yml` runs all succeeded, 2-12 minutes each with two 51/53-minute
> outliers, including this morning's. So the stall was environmental to this machine, not a
> defect in the gather — and hockey/F1 Keep4 boards mint on the next cron with no further
> change, since `daily_puzzle.SPORTS` is `tuple(sorted(validate._VALID_SPORTS))`.
> The workflow had **no `timeout-minutes` at all**, so a real hang would have burned GitHub's
> 6-hour default and starved the Who Am I?/Journeyman steps queued behind it; it now carries a
> 90-minute job bound and a 60-minute bound on the one step that pulls providers. (b) the `--write-fallback` bundle
> regen, which needs the same gather and has the same non-blocking character (it only refreshes
> the OFFLINE fallback JSON; live content comes from Supabase).
>
> **The main remaining depth lever** is `curation.SPORTS`: the niche-theme generator
> (`generate.py` + `curation.py`) has cohorts for nfl/nba/baseball/soccer/tennis and none for
> hockey or F1, so the two new sports have only their 8 curated themes where NFL has
> hundreds of generated ones. Curated themes plus the daily rotation work today — one board
> per theme is the normal shape (`max_variants=1`; tennis behaves identically) — but a
> `SportCuration` for each is what turns 8 themes into real archive depth.

**Goal.** Take the app from 5 sports to 8: **NHL hockey**, **Formula 1**, and **rugby union** —
each a first-class citizen of `Sport`, the ingest pipeline, the daily mint, and every format
whose shape it can honestly support.

**Why now.** §9.3 sequences growth and new engagement features ahead of Grid depth and
monetization funnel work. Three sports is the widest single lever on both at once: it is net-new
content for existing users, three new audiences to acquire (hockey and F1 both have large,
underserved trivia communities and their own seasonal calendars to time ASO against), and the
single strongest argument the Pro tier has ever had — free stays `{nfl, nba}`, so this triples
what a subscription unlocks without touching a price.

---

## 1. The honest tier split — read this before scoping anything

The three sports are **not** equal, and the difference is data availability, not effort. All
claims below were verified live on 2026-09-03, not recalled.

| Sport | Source | Probe result | Verdict |
|---|---|---|---|
| **Hockey** | `api.nhle.com/stats/rest/en/skater/summary` + `/goalie/summary`, keyless, `cayenneExp=seasonId=…` | 200; full-league season rows returned for **1917-18**, 1985-86 and 2023-24. Skater rows carry goals/assists/points/+-/PIM/shots/GP/`teamAbbrevs`/`positionCode`; goalie rows carry W/L/GAA/SV%/SO/saves | **First class.** Deeper history than MLB (1917 vs 1955) |
| Hockey media | `assets.nhle.com/mugs/nhl/{season}/{TEAM}/{id}.png`, `assets.nhle.com/logos/nhl/svg/{TEAM}_light.svg`, `a.espncdn.com/i/teamlogos/nhl/500/{abbr}.png` | all 200 | Real headshots + crests, no curation |
| **F1** | `api.jolpi.ca/ergast/f1/…` (the maintained Ergast mirror) | 200; 1990 driver standings with points/wins/constructor; `/results/{pos}` for podium counting; results rows carry `grid` | **First class.** 1950–present, ~900 drivers |
| F1 caveat | `ergast.com/api/f1/…` (the original) | **404 — dead.** | Use Jolpica only. Its `qualifying` table is empty pre-~1994, so derive **poles from `grid == "1"` in results**, not from `/qualifying/1` |
| **Rugby** | ESPN rugby site API (`/sports/rugby/{leagueSlug}/…`) | teams + logos + hex colors: **200**. `…/teams/{id}/roster` → `"athletes":[]`. `…/statistics` → `categories:[{"name":""}]`. core API `…/seasons/2024/athletes` → `count: 0` | **No player stats exist.** Teams/crests only |
| Rugby fallback | Wikidata SPARQL, `P1350` (matches played) over `Q14089670` (rugby union player), caps > 40 | **0 rows** — the property is not populated for rugby | Not a source |

**Consequence, stated plainly:** hockey and F1 can ship at full parity with NFL/NBA/MLB — every
format, real headshots, real crests, full history. **Rugby cannot.** It lands in the same
hand-curated seed tier as tennis and soccer GK/DF (§3's documented ceiling), and its format
surface must be sized to that rather than pretended around. This is the §1 product-feedback
principle 6 call — *data maximalism with honesty; hard ceilings get documented plainly* — and it
is the one thing in this plan not to negotiate with.

### Recommendation on sequencing

Ship **hockey → F1 → rugby**, in that order, as three independently releasable slices. Hockey
first because it is the highest-value and lowest-risk (a keyless full-league API in exactly the
`RawSeason` shape the pipeline already wants), F1 second (equally clean data, but new modelling
questions — see §3), rugby last and smallest. If rugby's curated pool proves too thin to carry a
daily mint, **cut it to Who Am I? + Journeyman only** rather than shipping empty Keep4 boards;
that decision has a hard gate in Phase 4's exit criteria, not a vibe.

---

## 2. Good news: no schema migration is needed for the sport itself

`player_seasons.sport`, `puzzles.sport`, `*_history.sport`, `teams.sport` are all `text not null`
with **no CHECK constraint** — a new sport is a new string, not a DDL change. But two
already-applied migrations hardcode the sport list *inside function bodies*, and both will
silently skip the new sports until replaced:

- `supabase/migrations/0014_grid_membership_index_cache.sql:193` —
  `foreach v_sport in array array['nfl','nba','baseball','soccer','tennis']` inside
  `refresh_grid_membership_index_cache()`.
- `supabase/migrations/0016_bot_ladder.sql:170` — the same literal array seeding bot ladder rows.

Plus `supabase/functions/_shared/sport.ts`'s `SPORT_ROTATION` (and its `sport.test.ts`), which
drives the daily-drop push.

---

## 3. Modelling decisions (settle these before writing providers)

**Hockey.**
- Positions: keep the API's `positionCode` (`C`/`L`/`R`/`D`) plus `G` for goalies. Two disjoint
  stat families — skater (goals, assists, points, plusMinus, PIM, shots, GP) and goalie (wins,
  GAA, savePct, shutouts, GP) — exactly the baseball H/P shape, so `positionStatFamilies` and
  `positionStatTemplates` port directly. **GAA is invert-scored** (lower is better), like ERA.
- `teamAbbrevs` can carry multiple teams for a traded player-season (`"STL"` vs `"STL,DET"`).
  Decide once: split into one row per team, or keep the primary. Recommend **primary team =
  first listed**, with the multi-team string preserved for Journeyman stint reconstruction.
- Grain: season now; the single-game grain via boxscore is a follow-up, not M31.

**F1.**
- A "player-season" is a **driver-season**: `year`, driver, constructor, points, wins, podiums,
  poles, races, championship position, DNFs. Position is a single value (`"Driver"`), exactly
  like tennis's `"Player"` — so like tennis and NBA, F1 gets **no** `positionStatFamilies` entry.
- `hasTeams` is **true** and `hasClubCareers` is **true** — the constructor *is* the club, and a
  driver's constructor history (Hamilton: McLaren → Mercedes → Ferrari) is one of the best
  Journeyman boards in the app. This is the key insight that makes F1 worth more than tennis.
- Crests: ESPN's `/sports/racing/f1/teams` returns **current** constructors only (with hex
  colors). Historic constructors (Brabham, Tyrrell, Lotus) must come through the existing
  Wikimedia + Storage-rehost path (`providers/wikimedia.py`, `logos.py`, `teams.py`) — do **not**
  hardcode a constructor→URL map, per the standing team-identity rule.
- Request budget: Jolpica is rate-limited. Per year that's 1 standings call + 3 `/results/{1,2,3}`
  calls ≈ **~300 requests for all of 1950–present** — a one-time cost behind the 24h disk cache;
  daily CI then refreshes only the current season.

**Rugby.**
- Union only. Model leagues the way soccer does (country-keyed `league` column): Premiership,
  Top 14, URC, Super Rugby, Six Nations.
- Curated `data/rugby_seed.csv` in the tennis mould. Positions: collapse to `FW`/`BK` unless the
  curated set justifies finer grain.
- Crests **are** available from ESPN (`a.espncdn.com/i/teamlogos/rugby/teams/500/{id}.png`,
  verified 200) — keyed by numeric team id like soccer, so they belong in the `teams` table via
  `teams.py`, not in a Swift-side id map.

---

## 4. The touchpoint checklist

Derived by walking tennis's full footprint (the most recently added sport) — 32 Swift files, 40
Python files, 4 Supabase artifacts. Each new sport touches the same set.

### 4a. Ingest (`tools/ingest/`)
| File | What changes |
|---|---|
| `providers/nhl_stats.py` **(new)** | `refresh()` / `load_seasons()` over skater+goalie summary, all seasons |
| `providers/f1_ergast.py` **(new)** | Jolpica standings + `/results/{1,2,3}`, poles from `grid` |
| `providers/seed.py` + `data/rugby_seed.csv` **(new)** | `load_rugby()`, mirroring `load_tennis()` |
| `main.py` | imports, per-sport pull + print line, merge into `all_seasons`, and the `--grid` / `--journeyman` `choices=[…]` lists (≈ lines 887, 898) |
| `themes.py` | ≥2 curated `KEEP4_THEMES` per sport, with `columns`/`fmt` (`dec2` for SV%/GAA). Theme **titles** must be dash-free — `test_no_em_dashes.py` enforces house style on every string the pipeline emits |
| `grade.py` | new `_SCALES` keys: hockey skater, hockey goalie (GAA/GA inverted), F1 driver, rugby |
| `whoami_pool.py` | `MIN_SEASONS`, `COHORTS[(sport, position)]`, `TEAM_SPORTS`, team-name map |
| `journeyman.py` | `MIN_STINTS`, `COVERAGE_MARGIN`, franchise-rename table (NHL has many: ATL→WPG, PHX→ARI→UTA, HFD→CAR) |
| `grid_axes.py` | axis specs, `POSITION_LABELS`, `TEAM_MOBILE_SPORTS`, `LEAGUE_SCOPED_SPORTS` (rugby joins soccer) |
| `career.py` | career-aggregate rules — sums vs derived rates (career SV% and GAA are **not** means of season values) |
| `periods.py` | season-label convention (NHL is a split year, `2023-24`, like soccer) |
| `teams.py` | `US_SPORTS`, `_ESPN_LOGO_SLUG` (`hockey → nhl`), league rows, F1/rugby club rows |
| `headshots.py` | `_ESPN_LEAGUE` map, Wikimedia sport map, NHL mugs URL pattern |
| `ladder.py` / `health.py` / `shapes.py` / `daily_puzzle.py` / `whoami_clues.py` / `validate.py` | sport lists, expected `(sport, position)` coverage pairs, shape cohort specs, clue dimensions |
| `tests/` | `test_nhl_stats.py`, `test_f1_ergast.py` (new, fixture-driven, no network) + extend `test_new_sports.py`, `test_export_themes.py`, `test_teams.py`, `test_journeyman.py` |

### 4b. App (`BallIQ/`)
| File | What changes |
|---|---|
| `Models/Sport.swift` | new cases + `displayName`, `symbol`, `cardFill`, `onCardFill`, `hasTeams`, `hasClubCareers`, `espnLeagueSlug`, `positionStatFamilies`, `positionStatTemplates(+Game)` — **and** the parallel `SportFilter` enum (case, `title`, `includes`, `sport`) |
| `DesignSystem/Theme.swift` | `sportHockeyFill` / `sportF1Fill` / `sportRugbyFill` + their `onSport…` pairs |
| `DesignSystem/TeamColors.swift`, `CountryFlags.swift` | fallback palettes; F1 driver nationality flags |
| `Models/ScoringStat.swift`, `ScoringKind.swift`, `ScoringRule.swift` | per-sport stat catalogs, ALL-CAPS badge text, and the per-sport "ranked by…" explainer copy |
| `Models/DraftSpin.swift` | formation (F1 = a 3-slot `"Driver"` shape like tennis), `SeasonShape`, `FantasyAnchors`, scale key |
| `Models/Blitz.swift`, `Features/Blitz/*` | format availability per sport, board-count estimation |
| `Features/Grid/GridLocalGenerator.swift`, `GridMembershipIndex.swift` | axis eligibility + team-grain rules |
| `Features/Create/CreateKeep4View.swift`, `Onboarding/OnboardingView.swift`, `Keep4/ScoringDetailSheet.swift` | pickers and explainer sheets |
| `Store/Entitlements.swift` | `freeSports` stays `{.nfl, .nba}` — all three new sports are Pro |
| `Data/Repositories/*`, `DebugLaunch.swift` | catalog/versus/puzzle sport handling, screenshot flags |
| `BallIQTests/` | `SportLogoTests`, `GridLocalGeneratorTests`, `BlitzTests`, `ScoringKind/Rule/BreakdownTests`, `EntitlementsTests` |

New files need **no** pbxproj edit (synchronized file groups).

### 4c. CI workflows — the gap this checklist originally MISSED
Several `.github/workflows/*.yml` files hardcode a sport list on the command line, where a
missing entry fails **silently and only in production, days later**. M31 shipped without these
and hockey/F1 Grid boards would have simply run out after the manual 7-day backfill:

| file | what breaks if the sport is missing |
|---|---|
| `ingest.yml` (daily 09:00 UTC) | `--grid <sports>` — no daily Grid board for that sport, ever |
| `weekly-refresh.yml` (Tue 10:00 UTC) | `--grid <sports>` re-mint. Was **already** missing `baseball`, a shipped sport, before M31 touched it |
| `daily-puzzle.yml` | safe — derives its sports from `validate._VALID_SPORTS`, no hardcoded list |
| `headshot-backfill.yml` | matrix of sports for the portrait sweep |

Also confirmed while fixing this: `daily-puzzle.yml` had **no `timeout-minutes` at all**, so a
hung provider inherited GitHub's 6-hour default and starved the two fast mints queued behind
the slow one. Now bounded at 90 (job) / 60 (the provider-pulling step).

### 4d. Backend + content ops
- New migration replacing `refresh_grid_membership_index_cache()` and the bot-ladder seeder's
  sport arrays; mirror into `supabase/schema.sql` in the same change.
- `supabase/functions/_shared/sport.ts` `SPORT_ROTATION` + `sport.test.ts`.
- `teams`/`leagues` rows + Storage crest rehost; headshot rehost + `headshot-backfill.yml` matrix.
- Grid membership index backfill — **budget ~45s/board**; 300 boards/sport ≈ 37 min each.
- Daily mint per sport, then `--grid-days` backfill.

### 4e. Docs + marketing
`docs/BALLIQ_SPEC.md` §1/§3/§8/§9.3, `tools/marketing/make_store_screenshots.py`,
`daily_content.py`, App Store keywords/screenshots for the new sports.

---

## 5. Product side effects to decide, not discover

1. **Push cadence dilutes.** `SPORT_ROTATION` is round-robin: 5 sports → each sport's daily-drop
   push lands every 5 days; 8 sports → every 8. Either accept it, or make the rotation
   preference-aware using `profiles.primary_sport` / `FavoriteTeams`.
2. **Nightly mint cost scales linearly** — Keep4 + Who Am I? + Journeyman + shapes, per sport per
   night, 5 → 8. Check `daily-puzzle.yml` runtime headroom before Phase 4.
3. **Home's sport pager grows to 8 pages.** Worth a design pass; 8 horizontal pages is past the
   point where a pager reads as browsable.
4. **Per-sport Elo dilutes.** Ratings are per-sport; 8 ladders over the same user base means
   thinner ranked pools per sport. Consider whether new sports start unranked for one season.

---

## 6. Phases, with exit criteria

Verification-first: each phase states what "done" *is*, and the next phase does not start until
the check passes.

**Phase 0 — Shared plumbing (orchestrator, no subagents).** `Sport.swift` + `SportFilter` + theme
colors + `Entitlements` for all three sports at once; the Supabase migration; `sport.ts`.
*Exit:* app builds, full test suite green, three new pills render on Home with correct colors and
Pro locks, all showing honest empty states.

**Phase 1 — Hockey ingest.** `nhl_stats.py` + themes + scales + pool/journeyman/grid config.
*Exit:* `python3 -m tools.ingest.main --dry-run` prints a hockey row count in the tens of
thousands; `pytest tools/ingest` green; every hockey theme produces a `validate()`-clean puzzle.

**Phase 2 — F1 ingest.** `f1_ergast.py` + constructor identity via Wikimedia/Storage.
*Exit:* ~900 drivers × season rows 1950–present; a Hamilton Journeyman board renders the real
constructor path with real crests.

**Phase 3 — App surfaces for hockey + F1.** Two `balliq-swift-feature` subagents in parallel
(disjoint file ownership: one owns Grid + Blitz, the other owns Draft & Spin + Create +
scoring/explainer copy).
*Exit:* every format's setup screen offers both sports and serves a real board; cards show real
headshot + crest + position-correct stat line (principle 1 and principle 7 both hold);
screenshots captured on device.

**Phase 4 — Rugby, scoped to its ceiling.** Curated `rugby_seed.csv` + ESPN crests.
*Exit gate, and it is a real gate:* if the curated pool cannot fill ≥2 Keep4 themes with
`validate()`-clean boards **and** ≥30 Who Am I? subjects, ship rugby as Who Am I? + Journeyman
only and document the ceiling in §3 — do not ship thin Keep4 boards.

**Phase 5 — Content ops + release.** Logo/headshot rehost, grid backfill, mint, spec update, App
Store metadata, build.
*Exit:* live daily boards for all shipped sports on three consecutive days with zero fallback
picks; headshot coverage ≥ the bar the existing coverage summary enforces.

---

## 7. Dispatch plan

- Phases 1, 2, 4 → `balliq-data-provider`, one provider per agent, sequentially (they share
  `main.py`'s merge chain and `themes.py`, so parallelising them courts conflicts).
- Phase 3 → two `balliq-swift-feature` agents in parallel, with the file-ownership split above.
- Phase 0 and 5 stay with the orchestrator — shared plumbing and live production writes.

## 7.3 WIRE SAFETY — read this before releasing hockey/F1 (2026-09-06)

**hockey and F1 are fully ingested but deliberately NOT minted.** `puzzles` has zero rows for
either sport, on purpose. Everything else is live: 47,317 catalog rows, 197 teams, 53,283
`grid_axis_membership` rows, cached membership indexes, and the Who Am I?/Journeyman pools.

### What went wrong

Minting them was a live regression, caught and reverted the same day. `Sport` on the client is
a plain `String` raw-value enum with **no unknown-case fallback**, and the archive fetch
(`RemotePuzzleRepository.fetch`) adds no `sport` predicate when the user is on the "All"
filter — `BrowseView`'s default. It decodes the pool as an **array** under `try?`. One row
naming a sport an installed build has never heard of throws, the whole array returns nil, and
that user's archive silently falls back to stale cache or the bundled JSON.

Proven, not theorised: decoding `[{"sport":"nfl"},{"sport":"hockey"},{"sport":"nba"}]` against
a `Sport` enum lacking `hockey` returns nil for the entire array. Every App Store build through
1.8.3 is in that position. The sport-FILTERED paths (Home's per-sport pager) are unaffected.

This is the identical hazard `validate._VALID_KINDS` already documents for `ClueKind` — "a
seventh value coming back from Supabase fails the decode for the whole fetch". The M31 plan's
own §4 checklist did not carry it across to `Sport`, which is why it was missed.

### The gate

`validate.WIRE_SAFE_SPORTS` is the single switch. All four mint paths read it:

| path | how |
|---|---|
| `daily_puzzle.SPORTS` | derives from it directly |
| `daily_whoami` | imports `daily_puzzle.SPORTS` |
| `daily_journeyman` | `set(journeyman.MIN_STINTS) & WIRE_SAFE_SPORTS` — an intersection, so tennis still stays out on its own no-clubs merits |
| `main.run_grid` | filters even when a sport is named EXPLICITLY, because the workflows pass a literal list |

Locked by `tests/test_wire_safe_sports.py`, including one test that documents the current
release state and is meant to be updated deliberately.

### To release hockey and F1

1. Ship a build whose `Sport` enum knows both (already in `main`, unreleased).
2. Wait until that build is the floor in the wild, or accept the archive degradation for the
   stragglers — the same judgement `daily-puzzle.yml`'s lookahead comment makes about
   minted-ahead rows.
3. Add `"hockey"`/`"f1"` to `WIRE_SAFE_SPORTS`, update `test_m31_sports_are_ingested_but_held_back`.
4. Re-mint — nothing else changes. `--grid hockey f1 --upsert`, and the nightly crons pick up
   the rest on their own.

**Also fixed while here:** `--grid-days 7` was used for the original hockey/F1 Grid backfill,
which `ingest.yml` explicitly warns against ("extra lookahead is unreleased content visible to
any client without a future-row filter"). Those rows are gone with the rest; keep to the
default 2 on re-mint.

## 7.4 The gather stall: root cause and fix (2026-09-05)

The manual `daily_puzzle` run that stalled for 24 minutes was **not** environmental after all,
though CI's healthy 9-12 minute runs made it look that way. `providers/http.py`'s `_get` used a
**60-second socket timeout with 4 retries** and backoff capped at 30s. Measured against a
black-holed host, that is **202.6 seconds to give up on a single URL** — cheap for one call,
ruinous inside a per-player loop. `espn_nba.fetch_by_ids` walks a ~900-id pool, so a couple of
dozen unreachable ids back to back is exactly 24 minutes of TLS handshakes with no cache writes,
which is precisely the symptom observed.

Why CI never showed it: GitHub runners reach these endpoints cleanly, so the pathological path
is never taken there. It is a latent landmine, not a local quirk — any transient network
degradation on the runner would have produced the same multi-hour job.

Two fixes, both landed with tests:
- `http._get`: timeout 60s -> **20s**, retries 4 -> **3**, backoff cap 30s -> **15s**. Worst
  case per URL drops from ~203s to ~50s. Safe for the large nflverse CSV downloads, because
  `urlopen`'s timeout is a per-blocking-operation socket timeout, not a total-transfer budget —
  a steady stream keeps resetting it.
- `mlb_stats.fetch_by_ids`: gained the **circuit breaker `espn_nba` already had**
  (`_MAX_CONSECUTIVE_FAILURES = 15`) — after 15 consecutive failures it stops and returns the
  partial pool rather than paying retry cost per id to the end of a several-hundred-id list.
  `espn_nba` had this and `mlb_stats` did not; the asymmetry was the gap.

Guarded by 7 new tests, including one that bounds worst-case wall clock per URL so a future
timeout/retry change cannot silently reintroduce the multiplication.

## 7.5 Follow-ups found during the build (not blockers)

- **One already-minted hockey Grid board is degenerate and was deliberately left in place.**
  `grid-hockey-2026-09-06` drew rows `['ARI','PHX','2020s']` — two crest chips for one
  franchise (Phoenix/Arizona Coyotes). The CLASS is fixed: `grid._franchises_distinct` now
  rejects any board putting one franchise on two axes, covering NFL's OAK/LV too, with a test.
  The existing board was not overwritten because `run_grid`'s own rule is "once a (sport, date)
  row exists, never re-mint it" (generation is only deterministic for a fixed catalog), and it
  is a playable board — every cell has 1-5 answers — not a broken one. To drop it anyway:
  `delete from puzzles where id = 'grid-hockey-2026-09-06';` plus its `grid_history` row.

- **[DONE 2026-09-05] Era-adjusted hockey now works**, and the fix generalised the mechanism.
  `baselines.QUALIFY`/`TOTAL_SCALE` mapped a sport to exactly ONE grading scale, which hockey
  cannot be expressed in (skaters and goalies share no stat key) — the same reason baseball and
  soccer had no era-adjustment either. Both dicts are now role-aware: a flat sport still stores
  a bare tuple/string and resolves through the identical code path (NFL/NBA baselines verified
  byte-identical, 9,163 rows on both sides), while hockey maps `skater`/`goalie` to their own
  gate and scale. Hockey `fantasy_total` went 0 -> 497 rows. The new `hockey-scoring-forwards-era`
  theme fixes the symptom, independently reproduced: **1980s share 5/8 -> 2/8**, spread across
  five decades instead of one dominating, surfacing McDavid, Jagr, MacKinnon and Sakic beside
  Gretzky. Goalies gate on `games_started >= 25` rather than `games` (a #1 still splits starts
  with a backup); that column is populated for 100% of goalie seasons back to 1917, so the gate
  excludes no era. Baseball and soccer are deliberately NOT enabled — the path is open, the
  content verification is separate work.

  *(original entry)* **Era-adjusted hockey themes need `fantasy_total` baselines first.** NHL scoring levels swing
  enormously across eras, and it shows: the all-time `hockey-scoring-forwards` board comes out
  5-of-8 from the 1980s (Gretzky 1981, Lemieux 1988, Bossy 1981 …). That is defensible — those
  genuinely were the highest-scoring seasons ever — and the era-scoped themes
  (`hockey-eighties-offense`, `hockey-modern-snipers`) already give the rotation variety, so it
  is not a content bug. But §4's `era_adjusted` flag is the designed answer and does not work
  for hockey yet: `baselines.compute_baselines` produces 5,518 hockey rows covering the raw
  stats and **no `fantasy_total` pseudo-stat**, which is the one era-adjustment reads. Wiring
  that is the fix; guessing at hand-tuned thresholds is not.
- **[DONE 2026-09-05] F1 constructor crests: 86 -> 124 of 164 live**, 28 of the top 30 by
  driver-season volume (was 19), **88.9% volume-weighted**. The earlier "real ceiling" claim
  was wrong: Brabham, Tyrrell, Jordan and Minardi all DO have logos — in the Wikipedia
  **infobox** wikitext, which neither Wikidata P154 nor the page lead image exposes. Parsing
  the infobox (three wikitext shapes, all handled) plus a disambiguation-page fallback for the
  one constructor whose Ergast URL points at a disambig page (Surtees) is what closed the gap.
  The wrong-in-kind cases are fixed too, verified by filename: Ferrari now resolves
  `Prancing_horse.svg` instead of the "Scuderia Ferrari HP" sponsor lockup, Williams
  `Logo_Williams_F1.png` instead of the Atlassian one, and Maserati a wordmark instead of a
  photo of a road car. A shape/dimension heuristic was deliberately NOT used for the sponsor
  cases — a 2026 lockup is exactly as logo-shaped as a correct marque crest — so those go
  through a small committed override table (`data/f1_constructor_logo_overrides.csv`), the same
  device soccer already uses for club codes.
  Residual: 124 rehosted vs 138 resolved, i.e. 14 sources resolve but fail to download; and 26
  constructors have no source at all. A crest-less stint still renders club name + years, which
  M22's own reasoning says is what carries fairness.

## 8. Follow-up worth doing regardless

This session had to reconstruct the "how do I add a sport" checklist by grepping tennis's
footprint across 70+ files. That checklist should not have to be re-derived a fourth time —
promote §4 into a standing `docs/adding-a-sport.md` (or an `AGENTS.md` section) once M31 has
proven it against three real sports and corrected whatever it got wrong.
