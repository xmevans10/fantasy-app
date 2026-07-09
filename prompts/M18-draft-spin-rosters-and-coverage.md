# M18 — Draft & Spin: perfect the per-round mechanic + real full-roster data coverage

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.
> Read [docs/BALLIQ_SPEC.md](../docs/BALLIQ_SPEC.md) — search "Draft & Spin" for the full history
> of this format's three prior iterations this session (all shipped, all superseded by the next
> one). This prompt is the fourth pass, and should be the last: the mechanic itself is now
> confirmed correct against a reference video; what's left is real data depth.

## Goal

Draft & Spin's core interaction is now built and verified correct against a user-supplied
reference recording. What's missing — and the reason this needs a dedicated session rather than
more iteration inside an already very long one — is **data coverage**: the catalog only has
curated top-performer pools per sport, not real complete team rosters, for any year. The user's
own words: *"We need every team roster for all years. For all sports."* That is a pipeline-scale
data problem, not a UI problem, and deserves focused, unhurried attention.

## Why now — what already shipped this session, and why it kept changing

Four consecutive redesigns of Draft & Spin happened in one session, each correcting a real
misunderstanding the previous one had:

1. **v1 (position-slotted, blind pick):** spin one (team, year), fill fixed QB/RB/WR/TE/FLEX
   slots from that one roster, stats hidden until picked. Shipped, tested, stress-tested across
   all 5 sports — then the user clarified this wasn't the ask at all.
2. **v2 (still one spin per session, "Starting XI"-style formations):** same single-spin
   structure, but real formations per sport (NFL 7 slots, NBA "Starting 5", soccer 8-slot
   formation, baseball 6 slots) with a slot-machine reveal animation added for juice. Also
   fully stress-tested live, including finding and fixing two real bugs along the way (see
   below) — then the user sent a **screen recording of a reference competitor app**, which
   showed a materially different mechanic.
3. **v3 (per-round spin, era buckets, visible stats):** rebuilt to match the video exactly —
   *every round* spins its own (team, era-range), full player stats are **visible** (not
   hidden), the player browses a real position-grouped/filtered roster list, taps a player to
   expand extra stats and highlight which open lineup slots their position can fill, then taps
   a slot to assign. Repeats until the lineup is full. This is the mechanic that's right.
4. **v4 (this state, era → year):** the user then clarified the second spin reel should be an
   **exact single year**, not a 5-year era range — the video's "1999–2005"-style buckets were
   not actually what they wanted, just what the reference app happened to show. Code and tests
   updated accordingly; this is believed correct now, but **has not yet been re-stress-tested
   live across all 5 sports post-change** — do that first, before touching data coverage, to
   confirm nothing regressed in the swap.

**Two real bugs were caught by live stress-testing in step 2** and are worth knowing about
before touching the pipeline further, since they'll resurface if coverage work bypasses the
same code paths:

- `PlayerSeasonCatalog.fetchRemote` had no `order=` clause and no pagination, so any broad,
  unfiltered fetch (Draft & Spin's whole-sport sample; Over/Under's pool) silently returned an
  arbitrary, non-representative slice regardless of the requested `limit` — PostgREST caps a
  single response at its own server-configured max (this project: 1000 rows) and, without an
  `order=`, doesn't even guarantee the *same* slice across calls. This is the identical bug
  class the Python Grid pipeline (`fetch_player_seasons`) already hit and fixed; it just hadn't
  been ported to the Swift client. Fixed with stable `order=id` + real `Range`-header pagination
  in `SupabaseClient.restRequest`/`select`.
- Even after that fix, a **sample** dense enough to correctly *pick* a good (team, year) is not
  necessarily dense enough to carry that combo's **complete** roster (verified live: a sample
  correctly identified a real best-filled team-year, but only carried a fraction of its actual
  players). Fixed with a two-phase fetch: a broad sample only decides *which* (team, year) to
  spin; the exact combo's full roster is then re-fetched separately before it's shown.

Any new data-coverage work should assume both of these are real, load-bearing fixes — don't
revert the `order=`/pagination change, and keep the discover-then-fetch-complete-roster shape
if adding new fetch paths.

## Current state (verified, not assumed — re-check before building on it)

**Swift, already built and passing 215 tests:**
- `BallIQ/Models/DraftSpin.swift` — `DraftSpinLineupSlot`, `DraftSpinRound` (team + year + real
  roster), `DraftSpinConstraint` (per-sport `formations`, `lineupSlots`, `sportOfTheDay`,
  `spinRound` — the year-based discover-a-viable-combo logic, `eligibleSlots`).
  `DraftSpinSimulator`/`DraftSpinResult` (season sim + outcome tiers) are unchanged from earlier
  work and still correct.
- `BallIQ/Features/DraftSpin/DraftSpinView.swift` — the full round loop: spin → reveal → browse
  (position tabs, grouped list, real visible stats, tap-to-expand) → tap-to-assign → repeat →
  simulate → result. `SpinRevealView.swift` — the two-reel slot-machine animation (team + year).
- `BallIQ/Backend/SupabaseClient.swift` / `BallIQ/Data/Repositories/PlayerSeasonCatalog.swift` —
  the ordering + pagination fix described above.
- **Not yet built:** the reference video's setup screen (Roster Both-sides/Offense-only, Teams
  All/One-team lock, Season Variations On/Prime-only). This session deliberately deferred it to
  ship the core loop; it's still a real gap — see Scope below.

**Data (Python pipeline + live Supabase project `nhccgufqwndtoasdbkhc`), measured this session:**

| Sport | Total rows | What it actually is | Real per-team-year depth |
|---|---|---|---|
| NFL | ~15,853 | Every player nflverse's season aggregate reports (not just leaders) | Good: median team-year has 2-3 QB, 3-6 RB, 5-8 WR, 2-4 TE |
| Baseball | ~47,898 | Every player MLB Stats API reports, plus a curated marquee-name list unioned on top | Good: median team-year has 8-15 hitters, 6-14 pitchers |
| NBA | ~8,141 | A **curated pool** of ~850+ notable players (`espn_nba_pool.py`), not every NBA player ever | Moderate: median team-year has 2-4 per G/F/C, but bench/replacement-level players are systematically missing — the pool itself is the ceiling |
| Soccer | ~1,250 live (FW/MF only) + ~32 seed (GK/DF) | API-Football's free tier returns only the **top ~20 scorers/assists per league-season** — never a full squad; GK/DF are permanently hand-curated (no live source has ever been found for them, verified twice this session) | Severe: only 2 clubs in the *entire* catalog (Chelsea, Liverpool) have ever had a real DF row; most team-years cover 1-2 of soccer's 4 real positions |
| Tennis | ~20 total | Fully hand-curated (no live source exists — verified twice, including a fresh check this session that the previously-assumed source repo is gone) | Minimal by nature: an individual sport, "team" is a country code, and a given country+year combo essentially never has >1 real player |

**The honest headline: "every team roster for all years, for all sports" is not achievable for
soccer and tennis without a paid/different data source** — this isn't a pipeline effort problem,
it's a data-availability ceiling already hit and documented twice this session
(`providers/api_football.py`, `providers/seed.py` module docstrings). NFL and baseball are
already close to "every real contributor," not just leaders — the gap there, if any, is width
(more historical years) rather than depth (more players per year already-covered). NBA is the
one sport where a **meaningfully better free/cheap source could plausibly close a real gap** —
worth investigating first.

## Scope

1. **Re-verify the mechanic post year-vs-era change.** Rebuild, run the 215 Swift tests, then
   stress-test live in the simulator across all 5 sports exactly like the prior session did
   (screenshot each sport's round 1 board + a full auto-played result via
   `-screenshotDraftSpin`/`-screenshotDraftSpinResult -draftSpinSport <sport>`). Confirm the
   YEAR chip shows a real single year everywhere, reroll still works, and nothing about the
   era→year swap silently broke soccer/tennis (their sample-viability logic no longer buckets by
   era window — check it still finds real viable combos, not just NFL/NBA/baseball).
2. **Build the deferred setup screen** (Roster Both-sides/Offense-only, Teams All/One-team lock,
   Season Variations On/Prime-only) from the reference video, *if* time remains after data
   coverage — this is real scope but secondary to the data problem, and was explicitly deferred
   for that reason.
3. **Data coverage, per sport, prioritized by real payoff:**
   - **NBA first**: investigate whether a real full-roster source exists beyond the current
     curated `espn_nba_pool.py` list (~850 players) — e.g. a season-by-season roster endpoint
     rather than a fixed name pool. If one exists, this is the sport where coverage work has
     the clearest win.
   - **NFL/baseball width**: confirm via `tools/ingest/health.py`'s `catalog_depth_report` (already
     built this session) whether any *specific* years are thinner than others (e.g. very old
     seasons) rather than assuming uniform depth — nflverse/MLB Stats API coverage may thin out
     going backward.
   - **Soccer/tennis**: don't re-attempt the same dead ends already verified twice
     (`providers/api_football.py`/`providers/seed.py` docstrings document exactly what was
     ruled out and why). If a genuinely new source is found, integrate it; otherwise, the
     honest move is documenting the ceiling clearly in `BALLIQ_SPEC.md` rather than continuing
     to search.
4. Whatever coverage lands, **re-run `DraftSpinConstraint`'s live stress test** (per sport,
   screenshot round boards) to confirm real improvement — a bigger `player_seasons` table only
   matters if it actually produces richer rounds; verify it, don't assume it.

## Key decisions (already made — don't re-litigate without new information)

- **Per-round independent spin**, not one spin for the whole lineup — confirmed via the
  reference video and explicit correction.
- **Stats fully visible**, not hidden/blind — confirmed via the reference video (directly
  contradicts an earlier verbal instruction in this session; the video is authoritative).
- **Exact single YEAR**, not a multi-year era range — confirmed explicitly, overriding what the
  reference video itself showed (the video's "ERA" buckets were not what the user actually
  wanted, just a visual similarity worth noting, not replicating).
- **Real per-sport lineup formations** (NFL 6: QB/RB/WR/TE/FLEX/FLEX; NBA 5: G/G/F/F/C; soccer
  8: GK/DF/DF/MF/MF/MF/FW/FW, largest the data can ever fill; baseball 6: Hitter×4/Pitcher×2;
  tennis 3 independent rounds, no formation) — grounded in live-measured depth, not guessed.
- **Soccer's DF/GK stay permanently seed-only** and **tennis stays permanently seed-only** —
  verified twice now that no live source exists for either. Don't re-investigate the exact same
  question a third time; only act on this if a genuinely new candidate source surfaces.

## Verification

- `pytest tools/ingest/tests` (if any pipeline changes) and the full Swift suite
  (`xcodebuild ... test`) after every change — both currently green (215 Swift tests).
- Live stress test, every sport, both the mid-draft board and the full result reveal, via the
  existing debug flags — this is the verification method that caught both real bugs described
  above, and is very cheap to re-run (a build + `simctl install` + a launch/screenshot loop, no
  manual tapping needed since `-screenshotDraftSpinResult` auto-plays through every round).
- For any new data-coverage claim ("NBA now has full rosters"), verify with a live SQL query
  against `nhccgufqwndtoasdbkhc` (project id) — count distinct players per (team, year,
  position) before and after, the same method used to establish the baseline numbers above.
  Don't claim a coverage improvement without a live before/after count (AGENTS.md §9).

## Hand-offs

- The setup screen (Roster/Teams/Season-Variations config) is real, deferred scope — build it
  if there's time after data coverage, since it's smaller and lower-risk than the data problem.
- If NBA's roster source turns out to be a dead end too (no better free option), say so plainly
  and move on — matching this session's own established norm of documenting a real ceiling
  rather than quietly re-trying the same search.
