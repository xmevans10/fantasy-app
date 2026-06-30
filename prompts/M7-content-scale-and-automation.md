# BallIQ — M7: Content scale + automation

Self-contained prompt for a fresh agent. Read [prompts/README.md](README.md) for shared context
(build/test commands, architecture, secrets policy). Assumes the repo **as of 2026-06-29 after M6
Phase A + the ESPN swap**: the project is now a git repo; NBA data comes **keyless from ESPN**
(`tools/ingest/providers/espn_nba.py` is primary, balldontlie + `nba_seed.csv` are fallbacks); the
daily-puzzle fetch is deterministic (`order=id`); grades display 0–100. Both suites green.

`fantasy-app` is **BallIQ**, a native SwiftUI iOS sports-trivia app. Supabase project
`nhccgufqwndtoasdbkhc` (MCP connected). Pipeline runs `python3 -m tools.ingest.main [...]`.

The theme of M7 is **breadth + letting the engine run on its own** — today every puzzle pool is tiny
and every upsert has been a manual CLI run.

---

## Task 1: Activate the daily pipeline (CI has never run)

`.github/workflows/ingest.yml` defines a correct daily cron that has **never executed** — the repo
was only just `git init`'d locally and was never pushed.

**Steps:** push to GitHub (honor `.gitignore` — never commit `Supabase.plist` or `tools/ingest/.env`);
add `SUPABASE_SERVICE_ROLE_KEY` (+ `SUPABASE_URL`) as Action secrets. **No balldontlie key needed —
ESPN is keyless.** Confirm the Action runs green and the daily/catalog upserts land in Supabase.

**Success:** a green scheduled (or manually-dispatched) run; row counts in `puzzles` / `player_seasons`
grow from a real CI run, not a laptop.

---

## Task 2: Broaden the pools (everything is too thin)

Today there are ~18 Keep4 + 6 Who Am I? puzzles **per sport**, and the NBA target list is just the
34 curated seed players. With ESPN keyless + historical (2003-04→present) and nflverse back to 1999,
breadth is now cheap.

- **NBA:** stop deriving `NBA_LIVE_TARGETS` only from the seed. Pull a broad, principled set — e.g.
  per-season statistical leaders, or all players above a minutes/games floor for each season — so the
  catalog reflects real role players, not just legends. ESPN has season-leaders endpoints; one stats
  call per athlete already returns every season (see `espn_nba.parse_seasons`).
- **NFL:** extend `DEFAULT_NFL_YEARS` (currently 2012–2023) toward 1999 as appetite allows.
- **Who Am I?:** the pool is ~12 entries total (`whoami_facts.json`); widen it from the now-larger
  catalog.

**Success:** materially larger pools (target: 50+ Keep4 and 25+ Who Am I? per sport), all real-data,
both suites still green, a screenshot of a richer Browse/daily surface.

---

## Task 3: Recalibrate the 0–100 bounds (records clip at 100)

`_FANTASY_BOUNDS` in `tools/ingest/grade.py` are hand-set constants. They were anchored to the *old*
small population, so a record season just clips at 100 (e.g. **Christian McCaffrey 2019 = 469 raw PPR
→ 100**, and the scale can't tell how far past the ceiling he is). Once Task 2 grows the population,
the bounds are stale.

Add a **`--recalibrate-bounds`** step that pulls fresh percentiles (p50/p90/p99/max per scale, with
the same games-played + position filters documented in
[docs/scoring-and-grading.md](../docs/scoring-and-grading.md)) and **prints** suggested `lo`/`hi`.
Keep it a print-only advisory by default — bounds are a product decision, not an auto-overwrite.

**If any constant changes:** maintain Swift↔Python parity across **all three** impls (`grade.py`,
`GradeFormula.swift`, `ScoringRule.swift`) and their tests — grades stay **baked at publish**, never
recomputed at read time.

**Success:** `--recalibrate-bounds` prints defensible percentiles against the grown population; any
adopted change keeps the three parity test suites green.

---

## Guardrails
- Stdlib-only at pipeline runtime (no new pip deps — that's why we hit ESPN directly, not via a
  wrapper). Tests via `.venv/bin/python -m pytest tools/ingest/tests`.
- Community `content` jsonb stays camelCase; never ship `service_role` in the app.
- Run both suites + a screenshot before claiming done.
