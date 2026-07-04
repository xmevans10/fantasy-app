# Playbook — M8: Single-game grading (net-new milestone)

Self-contained prompt for a fresh agent. Read [prompts/README.md](README.md) and
[docs/scoring-and-grading.md](../docs/scoring-and-grading.md) first — the grading model is the heart
of this one. Assumes the repo as of **2026-06-29**.

`fantasy-app` is **Playbook**, a native SwiftUI iOS sports-trivia app. The entire data model today is
**season-level only** (`RawSeason`, `player_seasons`, NFL season totals / NBA per-game averages).
There is no box-score / per-game concept anywhere (grep `tools/ingest` for `week`/`game_id` → nothing).

This milestone adds the ability to grade and play **single-game performances** (e.g. "rank these 8
playoff games"), which several formats would unlock.

---

## Why it's net-new (scope before building)

Three new pieces are required; none exist:

1. **A game-level data model** — a `RawGame`/box-score record (player, date, opponent, line). ESPN's
   public endpoints expose game logs (`.../athletes/{id}/gamelog` and event box scores) keyless, the
   same source M7 uses — so the provider path is feasible without new deps.
2. **A provider/ingest path** that pulls per-game lines (distinct from the season-averages path in
   `espn_nba.py`).
3. **Its own DFS-style scale with single-game bounds.** The current `_FANTASY_BOUNDS` are calibrated
   to *season* totals — a great single game (~60 fantasy pts) would clip near 0 under season bounds.
   A single-game scale needs its own `lo`/`hi`, kept in Swift↔Python parity like every other scale.

---

## Success criteria
- A documented data model + migration for game-level rows (don't overload `player_seasons`).
- An ingest path producing real, factual single-game lines for at least one sport.
- A single-game grade scale with bounds calibrated to per-game distributions, parity-tested across
  `grade.py` / `GradeFormula.swift` / `ScoringRule.swift`.
- At least one playable surface using it (a Keep4 variant over single games is the smallest viable
  proof), grades **baked at publish**.
- Both suites green + a screenshot.

## Guardrails
- Keep the season-level model intact — this is additive. Stdlib-only pipeline runtime. camelCase
  `content`. Never ship `service_role`. Match the "Prime Time" design system for any new UI.
