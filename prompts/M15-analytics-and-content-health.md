# M15 — Analytics & content health

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Status update (2026-07-02): shipped.

First-party path, as recommended: `events` table + insert-only RLS (M15 section of
`supabase/schema.sql`, **unapplied — hand-off**), `BallIQ/Backend/AnalyticsClient.swift`
(fire-and-forget, mirrors `SupabaseClient`), 8-event vocabulary wired at the funnel points
(onboarding, sign-in, game start/complete, publish, community/deep-link play, share, report).
Content health: `tools/ingest/health.py` writes `tools/ingest/content_health.json` on every
run including `--dry-run`. Queries: [docs/ANALYTICS.md](../docs/ANALYTICS.md). No dashboard/UI
was built, per the file's own don't-over-build guidance.

## Goal

Give the app eyes. Right now there is no analytics SDK, no event table, and no way to answer basic
questions — which format do people actually finish, where does onboarding lose people, is the
community feed growing, are any daily themes producing puzzles nobody plays — without manually
querying Supabase by hand. Build a minimal, privacy-conscious event pipeline and a content-health
view over the pipeline's own output.

## Why now

Every prior milestone added a new surface (Leagues, Versus, Community, scoring-kind badges) on
instinct and code review, with no way to check whether any of it is actually used. That's fine
early; it stops being fine once monetization (M5) and growth work (M12/M13) are live — you can't
price a Pro tier or judge a search feature's impact without baseline numbers to compare against.
This milestone should land *before or alongside* those, not after.

## Current state to build on

- `RepositoryContainer.complete(...)` is already the single choke point every finished game passes
  through (XP/streak/rating) — the natural place to also emit a `game_completed` event without
  duplicating call sites across `Keep4GameView`/`WhoAmIGameView`.
- `RemoteSync` and the various repositories already establish the pattern for a Supabase table +
  RLS + a thin Swift write path (`SupabaseClient.insert`) — an `events` table follows the exact same
  shape, no new infrastructure class needed.
- The ingest pipeline already computes rich per-theme pool stats internally (`assemble.py`) that
  never leave the pipeline run's stdout — a natural source for the content-health side without
  needing new instrumentation.
- Hard constraint from `prompts/README.md`: no third-party SDK dependencies beyond what's already
  vendored — this pushes toward a **first-party events table**, not a Firebase/Amplitude/Mixpanel
  integration, consistent with the rest of the app's hand-rolled backend approach.

## Scope

1. **First-party event pipeline.** A `supabase/schema.sql` `events` table (user_id nullable for
   signed-out play, event_name, properties jsonb, created_at) with an insert-only RLS policy (any
   authenticated or anonymous request can insert their own event, nobody can read others' — this is
   telemetry, not a social feature). A thin `AnalyticsClient` in `BallIQ/Backend/` mirroring
   `SupabaseClient`'s existing shape. Fire-and-forget, best-effort (never block or fail a user action
   on an analytics write — mirror `recordCommunityPlay`'s `try?` pattern).
2. **Core funnel events.** Onboarding completed, sign-in completed, game started/completed (per
   format + ranked/unranked), puzzle published, puzzle played from Community/Browse/deep-link, share
   tapped, report filed (once M12 ships). Keep the event vocabulary small and deliberate — a handful
   of well-chosen events beats instrumenting every tap.
3. **Content-health surface.** Surface the pipeline's own pool/coverage stats somewhere durable —
   at minimum, have `assemble.py` write a `content_health.json`/log artifact per run (pool size per
   theme, seasons excluded by min-stat floors, era-baseline coverage gaps) instead of only printing
   to stdout during `--dry-run`. Whether this needs an in-app or web view is a scope call — recommend
   starting with a structured artifact + a documented query, not a new UI, unless the user wants one.
4. **A minimal retention/funnel query set.** Documented SQL (in the spec or a new
   `docs/ANALYTICS.md`) for the handful of questions that actually matter right now: day-1/day-7
   retention, format completion rate, community publish→play conversion. Not a dashboard product —
   just answerable questions.

## Key decisions (recommend, then confirm)

- First-party table over a third-party SDK — confirm this matches the user's expectations (some
  teams want Amplitude/PostHog regardless of the "no SPM" constraint; that would mean a raw HTTP
  client instead of a dependency, which is still buildable within the existing constraints if
  actually wanted).
- Whether content-health needs any UI at all right now, or whether a structured log artifact +
  documented queries is sufficient for a single-operator app — don't over-build a dashboard nobody
  asked for.
- Privacy: no PII beyond what's already collected (user id, which the app already has via auth);
  no location, device fingerprinting, or third-party data sharing.

## Deliverables

- `events` table + RLS + `AnalyticsClient`, wired into the funnel points listed in Scope item 2.
- `assemble.py` content-health artifact per pipeline run.
- Documented retention/funnel/content-coverage queries.

## Verification / success criteria

- Playing through the app (onboarding → game → publish → share) produces the expected event rows,
  verifiable via a Supabase query.
- A pipeline `--dry-run` produces the content-health artifact with correct pool-size figures,
  cross-checked against a known theme's actual output.
- Analytics writes never block or visibly fail a user action if the network call fails (test by
  simulating a write failure — same resilience pattern as `CommunityFeedTests`' failed-fetch case).
- All existing tests green.

## Hand-offs (cannot be done by the agent)

- None expected for the first-party path. If a third-party SDK is chosen instead, its account/API
  key setup is a hand-off.
