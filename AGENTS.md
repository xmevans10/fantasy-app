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

## 7.1 A red test is a claim about *something* — find out what, before you touch product code

`PurchaseFlowTests` (all five purchase cases) fails on the **iOS 26.5 simulator runtime** with
`SKTestSession` logging `Error Domain=SKInternalErrorDomain Code=3` on every operation —
`saving configuration file`, `clearing overrides`, `deleting all transactions`. The visible
symptom is a real "Sign in to Apple Account" dialog appearing mid-test, because
`session.disableDialogs = true` silently doesn't apply either. The purchases then never
auto-approve, so entitlements are never granted and the assertions fail.

None of that is a product bug. Measured 2026-08-07:

| runtime | result |
|---|---|
| iOS 26.5 (Xcode 26.5) | 5 failures, 35 `SKInternalErrorDomain Code=3` |
| iOS 26.5, **brand-new simulator** | identical — so it isn't corrupted device state |
| iOS 18.3 | **7/7 pass, 0 SK errors** |

The mechanism, from a throwaway diagnostic test (worth rewriting if you ever need it again):
the initializer *succeeds*, then every operation on the session no-ops. `session.storefront`
comes back empty, and `disableDialogs = true` **reads back `false`** — the write is silently
dropped. Products still resolve at the config file's prices, which is what makes the failures
look real rather than environmental.

Two hypotheses were tested and **both were wrong**, so don't spend the time again:

- *"The Test action is missing the scheme's StoreKit configuration"* (it's only on the Launch
  action). Adding it changed nothing.
- *"The scheme config and the test's own `SKTestSession` are competing for the process"* — the
  Test action does inherit it via `shouldUseLaunchSchemeArgsEnv = "YES"`. Setting that to
  `"NO"` dropped the error count 35 → 4 and looked promising for about a minute, then the run
  **hung for an hour on `nw_read_request_report … Operation timed out`**: with no configuration
  at all, StoreKit falls through to the real App Store over the network. The scheme config was
  the only thing serving the catalog; the test's own session never worked on this runtime.

**The fix in place:** `PurchaseFlowTests.setUpWithError` writes `disableDialogs` and reads it
back, and `XCTSkipUnless`es the class when the value didn't stick. That's a probe of the actual
symptom rather than a version check, so the suite is honestly green on 26.5 (7 skipped in
0.06s instead of 5 failures after ~40s each) and **starts running again on its own** when Apple
fixes the runtime. Skipped tests are not coverage: run the purchase suite on 18.3 before
shipping anything that touches purchases.

**Rule:** when a test in an area you did not touch goes red, establish *where* it's red before
concluding anything — a second runtime, a pristine simulator, and the commit that added the
test are all cheap. Two wrong moves are available here and both look productive: "fix" working
purchase code to satisfy a broken harness, or weaken the assertions until they pass. And when
you do form a theory, kill it with an experiment rather than shipping it — the "competing
configurations" story above was coherent, partially supported by the error count, and false.

Related trap from the same session: the first full run also failed
`GridBoardGalleryTests.testRenderEveryArchetype` and four purchase cases — because the agent
was terminating and relaunching the app **on the same simulator while the suite was running**.
That test needs the hosted app's window. Don't drive a simulator that a test run is using.

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

## 11. The decision ladder — write the least code necessary (Ponytail discipline)

Adopted from [ponytail.dev](https://ponytail.dev/); its actual plugin isn't installed in this
repo (installing a marketplace/plugin means letting a third-party GitHub repo's code execute
in the agent's environment — that's a deliberate call for a human to make, not something to
wave through on an AI's own judgment; see the note at the bottom of this section). The
*ruleset* is adopted directly as text here instead, so it governs regardless of which tool or
harness is running — this is really just a sharper restatement of CLAUDE.md's own "don't add
features/refactor/abstractions beyond what the task requires," made into a concrete, ordered
checklist.

**Before writing any code, work through these in order — stop at the first one that fits:**

1. **Does this need to exist at all?** (YAGNI) — if the task doesn't actually require it, skip it.
2. **Is it already in this codebase?** — reuse existing code (§4/§10 above are this rung applied
   to sport/position tables and debug flags specifically).
3. **Does the standard library do it?** — Python stdlib / Foundation / SwiftUI before a helper.
4. **Is there a native platform feature?** — a SwiftUI modifier, a PostgREST filter, a stdlib
   `datetime`, before hand-rolling the equivalent.
5. **Is it an already-installed dependency?** — e.g. reach for `ConfettiSwiftUI` (already
   vendored) rather than a second confetti implementation.
6. **Can it be a one-liner?** — write the one-liner.
7. **Only then**, write the minimum custom implementation the problem actually needs.

The ladder activates *after* you've read the affected code and traced the real data flow
(§3 above) — this is "lazy about solutions, never about reading." It does not relax
trust-boundary validation, data-loss handling, security, or accessibility; those stay
mandatory regardless of which rung you land on.

**Note on the plugin itself:** if you want the actual `/ponytail-review`, `/ponytail-audit`,
and `/ponytail-debt` slash commands (diff-scoped over-engineering scans, a repo-wide audit, a
deferred-simplification ledger), install it yourself — `claude plugin marketplace add
DietrichGebert/ponytail` then `claude plugin install ponytail@ponytail` — after reviewing what
it does; an agent shouldn't add third-party plugin sources to your Claude Code config on your
behalf even when asked to, the same way it shouldn't `curl | sh` an unreviewed script.

## 12. When a session goes wrong, repair the context — not just the code

Adopted from *Trace: TRajectory Attribution for Automated Context Engineering* (Amazon,
[arXiv:2608.09153](https://arxiv.org/abs/2608.09153)), the same way §11 adopts ponytail.dev's
ruleset as text rather than as a tool. Its finding: in a deployment like this one, agent
failures are overwhelmingly *context-layer* failures — a stale procedure, a fact nobody wrote
down, a command quoted wrong — and the repair belongs in the context files, not in the model
and usually not in the product code.

This repo is the evidence. The memory directory is, read honestly, a list of times a session
burned real hours on something no file said: that the `supabase` CLI is authenticated to a
different account than this project; that an inactive Paid Apps Agreement returns an empty
product fetch with no error anywhere; that two Supabase decoders exist and the wrong one turns
every row into `[]` — which hid the entire Versus tab for *months*. Every one of those was
diagnosed once, at cost, and the only thing that stopped it recurring was writing it down.

Three mechanics are worth following exactly, because the paper measured the alternatives:

- **Attribute in one backward pass, not step by step.** Read the whole session at once, in
  reverse order, and find the *earliest* point inconsistent with "expected X, got Y." Walking
  forward step-by-step asking "did this one contain the error" scored half the accuracy at 16×
  the cost, because everything downstream of a bad fact contains the error and only one step
  introduced it.
- **Read the file before deciding CREATE vs UPDATE.** Verifying by opening the target scored
  83% against 33% for inferring it — and reading *overturned* the initial diagnosis 67% of the
  time that diagnosis was wrong. This is the same instinct as §1 (verify against the live
  system) pointed at the docs instead of the data.
- **Treat an implicit signal as a real one.** The user rephrasing a request, re-stating a
  constraint they already gave, or correcting a fact you stated confidently is the signal that
  a context source failed. Waiting to be told "update CLAUDE.md" means it never gets updated.

**Rule:** when the user corrects a fact you asserted, when a documented command or contract
turns out to be wrong, or when you had to grep for something the docs should have told you —
that is a defect in `CLAUDE.md` / `AGENTS.md` / `docs/BALLIQ_SPEC.md` / the memory directory /
a subagent brief, and fixing only the immediate task leaves it in place for the next session.
Diagnose it and write the smallest correct fix in the same session. The full loop — signal
taxonomy, attribution procedure, verification before writing, CRUD table, and what *not* to
repair — is the `context-repair` skill (`.claude/skills/context-repair/SKILL.md`).

Two guardrails: not every failure is a context failure (a plain bug with no documentary cause
is just a bug — the skill's NO_ACTION path exists for that), and this loop is a diagnosis plus
a small write, never a licence to turn a bugfix session into a documentation project.

## 13. A declaration can be authoritative-looking and stale — grep the call sites

Twice in one session (2026-08-26), across two different agents, a fact about *behaviour* was read
off a declaration that looked authoritative and was wrong. Both were caught only by grepping
producers, and each failed in the opposite direction:

- **The type system said independent; the convention wasn't.** A proposed rule counted
  `GameResult.mode == .daily` as a proxy for "was rating-eligible". `PlayMode` genuinely *is* a
  separate field from `ranked`, which is what made it attractive. But `DraftSpinView:642` writes
  `mode: .daily` beside a hard-coded `ranked: false`, and `OverUnderGameView:396` hard-codes
  `.daily` on every run while `ranked` varies — two call sites using `.daily` as a *surface* label.
  Nothing in the enum warns you. Three arcade spins would have silently consumed a new player's
  entire placement window.
- **The doc comment said one caller; there were six.** `RepositoryContainer.logSession`'s comment
  reads *"Exists for Grid practice"*. It has been the duel path for all four formats since duels
  shipped (`WhoAmI:421`, `Keep4:401`, `Journeyman:345` and `:748`, `Grid:438` and `:454`) and the
  comment never caught up. A brief was written on its authority and had to be corrected.

**Rule:** when a fact about how something *behaves* is load-bearing — especially when it decides a
gate, a count, or an invariant — grep the call sites before asserting it. A type signature tells
you what is *possible*; only the producers tell you what is *done*. Doc comments and enum cases age
badly precisely because they keep compiling.

The corollary is the cheaper half: when you find a declaration that has drifted, fix it in the same
change *if you are already editing that region*. If you are not, note it for whoever will be —
adding a file to your branch to correct a comment can create a merge collision that costs more than
the drift does (this is why the `logSession` comment was left for the M30 implementer, who is
editing `complete()` directly above it).
