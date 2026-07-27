# The Grid: axis-variety research + logo-latency diagnosis

Research date: 2026-07-27. Two separate findings, filed together because they were investigated
together: (1) our Grid is structurally locked to teams × decades and Immaculate Grid is not, and
(2) crest images are slow for reasons that are measurable and mostly fixable client-side.

---

## 1. Immaculate Grid — product notes

**What it is.** Brian Minter shipped it April 2023 (named after the "immaculate inning").
Sports Reference LLC acquired it 2023-07-11 and folded it into their reference sites. Sport
versions followed fast: football 2023-07-20, basketball + women's basketball 2023-07-25, hockey
2023-07-26, soccer ("Immaculate Footy") 2023-08-18. It now lives under
`sports-reference.com/immaculate-grid/` — note that `immaculategrid.com` 301s there, and both
that host and the marketing mirrors 403 automated fetches, so the notes below come from the
Wikipedia entry, the Footballguys strategy guide, and secondary coverage rather than the
first-party FAQ.

**The structural thing we don't do: axes are symmetric and untyped.** Every one of the six axes
(3 rows, 3 cols) independently carries *a team, a statistical achievement, or an award*. Nothing
says "rows are teams." That's what produces the game's most recognisable cell — **team × team**,
"who played for both the Jets and the Bills" — which our current model literally cannot express.
It also produces team × award, team × season-stat, team × career-stat, and award × stat cells
from the same machinery.

**Axis types observed** (football):

| Type | Example label | Notes |
|---|---|---|
| Franchise | "Dallas Cowboys" | current + historical franchise identities |
| Season stat threshold | "1,000+ Rushing Yards (Season)" | achieved *in a single season* |
| Career stat threshold | "10,000+ Career Passing Yards" | achieved at any point in career |
| Award / honour | "Pro Bowl", "All-Pro", "Super Bowl Champion" | |
| Draft | draft round / pick criteria | e.g. first-round, undrafted |
| College | player's college | |

**The two combination rules that matter** (this is the part people get wrong, and the part that
determines what our generator has to compute):

- **Team + season-stat / team + award** → the player must have done it *while on that team*. If
  he split the season across teams, the stat must have been recorded with the named team.
- **Team + career-stat** → the career milestone is career-wide, and the team side needs only
  **one game played** for that franchise. This is why journeymen are the cheat codes: a
  10-year vet who logged three snaps for six teams unlocks half a grid.

**Rules.** Nine guesses total, one per square. A miss burns a guess and leaves the square empty.
A player may only be used **once** per grid. One puzzle per day.

**Scoring is crowd-based, golf-style.** Your rarity score is the sum, over correct cells, of the
*percentage of all players who gave that same answer*, plus 100 for each empty cell. Lower is
better, so obscure-but-valid answers beat Tom Brady. It's live — your score drifts during the
day as the crowd distribution moves. Sports Reference added this specifically "to encourage
players to think of lesser known answers," i.e. it was a retrofit to fix the problem that the
optimal play was always the most famous name.

---

## 2. Where BallIQ's Grid stands today

The board is teams × decades and always has been. Confirmed against production — every minted
board, every sport:

```
nba    2026-07-27  rows=[TOR, UTAH, POR]  cols=[1990, 2000, 2010]
nfl    2026-07-27  rows=[KC, DAL, SEA]    cols=[1980, 1990, 2010]
soccer 2026-07-27  rows=[SAN, FIO, AUN]   cols=[2000, 2010, 2020]
tennis 2026-07-27  rows=[USA, NED, CRO]   cols=[1960, 1980, 2020]
```

The shape is hardcoded at **every layer**, which is the real cost — it isn't a generator tweak:

- [grid.py:40](tools/ingest/grid.py:40) — `row_teams: tuple[str, str, str]` / `col_decades: tuple[int, int, int]`
- [grid.py:137](tools/ingest/grid.py:137) — `rng.sample(teams, 3)` and `rng.sample(decades, 3)`; `_build_cell` matches on `s.team_abbr == team and _decade(...) == decade` and nothing else
- [GridPuzzle.swift:8](BallIQ/Models/GridPuzzle.swift:8) — `let rowTeams: [String]` / `let colDecades: [Int]`
- [GridGameView.swift:134](BallIQ/Features/Grid/GridGameView.swift:134) — the layout branches on "column 0 is a `TeamAbbrChip`, row 0 is a `\(decade)s` label"
- [GridGameView.swift:203](BallIQ/Features/Grid/GridGameView.swift:203) — the prompt string is literally `"\(team) in the \(decade)s"`
- `grid_history` stores `row_teams` / `col_decades` as its dedup key

**Things we already have that Immaculate Grid has** — worth knowing before designing anything:
answer reuse is already blocked ([GridGuessSheet.swift:48](BallIQ/Features/Grid/GridGuessSheet.swift:48), and it's typo-tolerant so "Tom Bradyy" can't sneak past),
one guess per cell, full-roster validity for NFL via `nfl_rosters` extras, and a `grid_guesses`
table already collecting crowd answers for a future "X% picked this."

**Rarity is the one place we're behind on philosophy, not just variety.** Ours is
`_rarity_stars(len(valid_answers))` baked at generation time — it measures how *permissive* a
cell is, not how *obscure your answer* was. That means the optimal play is still the most famous
name, exactly the problem Sports Reference retrofitted crowd rarity to solve. `grid_guesses`
exists and is being written to; nothing reads it yet.

---

## 3. What's actually blocking richer axes (data, not UI)

This is the part that surprised me and it should drive sequencing.

**`run_grid` throws away most of the row before the generator sees it.** At
[main.py:566](tools/ingest/main.py:566) each catalog row becomes:

```python
RawSeason(name=..., team_abbr=..., season_year=..., sport=..., position=..., stats=...)
```

No `league`, no `first_year`/`last_year`, no `meta`. So the generator currently *cannot* see
anything except team, year, position, and the stat bag — even where the catalog has more.

**`player_seasons` has no `meta` column at all.** The bio fields the theme engine keys on
(college, draft round/pick, height, rookie season — see
[nfl_players.py:46](tools/ingest/providers/nfl_players.py:46)) live only in the gather pipeline's
in-memory `RawSeason.meta`, never persisted. Grid generation reads the *catalog*, not the
gather. So **college and draft axes need a schema change first**, not just generator work.

**What we can build axes from today, no migration:**

| Axis type | Source | Sports |
|---|---|---|
| Team | `team_abbr` | all |
| Decade / era / explicit year range | `season_year` | all |
| Position | `position` | nfl(5), nba(4), soccer(4), baseball(2) |
| Season stat threshold | `stats` jsonb | all — coverage verified below |
| Career stat threshold | `career=true` rows (4.5k nfl / 6.6k mlb / 14.8k soccer / 3.5k nba / 1.1k tennis) | all, but `fetch_player_seasons` currently hard-filters `career=eq.false` |
| League / competition | `league`, `competition` cols | soccer (961 clubs across nations/tiers) |

Verified stat coverage (rows with the key present, `career=false`):

- **nfl** ~100k rows: `passing_yards`, `rushing_yards`, `receiving_yards`, `receptions`, `passing_tds`, `rushing_tds`, `receiving_tds`, `interceptions`, `carries`, `targets`, `games`, `ypc`, `ypr`, `completion_pct`
- **baseball** ~52k batting / ~31k pitching: `home_runs`, `hits`, `rbi`, `runs`, `stolen_bases`, `doubles`, `triples`, `avg`/`obp`/`slg`/`ops`; `wins`, `saves`, `strike_outs`, `innings_pitched`, `era`, `whip`
- **nba** ~51k: `points`, `rebounds`, `assists`, `steals`, `blocks`, `ppg`/`rpg`/`apg`, `fg_pct`, `fg3_pct`, `ts_pct`
- **soccer** ~79k: `goals`, `assists`, `appearances`, `clean_sheets`
- **tennis** ~8.5k: `titles`, `grand_slams`, `matches_won`

**We have no awards data in any sport.** No MVP, Pro Bowl, All-Pro, ring, Ballon d'Or. That's
Immaculate Grid's most flavourful axis type and it's a genuine new ingest, not a re-slice.
Stat thresholds are the honest substitute in the meantime ("2,000+ Yard Season" carries a lot of
the same "oh, *him*" energy).

**There is already a predicate engine to reuse — don't write a second one.**
`themes.Filter(field, op, value)` ([themes.py:57](tools/ingest/themes.py:57)) with
`field_value()` ([themes.py:28](tools/ingest/themes.py:28)) resolves computed fields → `stats`
→ `meta`, supports `eq | in | range | gte | lte | regex | exists`, and already backs the Quirk
catalog (`Filter("draft_round","exists",False)` → "Undrafted gems"). A grid axis is *exactly* a
`(label, tuple[Filter, ...])` pair. The whole vocabulary above is expressible in it today.

---

## 4. Proposed direction

**Make the axis the unit, and make both dimensions the same type.** Replace the fixed
`row_teams`/`col_decades` with symmetric `rows: [GridAxis]` / `cols: [GridAxis]`, where an axis
is `{ kind, label, filters }` — `label` is what renders ("KC", "2000s", "1,000+ Rush Yds"),
`filters` is the `Filter` tuple the generator ANDs to build the cell. Cell viability, rarity, and
the `nfl_rosters` widening all keep working unchanged, since `_build_cell` just changes from a
hardcoded team/decade test to "does this season satisfy both axes' filters."

Two rules to carry over from Immaculate Grid deliberately:

1. **Season-grain axes AND within one season row** (team + 1,000 yards must be the *same*
   player-season), while **career-grain axes** resolve against the `career=true` aggregate with
   the team side needing only one appearance. Getting this wrong is the difference between a
   correct grid and one that rejects real answers.
2. **At least one team axis per board**, and cap it at ~2 non-team axes per dimension, or
   viability collapses and the board stops feeling like a sports quiz.

**Sequencing, cheapest-first:**

1. **Symmetric axis shape, teams+decades only.** Pure refactor, no new data, no visible change
   except that team × team boards become possible. Unblocks everything else. Needs a
   content-version bump + a decoder that still reads old `rowTeams`/`colDecades` rows, since
   minted boards are immutable for their day and live boards must not break mid-flight.
2. **Position + stat-threshold axes** from the existing `stats` jsonb. Biggest variety-per-effort
   win; no migration.
3. **Career-grain axes** — needs `fetch_player_seasons` to stop hard-filtering `career=eq.false`
   and `run_grid` to carry `career`/`first_year`/`last_year` onto the `RawSeason`.
4. ~~**Soccer league/competition axes**~~ — **done, see §8.**
5. **Bio axes (college, draft)** — requires persisting `meta` onto `player_seasons` first.
6. **Awards ingest** — new provider, real scope, highest flavour.
7. **Crowd rarity** — read `grid_guesses`, serve a per-cell answer distribution, move scoring
   toward "how obscure was *your* answer." This is the one that changes how the game is *played*.

---

## 5. Logos: measured diagnosis

Measured against the live bucket today. Three real causes, in impact order.

**(a) No decoded-image cache, and the HTTP cache is too small to hold the set.** All 11 crest
call sites use bare `AsyncImage` ([PlayerMediaBadges.swift:133](BallIQ/DesignSystem/PlayerMediaBadges.swift:133)
and siblings). `AsyncImage` keeps no in-memory decoded image across view identity changes, so in a
`LazyVGrid` or a scrolling picker every re-appearance is a fresh URLCache lookup plus a full PNG
re-decode, blank-to-image each time. Worse, the app never configures `URLCache`
(`grep URLCache BallIQ` → nothing), so `URLSession.shared` runs the iOS default of ~512 KB memory
/ ~10 MB disk. **The bucket is 363 objects / 22.5 MB — more than twice the disk cache.** The set
cannot fit; it thrashes and re-downloads indefinitely. This is the dominant cause.

**(b) The assets are 10–30× larger than the size we draw them at.** Average object is **62 KB**,
max **325 KB**, and they're 500 px source crests. `TeamAbbrChip` renders at `minHeight * 0.5` —
**22 pt** on the Grid board. Good news: **Supabase image transforms are enabled on this project**,
verified live:

```
object/public/team-logos/nfl/_/kc.png                          → 40,228 bytes
render/image/public/...?width=96&height=96&resize=contain&q=80 →  8,578 bytes
```

4.7× smaller for a rendition still 4× our draw size, same `cache-control` on the response.

*(As shipped we settled on a shared 192 px rendition rather than 96 px — see
`AppImagePipeline.buckets` for why the ladder has to straddle the size clusters. Measured:
KC 40,228 → 18,806 B; LAL 64,550 → 25,548 B; CHC 56,094 → 26,013 B. ~2.3× rather than 4.7×,
but every call site shares one rendition, so a crest is fetched once app-wide instead of once
per size. Working set 22.5 MB → ~9.7 MB, comfortably inside the raised URLCache.)*

**(c) The Grid never warms the identity index, so its crests take the slow fallback path.**
`warmIdentities(for:)` is called from exactly one place —
[PlayerSeasonCatalog.swift:145](BallIQ/Data/Repositories/PlayerSeasonCatalog.swift:145),
inside `prefetchDraftSpinSample`. `GridGameView.load()` doesn't call it and `GameSetupScreen`
doesn't prefetch. So on a cold Grid open, `TeamIdentityIndex` is empty, `teamLogoURL` misses, and
we fall through to `legacyTeamLogoURL` → the ESPN CDN. Two consequences: ESPN serves
**`cache-control: max-age=123`** (measured), i.e. those crests genuinely re-download every two
minutes forever; and for soccer the legacy path is a hardcoded 11-club ESPN id table, so
essentially every soccer club renders no crest at all.

**Fixes, cheapest-first:**

1. Call `warmIdentities(for: sport)` from `GridGameView.load()` (or better, from
   `GameSetupScreen` generally, so every format benefits). One line, removes the ESPN fallback
   path entirely. — *(c)*
2. Configure `URLCache.shared` at launch with a realistic budget (e.g. 32 MB memory / 256 MB
   disk). One line in the app entry point. — *(a)*
3. Point crest URLs at `render/image/public/...` with a width matched to the draw size. Either a
   helper on `TeamIdentity.logoURL` or a rewrite in `Sport.teamLogoURL`. — *(b)*
4. Replace bare `AsyncImage` with a small shared `CrestImage` backed by an `NSCache<NSURL, UIImage>`
   of decoded images. This is the one that kills the flicker on re-appearance, and it's the right
   shared-component move given 11 duplicate call sites (AGENTS.md §4). — *(a)*

### Status (2026-07-27): all four landed

`RemoteImage`/`AppImagePipeline` ([RemoteImage.swift](BallIQ/DesignSystem/RemoteImage.swift))
replaced bare `AsyncImage` at all 11 call sites; `warmIdentities` moved to `GameSetupScreen` so
every format warms it; `URLCache.shared` raised to 32 MB / 256 MB at launch; crest URLs now go
through the Storage render endpoint at a shared 192 px rendition. Locked by
[AppImagePipelineTests.swift](BallIQTests/AppImagePipelineTests.swift) — note the bucket ladder
went through two failing iterations before landing on `[192, 384]`, both caught by the
"one rendition per crest" assertion rather than by eye.

---

## 6. The Grid rollout — content must ship AFTER the client

`grid.py` now emits the symmetric `rows`/`cols` payload, and `to_content` re-emits legacy
`rowTeams`/`colDecades` **only** for boards that are still the classic teams x decades shape.
A teams x teams or teams x stats board has no honest v1 rendering, so a client on the shipped
App Store build decodes nothing and shows "No Grid today".

**Therefore: do not run `--grid --upsert` until the client build with the v2 decoder is live.**
Minted boards are immutable for their day, so a premature push can't be walked back by
regenerating — it would strand every existing user for that sport that day. The client half is
in (`GridPuzzle` decodes both shapes, `GridBoardGalleryTests` renders every archetype); the
content half waits for the release.

---

---

## 7. Draft & Spin: the "screen between each spin"

Not a performance problem — `SpinRevealView` was simply too long, too often. Measured from its
own constants: 21 ticks at `0.05 + 0.013 × elapsed` = 3.78 s of reel, plus a hardcoded 1.0 s
landing beat = **~4.78 s per spin, once per round**.

| Sport | Rounds | Reel time before | After |
|---|---|---|---|
| Soccer | 8 | 38.2 s | **14.0 s** |
| NFL / MLB | 6 | 28.7 s | **11.2 s** |
| NBA | 5 | 23.9 s | **9.8 s** |
| Tennis | 3 | 14.3 s | **7.0 s** |

Fix: round 1 keeps the full casino run (4.28 s); every later round gets an abbreviated one
(1.39 s). The signature moment is untouched — what's cut is the fifth time you've seen it in two
minutes. Budgets are asserted in `BallIQTests/SpinRevealTimingTests.swift` rather than eyeballed.

Second, separate issue in the same flow, now also fixed: `assign()` cleared `currentRound` and
kicked off `spinNextRound()` without any loading state, so during the roster fetch (measured
0.32–0.43 s each, up to six sequential attempts) the player saw a stripped draft board — header
and empty lineup bar, no roster, no affordance.

The fix makes good on the view's original design intent. `SpinRevealView` had a `rosterReady`
binding documented as "the final roster is fetched while the reels spin", but the fillability
re-spin added later (the "BRO 2006" fix) moved the fetch *before* `presentRound` — so the flag
was always true on arrival, the overlap never happened, and the fetch surfaced as a dead frame
instead. It now takes `target: Binding<SpinRevealTarget?>`: `beginReveal()` puts the reel on
screen with **no landed target**, it rolls decoys, and `presentRound` supplies the (team, year)
once a combo is vetted. The fetch hides entirely behind animation that was going to play anyway.

Three details that are load-bearing rather than incidental:

- `target` **must** be a `Binding`. The tick loop recurses through `DispatchQueue.main
  .asyncAfter`, whose closure captures a *copy* of the struct; a stale copy's `let` would never
  observe a late value.
- While waiting, the countdown holds at `staggerTicks`, not 0. Both locks are gated on a landed
  target, so letting it reach zero first would make a late target satisfy the team-lock and
  year-lock conditions in the same tick — both reels snapping together, losing the anticipation
  beat that gives the moment its shape.
- "SCOUTING THE ROSTER…" only appears once the wait outlasts the reel (`extensions > 0`). A
  typical fetch finishes long before the reels would have stopped, and announcing it every round
  is flicker for no information gain.

`betweenRounds`/`spinningUpScreen` — a loading state added earlier in the same pass — were
deleted once this landed: the reel covers that window, and two mechanisms for one job is worse
than either.

---

---

## 8. Soccer club-code collisions (fixed 2026-07-27)

Surfaced by the team × team archetype, but it predates it — the old teams × decades boards had
it too, just less visibly. Soccer `team_abbr` values are **derived from club names and are not
unique**. Measured live against production:

- **152 of 954** soccer abbreviations carry rows from more than one league.
- **51** are *genuinely* mixed (>10% of rows from the minority club), and they are the game's
  most recognisable clubs.

| abbr | clubs merged under it | minority share |
|---|---|---|
| `DUN` | Dundee (Scotland) 173 / MLS 162 | 49% |
| `AUN` | Australia 98 / MLS 80 | 45% |
| `SJO` | Scotland 221 / San Jose 147 | 40% |
| `TOR` | **Torino** 322 / Toronto FC 186 | 37% |
| `MON` | **Monaco** 294 / Montreal 134 | 35% |
| `GAL` | **Galatasaray** 301 / LA Galaxy 140 | 34% |
| `MCI` | **Manchester City** 288 / Melbourne City 132 | 33% |
| `MUN` | **Manchester United** 327 / MLS 79 | 20% |

An unscoped `MCI` cell accepted Melbourne City players as correct Manchester City answers.

**Fix, in three parts:**

1. `league` now rides through `fetch_player_seasons` → `run_grid` → `RawSeason.meta['league']`
   (the convention `themes.field_value` already reads, so `Filter('league', ...)` just works).
2. `team_axis` takes a league: it joins the filter tuple *and* the key, so `team:MCI@England` and
   `team:MCI@Australia` are different axes. Rows whose league is blank under a league-scoped
   sport are dropped from axis selection — an axis with no league filter is precisely the merged
   behaviour being prevented.
3. The **label** is league-qualified — `MCI-ENG`, `MCI-AUS`, `TOR-ITA`, `GAL-TUR`. Scoping alone
   fixed the answer set but left two axes both reading "MCI": correct underneath,
   indistinguishable on screen. The nation code comes from `soccer_leagues.top_flight_slug`
   (`England` → `eng.1` → `ENG`) rather than a new hand-written map — that file already owns this
   fact. `abbr`/`league` still ship separately in the content because crest and color lookups
   must key on the raw code the `teams` table stores; `TeamAbbrChip` grew a `displayText`
   override for exactly that split.

**Caveat:** this is a *presentation* disambiguation. The underlying `team_abbr` in
`player_seasons` is still colliding, so any other consumer (Draft & Spin's roster fetch already
passes `league`; Browse/Keep4 do not) can still merge clubs. The real fix is resolving codes at
ingest time — see `soccer-club-code-collisions`, which notes a prod migration needs a CSV regen
because only the code, not the club name, is stored.

---

**One correction worth recording,** so nobody re-derives it: `curl -I` against the storage bucket
reports `cache-control: no-cache`, which looks like `logos.py`'s upload header never took. It did.
A real `GET` returns `public, max-age=31536000, immutable` and `cf-cache-status: HIT`, and
`storage.objects.metadata->>'cacheControl'` confirms the stored value. Supabase's HEAD path just
doesn't apply stored object metadata. CDN caching is fine — the problem is entirely on the client.

---

## 9. Where to go next

Ordered by value-per-unit-risk, grounded in what this session actually measured rather than in
what sounds ambitious. Items 1–2 are release hygiene and should happen before anything new.

### Gate 0 — ship what's already built (blocking everything below)

1. **Cut a client build carrying the v2 Grid decoder**, then and only then run
   `python -m tools.ingest.main --grid <sports> --upsert`. The ordering is not a preference: a
   teams × teams board has no legacy `rowTeams`/`colDecades` fallback, minted boards are
   immutable for their day, and the app is live. Pushing first strands every existing user for
   that sport that day, unrecoverably.
2. **Watch the first week of real boards.** `grid_history` now records the archetype implicitly
   via the axis keys; a quick query over `puzzles.content->>'archetype'` tells you whether the
   weighted rotation is actually producing the mix intended (4/3/3/4) or whether one sport keeps
   failing viability into a single shape. Soccer is the one to check — its team × team boards
   drew obscure clubs (`PAG-GRE`, `GDE-POR`) even after the prominence cap.

### Tier 1 — finish the Immaculate-parity story

3. **Crowd rarity should drive scoring, not just decorate the recap.** This is the biggest
   remaining product gap and the data is already flowing. `grid_guesses` collects every ranked
   answer and `grid_guess_stats` aggregates it, but scoring is still
   `solved × 100 + stars × 20`, where `stars` is derived from *how permissive a cell is* at
   generation time. That means the optimal play is still the most famous name — exactly the
   problem Sports Reference retrofitted crowd rarity to solve. Evidence it matters: on the old
   teams × decades boards, **all nine cells came back 1-star** on live NFL data; the new
   archetypes spread 1–5, which helps, but it still measures the cell rather than your answer.
   Golf-style scoring (sum of "% who gave your answer", +100 per blank) would also make the
   emoji share meaningful to compare.
4. **Awards axes.** The one Immaculate Grid category type we have no data for at all — MVP,
   Pro Bowl, All-Pro, rings, Ballon d'Or. Highest flavour per axis ("Chiefs × MVP" is a better
   question than "Chiefs × 4,000+ Pass Yds"), but it is a genuine new ingest, not a re-slice.
   Scope it as one provider + one join, like any other in `tools/ingest/providers/`.
5. **Career-grain stat axes.** "10,000+ Career Passing Yards" — Immaculate Grid's journeyman
   cheat-code cell. The `career=true` rows already exist (4.5k NFL / 6.6k MLB / 14.8k soccer /
   3.5k NBA / 1.1k tennis) but `fetch_player_seasons` hard-filters `career=eq.false`, and the
   grain model in `grid_axes` already has the `career` concept wired. Mostly plumbing.
6. **Bio axes (college, draft round).** Needs a schema change first: `player_seasons` has no
   `meta` column, so the bio fields `nfl_players.py` collects never reach the catalog. Lowest
   priority of this tier — real work for one sport's worth of axes.

### Tier 2 — correctness debt this session surfaced but did not fully fix

7. **Resolve soccer club codes at ingest, not at render.** §8's fix is a *presentation*
   disambiguation scoped to The Grid. `player_seasons.team_abbr` still collides, so Browse,
   Keep4 and any future consumer can still merge Manchester City with Melbourne City. The real
   fix is a resolved code at ingest time — note the prior finding that a prod migration needs a
   CSV regen, because only the code, not the club name, is stored.
8. **Rarity-star thresholds are calibrated for a catalog that no longer exists.**
   `_rarity_stars` buckets at 1/3/7/14 valid answers, which was tuned before `nfl_rosters`
   widened NFL cells to 149–425 answers. Either recalibrate against the live distribution or
   retire stars entirely in favour of item 3.

### Tier 3 — polish with real numbers behind it

9. **Finish the Draft & Spin latency story.** The reel now hides the roster fetch, but
   `spinUntilFillable` still validates candidates *sequentially* — up to six round trips at
   0.32–0.43 s each. Spinning three candidates up front and fetching their rosters concurrently
   would cap the pathological case at one round trip. Determinism is safe: the per-round RNG is
   re-seeded from `dailyDraftRoundGenerator(sport:date:roundIndex:)`, so pre-spinning advances
   state identically for every player.
10. **Extend `RemoteImage` to the remaining image surfaces.** All 11 crest/headshot call sites
    are converted, but the win was measured on crests specifically. Headshots come from ESPN and
    nflverse, have no transform endpoint, and are the larger payload — worth measuring before
    assuming they benefit equally.
11. **Full-name team labels.** `MCI-ENG` is unambiguous but not friendly. The `teams` table
    already carries `full_name`; a Grid axis could ship it for the guess-sheet prompt ("Manchester
    City · 1990s") while the chip keeps the short code. Cheap, and it makes the prompt read like
    a question rather than a key.
