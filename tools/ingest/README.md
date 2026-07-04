# Playbook ingestion pipeline (M3, expanded M7–M10, 5 sports)

Pulls **real** NFL + NBA + MLB (baseball) player-season (and single-game) stats — plus
seed-only soccer and tennis content, see below — derives a documented `grade`, assembles
Keep4/Cut4 and Who Am I? puzzles plus era baselines, and upserts them into Supabase. Also
regenerates the app's bundled offline fallback from real data. No hand-authored player
content, no invented grades.

> The living source of truth for the whole app (not just this pipeline) is
> [docs/BALLIQ_SPEC.md](../../docs/BALLIQ_SPEC.md) §3–§5 — read that first if you need the
> full picture (scoring invariants, era-adjustment math, community/daily template
> unification). This file covers just how to run and extend the pipeline itself.

## What it does

```
providers ─▶ grade ─▶ baselines ─▶ themes (+ generate) ─▶ assemble ─▶ validate ─▶ upsert (Supabase)
                                                                    └─▶ write-fallback (bundled JSON)
                                                                    └─▶ write-themes (keep4_themes.json)
```

- **Providers** (`providers/`, shared 24h on-disk cache in `.cache/`)
  - `nfl_nflverse.py` — real season aggregates from [nflverse](https://github.com/nflverse/nflverse-data)
    `player_stats_season_{year}.csv` releases. No API key. Coverage 1999–present.
  - `nfl_nflverse_games.py` — the same source at **weekly grain**, for single-game themes
    (M8). Bounded by `--game-years` since the weekly files are heavy.
  - `nfl_players.py` — bio join (draft round, height, age) that powers the niche-theme
    quirks in `curation.py` (undrafted gems, day-3 steals, towering, sub-6-foot, etc).
  - `espn_nba_pool.py` / `espn_nba.py` — a keyless ESPN pool of 853 NBA players
    (~1993–2026). **Primary NBA source since M7** — no API key needed, much broader
    coverage than the old balldontlie-only path.
  - `nba_balldontlie.py` — live [balldontlie.io](https://www.balldontlie.io) season
    averages when `BALLDONTLIE_API_KEY` is set. Fallback, not primary.
  - `seed.py` + `data/nba_seed.csv` — curated, **real** NBA seasons (hand-sourced from
    Basketball-Reference), the last-resort fallback so NBA content is factual even with
    no network/keys at all.
  - `mlb_stats.py` — real season hitting/pitching stats from the public, keyless
    [MLB Stats API](https://statsapi.mlb.com) (`stats=yearByYear`, one call per player per
    stat group returns their whole career). Verified live against real players before
    building. Primary baseball source; `seed.py`'s `data/baseball_seed.csv` is the fallback.
  - **Soccer and tennis are seed-only for now** (`seed.py`'s `data/soccer_seed.csv` /
    `data/tennis_seed.csv`) — curated from well-documented record/award seasons. No live
    provider exists yet: ESPN's soccer stats endpoint only ever returned international-duty
    splits (never club-season stats) when tested against real players, and the assumed
    tennis data-source repo doesn't exist under that account. A real club-stats source
    (e.g. football-data.org, needs an API key) is future work.
- **`grade.py`** — the scoring engine. Two families: fixed 0–100 weighted scales (legacy,
  still available as a "custom" author rule) and **fantasy-points rules** (`_FANTASY`,
  the shipped default — the grade IS the raw fantasy-point total, optionally
  era-adjusted). See spec §4 for the exact coefficients and the era-index formula.
- **`baselines.py`** — per-(sport, position, year) stat distributions over *qualified*
  seasons, including the `fantasy_total` pseudo-stat that era-adjustment divides by.
  Season-grain only — never feed it game-grain rows (see spec §4 baseline-hygiene note).
- **`themes.py`** — `KEEP4_THEMES`: the ONE template definition (sport, scale, positions,
  min-stat floors, on-card columns, pool cap, grain, era-adjusted flag) shared by the daily
  pipeline and the in-app creation flow (`Keep4Theme.swift` decodes the exported JSON —
  spec §5). 18 curated themes today.
- **`curation.py` + `generate.py`** — auto-generates additional bio/era-quirk themes per
  position (undrafted, day-3 steals, first-round, sub-6-foot, towering, age-33+,
  under-24 seasons) crossed with decades, keeping only themes with a viable pool. All
  generated themes grade on the same fantasy scales as the curated ones — none are
  custom/vibes-based.
- **`assemble.py`** — grades the pool, dedupes by person, slices 8 seasons *clustered in
  grade* (so the blind sort is hard) with an unambiguous top-4/bottom-4 split, and builds
  the camelCase `content` JSON the Swift `Keep4Puzzle`/`WhoAmIPuzzle` models decode.
  Cross-position NFL themes slice card columns per position (`columns_for`) so a WR card
  never shows "Pass Yds 0". Who Am I? clues come from `data/whoami_facts.json` (real
  era/teams/stat line/jersey + a curated "known-for" fact).
- **`era_analysis.py`** — a standalone validation script (not part of the normal pipeline
  run) that computed and sanity-checked the era-index table in spec §4. Run it directly if
  you're touching era-adjustment math; it's not invoked by `main.py`.
- **`upsert.py`** — PostgREST upsert with `on_conflict=id` + `merge-duplicates` →
  deterministic, no dupes on re-run. Requires the Supabase **service_role** key.

## Run

Requires Python 3.11+. The pipeline uses only the standard library at runtime
(tests need `pytest`).

```bash
# from the repo root
cp tools/ingest/.env.example tools/ingest/.env   # fill in keys

# build + validate + print samples, no writes
python3 -m tools.ingest.main --dry-run

# regenerate the bundled offline fallback (BallIQ/Data/*.json) from real data
python3 -m tools.ingest.main --write-fallback

# rewrite BallIQ/Data/keep4_themes.json only, no data pull (after a themes.py edit)
python3 -m tools.ingest.main --write-themes

# upsert ~30 days of dailies into Supabase (needs SUPABASE_* env)
python3 -m tools.ingest.main --backfill 30 --upsert

# also populate the player_seasons creation catalog (for user-generated puzzles)
python3 -m tools.ingest.main --catalog --upsert
```

CLI flags (`python3 -m tools.ingest.main --help`): `--backfill N` (active_date archive
span), `--nfl-years Y...`, `--game-years Y...` (single-game grain, bounded — weekly files
are heavy), `--upsert`, `--catalog` (also upsert `player_seasons` + refresh its bundled
fallback `BallIQ/Data/player_seasons.json`), `--write-fallback`, `--write-themes`,
`--dry-run`.

### Creation catalog (`player_seasons`)

User-generated Keep4 puzzles let creators pick from a catalog of **real** player-seasons.
`--catalog` upserts every gathered season into the `player_seasons` table (searched by the
app's create flow) and writes a trimmed bundled `player_seasons.json` so creation works
offline / before the table is populated. The grade that ranks a creator's picks is the same
`ScoringRule` engine as here, ported 1:1 to Swift (`BallIQ/Models/ScoringRule.swift` +
legacy `GradeFormula.swift`), locked by `ScoringRuleTests`/`GradeFormulaTests`.

## Test

```bash
python3 -m venv .venv && .venv/bin/pip install -r tools/ingest/requirements.txt
.venv/bin/python -m pytest tools/ingest/tests -q
```

`test_grade.py` locks the grade ordering and the raw fantasy-point values (locked-value
parity with `GradeFormulaTests`/`ScoringRuleTests` on the Swift side — see spec §4).
`test_export_themes.py` asserts the bundled `keep4_themes.json` equals `export_themes()`
(fails if `themes.py` changes without a `--write-themes` re-run). `test_generate.py` /
`test_filters.py` cover the niche-theme generator. `test_main.py` covers CLI wiring.

## Schedule

[.github/workflows/ingest.yml](../../.github/workflows/ingest.yml): `pytest` runs on every
push touching `tools/ingest/**`. On a daily 09:00 UTC cron (or manual
`workflow_dispatch`), it additionally runs `--backfill 30 --upsert` against the live
Supabase project — **not** `--catalog` or `--write-fallback`; those stay manual. Repo
**secrets** required for the live run: `BALLDONTLIE_API_KEY` (optional — only feeds the
NBA fallback provider), `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.

## Secrets / hand-offs

- `BALLDONTLIE_API_KEY` — free, from balldontlie.io. Optional: NBA content works without
  it via the ESPN pool primary + seed CSV fallback.
- `SUPABASE_SERVICE_ROLE_KEY` — Supabase dashboard → Project Settings → API.
  **Server-side only**; never ship it in the app (the app only carries the anon key).
- The GitHub Action needs this repo pushed to GitHub with the three secrets set.
