# M12 — Trust & safety: community moderation

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Status update (2026-07-02, later session): the policy half shipped too — M12 is code-complete.

Auto-hide lands as a `SECURITY DEFINER` trigger in the M12 section of `supabase/schema.sql`
(3 distinct reporters flips `visibility` to `'hidden'`; a per-user unique index stops one
account crossing the threshold alone), with RLS so hidden puzzles stay visible to their author
and to admins only, and reports become readable by reporter/admin. The review surface is the
in-app `ModerationQueueView` (Profile → Moderation, gated by a new `profiles.is_admin` flag):
restore (clears reports + re-publishes), hide, remove. Pure grouping/threshold logic is
`ModerationPolicy` + `ModerationPolicyTests`. **Remaining hand-offs:** run the updated
`schema.sql` against the live project, and grant `is_admin` to the operator account
(`update public.profiles set is_admin = true where id = '<uuid>';`). The stretch author-mute
item was not built.

## Original status update (2026-07-02): the report UI shipped. This file now covers what's left — the policy half.

A follow-up pass (task-tracked as "[Sonnet 5] Wire the community report button to the existing
repo method") built the report **UI**: an overflow icon on every Community feed card and in both
game-view headers, a `.confirmationDialog` reason picker (spam/offensive/inaccurate/other, with a
free-text follow-up for "other"), a `Haptics.success()` + "Report sent" confirmation alert, and a
shared `BallIQ/DesignSystem/ReportReasonDialog.swift` modifier so the 4-reason list isn't
duplicated across `CommunityView`/`Keep4GameView`/`WhoAmIGameView`. It was verified live in the
simulator (tap → dialog → reason → confirmation, hit-testing confirmed not to conflict with the
card's primary tap-to-play). **Scope items 1 below is done — do not rebuild it.** What's left is
the *policy* half: nothing currently reads `community_reports`, there's no auto-hide, and there's
no review surface. A reported puzzle today is filed and then never looked at again.

## Goal

Close the loop the report UI opened: once a puzzle is reported enough times, take it out of the
public feed (without deleting it) and make it visible to someone who can review it. Right now
`community_reports` fills up with real user reports that nothing reads.

## Why now

Community publishing (M6/M10) is a real growth surface, and it now has a way for users to flag bad
content — but flagging with no consequence is worse than no reporting at all: it trains users that
reporting does nothing. This is a pre-growth requirement, not a nice-to-have — cheap to fix now,
expensive after the feed has real traffic and a backlog of ignored reports.

## Current state to build on

- **Report UI: done** (see status note above). `CommunityPuzzleRepository.report(id:userID:reason:)`
  writes real rows into `community_reports` today; `reason` is free-form text from the reason
  picker (`"spam"` / `"offensive"` / `"inaccurate"` / user-typed free text for "other").
- `community_reports` (schema.sql) has RLS policy `"reports insert own"` restricting writes to the
  reporting user. **No `select`/review policy exists yet** — nothing can currently read the table
  back out, including the operator, short of a raw SQL query.
- `CommunityPuzzleRepository.feed(...)` is the query every visibility decision flows through — the
  natural place for an auto-hide filter to plug in (it already filters on `visibility eq.public`,
  see `Data/Repositories/CommunityPuzzleRepository.swift`).
- Author identity is already resolved for display (`authors: [String: String]` in `CommunityView`,
  `CommunityPuzzleRepository.authorNames`) — the same lookup pattern extends to a block/mute list
  if you build the stretch item.

## Scope

1. ~~Report UI~~ — **done, do not rebuild.**
2. **Auto-hide threshold.** Once a puzzle crosses N reports (pick a number — recommend low, e.g. 3,
   given the audience is small and false-positive cost is low), exclude it from the public feed
   query without deleting it, so a human can still review before anything is permanently lost.
   Simplest implementation: a computed/materialized `report_count` the feed's `visibility` filter
   checks, or a Postgres trigger that flips `visibility` once the threshold is crossed.
3. **Minimal review surface.** Reported/hidden puzzles need to be visible to *someone* who isn't
   just querying Postgres by hand. Given there's no web admin app in this repo, the pragmatic
   options are (recommend one, confirm with the user): (a) an in-app admin mode gated by a
   `profiles.is_admin` flag + RLS, visible only to the operator's own account; (b) a documented SQL
   query for now, deferring a real admin UI. Don't over-build a full admin dashboard for a
   single-operator app — match effort to actual need.
4. **Author-level mute (stretch, only if time allows).** Let a user hide all future puzzles from a
   specific author in their own feed — client-side filter against a local block list is sufficient;
   doesn't need a server round-trip.

## Key decisions (recommend, then confirm)

- Auto-hide threshold and the exact review-surface approach (in-app admin mode vs. documented SQL)
  need explicit user confirmation before building — this is a product/ops call, not a technical one.
- Don't delete reported content automatically; hiding is reversible, deletion isn't.

## Deliverables

- Auto-hide-on-threshold behavior, server-enforced (RLS/trigger, not just client-side filtering).
- Whatever review surface was agreed in Key Decisions, wired to actually read `community_reports`.
- A `select`/review RLS policy on `community_reports` (currently insert-only).

## Verification / success criteria

- Reporting a puzzle N times (via the now-live report UI) removes it from `feed()` results for
  other users but the author (and the review surface) can still see it.
- A puzzle under threshold remains fully visible and playable.
- New tests: report-threshold logic (pure, testable independent of the network layer, same pattern
  as `CommunityFeedTests`).
- All existing tests green.

## Hand-offs (cannot be done by the agent)

- Deciding the actual report threshold and moderation policy (a product/legal judgment call).
- If an `is_admin`-gated surface is chosen: granting that flag to the operator's own account.
- Applying any RLS/trigger migration to the live Supabase project needs authorized MCP access or
  the Supabase dashboard — not available from a non-interactive session.
