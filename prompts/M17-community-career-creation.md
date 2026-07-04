# M17 — Let players build career-grain community puzzles

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Goal

`CreateKeep4View` (the Keep4/Cut4 creation flow) can only ever build **season-grain**
puzzles today — `Keep4Theme.isCreatable` hard-gates on `grain == "season"`. Extend it so a
player can build a **career-grain** community puzzle too ("all-time leaders" style, using
real aggregated career totals), reusing the career infrastructure this session just shipped
rather than inventing a second one.

Single-game creation is explicitly **out of scope** for this milestone — see "Why not
single-game too" below; it's a materially harder catalog problem, not a small extension of
this one.

## Why now

This session (unlogged as its own milestone until now) shipped, end-to-end:

- **Community data parity**: community-published cards were missing `headshot` because the
  create-flow catalog (`player_seasons` / Swift `CatalogSeason`) never carried it.
  Fixed: `tools/ingest/main.py`'s `catalog_rows()` → `CatalogSeason` (`BallIQ/Models/GradeFormula.swift`)
  → `CreateKeep4View.cards()` all carry `headshot` now.
- **A third puzzle grain, career**, alongside the existing season/single-game ones:
  - `tools/ingest/career.py` — `build_career_rows()` aggregates every real season a player
    has into one row per (sport, position). Counting stats sum; rate stats (AVG, OBP, SLG,
    ERA, WHIP, PPG, RPG, APG, SPG, BPG) are recomputed as an exact weighted average using
    each season's real denominator (not an approximation — see the module docstring for the
    algebra proving `sum(rate_i * weight_i) / sum(weight_i)` collapses to the true aggregate).
  - 4 new daily themes with `grain="career"`: `nfl-career-fantasy`, `nba-career-fantasy`,
    `baseball-career-hitters`, `baseball-career-pitchers` (`tools/ingest/themes.py`). Soccer
    and tennis don't have one yet — their seed data is ~1 season/player, so
    `build_career_rows` (which requires ≥2 seasons to emit a row) produces nothing for them.
    That's a real data-depth gap, not a bug; revisit once/if either sport gets a live
    multi-season provider (still unverified as of M13's session — see `providers/seed.py`'s
    module docstring).
  - `PuzzleGrain` (Swift, `BallIQ/Models/PuzzleGrain.swift`) + `GrainChip` — mirrors
    `ScoringKind`/`ScoringNoteChip` exactly. `Keep4Puzzle.grain: String?` is baked at
    assembly (`assemble.py`) and resolved via `puzzleGrain(themes:)`, same pattern as
    `scoringKind(themes:)`. Wired into Keep4GameView, Home, Browse, Community, and the
    share-sheet preview card.
  - `PlayerSeason.firstYear`/`lastYear` (Swift) — a career card's subtitle reads
    "LAD · 2018-2026" instead of a single year.
- **Unrelated fix while in the area**: tennis cards were fetching a broken NBA-style team
  logo (tennis has no team; `teamAbbr` holds a country code — see `providers/seed.py`'s
  `load_tennis` docstring). Added `Sport.hasTeams` + `CountryFlags` (flag emoji from the
  IOC-style codes tennis already uses) so the logo slot shows a flag instead.

All of the above is live: bundled JSON regenerated, 93 Python + 126 Swift tests green, and
pushed to the production Supabase project (`puzzles` + `player_seasons` tables).

The natural next step: the Create flow can already show a career-grain card correctly (the
rendering is grain-agnostic — `Keep4Theme.cardStats`/`PlayerSeason.subtitle` already branch
on it), but nothing lets a player *pick* career players to build one, because the catalog a
player searches (`player_seasons` / `CatalogSeason`) only ever contains season rows.

## Current state to build on (measured, not assumed)

- `catalog_rows()` (`tools/ingest/main.py:205`) explicitly excludes both game rows
  (`s.week is not None`) and career rows (`s.career`) — that second exclusion is this
  session's own fix (M17 prep), added deliberately because Create wasn't ready for either
  yet. You're removing the career half of that exclusion, not fixing a bug.
- `write_catalog_fallback()` (`main.py:222`) builds the trimmed **bundled** catalog by
  looping `KEEP4_THEMES` and skipping anything with `theme.grain != "season"` — same
  deliberate gate.
- The **live** `--upsert --catalog` path pushes the *entire* untrimmed `catalog_rows(seasons)`
  (21,925 rows as of this session, season-grain only) — not per-theme-trimmed. Adding career
  rows (~3,354 in this session's pull, per (sport, position)) is a proportionally modest
  ~15% addition, not a scale problem. Confirm this order-of-magnitude still holds when you
  actually run the pipeline — provider pool sizes drift.
- `Keep4Theme.isCreatable` (`BallIQ/Models/Keep4Theme.swift:40`) is the single gate
  `CreateKeep4View`'s `templateSection` uses to decide which daily themes to offer as
  starting templates (`Keep4Theme.bundled.filter(\.isCreatable)`).
- `CatalogSeason` (`BallIQ/Models/GradeFormula.swift:88`) has no field distinguishing a
  season row from a career row today — a search result list mixing both would look
  identical except for wildly different stat magnitudes and no visual cue why.
- `career.py`'s per-sport/position `min_stats` floors (in `themes.py`'s 4 new theme defs)
  were chosen as "this is a real career, not a cup of coffee" — e.g. NFL 80 games, NBA 300
  games, MLB hitters 3,000 PA, MLB pitchers 800 IP. Reuse these as your pool floor rather
  than re-deriving new ones.

## Why not single-game too

Single-game rows are two orders of magnitude larger (79,208 player-games from just the NFL
2009–2023 pull alone, seen this session) than the season catalog. Bundling or live-fetching
that as a flat browsable list the way `CatalogSeason` works today isn't the same small
extension career is — it needs its own search UX (e.g. "pick a player, then pick one of
their games" rather than "browse a big flat list") and probably its own catalog shape
entirely. Don't fold it into this milestone; flag it as a separate, larger design problem if
you want to pick it up after this one ships.

## Scope

1. **Catalog**: stop excluding career rows in `catalog_rows()`; decide whether
   `write_catalog_fallback()`'s per-theme trim loop should include the 4 career themes (they
   have real `min_stats` and `scale` already — likely just remove the `grain != "season"`
   skip and let it work generically) or keep the bundled fallback season-only for size and
   only offer career via the *live* Supabase catalog. Recommend the latter to start (matches
   how career itself only exists live-first, no urgency to bloat the shipped binary) —
   confirm with the user before deciding either way, since it's a real tradeoff (offline
   demo completeness vs. binary size).
2. **`CatalogSeason` (Swift)**: add whatever's needed to tell career rows apart in a search
   result — at minimum a `career: Bool` flag (mirrors `RawSeason.career`), decoded from a new
   `catalog_rows()` key. Decide how `CatalogSeason.subtitle` should read for a career row
   (mirror `PlayerSeason.subtitle`'s "TEAM · first-last" treatment — you'll need first/last
   year here too, likely from the same `meta`-sourced fields `career.py` already computes).
3. **`Keep4Theme.isCreatable`**: extend the gate to admit `grain == "career"` themes too
   (still requiring `scoringRule != nil`, which all 4 career themes already have).
4. **`CreateKeep4View`**: when a career theme is the active template, the discovery/search
   section is searching a catalog that (post-scope-item-2) now mixes season and career rows
   for the same sport/position — decide whether picking a career-grain template should
   *filter search results to career rows only* (recommended — mixing "LeBron's 2019 season"
   and "LeBron's whole career" in the same 8-pick pool would be a confusing, apples-to-oranges
   puzzle) the same way it already filters by `theme.positions`.
5. **Bake `grain` at publish**: `CreateKeep4View.publish()` currently hardcodes
   `grain: "season"` (this session's own placeholder, written because Create had no other
   option). Make it `activeTheme?.grain ?? "season"` once a career template can be active.

## Key decisions (recommend, then confirm)

- Bundled-fallback vs. live-only for the career catalog (scope item 1) — recommend live-only
  first; the offline/no-network create experience already accepts a smaller pool (see
  `write_catalog_fallback`'s existing `per_theme=40` trim), and career rows are a genuinely
  optional nice-to-have there.
- Whether free-form (non-templated) creation should ever offer career stats as a "3 headline
  stat" fallback the way it does for season rows today (`ScoringStat.catalog(for:)` prefix-3)
  — recommend **no**: free-form creation has no per-position career scale to grade against
  without a template (mirrors the existing docstring rationale for why baseball/soccer
  default scales are hitter/attacker-only without a template). Career creation should
  probably *require* picking one of the 4 career templates, not be freely composable.

## Deliverables

- `catalog_rows()` includes career rows (gated by your scope-item-1 decision on the bundled
  fallback).
- `CatalogSeason` distinguishes career rows and displays them sensibly.
- The 4 career themes are `isCreatable`, selectable in `CreateKeep4View`'s template section,
  and search correctly scopes to career-only players once one is active.
- A player can publish a career-grain community puzzle end-to-end (build → publish → play →
  grain chip reads CAREER, same as daily career puzzles).
- Tests: Python coverage mirroring `test_main.py`'s existing `test_catalog_excludes_career_grain_rows`
  (now inverted — a career-inclusive test), Swift coverage for `CatalogSeason` career
  decoding and `isCreatable` including career.

## Verification / success criteria

- Build a career puzzle end-to-end in the simulator (Create tab → pick a career template →
  search finds only career rows → publish → play) and screenshot it.
- All existing tests stay green; new ones cover the career-catalog path.
- Confirm a **season** creation flow still behaves identically (no regression from the
  broadened catalog/search).

## Hand-offs (cannot be done by the agent)

- Pushing the broadened catalog to the **live** Supabase project needs
  `SUPABASE_SERVICE_ROLE_KEY` — present in this environment's `tools/ingest/.env` as of this
  session, but confirm it's still there and get explicit user sign-off before running
  `--upsert` again; it's a real production push, not a local-only change.
- Single-game community creation (see "Why not single-game too") — a separate, larger design
  problem; don't fold it in here.
- Soccer/tennis career themes — blocked on those sports getting a real live multi-season
  provider first (still unverified as of M13's session).
