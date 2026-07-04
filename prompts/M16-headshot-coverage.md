# M16 — Headshot coverage: every player gets a real photo

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Goal

Every player-season the app ships should carry a real headshot photo. Today it doesn't:
NFL and NBA are at 100% coverage, but the three sports added this session (baseball,
soccer, tennis) are at **0%** — not "some gaps," the entire pool. Close that gap at the
source (the ingest providers/seed loaders), not by hand-patching the bundled JSON.

## Why now

`RawSeason.headshot` already flows end-to-end with zero plumbing left to build: it's
baked into `content["headshot"]` by `assemble.py`'s `_player_content`, decoded by the
Swift `PlayerSeason.headshot: String?`, and rendered by `Keep4CardView.headshotView`
(falls back to a neutral glyph when `nil` — so nothing is *broken* today, the app just
looks visibly less finished on 3 of its 5 sports). This is a pure content-completeness
gap, not an architecture problem, which makes it a clean, bounded task.

## Current state to build on (measured, not assumed)

Verified by loading the actual bundled `keep4_puzzles.json` and counting
`player.headshot` presence per sport:

```
nfl      224/224 have a headshot   (100%)
nba       48/48  have a headshot   (100%)
baseball   0/16  have a headshot     (0%)
soccer     0/16  have a headshot     (0%)
tennis     0/16  have a headshot     (0%)
```

Re-run this yourself before starting — the exact numbers will have shifted since M13's
seed data was small (~16 rows per new sport); confirm the shape of the problem still
holds (NFL/NBA solved, the 3 new sports at or near zero) rather than trusting this
snapshot verbatim.

**Why NFL/NBA are already solved** (the patterns to extend, not reinvent):
- `providers/nfl_nflverse.py` / `nfl_nflverse_games.py` read `headshot_url` straight off
  the nflverse CSV rows (often blank for older seasons).
- `providers/nfl_players.py` bio-registry join backfills the gaps nflverse leaves (~97%
  coverage on its own), merged in `main.merge_nfl_bio`.
- `providers/espn_nba.py` builds a headshot URL directly from the ESPN athlete id it
  already resolved for stats: `https://a.espncdn.com/i/headshots/nba/players/full/{id}.png`.

**Why the 3 new sports are at zero** — checked directly, don't re-derive:
- `providers/mlb_stats.py` (baseball's live provider) never sets `RawSeason.headshot` —
  the field is simply never populated in `_hitting_row`/`_pitching_row`.
- `providers/seed.py`'s `load_baseball()`/`load_soccer()`/`load_tennis()` (all three new
  sports currently route through seed data — soccer/tennis are seed-*only*, see M13's
  handoff notes in `prompts/README.md`) never set `headshot` either; the seed CSVs
  (`data/baseball_seed.csv`, `data/soccer_seed.csv`, `data/tennis_seed.csv`) don't even
  have a headshot column.

## Candidate sources (pre-verified live this session — start here, don't re-search blind)

Learned the hard way earlier this session (M13/sports work): don't assume an endpoint
works because it's plausible — curl it first. These three were actually verified:

- **Baseball**: MLB's own image CDN, confirmed working against a real player id already
  in `main.MLB_LIVE_TARGETS` (Aaron Judge, id `592450`):
  `https://img.mlbstatic.com/mlb-photos/image/upload/w_213,d_people:generic:headshot:silo:current.png,q_auto:best,f_auto/v1/people/{id}/headshot/67/current`
  → `200 image/jpeg`. This is the same person id `mlb_stats.py` already fetches stats
  with — no new id-resolution step needed, just build the URL in `_hitting_row`/
  `_pitching_row` alongside the stats.
- **Soccer**: the ESPN NBA-style pattern does **not** work —
  `https://a.espncdn.com/i/headshots/soccer/players/full/{id}.png` returned `404` for a
  real player (Haaland, id `253989`) when tested this session. Don't reuse the NBA
  pattern here; it needs its own investigation.
- **Soccer + Tennis**: Wikipedia's REST summary API works for both, verified against a
  real player from each sport:
  `https://en.wikipedia.org/api/rest_v1/page/summary/{Name_With_Underscores}` →
  `thumbnail.source` is a real Wikimedia Commons image URL. Confirmed working for both
  `Erling_Haaland` and `Novak_Djokovic` this session. Wikimedia Commons images are
  freely licensed (public domain or CC — verify the specific license per image before
  treating this as a blanket green light; Wikipedia's API response includes enough
  metadata to check, or cross-reference the file's page on commons.wikimedia.org).
  This could plausibly also serve as a **fallback** for baseball players the MLB CDN
  doesn't cover (unlikely for the curated `MLB_LIVE_TARGETS` roster, more likely if this
  task broadens the player pool later).

None of the above is a substitute for the agent doing its own verification pass — these
are leads to start from, confirmed working *for the specific players tested*, not a
guarantee they work for every player in scope.

## Scope

1. **Baseball**: add a headshot URL to `providers/mlb_stats.py`'s `_hitting_row`/
   `_pitching_row` using the MLB image CDN pattern above and the same `pid` already used
   for the stats call. Add it to `providers/seed.py`'s `load_baseball()` too (as a
   fallback path) — either hand-curate real URLs per seeded player, or have the seed
   loader construct the same CDN URL if the seed CSV gains a player-id column.
2. **Soccer + Tennis**: since both are seed-only (no live provider — confirm this is
   still true, or extend whichever live provider exists by the time this runs), add a
   headshot column to `data/soccer_seed.csv`/`data/tennis_seed.csv` populated from
   Wikipedia's summary API (a one-time fetch per curated player while writing the CSV,
   not a live per-run network call from `seed.py` — seed loaders elsewhere in this
   pipeline are pure/offline by design, don't make this one the exception without a
   good reason). Wire `seed.py`'s loaders to read the new column into `RawSeason.headshot`.
3. **Regenerate the bundle**: `python3 -m tools.ingest.main --write-fallback` and re-run
   this brief's coverage measurement to confirm all 5 sports hit 100%.
4. **Lock it with a test** so this can't silently regress: a pure test (mirrors
   `test_content_drift.py`'s spirit) asserting every player in the bundled
   `keep4_puzzles.json` — or, more sustainably, every seed/provider row for the sports
   that have gone through this fix — has a non-empty `headshot`. Decide whether that
   guard belongs in `tools/ingest/tests/` (checking the bundle directly) or as a
   provider/seed-loader unit test (checking the `RawSeason`s each one produces) — the
   former catches bundle drift, the latter catches provider regressions; this task
   probably wants both, following the two-sided pattern `test_content_drift.py`
   (bundle) and `test_grade.py`/`test_mlb_stats.py` (provider) already establish
   separately.

## Key decisions (recommend, then confirm)

- Whether to broaden the player pool at all in this pass, or strictly backfill headshots
  for the players already in `MLB_LIVE_TARGETS`/the 3 seed CSVs — **recommend strictly
  backfilling existing players only**, matching this session's own "M6 ships small, M7
  broadens later" pattern; don't conflate a coverage fix with a content-breadth task.
- Whether Wikimedia's licensing is clean enough to ship without a per-image manual
  review — recommend spot-checking a handful of the actual images this task ends up
  using (not just trusting the API returned *a* thumbnail) before treating this as settled.
- If MLB's CDN or Wikipedia's API turns out not to work for some players when the agent
  actually runs this (roster gaps, disambiguation-page collisions on common names,
  etc.), that's expected — fall back to leaving `headshot` empty for that specific
  player (the app already degrades gracefully) rather than blocking the whole task or
  hotlinking a lower-confidence image source without checking it first.

## Deliverables

- `mlb_stats.py` and `seed.py` (all three new-sport loaders) populate `RawSeason.headshot`.
- `data/soccer_seed.csv`/`data/tennis_seed.csv` gain a headshot column with real,
  verified image URLs.
- Regenerated bundle at 100% headshot coverage across all 5 sports (or as close to it as
  real source coverage allows — document any player left without one and why).
- A test (or two, per the two-sided pattern above) that fails if headshot coverage
  regresses.

## Verification / success criteria

- Re-run this brief's coverage-measurement snippet against the regenerated bundle;
  every sport should read at or near 100%.
- Spot-check a handful of the actual image URLs resolve (`curl -I`) and are visibly the
  correct player, not a disambiguation mismatch (a real risk with Wikipedia lookups on
  common names — verify a few, don't assume the name string always resolves to the
  right person).
- All existing tests green; new coverage-guard test(s) pass.
- Simulator screenshot: a baseball, soccer, and tennis Keep4 card now showing a real
  photo instead of the fallback glyph.

## Hand-offs (cannot be done by the agent)

- Pushing the updated `player_seasons`/`puzzles` content to the **live** Supabase
  project needs `--upsert` with `SUPABASE_SERVICE_ROLE_KEY`, which this environment
  doesn't have (same standing hand-off as every other milestone this session) — the
  regenerated bundled JSON ships in the app either way, so this isn't blocking, just
  incomplete for the live-content path until the user runs `--upsert` themselves or
  authorizes the Supabase connector.
- Confirming Wikimedia image licensing/attribution requirements if the user wants to be
  fully rigorous about it (a legal/product judgment call, not a technical one).
