# Handoff — post-backlog opportunity audit (2026-07-16)

## Goal

The documented roadmap is exhausted of agent-buildable product work. Your job is **not** to
re-mine `docs/BALLIQ_SPEC.md` §9 for a task — read it first to confirm that for yourself, then
pivot to a fresh audit: use the app like a real player across every surface, find real
functionality gaps and polish issues that aren't written down anywhere yet, and fix them.
This is the same mode that produced today's session's fixes (below) — none of which were in
any backlog doc; all were found by actually looking at cards and screens.

## Why now

Read `docs/BALLIQ_SPEC.md` §8 and §9.0 yourself before starting — don't take this summary as
a substitute. As of this handoff:
- **M1–M20 are all ✅ shipped** except M5 Phase B (monetization rating-season structure).
- **Phase F rating seasons** (backlog #7) — explicitly **deferred by the user** 2026-07-14.
  Do not start it from inference; if you think it's relevant, ask first. Scoping questions
  are already logged in `prompts/HANDOFF-next-agent-2026-07-12c.md`.
- **M5 Phase B monetization** — blocked entirely on a human-only App Store Connect step
  (Paid Applications agreement + real IAP products). Not agent-executable.
- **Push notifications** — infra is fully built and cron-verified; the only remaining piece
  is real APNs key material, which is the user's Apple Developer portal action, not yours.
- **M19/M20 TestFlight QA** — needs two real signed-in accounts; checklist is prepped at
  `prompts/QA-testflight-social-flows.md` but you can't run it yourself.

In other words: every named backlog item is either done, deferred, or blocked on the user.
That's *why* this handoff asks you to go find the next layer of issues yourself rather than
handing you a numbered list — there almost certainly isn't a clean one left.

## Current state to build on

- `origin/main` — check `git log --oneline -5` for the latest commit before starting.
- This session (2026-07-16) shipped three examples of exactly the kind of work you should be
  doing, for calibration:
  1. **Content gap**: `nfl-rb-workhorse` and `nfl-game-rb-explosion` Keep4 themes were
     missing a "Rec TD" stat column even though the data was already ingested for every
     position — found by literally looking at what a card shows, not by reading a spec.
  2. **UI bug (cross-cutting)**: iOS 26's Liquid Glass toolbar was clipping the `Wordmark()`
     logo into an illegible circle on *every* tab that uses it (Profile, Leagues, Versus,
     Community, Friends) — the user only reported it on one screen, but screenshotting the
     others showed it was universal. Fixed once, in one shared helper
     (`Wordmark.toolbarItem()` in `DesignSystem/Theme.swift`), not five times.
  3. **Missing feature**: profile avatars were a fixed 24-emoji set with no real photo
     upload. Built end-to-end: a Supabase Storage bucket + RLS, a hand-rolled upload path
     (no `supabase-swift` SDK in this project), a `PhotosPicker` flow, and — the part that
     would've been easy to skip — a shared `AvatarView` so the new photo-vs-emoji branch
     is correct at all ~9 existing render sites instead of just the one you were asked about.
- Read `AGENTS.md` in full before touching code. It is *not* generic advice — every rule in
  it is a mistake caught in this exact repo. The ones most relevant to an open-ended audit:
  - §1: query the **live** Supabase catalog before asserting coverage/counts — the bundled
    `BallIQ/Data/*.json` fallback is a deliberately trimmed sample and will mislead you.
  - §5: screenshot the outlier states (longest text, fewest stats, every sport a shared
    component renders for), not just the first happy path — that's where bugs like the
    wordmark clipping actually live.
  - §3: when something looks wrong, trace the function that actually produces it before
    patching the symptom.
  - §9: quantify — a row count, a test pass line, a screenshot — not "looks fine now."

## Scope

Play through the app end-to-end as a real user would, on the simulator (build + install +
`DebugLaunch` flags per `BallIQ/DebugLaunch.swift`, or interactive if you need to reach a
state no flag covers). Cover at minimum:
- All 5 game formats (Keep4, WhoAmI, Over/Under, Grid, Draft & Spin) — setup screen through
  result/share.
- Profile (signed-in and guest), Friends, Leagues, Versus, Community, Browse, Create (all
  three grains: season/game/career; both single- and cross-sport).
- The daily loop (both dailies done → countdown card) and the arcade leaderboards.

For each surface, look for:
- **Data quality**: cards/stats that are missing, zeroed, mislabeled, or use the wrong
  position's stat family — cross-check against what the live catalog actually has, not just
  what a card renders.
- **UI correctness**: clipped/truncated text, broken layouts on long content, redundant or
  dead-end controls, inconsistent use of shared design-system components (`AvatarView`,
  `TeamAbbrChip`, `blockCard`/`cardSurface`, etc.) vs. one-off hand-rolled styling.
- **Flow completeness**: any tap that goes nowhere, any state with no empty-state treatment,
  any error that fails silently instead of surfacing something to the user.
- **Consistency**: a fix or pattern that exists on one screen but was never applied to its
  siblings (exactly the wordmark bug's shape — check every shared component's *other*
  call sites once you fix one instance).

If you exhaust that and still have capacity, only then consider the optional, already-
documented, non-blocking item: **cut a new TestFlight build**. A lot has shipped since the
last one (arcade leaderboards, team colors, Spanish localization, and now this session's
three fixes) with nobody external able to see any of it. Use the `testflight-release` skill
— don't rebuild its cloud-signing workaround from scratch — and check the App Store Connect
review status first (submitted for full review as of 2026-07-05 per §8; confirm whether
that's still pending, approved, or needs a fresh submission). This is genuinely optional and
should not crowd out the audit work above; do it last if at all.

## Explicitly out of scope — do not build

- Phase F rating seasons (backlog #7) — deferred, ask first if it seems relevant.
- M5 Phase B monetization — blocked on a human-only ASC step.
- Anything requiring the user's Apple Developer portal access, a physical device, or two
  simultaneous TestFlight accounts (QA checklist stays a hand-off).
- Don't silently "fix" the deliberate product-taste calls logged in the 2026-07-14 color
  audit (`SpinRevealView`'s volt motif, `DraftSpinResultView`'s share-card stripe, WhoAmI's
  content model) — those were explicit decisions, not gaps.

## Key decisions / working style

- Follow `AGENTS.md`'s decision ladder (§11) before adding anything new: does it need to
  exist, is it already in the codebase, does stdlib/SwiftUI/Foundation already do it, is
  there an existing shared table/component to extend (§4/§10) — in that order.
- Test after every logically-complete change, not in one batch at the end (§7): `xcodebuild
  ... test` (Swift) and `.venv/bin/python -m pytest tools/ingest/tests -q` (Python) both
  complete in well under a second once built — there's no cost excuse to skip this.
- Additive Supabase schema/data changes and CLI-run data pushes are pre-authorized per
  `CLAUDE.md` — run them directly. Destructive operations (`drop table`, `delete`,
  revoking RLS) still need to be asked about first.
- Respect blast radius (§8): a new scoped fix following an established pattern (like the
  Wordmark toolbar helper) is fair game to just ship; anything that would widen who can see
  the app externally (TestFlight groups, App Store submission) needs explicit confirmation.

## Deliverables

Not a report — a punch list of real fixes, each:
- Committed as its own logical commit (or a small tightly-related group), with a message
  that states the "why," matching this repo's existing commit style.
- Verified: both test suites green, and for any UI change, a before/after screenshot of the
  specific state that was broken (not just "build succeeded").
- If a finding is a product-taste call rather than an unambiguous bug (e.g. "should X open a
  detail view?"), flag it in your final summary rather than guessing — don't silently ship a
  judgment call that could go either way.

## Verification

- `xcodebuild -project BallIQ.xcodeproj -scheme BallIQ -destination 'platform=iOS Simulator,name=iPhone 17' build test` — green.
- `.venv/bin/python -m pytest tools/ingest/tests -q` — green, if any ingest-side change.
- Screenshot-confirm every UI fix in the simulator (see `BallIQ/DebugLaunch.swift` for the
  `-screenshotX` flags that jump straight to a given tab/screen without manual navigation).

## Hand-offs (cannot be done by you)

- Anything flagged as a product-taste call in your deliverables — needs the user's decision.
- The two-account TestFlight QA pass (`prompts/QA-testflight-social-flows.md`).
- APNs key material / Apple Developer portal confirmation (push notifications).
- Paid Applications agreement + IAP product creation in ASC (M5 Phase B).
