# Playbook — Scoring & Grading Reference

The authoritative explanation of how a player-season earns its **grade** (the hidden 0–100 number
that defines the "true" Keep/Cut ranking) and how that relates to the **game score** the player sees.
Current as of 2026-06-29, after the M5 PPR overhaul + 0–100 display normalization shipped.

Hand this to a fresh agent or read it before touching anything under `tools/ingest/grade.py`,
`BallIQ/Models/GradeFormula.swift`, or `BallIQ/Models/ScoringRule.swift`.

---

## TL;DR — answers to the common questions

1. **"What is the grade a percentile of — season, decade, all-time?"**
   All-time, pooled across *every year currently in the catalog* (NFL 2012–2023 from nflverse; NBA the
   34-season curated seed, 1987–2024). Not per-season, not per-decade, not era-adjusted on the shipped
   surface. The bounds are static constants calibrated against that whole population.

2. **"When we ingest new data, do we auto-grade it?"**
   Yes — grading is **inline** in the pipeline (no separate grading step). The 0–100 *bounds*, however,
   are fixed constants, not recomputed per run. And the pipeline is not auto-*triggered* yet (see
   [Known gaps](#known-gaps--next-milestones)).

3. **"How do we grade single-game performances?"**
   We don't. The entire data model is **season-level only**. Single-game grading is a net-new milestone.

4. **"Still PPR?"**
   Yes. `nfl_skill_ppr` is full PPR, unchanged. The 0–100 step is a monotonic transform on top of the
   same raw points, so it cannot alter the ranking.

---

## The two numbers a player sees (don't conflate them)

| | **GAME SCORE** (the big "FINAL" number) | **GRADE** (the per-card chip) |
|---|---|---|
| What it measures | how well *you* sorted the 8 cards | how good the *player-season* actually was |
| Source | `Keep4Scoring` — `correctCount × 250 + 1000` perfect bonus | `PlayerSeason.grade`, computed from stats |
| Range | 0–2000 | 0–100 |
| Where | result page header | small chip on each card, revealed post-submit |

This doc is about the **GRADE**. The game score is just `correctCount × 250 (+1000 perfect)` and lives
in `Keep4Scoring`.

---

## How a grade is computed

Two layers. The first decides *who wins*; the second decides *what number is shown*.

### Layer 1 — raw fantasy points (the ranking truth)
Each scale sums `stat × per_unit` over a fixed set of terms. These are real fantasy formulas:

- **`nfl_skill_ppr`** (WR/RB/TE) — full PPR:
  `receptions×1 + receiving_yards×0.1 + receiving_tds×6 + rushing_yards×0.1 + rushing_tds×6`
- **`nfl_qb_fantasy`** — standard passing + rushing:
  `passing_yards×0.04 + passing_tds×4 + interceptions×(−2) + rushing_yards×0.1 + rushing_tds×6`
- **`nba_fantasy`** — DraftKings-ish, per-game (no TOV in our data):
  `ppg×1 + rpg×1.2 + apg×1.5 + spg×3 + bpg×3`

The Keep/Cut split is decided by ranking on this raw total. The sign of a penalty (interceptions)
lives in its coefficient — there is no separate "lower wins" flag for points terms.

### Layer 2 — 0–100 display normalization
The raw total is min-maxed into 0–100 *for display only*:

```
grade = round( 100 × clamp( (raw − lo) / (hi − lo), 0, 1 ), 1 )
```

Because min-max is **strictly monotonic in `raw`**, applying it cannot change relative order — the
Keep/Cut split is mathematically identical to ranking by raw fantasy points. It exists purely so the
number is legible: an NFL season total (~330) and an NBA per-game total (~63) were on wildly different
scales and "looked broken" side by side. Now everything reads on the familiar 0–100 a fan expects.

### The bounds (`_FANTASY_BOUNDS` in `grade.py`)

| Scale | lo | hi | Calibrated against |
|---|---|---|---|
| `nfl_skill_ppr` | 40 | 450 | WR/RB/TE, games≥8: p50 99, p90 228, p99 338, max 469. lo≈fringe part-timer. |
| `nfl_qb_fantasy` | 100 | 450 | QB, games≥8: p50 232, p90 332, p99 402, max 422. lo≈spot-starter. |
| `nba_fantasy` | 15 | 75 | Reasoned from fantasy-basketball benchmarks, **not** the seed's own min/max. |

The percentiles were pulled with live SQL against the full `player_seasons` Supabase table (no year
filter; just a games-played floor + position filter). NBA was deliberately **not** self-anchored to its
own 34-season "legends" seed — that sample already skews great, so anchoring to it would compress the
scale and break once a full-league live pull lands with real bench players.

---

## Where grading happens in the pipeline (it's automatic)

Grading is inline — there is no separate "grade" command. Every pipeline run grades as it assembles:

- `tools/ingest/main.py:115` — sorts each theme's pool by `grade(s.stats, theme.scale)` to pick the top seasons.
- `tools/ingest/assemble.py:53` — grades survivors when building the puzzle.
- `tools/ingest/main.py` `write_catalog_fallback()` — grades the catalog the same way.

The resulting grade is **baked into the `content` jsonb at publish time** and never recomputed at
read/play time. Community puzzles (`CreateKeep4View.publish()`) bake their grade the same way using the
Swift port. This is the core guardrail: a puzzle's grade is frozen the moment it's built.

### Swift ↔ Python parity (non-negotiable)
Three implementations must stay byte-for-byte identical:
- `tools/ingest/grade.py` — source of truth.
- `BallIQ/Models/GradeFormula.swift` — used by `CreationTemplate` + parity tests.
- `BallIQ/Models/ScoringRule.swift` — the composable create-flow scoring (carries a `displayScale`).

Locked by `tools/ingest/tests/test_grade.py`, `BallIQTests/GradeFormulaTests.swift`,
`BallIQTests/ScoringRuleTests.swift`. **Touch one formula → update all three + their tests.** Note the
`ScoringRule` gotcha: a points rule needs its `displayScale` threaded through `init`, `eraAdjusted(_:)`,
the preset helper, **and** every `CreateKeep4View` preset-switch call site — dropping it silently makes
the live preview show raw points (hundreds) while published dailies show 0–100.

---

## Why grades changed (the audit that motivated PPR)

The old `nfl_wr` scale (receiving yards 60% + capped TDs/receptions) **buried reception/TD-heavy elite
seasons**. Catalog evidence, grade-rank vs PPR-rank of 40 WR seasons:

- Antonio Brown 2018 — #39 by old grade → #26 by PPR
- Michael Thomas 2018 — #37 → #27
- Tyreek Hill 2018 — #30 → #23

PPR is the fan-legible fix, and it's now the default create-flow preset. Legacy fixed/era-adjusted
scales still exist for custom rules.

---

## Data model: season-level only

`RawSeason` / `CatalogSeason` / the `player_seasons` table all store **season aggregates** — NFL season
totals, NBA season per-game averages. There is no game/week/box-score concept anywhere in the pipeline
(grep `tools/ingest` for `week`/`game_id`/`box_score` → nothing). This is why single-game grading is a
new milestone, not a config flag.

---

## Known gaps / next milestones

1. **Single-game grading (net-new).** Requires: a game-level data model (box scores), a provider/ingest
   path that pulls per-game lines, and its own DFS-style scale with single-game bounds (the current
   bounds are calibrated to *season* totals, so a great single game would clip low under them). None
   exists today.

2. **Bounds don't auto-recalibrate.** `_FANTASY_BOUNDS` are hand-set constants. A record-breaking new
   season just clips at 100 — graceful, but the scale won't widen on its own. Revisit the bounds
   whenever the ingested population grows materially (e.g. extending NFL back to 1999, or a full NBA
   live pull). Consider a `--recalibrate-bounds` step that prints fresh percentiles.

3. **Pipeline isn't auto-triggered.** Grading is automatic *within* a run, but the run itself is manual.
   `.github/workflows/ingest.yml` defines a correct daily cron that has **never executed** — the local
   directory isn't a git repo and was never pushed. Every upsert to date has been a manual CLI run.
   First step: `git init` + push so CI can run.

4. **NBA isn't live.** `nba_balldontlie.py` 429s on every fetch (no sleep between the two sequential
   calls per player) and silently falls back to the 34-season curated seed. Until that's fixed, NBA
   grades are calibrated against legends only — another reason the NBA bounds are reasoned, not
   self-anchored.

5. **Era adjustment is shelved off the shipped surface.** The `eraAdjusted` normalization and
   `stat_baselines.json` still exist and are tested, but fantasy points (not era-relative grades) are
   the one shipped scoring mechanism. Don't re-surface era-adjust without a product decision.

---

## Guardrails (every time you touch scoring)

- Keep Swift↔Python parity tested on **all three** implementations.
- Grades stay **baked at publish** — never recompute at read/play time.
- Community `content` jsonb stays **camelCase** (plain `JSONEncoder`, not the snake-casing `.supabase` one).
- Never ship `service_role` in the app (it lives only in `tools/ingest/.env`).
- Verify both suites green + a screenshot before claiming done.
