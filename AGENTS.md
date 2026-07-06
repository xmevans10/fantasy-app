# AGENTS.md — how to work at the right quality bar in this repo

This file is about *process*, not facts. For project facts (build commands, architecture,
credentials, established gotchas) see [CLAUDE.md](CLAUDE.md) and
[docs/BALLIQ_SPEC.md](docs/BALLIQ_SPEC.md) — read those first. This file is what separates a
change that merely compiles from one that's actually correct, and it's written from concrete
mistakes and catches made while working this repo, not generic advice.

## 1. Verify against the live system, not the artifact in front of you

The bundled offline fallback (`BallIQ/Data/player_seasons.json`) is a deliberately trimmed
~500-row sample. Early in a "check our data coverage" pass, reading only that file said
baseball had 280 rows. The real number — queried live from Supabase — was different, and
the true gap (23 hardcoded MLB player ids feeding the *live* catalog) was invisible from the
bundle alone.

**Rule:** when asked about coverage, counts, or "is X working," query the live/production
source of truth (Supabase via the service-role `.env` key or MCP tools) before drawing a
conclusion from a local fallback, cache, or bundle. If you can't reach the live system, say
so explicitly rather than reporting the bundle's numbers as if they were current.

## 2. A literal that encodes "now" will go stale — compute it instead

`tools/ingest/main.py` had `DEFAULT_NFL_YEARS = list(range(1999, 2024))` — a value that was
correct the day it was written and silently wrong every year after, quietly dropping entire
NFL seasons from ingestion with no error, no test failure, nothing. Same pattern was found
independently in two other files (`espn_nba_pool.py`, `mlb_pool.py`).

**Rule:** any constant derived from "today," "this year," or "the current season" should be
computed from `dt.date.today()` (or equivalent), not hardcoded — *provided* the code that
consumes it degrades gracefully on an out-of-range value (confirm the fetch loop skips a
missing/future year rather than raising). When you find one stale literal of this shape,
grep for the same pattern elsewhere; it's rarely isolated.

## 3. Trace the actual data flow before patching a symptom

A screenshot showed a QB card with zeroed-out "Rec Yds / Rec TD / Rec" — WR stats on a QB.
The fix wasn't "hide zero stats" or "pick different mock data" — it required reading
`CreateKeep4View.defaultStatLines`, finding it called `ScoringStat.catalog(for: sport).prefix(3)`
with **no position parameter at all**, and recognizing that the NFL catalog's first three
entries happen to be receiving stats (a WR-flavored ordering), so *every* Vibes puzzle mixing
positions inherited that ordering regardless of what a given card's player actually played.

**Rule:** when a user reports "X shows the wrong thing," find the exact function that
produces X and read what it actually does with the actual inputs, before writing a fix.
Guessing at a plausible-sounding cause and patching that is how surface-level fixes leave
the root bug in place for the next similar report.

## 4. One shared table beats N per-case special implementations

`Keep4Theme.columns(for:)` already had a private, NFL-only `nflPositionStats` prefix table to
solve exactly the position-column problem above — for *themed* daily puzzles. The free-form
Create flow (`ScoringStat`) had no equivalent, so the same class of bug existed there
independently, undetected. The fix moved the table onto `Sport` (`positionStatFamilies`,
covering NFL *and* baseball H/P *and* soccer GK/DF/FW/MF) so both call sites — and any future
one — share a single definition instead of two independently-drifting copies.

**Rule:** before writing sport-specific or position-specific logic, grep for whether a
similar table/switch already exists elsewhere in the codebase for a sibling feature. If it
does, extract and share it rather than writing a second one that will inevitably diverge. If
you're asked to make something "reproducible/templated across N variants," that's a request
to find and eliminate exactly this kind of duplication, not to add a fourth `case .soccer:`
next to three existing ones.

## 5. Actually render UI changes — screenshot before AND after

A layout bug (a long "ERA-ADJUSTED" badge starving the "K4C4" label down to a bare `…`) was
only caught by screenshotting the Browse tab filtered to the specific theme that had a long
badge string — NFL/NBA screenshots alone looked fine, because their badges happen to be
short. The fix was verified by re-screenshotting the *same* filtered view, not just by
rebuilding successfully.

**Rule:** for any visual change, screenshot the specific states most likely to break (longest
text, most items, smallest screen, every sport a shared component renders for — not just the
first one you think to check), both before and after. A green build proves the code compiles,
not that it looks right. When a shared component renders for multiple sports/kinds, check
the one with the outlier content (longest label, fewest stats, no team, etc.), not just NFL.

## 6. Don't claim "fixed" without confirming it — and know the difference between a bug and a documented limitation

A Python test (`test_content_drift.py::test_bundled_wr_grades_match_current_formula`) failed
on "CeeDee Lamb 2023" both before and after a full data pipeline run. The test's own comments
say plainly: *"real drift... expected to fail"* — it's a self-documented, intentional test
limitation (the recompute-from-display-columns method can't see stats a card doesn't show),
not a regression from anything in this session. Earlier in the same session, this was
mis-described as "resolved" without re-running the test to confirm — an avoidable error.

**Rule:** re-run the actual test/verification after every change that could plausibly affect
it, even if you're confident. Before describing something as fixed, look for the test's own
docstring/comments explaining *why* it might legitimately still fail — a failure with an
explanatory comment already attached is a different situation than a fresh regression, and
conflating them misleads whoever reads your summary next.

## 7. Test after every meaningful change, not just at the end

This repo has fast test suites on both sides (`xcodebuild ... test` for Swift, `pytest
tools/ingest/tests` for Python — both complete in well under a second once built). There is
no excuse to batch five changes and test once at the end; run both suites after each
logically-complete edit so a regression is attributable to the change that caused it, not
buried in a pile.

## 8. Respect blast radius — extend established automation patterns, don't invent new authority

This repo already has a precedent: a daily CI job pushes real data to production Supabase
unattended (`ingest.yml`, `on_conflict=id` + merge-duplicates — additive and reversible). A
new weekly discovery workflow that commits refreshed id-pool JSON files and upserts newly
found players **follows that existing precedent** — same blast radius, same reversibility,
same "additive data change" category CLAUDE.md already blesses as fair game to just run.

Contrast: submitting a TestFlight build to **external** beta groups (widening who can see it)
is a different category — visible to people outside the org, not reversible by a revert
commit — and was correctly refused by the permission layer even under an explicit "upload to
TestFlight" instruction, because the instruction didn't clearly ask for that specific
widening. When in doubt about which category an action falls into, match it against the
closest existing precedent in the repo/org rather than reasoning from first principles.

## 9. Quantify claims — a status code, a count, a diff, not a vibe

"Soccer/tennis have thin coverage" is a vibe. "Live `player_seasons` has 17 soccer rows and 19
tennis rows, both seed-only, vs. 15,853 NFL and 38,704 baseball post-fix" is a claim someone
can act on. Before asserting something works, is missing, or is broken, get the actual number
(a row count, an HTTP status, a test pass/fail line) and cite it.

## 10. Extend the codebase's existing conventions before inventing a new one

Need to preselect a screen's filter for a screenshot? This repo already has a `DebugLaunch`
pattern (`-searchQuery`, `-screenshotGame`, etc.) for exactly this purpose — add one more
flag in that same shape (`-browseSport`) rather than reaching for simulator UI automation or
a bespoke debug hook. The same goes for provider caching (`providers/http.py`'s shared
on-disk cache + TTL), theme/column tables, and design tokens (`DesignSystem/Theme.swift`'s
`cardSurface`/`blockCard`/color roles) — grep for the existing mechanism first.
