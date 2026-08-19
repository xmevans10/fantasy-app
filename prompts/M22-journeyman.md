# M22 — Journeyman (career-path guessing format)

**Goal.** A fourth daily format: the game shows a player's whole club history as a
chronological crest timeline — club badge, club name, year span — and you name the player. Drew
Brees is `Chargers 2001–2005` → `Saints 2006–2020`. Five guesses; each wrong one costs you.

**Why now.** §9.3 sequences *new engagement features* ahead of Grid depth and monetization
funnel work. This is the cheapest genuinely-new format the pipeline can already feed: the
career path is a `group by` over `player_seasons`, which the catalog has had since M3, and it
reuses the Who Am I? subject-qualification machinery wholesale. It is also the app's first
format whose board is *visual* rather than textual, which is exactly what the share loop
(MARKETING.md) is short of.

---

## 1. The game — as shipped

- Board = an ordered list of **stints**. A stint is a maximal run of consecutive catalog seasons
  at the same club, so a return spell is its own stint (Ronaldo: United → Madrid → Juventus →
  United).
- **The whole path is on screen from the first second.** The first build revealed it a club at a
  time and priced each reveal; the user's call, mid-build, was to show all the logos at once —
  correctly, because the drip-feed made the game about *when to spend a reveal* when it should be
  about *who is this*. What costs you now is a wrong name, not a look.
- **Five guesses**, worth 1000 / 800 / 600 / 400 / 200 and then nothing. That is deliberately the
  same table `WhoAmIScoring.perClue` uses: the two formats are the same bet in different clothes,
  and a player who has learned what "600" means in one should read it the same way in the other.
- Guess through the shared name typeahead — `GridGuessSheet.rank` (the Grid's own ranker, reused)
  over the sport-wide name index, rendered as an inline strip rather than a sheet.
- Running out of guesses ends the run at zero, as does "Give up". The reveal card shows the
  headshot, name, position and the path again beside the answer.

**Stint rows show crest + club name + years, not crest alone.** The pure-crest version is the
prettier game and the wrong one here: this app carries 1,182 distinct soccer club codes and five
sports, VoiceOver needs the name anyway, and an unrecognizable badge is unfair rather than hard.
The crest carries the recognition, the name carries the fairness.

**Scoring invariants** (`JourneymanScoring`, mirroring `WhoAmIScoring`):
- Difficulty tiers reuse Who Am I?'s `easy/medium/hard` (×1.0/×1.25/×1.6), extracted to a shared
  `SubjectDifficulty` so there is one tier vocabulary, not two.
- The multiplier scales points and XP only. `performance` — the rating-engine input — is
  difficulty-**independent** (§4's invariant): the tier the pipeline happened to serve must never
  move a rating.

## 2. Data — what's actually there (verified against live Postgres, 2026-08-19)

`player_seasons` season-grain rows carry `(name, sport, team_abbr, league, season_year,
position, headshot)`. Stints are a run-length encoding of that, ordered by year.

Three real data facts that shape the design:

1. **Franchise codes are era-mixed and partly aliased.** `teams` has crests for 28 NBA and 32
   NFL codes, but the catalog also uses `NY`/`GS`/`SA`/`UTAH`/`WSH`/`NO` (NBA) and `LA` (NFL),
   plus every defunct code (`SEA` Sonics, `NJN`, `WSB`, `VAN`, `SD`, `OAK`, `RAM`, `PHO`).
   Deliberately **not** treated as a content gate: `Sport.teamLogoURL` falls back to ESPN's CDN,
   which serves most of the defunct crests, and `TeamLogoBadge` degrades a genuine miss to the
   club's own color chip. The club NAME carries the information, so a missing crest costs polish,
   not fairness. Widening the `teams` table to the catalog's alias codes would fix crest lookup
   app-wide and is worth doing on its own — it is not this milestone.
2. **Some codes cannot be named at all.** `whoami_pool._AMBIGUOUS_TEAM_CODES` already records
   which (`nba NO` = Hornets-then-Pelicans, `nfl LA` = Rams-and-Raiders, …), and the catalog
   has ~2k rows with an empty `team_abbr`. A subject with any unnameable stint is **dropped**
   — a board that says "?" for a club is not a puzzle.
3. **Relocations render under the modern nickname where the catalog stores the modern code.**
   Brees's 2001–2005 rows say `LAC`, so that stint reads "Chargers 2001–2005" — nickname, never
   city, precisely so the label is not historically false. Documented limitation, not a bug;
   real historical codes (`SD`) do exist elsewhere in the same table and render correctly.

**Pool generation** (`tools/ingest/journeyman.py`) reuses `whoami_pool`'s qualification
pipeline verbatim — `build_candidates` → `qualify` (headshot, unique name in sport, ≥4-5
seasons, production floor, plausible-career span/density, soccer-league whitelist) →
`blended_fame` → `tier_for_fame`. On top of that it adds only what this format needs:
- ≥2 stints (soccer ≥3 — a soccer career with two clubs is the norm, not a journeyman),
- every stint nameable (see above),
- ≤8 stints rendered (longer paths truncate to the 8 most recent — a 14-row board is
  unplayable and unreadable), with the truncation stated on the board.
Cap 150/sport, tier mix identical to Who Am I?'s, written to `data/journeyman_pool.json`.

**Daily minting** (`tools/ingest/daily_journeyman.py`) is a straight port of
`daily_whoami.py`: per-(date, sport) tier draw, least-recently-served within tier, idempotent
against a new `journeyman_history` table, dated row id `…-daily-YYYYMMDD`, `active_date` set.
Same 2-day lookahead the nightly job already uses.

---

## 2.5 What the live pool actually caught

Every one of these was found by reading generated boards against real careers, not by a test —
and every one would have shipped a confidently false board (AGENTS.md §1).

1. **"Eddie George — Texans 1996".** He played for the Houston *Oilers*; the Texans did not exist
   until 2002. `whoami_pool.FRANCHISES` names a code with one nickname, which is right for a clue
   and wrong next to a year span. Fixed with `ERA_FRANCHISES` (era-aware naming) + a `historical`
   flag that suppresses the modern crest, since ESPN's `nfl/hou` badge *is* the Texans'.
2. **"Charles Woodson — Raiders → Raiders".** Oakland arrives as both `OAK` and `LV`; keying the
   run-length encoding on the code invented a transfer to the club he was already at. Runs are
   keyed on the club NAME now, which also lets a genuine rebrand (Oilers → Titans, both `TEN`)
   show up as the two clubs a fan remembers.
3. **"Marcos Llorente — FC Dallas 2017"** (Deportivo Alavés) and **"Luis Díaz — Portimonense"**
   (FC Porto). Soccer club codes are not unique: the flat `{code: name}` map ignores country, and
   `resolve_code` derives "POR" for both Porto and Portimonense *inside* Portugal. Fixed with
   league-qualified `ClubNames` plus `contested_club_codes`, which drops any code a curated famous
   club claims but the sweep has assigned elsewhere. **The underlying code collision is upstream
   and still open** — it is latent in every surface that shows a soccer club name.
4. **Careers that start where the catalog does, not where the player did.** NFL defensive rows
   begin in 1999 (0 defenders in 1998, 701 in 1999) and soccer's sweep only thickens in 2013 — so
   Cristiano Ronaldo's board opened at Real Madrid. `coverage_floors()` now measures where each
   position's history becomes trustworthy from the rows themselves, with soccer carrying extra
   clearance because a European career routinely begins in a league this catalog never saw.

One bug found *outside* the format: the guess typeahead's RPC (`grid_player_names`) had no index
behind it and returned 57014 under the anon role, so **The Grid's typeahead has been silently
degraded to free text since it shipped**. Migration 0019 adds `(sport, career, name)`; measured
500 → 200 in 0.3–3.0s across all five sports.

## 3. Work breakdown

### Supabase (additive; applied live + mirrored into `supabase/schema.sql`)
- `journeyman_history` table (service-role only), mirroring `whoami_history`.
- `create_versus_challenge`'s format whitelist gains `'journeyman'` (line 844 today refuses
  anything outside `keep4|grid|whoami`). Required, not optional: `PuzzleFormat.allCases`
  drives the duel format picker in `VersusView`/`PublicProfileView`, so a new case is offered
  to players the moment it exists.
- `puzzles.format = 'journeyman'` needs no DDL (free text, already indexed by `(format, sport,
  id)`).
- `ladder_rungs.mode`'s check constraint is deliberately **not** widened — no journeyman rungs
  are minted in this milestone, though the client handles one if the server ever serves it.

### Pipeline (`tools/ingest/`)
- `journeyman.py` — pool generation + archival upsert + `--write-bundle`.
- `daily_journeyman.py` — the nightly mint.
- `upsert.py` — `fetch_journeyman_history` / `upsert_journeyman_history`.
- `.github/workflows/ingest.yml` — mint journeyman alongside whoami/grid.
- `tests/test_journeyman.py` — stint RLE (gaps, return spells, mid-season trades), the
  nameability gate, truncation, tier draw, LRS rotation, idempotency.

### App (`BallIQ/`)
New:
- `Models/SubjectDifficulty.swift` — the tier enum lifted out of `WhoAmIPuzzle`, with
  `extension WhoAmIPuzzle { typealias Difficulty = SubjectDifficulty }` so every existing call
  site and every persisted raw value is untouched.
- `Models/JourneymanPuzzle.swift` — puzzle + stint + `JourneymanScoring`.
- `Features/Journeyman/CareerPathTimeline.swift` — the shared board component (game view and
  result view render the same timeline, locked vs revealed).
- `Features/Journeyman/JourneymanGameView.swift`, `JourneymanResultView.swift`.

Modified:
- `PuzzleFormat` (+`journeyman`), `GameFormatKind` (+`journeyman`, weight 1.5, XP 100).
- `PuzzleRepository` / `RemotePuzzleRepository` (daily + archive fetch, bundled fallback).
- `GameFormat.all` (+tile), `HomeView` (daily card in the pager stack, hub launch, cover),
  `HomeDailyLoop` (the "you're done today" countdown now needs all three dailies — a third
  ranked daily that the completion card ignores would be dishonest).
- `BrowseView` (+archive tab), `DuelBoard`/`BotSolver`/`ChallengeLink` (duel + dare-a-friend
  parity), `ShareMessage`, `DebugLaunch` (`-screenshotJourneyman[Result]`), `Localizable.xcstrings`.

### Verification (met, 2026-08-19)
1. `python -m pytest tools/ingest/tests -q` — 472 passed (37 of them new).
2. `xcodebuild … test` — TEST SUCCEEDED, including 23 new Journeyman cases.
3. Pool generated for all four team sports and read against real careers — the four defects in
   §2.5 all came out of that pass.
4. Content live: 525 archival rows + 12 dated dailies (today + 2, all four sports), confirmed by
   SQL count against `puzzles`.
5. Simulator: board, wrong guess (1000 → 800), solve on guess 2, result screen, Home daily card,
   formats tile, Journeyman hub — all captured on device.

## 4. Explicitly out of scope
- Community authoring of Journeyman puzzles (`CreateWhoAmIView` has no analogue yet).
- Ladder rungs in journeyman mode (the 30-rung curve is tuned; adding a mode re-tunes it).
- Historical/defunct crest artwork (§9.3 backlog #8 "defunct-franchise styling") — the color
  chip degrade is the v1 answer.
