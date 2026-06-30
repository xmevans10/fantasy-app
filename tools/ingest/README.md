# BallIQ ingestion pipeline (M3)

Pulls **real** NFL + NBA player-season stats, derives a documented `grade`,
assembles Keep4/Cut4 and Who Am I? puzzles, and upserts them into the Supabase
`puzzles` table. Also regenerates the app's bundled offline fallback from real
data. No hand-authored player content, no invented grades.

## What it does

```
providers ─▶ grade ─▶ themes ─▶ assemble ─▶ validate ─▶ upsert (Supabase)
                                                      └─▶ write-fallback (bundled JSON)
```

- **Providers** (`providers/`)
  - `nfl_nflverse.py` — real season stats from [nflverse](https://github.com/nflverse/nflverse-data)
    `player_stats_season_{year}.csv` releases. No API key. Coverage 1999–present.
  - `nba_balldontlie.py` — live [balldontlie.io](https://www.balldontlie.io) season averages
    when `BALLDONTLIE_API_KEY` is set; otherwise the pipeline falls back to…
  - `seed.py` + `data/nba_seed.csv` — curated, **real** NBA seasons (hand-sourced from
    Basketball-Reference) so NBA content is factual even with no key.
- **`grade.py`** — the 0–100 quality score. Monotonic, weighted, documented reference scales per
  sport/position. The four highest grades in a Keep4 are the correct "Keep" pile.
- **`themes.py`** — editorial themes → real-data queries (position + min-stat filters) + which
  stats to show on each card.
- **`assemble.py`** — grades the pool, slices 8 seasons *clustered in grade* (so the blind sort is
  hard) with an unambiguous top-4/bottom-4 split, and builds the camelCase `content` JSON the Swift
  `Keep4Puzzle` / `WhoAmIPuzzle` models decode. Who Am I? clues are generated from
  `data/whoami_facts.json` (real era/teams/stat line/jersey + a curated "known-for" fact).
- **`upsert.py`** — PostgREST upsert with `on_conflict=id` + `merge-duplicates` → deterministic, no
  dupes on re-run. Requires the Supabase **service_role** key.

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

# upsert ~30 days of dailies into Supabase (needs SUPABASE_* env)
python3 -m tools.ingest.main --backfill 30 --upsert

# also populate the player_seasons creation catalog (for user-generated puzzles)
python3 -m tools.ingest.main --catalog --upsert
```

CLI flags: `--backfill N` (active_date archive span), `--nfl-years Y...`,
`--upsert`, `--catalog` (also upsert `player_seasons` + refresh its bundled
fallback `BallIQ/Data/player_seasons.json`), `--write-fallback`, `--dry-run`.

### Creation catalog (`player_seasons`)

User-generated Keep4 puzzles let creators pick from a catalog of **real** player-seasons.
`--catalog` upserts every gathered season into the `player_seasons` table (searched by the
app's create flow) and writes a trimmed bundled `player_seasons.json` so creation works
offline / before the table is populated. The grade that ranks a creator's picks is the same
formula as here, ported 1:1 to Swift (`BallIQ/Models/GradeFormula.swift`, locked by
`GradeFormulaTests`).

## Test

```bash
python3 -m venv .venv && .venv/bin/pip install -r tools/ingest/requirements.txt
.venv/bin/python -m pytest tools/ingest/tests -q
```

`test_grade.py` locks the grade ordering (e.g. a 2,000-yard rusher outranks an
1,100-yard one; Jordan's 37.1 ppg outranks Vince Carter's 27.6). `test_assemble.py`
checks shape, clustering, and the unambiguous keep/cut boundary.

## Schedule

`.github/workflows/ingest.yml` runs `pytest` on every push and `--backfill 1
--upsert` daily via cron. Configure repo **secrets**: `BALLDONTLIE_API_KEY`,
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.

## Secrets / hand-offs

- `BALLDONTLIE_API_KEY` — free, from balldontlie.io (optional).
- `SUPABASE_SERVICE_ROLE_KEY` — Supabase dashboard → Project Settings → API.
  **Server-side only**; never ship it in the app (the app only carries the anon key).
- The GitHub Action needs this repo pushed to GitHub with the three secrets set.
