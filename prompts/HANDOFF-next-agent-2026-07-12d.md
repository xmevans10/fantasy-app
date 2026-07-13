# Handoff — continue BallIQ development (2026-07-12, session D)

You are the orchestrator agent for this repo. Read `CLAUDE.md`, `AGENTS.md`, and
`docs/BALLIQ_SPEC.md` §9.0 before doing anything else — §9.0 is not optional context, it
is the actual mandate for this session: **the user set an explicit priority order
(performance, then unbuilt features/functionality, then launch/polish — "make it fast,
make it crisp, make it sturdy") that supersedes the older impact-ordered P0–P3 backlog
as the sequencing rule.** Your job this session is to organize the work under that
framework and dispatch subagents to execute it, working Tier 1 to done before starting
Tier 2, and Tier 2 before Tier 3.

## 0. FIRST ACTION — review and commit the uncommitted tree

Nothing from the prior session (2026-07-12, session C) was committed yet:
- `CLAUDE.md`, `docs/BALLIQ_SPEC.md` — the priority framework (§9.0) and a pointer to it,
  written this session.
- `tools/ingest/providers/espn_soccer.py`, `tools/ingest/tests/test_espn_soccer.py`,
  `tools/ingest/data/soccer_espn_seasons.csv`, `tools/ingest/main.py` (merge wiring) —
  the ESPN soccer provider (Tier 2 item, see §2 below): validated end-to-end (190 tests
  passing, real `usa.1`/2024 data, confirmed merge into the main pipeline), but only
  backfilled for that one league/season so far.
- `tools/ingest/content_health.json` — touched as a side effect of running
  `main.py --dry-run` during validation, not hand-edited.

Review the diffs, then commit (in whatever grouping makes sense — the docs and the
soccer-provider work are unrelated changes and probably want separate commits).

## 1. Tier 1 — Performance ("make it fast"). Start here, and stay here until it's done.

`docs/BALLIQ_SPEC.md` §9.0 has the full context; the short version:

**Confirmed live this session**: Over/Under's first cold launch of an app session takes
~15 seconds to show its first card, versus ~3.5s for every other minigame format (Keep4,
WhoAmI, Draft & Spin, The Grid). This is backlog item #3 ("cold-launch speed: persist the
arcade pools to disk") — already-known and already-scoped in the SPEC, now empirically
confirmed rather than theoretical.

Your job:
1. Root-cause Over/Under's specific cold-launch path — find what it fetches/computes on
   first launch that the other formats don't, or that isn't covered by the in-memory
   prefetch/caching added 2026-07-09.
2. Fix it, most likely via the disk-backed cache #3 already proposes (TTL ~1 day, same
   shape as the ingest pipeline's own `.cache/` — see `tools/ingest/providers/http.py`
   for that pattern, though this is Swift-side so it won't be the same code, just the
   same idea).
3. **Audit the other 4 formats' cold-launch times the same way** — this session only
   measured Over/Under; the same gap may exist elsewhere and wasn't checked.
4. Verify with a real cold-launch timing measurement (uninstall, fresh install, launch,
   time-to-first-content), not just "it feels faster" — same rigor as the rest of this
   repo's verification culture (`AGENTS.md` §7/§9).

This is real app-code work (SwiftUI + whatever caching layer needs to change) — a good
fit for the `balliq-swift-feature` subagent (model: Sonnet 5) once you've scoped the
root cause yourself; don't dispatch a subagent to go find the bug blind, dispatch it
once you know what needs to change and can give it a concrete brief.

## 2. Tier 2 — Unbuilt features/functionality ("make it crisp"). Only after Tier 1 is done.

Full detail in SPEC §9.0. In rough dependency order:
1. **ESPN soccer provider full backfill** — lowest-risk, most mechanical item in this
   tier, and already has a validated, working provider (see §0 above). Just needs the
   remaining ~37 leagues × their full historical range run through `refresh()` (see the
   module's own docstring for the exact scope/estimate — it's a genuine multi-hour job,
   background it). Good `balliq-data-provider` subagent work.
2. **Share sheet + Keep4 scoring-info popover** — didn't render during this session's
   full-app screenshot pass (`-screenshotShare`, `-screenshotScoringInfo`). Almost
   certainly just need to be combined with a game-context launch flag rather than
   launched standalone (untested, not confirmed broken) — verify which it is before
   assuming a fix is needed.
3. **Push notifications end-to-end, post-completion daily loop, daily Draft & Spin
   challenge mode, arcade leaderboards, Leagues season bootstrap** — backlog #1/#2/#4/
   #5/#6, unchanged from the existing SPEC §9 detail, no new information this session.
4. **Phase F rating seasons (backlog #7) — do NOT start building.** Confirmed
   genuinely underspecified (three one-line mentions, no schema, no reset/decay
   decision, no reward definition). If you reach this item, the next step is a scoping
   conversation with the user, not code.
5. **M19/M20 TestFlight QA** — needs two real signed-in human accounts, not agent-
   executable. You can prep a concrete test checklist to make the human pass fast, but
   the pass itself isn't schedulable as agent work.

## 3. Tier 3 — Launch/polish ("make it sturdy"). Only after Tier 1 and Tier 2.

Full detail in SPEC §9.0: defunct-franchise team styling (#8), widen historical
headshot slices (#9 — **this session's UI pass directly observed the symptom**: a
placeholder icon instead of a real photo in WhoAmI's answer card and a Draft & Spin
lineup row, both traced to the bundled offline sample's limited coverage, not a code
bug), M14 Spanish localization (#10, already well-scoped in
`prompts/M14-accessibility-and-localization.md`), content-drift guard (#11).

## 4. Method

Same orchestration pattern as prior sessions (see `prompts/HANDOFF-next-agent-
2026-07-12.md` §2 for the full original writeup): recon yourself first, own shared
plumbing directly, dispatch subagents for genuinely disjoint implementation work with
an explicit file-ownership brief. Two custom subagents now exist for this —
`balliq-swift-feature` (Sonnet 5, app-code work) and `balliq-data-provider` (Sonnet 5,
ingest-pipeline work) — use them by name via the `Agent` tool's `subagent_type`
parameter. (Note from session C: these weren't recognized mid-session because they were
added to `.claude/agents/` and committed in the same session that tried to use them —
a fresh session, like this one, should see them correctly. If `subagent_type:
"balliq-swift-feature"` still 404s, fall back to `general-purpose` with the subagent's
`.claude/agents/balliq-swift-feature.md` file content pasted into the brief, same as
session C did.)

Verification bar per subagent dispatch: own `-derivedDataPath` for Swift work, full test
suite before reporting done, `pytest tools/ingest/tests -q` for Python work — both
subagent definitions already encode this, just confirm the dispatched agent actually
did it rather than asserting it.
