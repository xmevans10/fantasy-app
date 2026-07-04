# M3 — Real sports data pipeline

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Goal

Replace Playbook's hand-authored, bundled puzzle content and **invented** player `grade` values with
**real player-season data** ingested from a live sports source into the Supabase `puzzles` table.
After this milestone, the daily Keep4/Cut4 and Who Am I? puzzles are generated from real statistics —
the "true top 4" in a Keep4 sort reflects actual real-world performance, and Who Am I? clues are
factually correct — with no hardcoded player data in the shipping path (offline fallback is
regenerated from real data, not fiction).

## Why now

The repository seam + `RemotePuzzleRepository` (M2) already read puzzles from Supabase with a bundled
fallback. The only thing fake left is the *content itself*: ~5 hand-written puzzles with eyeballed
`grade` numbers. Real data makes the game credible, infinitely refreshable, and is the prerequisite
for leagues/versus (M4) to feel legitimate.

## Current state to build on

- `puzzles` table exists (`id, sport, format, content jsonb, active_date`), world-readable via RLS.
  `content` is the JSON of a `Keep4Puzzle` / `WhoAmIPuzzle` in the **camelCase** shape the Codable
  models decode (`BallIQ/Models/Keep4Puzzle.swift`, `WhoAmIPuzzle.swift`).
- `PlayerSeason` has a hidden `grade: Double` — sorting players by `grade` desc defines the correct
  Keep (top 4) / Cut (bottom 4). **This grade must now come from real stats.**
- `RemotePuzzleRepository` fetches `puzzles` filtered by `format`/`sport` and the client picks the
  daily puzzle deterministically (`PuzzleStore.dailyIndex`). Bundled JSON is offline fallback only.

## Scope

1. **Pick a data source** (see decision below) for NFL + NBA historical player-season stats.
2. **Build a server-side ingestion pipeline** that pulls stats, derives a `grade`, assembles themed
   puzzles, and upserts them into `puzzles`. Runs on a schedule (daily) and can backfill an archive.
3. **Define the grade formula** — a documented, deterministic mapping from real stats → 0–100 quality
   score, per sport/position/theme, so the correct ranking is defensible.
4. **A theme catalog** — editorial themes (e.g. "Elite scoring seasons", "Workhorse RB seasons") each
   resolved to a query that yields 8 player-seasons *close in grade* (so the blind sort is non-trivial).
5. **Who Am I? clue generation** from real data (era, position, teams, a real stat line, jersey,
   plus a curated "known-for" fact field where data alone is insufficient).
6. **Wire the client to real content** and regenerate the bundled offline fallback from real data.

## Key decisions (recommend, then confirm with the user)

- **Provider** (cost + ToS implications — surface to the user):
  - **NBA:** [balldontlie.io](https://www.balldontlie.io) — free tier, season averages + players + teams. Good default.
  - **NFL:** free options are thinner. Recommend **nflverse** public player-stats datasets (CSV/parquet on GitHub, widely used, factual stats) ingested periodically; alternative is a paid all-in-one like **API-Sports** (API-NFL/API-NBA) if the user wants one keyed provider for both.
  - Factual stats aren't copyrightable, but respect each provider's ToS and rate limits. We already avoid team logos/marks — keep it that way.
- **Where the pipeline runs:** prefer a **Supabase Edge Function** (Deno/TS) triggered by `pg_cron`, or a script in `tools/ingest/` run by a scheduled GitHub Action. Either way the **provider API key lives server-side only** (Edge Function secret / Action secret), never in the app.
- **Grade derivation:** compute server-side during ingestion and store the final `grade` in `content`. Keep the formula in one documented place; unit-test it (in the pipeline's language, or port the core to a tiny Swift test if you grade client-side — but server-side is preferred).
- **Daily selection:** keep the client's deterministic daily pick over the fetched pool; the pipeline just needs to keep the pool populated (and may set `active_date` for a true "puzzle of the day").

## Approach (outline — adapt as you learn)

1. Spike the chosen provider: fetch a season of player stats, confirm fields + rate limits.
2. Implement `grade(stats, sport, format, theme) -> Double` and a theme→query catalog; unit-test the
   grade ordering against a few known cases (e.g. a 2,000-yard rusher outranks a 1,100-yard one).
3. Assemble puzzles: per theme, pick 8 seasons clustered in grade; build `Keep4Puzzle`/`WhoAmIPuzzle`
   JSON; upsert into `puzzles` with `sport/format/active_date`.
4. Schedule it (cron/Action). Backfill ~30 days so the archive isn't empty.
5. Client: confirm `RemotePuzzleRepository` serves real content end-to-end; regenerate the bundled
   `keep4_puzzles.json` / `whoami_puzzles.json` fallback from real data so offline isn't fictional.

## Deliverables

- Ingestion pipeline (code under `tools/ingest/` or `supabase/functions/`), with a README on how to
  run, schedule, and configure secrets.
- Documented + tested grade formula and theme catalog.
- `puzzles` populated with real NFL + NBA content (≥ a few weeks of dailies per format).
- Client verified on real content; offline fallback regenerated from real data.

## Verification / success criteria

- `puzzles` table contains real, factually correct player-seasons; spot-check 3 puzzles by hand
  against a reference (e.g. Basketball/Pro-Football-Reference) — the Keep4 "true top 4" matches the
  real stat ranking, and Who Am I? clues are accurate.
- App (simulator) pulls and plays **real** puzzles for both formats, NFL + NBA; screenshot them.
- Re-running the pipeline refreshes content deterministically without dupes.
- All existing tests green; new grade/theme logic has tests.

## Hand-offs (cannot be done by the agent)

- Choosing/paying for the data provider and creating the API key.
- Adding the provider key as a server-side secret (Edge Function / Action).
