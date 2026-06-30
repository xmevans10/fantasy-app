# M4 — Social retention: Leagues, Versus, Stats, Push

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Goal

Turn BallIQ from a solo daily game into a competitive, sticky one by shipping the retention engine
from the product brief: **weekly Leagues** (cohorts with promotion/relegation), **async Versus 1v1**,
the **Stats** tab (rating history + breakdowns), and **push notifications**. These are the strongest
daily-retention drivers — players should have a reason to come back multiple times a day to defend a
league position, answer a challenge, or protect a streak.

## Why now

M2 gives us identity + synced per-user progression, and M3 gives real, shared daily content — both
prerequisites for multiplayer to be meaningful. The `Leagues`, `Versus`, and `Stats` tabs currently
exist only as "Coming soon" placeholders (`PlaceholderView` in `ContentView.swift`).

## Current state to build on

- Auth + per-user rows (M2): `profiles`, `ratings`, `rating_history`, `progress` with RLS; `RemoteSync`
  pulls/pushes via `SupabaseClient`. Rating history is already recorded on every game → the Stats graph
  is mostly a read.
- Shared daily puzzles (M3) mean two players can be served the *same* puzzle deterministically — the
  basis for fair Versus and league scoring.
- Design system "Prime Time" + `RepositoryContainer` are the integration points. New tabs replace the
  placeholders.

## Scope

1. **Stats tab** (smallest, do first): rating-over-time graph per sport (Swift Charts, reading
   `rating_history`), format accuracy breakdown, current/best streaks, totals. Mostly reads.
2. **Weekly Leagues:** users grouped into **cohorts of ~30** at similar rating at week start; weekly
   **XP** (not rating) ranks them; **top 5 promote, bottom 5 relegate** next week. Live cohort table,
   promotion/relegation zones, season countdown. Pseudonymous (username + avatar only).
3. **Async Versus 1v1:** challenge by username or quick-match by rating (±150); both play the *same*
   daily puzzle independently; compare on completion (or 24h forfeit); **7-challenge head-to-head
   series**; Versus tab with pending/active/results.
4. **Push notifications (APNs):** streak-at-risk (8pm local if unplayed), league position change,
   versus challenge received, season-end approaching. Max 2/day/user, per-category settings.

## Key decisions (recommend, then confirm)

- **Server-side scheduled logic is required** (cohort rollover, weekly XP reset, series timeouts,
  season reset). Use **Supabase Edge Functions + `pg_cron`**. Keep the client thin; it reads cohort
  standings and writes XP/challenge results through RLS-guarded tables.
- **New tables** (extend `supabase/schema.sql`, with RLS): `usernames`/extend `profiles`; `seasons`;
  `cohorts` + `cohort_members` (weekly XP); `versus_challenges` + `versus_series`. Weekly XP is
  separate from lifetime XP and from rating. Cohort assignment + rollover run server-side.
- **Push transport:** APNs. Decide between (a) Supabase + a small sender (Edge Function calling APNs
  with the user's device token) or (b) a managed push service. APNs needs an **APNs key + the Push
  Notifications capability** (user-side Apple Developer setup) — surface as a hand-off. Device tokens
  stored per user (RLS).
- **Matchmaking + cohorting** are batch jobs, not realtime — simplest correct version first.

## Approach (outline)

1. Stats tab end-to-end (Swift Charts off `rating_history`) — fast win, exercises remote reads.
2. Schema + RLS for seasons/cohorts/versus; Edge Functions for weekly cohort assignment + rollover.
3. Leagues tab: read cohort standings, surface promotion/relegation zones + countdown; weekly XP
   written on game completion via `RepositoryContainer.complete(...)`.
4. Versus: challenge/quick-match flow, same-puzzle play, result comparison, series tracking.
5. Push: register device token, store per user; Edge Functions/cron fire the scheduled categories;
   per-category settings in Profile.

## Deliverables

- Three real tabs (Stats, Leagues, Versus) in the Prime Time style, replacing the placeholders.
- Schema + RLS + Edge Functions/cron for cohorts, seasons, versus, and the push senders.
- Per-category notification settings; device-token registration.

## Verification / success criteria

- Two test accounts: both land in a cohort; weekly XP updates a live standings table; a simulated
  week rollover promotes/relegates correctly (test the rollover function directly).
- A Versus challenge between the two accounts on the same daily puzzle compares results and advances a
  head-to-head series; 24h-incomplete forfeits.
- Stats graph renders real rating history (screenshot, light + dark).
- A scheduled notification category fires against a test token (or is unit-tested at the
  payload-builder level).
- All existing tests green; new server logic + any client pure-logic tested.

## Hand-offs (cannot be done by the agent)

- APNs key + Push Notifications capability on the App ID (Apple Developer account).
- Enabling/scheduling Edge Functions + `pg_cron` in the Supabase project; any related secrets.
